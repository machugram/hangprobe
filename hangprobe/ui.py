#!/usr/bin/env python3
"""Retired local page. The Mac window replaced it. The handler stays so the
old module still imports, and main no longer binds a port."""

from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from hangprobe.probe import ProbeError, list_apps, probe_hang

_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hangprobe</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: canvas;
    --text: canvastext;
    --muted: color-mix(in srgb, canvastext 64%, transparent);
    --line: color-mix(in srgb, canvastext 14%, transparent);
    --fill: color-mix(in srgb, canvastext 5%, canvas);
    --fill-2: color-mix(in srgb, canvastext 9%, canvas);
    --accent: color-mix(in srgb, canvastext 88%, canvas);
    --on-accent: canvas;
    --busy: color-mix(in srgb, #c2410c 78%, canvastext);
    --blocked: color-mix(in srgb, #a16207 78%, canvastext);
    --wait: color-mix(in srgb, #3f7cac 70%, canvastext);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  }
  main { max-width: 760px; margin: 0 auto; padding: 28px 20px 48px; }
  h1 { font-size: 22px; font-weight: 600; letter-spacing: -0.02em; margin: 0; }
  .lede { color: var(--muted); margin: 6px 0 20px; }
  form { display: flex; gap: 8px; align-items: end; flex-wrap: wrap; }
  label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--muted); }
  label.grow { flex: 1 1 220px; }
  input, select, button {
    font: inherit;
    color: var(--text);
    background: var(--fill);
    border: 1px solid var(--line);
    border-radius: 8px;
    height: 36px;
    padding: 0 10px;
  }
  input { width: 100%; }
  button.probe {
    background: var(--accent);
    color: var(--on-accent);
    border-color: transparent;
    padding: 0 14px;
    font-weight: 500;
  }
  button:disabled { opacity: 0.45; }
  h2 { font-size: 13px; font-weight: 600; margin: 28px 0 8px; }
  #apps { border: 1px solid var(--line); border-radius: 10px; max-height: 280px; overflow: auto; }
  #apps button {
    width: 100%;
    height: auto;
    text-align: left;
    border: 0;
    border-radius: 0;
    border-bottom: 1px solid var(--line);
    background: transparent;
    padding: 8px 12px;
    display: flex;
    gap: 10px;
    align-items: baseline;
  }
  #apps button:last-child { border-bottom: 0; }
  #apps button:hover, #apps button[aria-current="true"] { background: var(--fill-2); }
  .where { font-size: 12px; color: var(--muted); min-width: 72px; }
  .pid { margin-left: auto; font-variant-numeric: tabular-nums; color: var(--muted); font-size: 12px; }
  #result { margin-top: 22px; }
  .kind { font-size: 13px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; }
  .kind.busy { color: var(--busy); }
  .kind.blocked { color: var(--blocked); }
  .kind.responsive { color: var(--wait); }
  .gap { font-size: 28px; font-weight: 600; letter-spacing: -0.03em; margin: 4px 0 10px; }
  .gap span { font-size: 14px; font-weight: 400; color: var(--muted); }
  .bar { display: flex; height: 10px; border-radius: 99px; overflow: hidden; background: var(--fill-2); }
  .bar i { display: block; height: 100%; }
  .bar .busy { background: var(--busy); }
  .bar .blocked { background: var(--blocked); }
  .bar .wait { background: var(--wait); }
  .legend { display: flex; gap: 14px; margin: 8px 0 0; padding: 0; list-style: none; font-size: 12px; color: var(--muted); }
  .legend b { font-weight: 500; color: var(--text); }
  ol.stack {
    list-style: none;
    margin: 14px 0 0;
    padding: 10px 12px;
    border: 1px solid var(--line);
    border-radius: 10px;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 12px;
    line-height: 1.55;
    overflow-x: auto;
  }
  ol.stack li { white-space: nowrap; }
  .note, .error { color: var(--muted); font-size: 13px; margin: 8px 0 0; }
  .error { color: var(--busy); }
</style>
</head>
<body>
<main>
  <h1>Hangprobe</h1>
  <p class="lede">Sample a running Mac or Simulator app. A hang is main-thread time outside the UI event loop. Apple's floor for that is 250 ms.</p>
  <form id="probe">
    <label class="grow">App
      <input id="app" name="app" autocomplete="off" placeholder="Finder, Awtsyde, or a bundle id" required>
    </label>
    <label>Seconds
      <select id="seconds" name="seconds">
        <option value="1" selected>1</option>
        <option value="2">2</option>
        <option value="3">3</option>
      </select>
    </label>
    <label>Hang at
      <input id="threshold" name="threshold_ms" type="number" min="50" max="3000" value="250" style="width: 5.5rem">
    </label>
    <button class="probe" type="submit">Probe</button>
  </form>
  <p id="status" class="note" hidden></p>
  <h2>Running apps</h2>
  <div id="apps" role="list"></div>
  <section id="result" hidden aria-live="polite"></section>
</main>
<script>
const appInput = document.querySelector("#app");
const form = document.querySelector("#probe");
const appsEl = document.querySelector("#apps");
const resultEl = document.querySelector("#result");
const statusEl = document.querySelector("#status");
const submit = form.querySelector("button");

function setStatus(text) {
  statusEl.hidden = !text;
  statusEl.textContent = text || "";
}

async function loadApps() {
  const response = await fetch("/api/apps");
  const apps = await response.json();
  appsEl.replaceChildren();
  for (const item of apps) {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("aria-label", item.app + ", " + item.where);
    const where = document.createElement("span");
    where.className = "where";
    where.textContent = item.where;
    const name = document.createElement("span");
    name.textContent = item.app;
    const pid = document.createElement("span");
    pid.className = "pid";
    pid.textContent = String(item.pid);
    button.append(where, name, pid);
    button.addEventListener("click", () => {
      appInput.value = item.app;
      for (const other of appsEl.querySelectorAll("button")) other.removeAttribute("aria-current");
      button.setAttribute("aria-current", "true");
      form.requestSubmit();
    });
    appsEl.append(button);
  }
}

function segment(className, ms, total) {
  const node = document.createElement("i");
  node.className = className;
  node.style.width = total ? (ms / total * 100) + "%" : "0";
  return node;
}

function showReport(report) {
  resultEl.hidden = false;
  resultEl.replaceChildren();
  const kind = document.createElement("p");
  kind.className = "kind " + report.kind;
  kind.textContent = report.hung ? report.kind + " hang" : "responsive";
  const gap = document.createElement("p");
  gap.className = "gap";
  gap.append(document.createTextNode(report.main_gap_ms + " ms"));
  const aside = document.createElement("span");
  aside.textContent = " off the event loop, of " + report.window_ms + " ms";
  gap.append(aside);
  const bar = document.createElement("div");
  bar.className = "bar";
  bar.setAttribute("role", "img");
  bar.setAttribute("aria-label", "Main thread time: " + report.busy_ms + " ms busy, " + report.blocked_ms + " ms blocked, " + report.event_wait_ms + " ms waiting");
  const total = report.busy_ms + report.blocked_ms + report.event_wait_ms;
  bar.append(
    segment("busy", report.busy_ms, total),
    segment("blocked", report.blocked_ms, total),
    segment("wait", report.event_wait_ms, total)
  );
  const legend = document.createElement("ul");
  legend.className = "legend";
  for (const [label, ms] of [["Busy", report.busy_ms], ["Blocked", report.blocked_ms], ["Event wait", report.event_wait_ms]]) {
    const li = document.createElement("li");
    const strong = document.createElement("b");
    strong.textContent = label + " ";
    li.append(strong, document.createTextNode(ms + " ms"));
    legend.append(li);
  }
  resultEl.append(kind, gap, bar, legend);
  if (report.gap_at_least) {
    const note = document.createElement("p");
    note.className = "note";
    note.textContent = "The main thread never returned to the event loop, so the stall is at least this long.";
    resultEl.append(note);
  }
  const meta = document.createElement("p");
  meta.className = "note";
  meta.textContent = report.app + " · pid " + report.pid + " · " + report.where + " · " + report.samples + " samples";
  resultEl.append(meta);
  if (report.stack && report.stack.length) {
    const list = document.createElement("ol");
    list.className = "stack";
    for (const frame of report.stack) {
      const li = document.createElement("li");
      li.textContent = frame;
      list.append(li);
    }
    resultEl.append(list);
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  submit.disabled = true;
  setStatus("Sampling the main thread…");
  try {
    const response = await fetch("/api/probe", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        app: appInput.value.trim(),
        seconds: Number(document.querySelector("#seconds").value),
        threshold_ms: Number(document.querySelector("#threshold").value)
      })
    });
    const body = await response.json();
    if (!response.ok) {
      resultEl.hidden = false;
      resultEl.replaceChildren();
      const error = document.createElement("p");
      error.className = "error";
      error.textContent = body.error || "Probe failed.";
      resultEl.append(error);
      return;
    }
    showReport(body);
  } catch (error) {
    resultEl.hidden = false;
    resultEl.replaceChildren();
    const node = document.createElement("p");
    node.className = "error";
    node.textContent = "The page could not reach the local probe.";
    resultEl.append(node);
  } finally {
    submit.disabled = false;
    setStatus("");
  }
});

loadApps().catch(() => setStatus("Could not list running apps."));
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            body = _PAGE.encode()
            self._send(200, "text/html; charset=utf-8", body)
            return
        if path == "/api/apps":
            self._send(200, "application/json", json.dumps(list_apps()).encode())
            return
        self._send(404, "text/plain", b"Not found")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/api/probe":
            self._send(404, "text/plain", b"Not found")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > 8192:
            self._send(400, "application/json", b'{"error":"Request is too large."}')
            return
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send(400, "application/json", b'{"error":"Expected JSON."}')
            return
        if not isinstance(payload, dict):
            self._send(400, "application/json", b'{"error":"Expected an object."}')
            return
        app = payload.get("app")
        seconds = payload.get("seconds", 1)
        threshold = payload.get("threshold_ms", 250)
        try:
            report = probe_hang(app, seconds=seconds, threshold_ms=threshold)
        except ProbeError as exc:
            self._send(400, "application/json", json.dumps({"error": str(exc)}).encode())
            return
        self._send(200, "application/json", json.dumps(report).encode())

    def _send(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


def main(argv):
    del argv
    sys.stderr.write(
        "The page has been retired. Open the Mac window with:\n"
        "  swift run hangprobe ui\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
