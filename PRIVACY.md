# Hangprobe Privacy

Hangprobe is a **local** main-thread hang desk tool. It is built to stay on your Mac.

## What stays on your machine

- Live samples via `/usr/bin/sample` and `adb` run on your desk.
- Hang reports and history are stored under `~/Library/Application Support/Hangprobe/`.
- The Mac studio app and CLI do **not** embed crash reporters, analytics SDKs, or session RUM.

## Network

- **Default:** nothing phones home.
- **Phone Inbox (`hangprobe inbox` / desk listener):** accepts hang JSON on **loopback (`127.0.0.1`)** by default. Use `--bind all` only on trusted networks. Prefer `--token` / `HANGPROBE_INBOX_TOKEN` so `POST`/`GET /v1/hangs` require a shared secret.
- Device watchdogs (`oss/HangprobeKit`, Android watchdog) only emit to the URL **you** configure (typically your Mac inbox).

## License

Hangprobe is MIT open source. There are no license keys, purchase flows, or telemetry tied to entitlement state.

## Contact

Questions about data handling: open an issue on the Hangprobe repository or email the address listed on the product site when published.
