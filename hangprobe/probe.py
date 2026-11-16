#!/usr/bin/env python3
"""Probe a running app for a main-thread hang.

`sample` stops the process a few times a second and records every thread.
The main thread of a live app spends that time in the UI run loop
(`__CFRunLoopServiceMachPort` → `mach_msg2_trap`). Time anywhere else is the
hang: a layout loop stays on CPU, and a lock or sleep parks off the run loop.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

_BUNDLE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.\-]{1,220}$")
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._\-]{0,80}$")
_TREE = " \t+|!:"
_INTERVAL = re.compile(r"every (\d+) milliseconds")
_OFFSET = re.compile(r"\s+\+\s+[0-9].*$")

# The run loop's own wait. A lock taken while a source is running sits under
# __CFRunLoopDoSources / __CFRUNLOOP_IS_CALLING_OUT and is a blocked hang.
_SERVICE = (
    "__CFRunLoopServiceMachPort",
    "_CFRunLoopServiceMachPort",
    "ReceiveNextEventCommon",
    "_BlockUntilNextEventMatchingListInMode",
    "_DPSBlockUntilNextEventMatchingListInMode",
    "GSEventRunModal",
)
_CALLED_OUT = (
    "__CFRUNLOOP_IS_CALLING_OUT",
    "__CFRunLoopDoSources",
    "__CFRunLoopDoBlocks",
    "__CFRunLoopDoObservers",
    "__CFRunLoopDoTimers",
)
_WAIT = (
    "mach_msg_trap",
    "mach_msg2_trap",
    "semaphore_wait_trap",
    "kevent",
    "kevent64",
    "__psynch_cvwait",
    "__psynch_mutexwait",
    "__semwait_signal",
    "ulock_wait",
    "nanosleep",
    "__select",
    "poll",
)


class ProbeError(Exception):
    pass


class _Node:
    def __init__(self, depth: int, count: int, symbol: str):
        self.depth = depth
        self.count = count
        self.symbol = symbol
        self.children = []


def probe_hang(app=None, seconds=1, threshold_ms=250):
    """Sample `app` and return a hang report.

    `app` is a pid, a bundle id, or a process name. Omit it to sample the only
    user app running in the booted Simulator.
    """

    seconds = _seconds(seconds)
    threshold_ms = _threshold(threshold_ms)
    target = resolve(None if app in (None, "", "booted", "simulator") else str(app))
    text = _sample(target.pid, seconds)
    report = classify_report(text, threshold_ms)
    report["pid"] = target.pid
    report["app"] = target.name
    report["bundle_id"] = target.bundle_id
    report["where"] = target.where
    return report


class Target:
    def __init__(self, pid, name, where, bundle_id=None):
        self.pid = pid
        self.name = name
        self.where = where
        self.bundle_id = bundle_id


def resolve(app):
    if app is None:
        return _only_simulator_app()
    if isinstance(app, int) or (isinstance(app, str) and app.isdigit()):
        return _target_for_pid(int(app))
    if not isinstance(app, str) or "\n" in app or "\x00" in app:
        raise ProbeError("app must be a pid, bundle id, or process name.")
    if _BUNDLE.match(app) and "." in app:
        return _resolve_bundle(app)
    if not _NAME.match(app):
        raise ProbeError("app must be a pid, bundle id, or process name.")
    return _resolve_name(app)


def classify_report(text, threshold_ms):
    interval = _interval(text)
    root = _main_thread(text)
    leaves = list(_leaves(root, ()))
    accounted = 0
    busy = blocked = waiting = 0
    tagged = []
    for weight, chain in leaves:
        kind = _leaf_kind(chain)
        tagged.append((kind, weight, chain))
        accounted += weight
        if kind == "busy":
            busy += weight
        elif kind == "blocked":
            blocked += weight
        else:
            waiting += weight
    # A truncated tree would otherwise look idle. Count the missing samples
    # as time on the CPU.
    missing = root.count - accounted
    if missing > 0:
        busy += missing
    busy_ms = busy * interval
    blocked_ms = blocked * interval
    wait_ms = waiting * interval
    off_loop = busy_ms + blocked_ms
    if off_loop >= threshold_ms and blocked_ms >= busy_ms:
        kind = "blocked"
    elif off_loop >= threshold_ms:
        kind = "busy"
    else:
        kind = "responsive"
    if kind == "responsive":
        chosen = _heaviest(tagged, None)
    elif kind == "blocked":
        chosen = _heaviest(tagged, "blocked") or _heaviest(tagged, None)
    else:
        chosen = _heaviest(tagged, "busy") or _heaviest(tagged, None)
    stack = _display_stack(chosen[2]) if chosen else []
    return {
        "hung": kind != "responsive",
        "kind": kind,
        "main_gap_ms": off_loop,
        "gap_at_least": waiting == 0 and root.count > 0,
        "busy_ms": busy_ms,
        "blocked_ms": blocked_ms,
        "event_wait_ms": wait_ms,
        "window_ms": root.count * interval,
        "threshold_ms": threshold_ms,
        "samples": root.count,
        "top": _leaf_label(stack[-1]) if stack else "",
        "stack": stack,
    }


def _seconds(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 3:
        raise ProbeError("seconds must be 1, 2, or 3.")
    return value


def _threshold(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 50 <= value <= 3000:
        raise ProbeError("threshold_ms must be between 50 and 3000.")
    return value


def _sample(pid, seconds):
    path = None
    try:
        with tempfile.NamedTemporaryFile(prefix="hangprobe-", suffix=".txt", delete=False) as handle:
            path = handle.name
        completed = subprocess.run(
            ["sample", str(pid), str(seconds), "10", "-mayDie", "-file", path],
            capture_output=True,
            text=True,
            timeout=seconds + 60,
        )
    except subprocess.TimeoutExpired as exc:
        raise ProbeError("sample did not finish within a minute.") from exc
    finally:
        text = ""
        if path and Path(path).exists():
            text = Path(path).read_text(errors="replace")
            Path(path).unlink(missing_ok=True)
    if "com.apple.main-thread" not in text:
        detail = (completed.stderr or completed.stdout or "").strip()
        if not detail:
            detail = "sample recorded no main thread."
        raise ProbeError(detail.splitlines()[-1][:500])
    return text


def _interval(text):
    match = _INTERVAL.search(text)
    if not match:
        raise ProbeError("sample report has no interval.")
    return int(match.group(1))


def _main_thread(text):
    start = text.find("Call graph:")
    if start < 0:
        raise ProbeError("sample report has no call graph.")
    end = text.find("Total number in stack", start)
    if end < 0:
        end = len(text)
    roots = []
    stack = []
    for line in text[start:end].splitlines():
        parsed = _parse_line(line)
        if parsed is None:
            continue
        depth, count, symbol = parsed
        node = _Node(depth, count, symbol)
        while stack and stack[-1].depth >= depth:
            stack.pop()
        if stack:
            stack[-1].children.append(node)
        else:
            roots.append(node)
        stack.append(node)
    for node in roots:
        if "com.apple.main-thread" in node.symbol:
            return node
    raise ProbeError("sample report has no main thread.")


def _parse_line(line):
    index = 0
    while index < len(line) and line[index] in _TREE:
        index += 1
    end = index
    while end < len(line) and line[end].isdigit():
        end += 1
    if end == index or (end < len(line) and line[end] not in " \t"):
        return None
    return index, int(line[index:end]), line[end:].strip()


def _leaves(node, ancestors):
    chain = ancestors + (node.symbol,)
    if not node.children:
        yield node.count, chain
        return
    child_total = sum(child.count for child in node.children)
    if node.count > child_total:
        yield node.count - child_total, chain
    for child in node.children:
        yield from _leaves(child, chain)


def _leaf_kind(chain):
    leaf = _leaf_label(chain[-1])
    if leaf in _WAIT and _in_run_loop_wait(chain):
        return "event"
    if leaf in _WAIT:
        return "blocked"
    return "busy"


def _in_run_loop_wait(chain):
    for symbol in reversed(chain):
        if any(marker in symbol for marker in _CALLED_OUT):
            return False
        if any(marker in symbol for marker in _SERVICE):
            return True
    return False


def _heaviest(tagged, kind):
    best = None
    for item in tagged:
        if kind is not None and item[0] != kind:
            continue
        if best is None or item[1] > best[1]:
            best = item
    return best


def _display_stack(chain):
    frames = []
    for symbol in chain:
        short = _short(symbol)
        label = _leaf_label(short)
        if label in {"start", "???"} or label.startswith("Thread_"):
            continue
        frames.append(short)
    if not frames:
        frames = [_short(chain[-1])]
    return frames[-16:]


def _leaf_label(symbol):
    return _short(symbol).split(" (in ")[0].strip()


def _short(symbol):
    text = _OFFSET.sub("", symbol).strip()
    return re.sub(r"\s{2,}", " ", text)


_RECORD = re.compile(r'^\s*\d+\)\s+"')
_PID = re.compile(r"pid = (\d+)")
_TYPE = re.compile(r'type="([^"]+)"')
_BUNDLE_ID = re.compile(r'bundleID="([^"]+)"')
_EXE = re.compile(r'executable path="([^"]+)"')


def list_apps():
    """Foreground Mac apps, plus user apps running in the Simulator."""

    found = []
    seen = set()
    try:
        listing = subprocess.check_output(["lsappinfo", "list"], text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        listing = ""
    for item in _foreground_from_lsappinfo(listing):
        seen.add(item["pid"])
        found.append(item)
    for pid, command in _processes():
        executable = command.split(" ", 1)[0]
        if "CoreSimulator/Devices/" not in executable:
            continue
        if ".app/" not in executable or ".appex/" in executable:
            continue
        if pid in seen:
            continue
        seen.add(pid)
        found.append({
            "pid": pid,
            "app": executable.rsplit("/", 1)[-1],
            "bundle_id": None,
            "where": "simulator",
        })
    found.sort(key=lambda item: (item["where"] != "simulator", item["app"].lower()))
    return found


def _foreground_from_lsappinfo(text):
    found = []
    current = None

    def flush():
        if not current:
            return
        if current.get("kind") != "Foreground" or current.get("terminated"):
            return
        if not current.get("pid") or not current.get("app"):
            return
        found.append({
            "pid": current["pid"],
            "app": current["app"],
            "bundle_id": current.get("bundle_id"),
            "where": "mac",
        })

    for line in text.splitlines():
        if _RECORD.match(line):
            flush()
            current = {"terminated": False}
            continue
        if current is None:
            continue
        if "executable path=" in line:
            match = _EXE.search(line)
            if match:
                current["app"] = match.group(1).rsplit("/", 1)[-1]
        if "bundleID=" in line:
            match = _BUNDLE_ID.search(line)
            if match:
                current["bundle_id"] = match.group(1)
        if "pid =" in line:
            if "terminated" in line:
                current["terminated"] = True
            match = _PID.search(line)
            if match:
                current["pid"] = int(match.group(1))
            kind = _TYPE.search(line)
            if kind:
                current["kind"] = kind.group(1)
    flush()
    return found


def _only_simulator_app():
    hits = []
    for pid, command in _processes():
        executable = command.split(" ", 1)[0]
        if "CoreSimulator/Devices/" not in executable:
            continue
        if ".app/" not in executable or ".appex/" in executable:
            continue
        hits.append((pid, executable))
    if not hits:
        raise ProbeError(
            "No user app is running in the Simulator. Pass app as a bundle id, name, or pid."
        )
    if len(hits) > 1:
        listed = ", ".join("%s (%s)" % (pid, executable.rsplit("/", 1)[-1]) for pid, executable in hits)
        raise ProbeError("More than one Simulator app is running: %s. Pass app." % listed)
    pid, executable = hits[0]
    return Target(pid, executable.rsplit("/", 1)[-1], "simulator")


def _resolve_name(name):
    hits = []
    for pid, command in _processes():
        executable = command.split(" ", 1)[0]
        if executable.rsplit("/", 1)[-1] == name:
            hits.append((pid, executable))
    if not hits:
        raise ProbeError("No running process is named %s." % name)
    if len(hits) > 1:
        listed = ", ".join(str(pid) for pid, _ in hits)
        raise ProbeError("%s has more than one process: %s. Pass a pid." % (name, listed))
    pid, executable = hits[0]
    return Target(pid, name, _where(executable))


def _resolve_bundle(bundle_id):
    if _booted_simulators():
        info = _sim_appinfo(bundle_id)
        if info is not None:
            binary = info["path"].rstrip("/") + "/" + info["executable"]
            hits = [pid for pid, command in _processes() if command.split(" ", 1)[0] == binary]
            if not hits:
                raise ProbeError(
                    "%s (%s) is installed on the booted Simulator but not running."
                    % (info["name"], bundle_id)
                )
            if len(hits) > 1:
                raise ProbeError("%s has more than one process. Pass a pid." % bundle_id)
            return Target(hits[0], info["name"], "simulator", bundle_id)
    pid = _mac_pid(bundle_id)
    if pid is None:
        raise ProbeError("No running app has bundle id %s." % bundle_id)
    return _target_for_pid(pid, bundle_id)


def _target_for_pid(pid, bundle_id=None):
    for found, command in _processes():
        if found == pid:
            executable = command.split(" ", 1)[0]
            return Target(pid, executable.rsplit("/", 1)[-1], _where(executable), bundle_id)
    raise ProbeError("No process has pid %s." % pid)


def _where(executable):
    if "CoreSimulator/Devices/" in executable:
        return "simulator"
    return "mac"


def _processes():
    raw = subprocess.check_output(["ps", "-axww", "-o", "pid=,command="], text=True)
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        if pid_text.isdigit() and command:
            yield int(pid_text), command.strip()


def _booted_simulators():
    completed = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "booted", "-j"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    if completed.returncode != 0:
        return []
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return []
    found = []
    for devices in payload.get("devices", {}).values():
        for device in devices:
            if device.get("state") == "Booted":
                found.append(device.get("udid") or device.get("name"))
    return found


def _sim_appinfo(bundle_id):
    listed = subprocess.run(
        ["xcrun", "simctl", "appinfo", "booted", bundle_id],
        capture_output=True,
        timeout=20,
    )
    if listed.returncode != 0:
        return None
    converted = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", "-"],
        input=listed.stdout,
        capture_output=True,
        timeout=20,
    )
    if converted.returncode != 0:
        raise ProbeError("simctl appinfo for %s was not a plist." % bundle_id)
    data = json.loads(converted.stdout)
    if isinstance(data.get(bundle_id), dict):
        data = data[bundle_id]
    path = data.get("Path") or ""
    if path.startswith("file://"):
        path = path[7:]
    executable = data.get("CFBundleExecutable") or ""
    if not path or not executable:
        raise ProbeError("simctl appinfo for %s has no executable path." % bundle_id)
    name = data.get("CFBundleDisplayName") or data.get("CFBundleName") or executable
    return {"path": path, "executable": executable, "name": name}


def _mac_pid(bundle_id):
    script = (
        'tell application "System Events" to unix id of first process '
        'whose bundle identifier is "%s"' % bundle_id
    )
    completed = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if completed.returncode != 0:
        return None
    text = completed.stdout.strip()
    if text.isdigit():
        return int(text)
    return None


def main(argv):
    app = None
    seconds = 1
    threshold = 250
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--seconds":
            index += 1
            seconds = int(argv[index])
        elif arg == "--threshold-ms":
            index += 1
            threshold = int(argv[index])
        elif arg.startswith("-"):
            print("Usage: hangprobe probe [app] [--seconds 1] [--threshold-ms 250]", file=sys.stderr)
            return 2
        elif app is None:
            app = arg
        else:
            print("Usage: hangprobe probe [app] [--seconds 1] [--threshold-ms 250]", file=sys.stderr)
            return 2
        index += 1
    try:
        report = probe_hang(app, seconds=seconds, threshold_ms=threshold)
    except (ProbeError, IndexError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
