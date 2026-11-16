#!/usr/bin/env python3
"""MCP server with one tool, probe_hang.

Speaks newline-delimited JSON and Content-Length framing. Logs stay on stderr.
"""

from __future__ import annotations

import json
import sys

from hangprobe.probe import ProbeError, probe_hang

_PREFERRED = "2025-06-18"

_TOOL = {
    "name": "probe_hang",
    "title": "Probe a running app for a hang",
    "description": (
        "Sample a running Mac or iOS Simulator app and report whether its main "
        "thread is hung. Pass app as a pid, a bundle id, or a process name "
        "such as Finder. Omit app to probe the only user app "
        "in the booted Simulator. hung means the main thread spent at least "
        "threshold_ms outside the UI event loop during the sample: kind busy is "
        "on-CPU work such as a layout loop, kind blocked is a lock or sleep. "
        "main_gap_ms is that time. gap_at_least means the thread never returned "
        "to the event loop, so the stall is at least as long as the sample and "
        "may have started earlier. stack is the heaviest main-thread leaf. "
        "Sampling pauses the process for about a second. A physical iPhone is "
        "not a local process and cannot be sampled this way."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "app": {
                "type": "string",
                "description": "Pid, bundle id, or process name. Omit for the booted Simulator app.",
            },
            "seconds": {
                "type": "integer",
                "minimum": 1,
                "maximum": 3,
                "description": "How long to sample. Default 1.",
            },
            "threshold_ms": {
                "type": "integer",
                "minimum": 50,
                "maximum": 3000,
                "description": "Off-loop main-thread time that counts as a hang. Default 250.",
            },
        },
    },
}

_FIELDS = frozenset({"app", "seconds", "threshold_ms"})


class Server:
    def __init__(self):
        self.initialized = False

    def handle(self, message):
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return _error(_message_id(message), -32600, "invalid request")
        method = message.get("method")
        if not isinstance(method, str):
            return _error(_message_id(message), -32600, "invalid request")
        if method.startswith("notifications/"):
            if method == "notifications/initialized":
                self.initialized = True
            return None
        if "id" not in message:
            return None
        request_id = message["id"]
        if method == "initialize":
            params = message.get("params") if isinstance(message.get("params"), dict) else {}
            requested = params.get("protocolVersion")
            version = requested if isinstance(requested, str) and len(requested) == 10 else _PREFERRED
            self.initialized = True
            return _result(
                request_id,
                {
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "hangprobe", "version": "1"},
                    "instructions": (
                        "Call probe_hang while the screen is up. Pass the app name, "
                        "bundle id, or pid. Read hung, kind, main_gap_ms, and stack."
                    ),
                },
            )
        if method == "ping":
            return _result(request_id, {})
        if not self.initialized:
            return _error(request_id, -32600, "server not initialized")
        if method == "tools/list":
            return _result(request_id, {"tools": [_TOOL]})
        if method == "tools/call":
            return _result(request_id, _call(message.get("params")))
        return _error(request_id, -32601, "method not found")


def serve(stdin, stdout) -> None:
    server = Server()
    reader = _Reader(stdin)
    while True:
        try:
            incoming = reader.read_message()
        except json.JSONDecodeError:
            _write(stdout, _error(None, -32700, "parse error"), reader.framing or "line")
            continue
        if incoming is None:
            return
        message, framing = incoming
        response = server.handle(message)
        if response is not None:
            _write(stdout, response, framing)


def _call(params):
    if not isinstance(params, dict):
        return _tool_error("Invalid tool call.")
    if params.get("name") != "probe_hang":
        return _tool_error("Unknown tool.")
    arguments = params.get("arguments", {})
    if not isinstance(arguments, dict):
        return _tool_error("Arguments must be an object.")
    extra = sorted(set(arguments) - _FIELDS)
    if extra:
        return _tool_error("Rejected unknown fields: %s." % ", ".join(extra))
    app = arguments.get("app")
    seconds = arguments.get("seconds", 1)
    threshold = arguments.get("threshold_ms", 250)
    if app is not None and not isinstance(app, str):
        return _tool_error("app must be a string.")
    try:
        report = probe_hang(app, seconds=seconds, threshold_ms=threshold)
    except ProbeError as exc:
        return _tool_error(str(exc))
    text = json.dumps(report, indent=2, ensure_ascii=True)
    return {
        "content": [{"type": "text", "text": text}],
        "structuredContent": report,
        "isError": False,
    }


class _Reader:
    def __init__(self, stream):
        self.stream = stream
        self.buf = b""
        self.framing = None

    def read_message(self):
        while True:
            if not self.buf:
                chunk = self.stream.read(4096)
                if not chunk:
                    return None
                self.buf += chunk
            if self.buf[:1] in (b"\r", b"\n"):
                self.buf = self.buf.lstrip(b"\r\n")
                continue
            if self.buf[:1] == b"{":
                if b"\n" not in self.buf:
                    chunk = self.stream.read(4096)
                    if not chunk:
                        return None
                    self.buf += chunk
                    continue
                line, _, rest = self.buf.partition(b"\n")
                self.buf = rest
                self.framing = "line"
                return json.loads(line.strip()), "line"
            return self._read_lsp()

    def _read_lsp(self):
        while b"\r\n\r\n" not in self.buf:
            chunk = self.stream.read(4096)
            if not chunk:
                return None
            self.buf += chunk
        header, _, rest = self.buf.partition(b"\r\n\r\n")
        self.buf = rest
        length = None
        for line in header.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        if length is None:
            raise json.JSONDecodeError("missing Content-Length", "", 0)
        while len(self.buf) < length:
            chunk = self.stream.read(length - len(self.buf))
            if not chunk:
                return None
            self.buf += chunk
        body, self.buf = self.buf[:length], self.buf[length:]
        self.framing = "lsp"
        return json.loads(body), "lsp"


def _write(stdout, payload, framing) -> None:
    body = json.dumps(payload, ensure_ascii=True).encode()
    if framing == "lsp":
        stdout.write(b"Content-Length: %d\r\n\r\n" % len(body))
        stdout.write(body)
    else:
        stdout.write(body + b"\n")
    stdout.flush()


def _result(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def _tool_error(message):
    return {"content": [{"type": "text", "text": message}], "isError": True}


def _message_id(message):
    if isinstance(message, dict) and "id" in message:
        return message["id"]
    return None


if __name__ == "__main__":
    serve(sys.stdin.buffer, sys.stdout.buffer)
