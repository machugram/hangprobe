#!/usr/bin/env python3
"""Parser and MCP framing checks. Live sampling is not required."""

from __future__ import annotations

import json
import sys
from io import BytesIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hangprobe import mcp as server
from hangprobe import probe

FIXTURES = Path(__file__).resolve().parent / "fixtures"

_LAYOUT = """Analysis of sampling Awtsyde every 10 milliseconds
Call graph:
    100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 100 start  (in dyld) + 1  [0x1]
    +   100 main  (in Awtsyde) + 1  [0x1]
    +     100 UIApplicationMain  (in UIKitCore) + 1  [0x1]
    +       100 GSEventRunModal  (in GraphicsServices) + 1  [0x1]
    +         100 CFRunLoopRunSpecific  (in CoreFoundation) + 1  [0x1]
    +           100 __CFRunLoopRun  (in CoreFoundation) + 1  [0x1]
    +             100 __CFRunLoopDoObservers  (in CoreFoundation) + 1  [0x1]
    +               100 CA::Transaction::commit()  (in QuartzCore) + 1  [0x1]
    +                 100 -[UIView layoutSubviews]  (in UIKitCore) + 1  [0x1]
    +                   100 SportProfileEditorView.body.getter  (in Awtsyde) + 1  [0x1]
Total number in stack (recursive counted multiple, when >=5):
"""

_DEADLOCK = """Analysis of sampling Awtsyde every 10 milliseconds
Call graph:
    80 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 80 start  (in dyld) + 1  [0x1]
    +   80 __CFRunLoopRun  (in CoreFoundation) + 1  [0x1]
    +     80 __CFRunLoopDoSources0  (in CoreFoundation) + 1  [0x1]
    +       80 __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__  (in CoreFoundation) + 1  [0x1]
    +         80 -[Store load]  (in Awtsyde) + 1  [0x1]
    +           80 pthread_mutex_lock  (in libsystem_pthread.dylib) + 1  [0x1]
    +             80 __psynch_mutexwait  (in libsystem_kernel.dylib) + 1  [0x1]
Total number in stack (recursive counted multiple, when >=5):
"""

_RESPONSIVE = """Analysis of sampling Awtsyde every 10 milliseconds
Call graph:
    100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 100 start  (in dyld) + 1  [0x1]
    +   100 UIApplicationMain  (in UIKitCore) + 1  [0x1]
    +     97 __CFRunLoopServiceMachPort  (in CoreFoundation) + 1  [0x1]
    +     ! 97 mach_msg2_trap  (in libsystem_kernel.dylib) + 1  [0x1]
    +     3 __CFRunLoopDoObservers  (in CoreFoundation) + 1  [0x1]
    +       3 -[UIView layoutSubviews]  (in UIKitCore) + 1  [0x1]
Total number in stack (recursive counted multiple, when >=5):
"""


def main():
    checks = [
        test_layout_loop,
        test_deadlock_inside_source,
        test_responsive_with_a_little_layout,
        test_busy_fixture,
        test_sleep_fixture,
        test_lock_fixture,
        test_finder_fixture,
        test_rejects_bad_window,
        test_newline_framing,
        test_content_length_framing,
        test_unknown_field,
        test_list_apps,
    ]
    for check in checks:
        check()
        print("ok", check.__name__)
    print("ok", len(checks))


def test_layout_loop():
    report = probe.classify_report(_LAYOUT, 250)
    assert report["hung"] is True
    assert report["kind"] == "busy"
    assert report["gap_at_least"] is True
    assert report["main_gap_ms"] == 1000
    assert report["event_wait_ms"] == 0
    assert report["top"] == "SportProfileEditorView.body.getter"
    assert "SportProfileEditorView.body.getter (in Awtsyde)" in report["stack"]


def test_deadlock_inside_source():
    report = probe.classify_report(_DEADLOCK, 250)
    assert report["hung"] is True
    assert report["kind"] == "blocked"
    assert report["blocked_ms"] == 800
    assert report["top"] == "__psynch_mutexwait"
    assert any("Store load" in frame for frame in report["stack"])


def test_responsive_with_a_little_layout():
    report = probe.classify_report(_RESPONSIVE, 250)
    assert report["hung"] is False
    assert report["kind"] == "responsive"
    assert report["event_wait_ms"] == 970
    assert report["busy_ms"] == 30
    assert report["main_gap_ms"] == 30
    assert report["top"] == "mach_msg2_trap"


def test_busy_fixture():
    report = probe.classify_report(_fixture("busy.txt"), 250)
    assert report["hung"] is True
    assert report["kind"] == "busy"
    assert report["blocked_ms"] == 0
    assert report["event_wait_ms"] == 0
    assert report["main_gap_ms"] >= 250
    assert report["samples"] == 92


def test_sleep_fixture():
    report = probe.classify_report(_fixture("sleep.txt"), 250)
    assert report["hung"] is True
    assert report["kind"] == "blocked"
    assert report["top"] == "__semwait_signal"
    assert any("time_sleep" in frame for frame in report["stack"])


def test_lock_fixture():
    report = probe.classify_report(_fixture("lock.txt"), 250)
    assert report["hung"] is True
    assert report["kind"] == "blocked"
    assert report["top"] == "__psynch_cvwait"
    assert any("_PyMutex_LockTimed" in frame for frame in report["stack"])


def test_finder_fixture():
    report = probe.classify_report(_fixture("finder.txt"), 250)
    assert report["hung"] is False, report
    assert report["kind"] == "responsive"
    assert report["event_wait_ms"] > report["main_gap_ms"]
    assert report["top"] == "mach_msg2_trap"


def test_rejects_bad_window():
    try:
        probe.classify_report("nope", 250)
    except probe.ProbeError:
        pass
    else:
        raise AssertionError("expected ProbeError")
    for seconds in (0, 4, True, 1.5):
        try:
            probe._seconds(seconds)
        except probe.ProbeError:
            continue
        raise AssertionError("accepted %r" % seconds)


def test_newline_framing():
    reply = _roundtrip(
        b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}\n'
        b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
        b'{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n'
        b'{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"probe_hang","arguments":{"app":"Finder"}}}\n'
    )
    assert reply[0]["result"]["serverInfo"]["name"] == "hangprobe"
    assert reply[1]["result"]["tools"][0]["name"] == "probe_hang"
    body = json.loads(reply[2]["result"]["content"][0]["text"])
    assert body == {"hung": False, "kind": "responsive", "app": "Finder"}


def test_content_length_framing():
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}
    ).encode()
    raw = b"Content-Length: %d\r\n\r\n" % len(payload) + payload
    out = BytesIO()
    server.serve(BytesIO(raw), out)
    text = out.getvalue()
    assert text.startswith(b"Content-Length:")
    body = text.split(b"\r\n\r\n", 1)[1]
    message = json.loads(body)
    assert message["result"]["protocolVersion"] == "2024-11-05"


def test_unknown_field():
    raw = (
        b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n'
        b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"probe_hang","arguments":{"nope":1}}}\n'
    )
    reply = _roundtrip(raw)
    assert reply[1]["result"]["isError"] is True


def test_list_apps():
    listing = """
53) "Simulator" ASN:0x0-1:
    bundleID="com.apple.iphonesimulator"
    executable path="/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"
    pid = 55077 type="Foreground" flavor=3 fileType="APPL"
56) "Finder" ASN:0x0-2:
    bundleID="com.apple.finder"
    executable path="/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    pid = 93736 type="Foreground" flavor=3 fileType="FNDR"
76) "Cursor Helper" ASN:0x0-3:
    bundleID="com.todesktop.helper"
    executable path="/Applications/Cursor.app/Contents/MacOS/Cursor Helper"
    pid = 20234 type="UIElement" flavor=2 fileType="APPL"
80) "Old" ASN:0x0-4:
    bundleID="com.example.old"
    executable path="/Applications/Old.app/Contents/MacOS/Old"
    pid = 4 (terminated) type="Foreground" flavor=3 fileType="APPL"
"""
    apps = probe._foreground_from_lsappinfo(listing)
    assert [(item["app"], item["pid"], item["bundle_id"]) for item in apps] == [
        ("Simulator", 55077, "com.apple.iphonesimulator"),
        ("Finder", 93736, "com.apple.finder"),
    ]
    live = probe.list_apps()
    assert isinstance(live, list)
    for item in live:
        assert set(item) >= {"pid", "app", "where"}
        assert item["where"] in {"mac", "simulator"}


def _roundtrip(raw):
    original = server.probe_hang
    server.probe_hang = lambda app=None, seconds=1, threshold_ms=250: {
        "hung": False,
        "kind": "responsive",
        "app": app,
    }
    try:
        out = BytesIO()
        server.serve(BytesIO(raw), out)
    finally:
        server.probe_hang = original
    return [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]


def _fixture(name):
    return (FIXTURES / name).read_text()


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print("FAIL", exc, file=sys.stderr)
        sys.exit(1)
