"""Open the page, probe one app, or speak MCP."""

from __future__ import annotations

import sys

from hangprobe.mcp import serve
from hangprobe.probe import main as probe_main
from hangprobe.ui import main as ui_main

_HELP = """hangprobe — the Python probe is still here. The page has been retired.

  swift run hangprobe ui               open the Mac window
  swift run hangprobe probe [app]      print one sample as JSON
  swift run hangprobe mcp              speak MCP on stdin

  python3 -m hangprobe probe [app]     the same probe, in Python
  python3 -m hangprobe mcp             the Python MCP server

probe accepts --seconds 1|2|3 and --threshold-ms 250.
A physical iPhone is not a process on this Mac.
"""


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    if not argv:
        if sys.stdin.isatty():
            return ui_main([])
        sys.stdout.write(_HELP)
        return 0
    command, rest = argv[0], argv[1:]
    if command in ("-h", "--help"):
        sys.stdout.write(_HELP)
        return 0
    if command == "ui":
        return ui_main(rest)
    if command == "probe":
        return probe_main(rest)
    if command == "mcp":
        if rest:
            sys.stderr.write("mcp takes no arguments.\n")
            return 2
        serve(sys.stdin.buffer, sys.stdout.buffer)
        return 0
    sys.stderr.write("Unknown command %s.\n%s" % (command, _HELP))
    return 2


if __name__ == "__main__":
    sys.exit(main())
