# ADR 0001: Hang-First Mobile Diagnostics & Flat-Seat Phone APM (Not a Session-Metered RUM)

- **Status:** Accepted (Licensing §4 superseded by [ADR 0003](./0003-mit-open-source.md))
- **Date:** 2026-11-12
- **Deciders:** Hangprobe maintainers

## Context

Mobile engineers debugging freezes on macOS, iOS, and Android sit between two categories of tools that miss the daily workflow:

1. **Pre-recording desk profilers** (`Instruments` Time Profiler, `Android Studio CPU Profiler`, `Perfetto` at `ui.perfetto.dev`): accurate, free, and zero-SDK, but they require a recording session to be open *before* the screen freezes, cannot gate a CI script with an exit code, and are awkward for an AI coding agent over MCP.
2. **Fleet RUM / crash platforms** (`Datadog Mobile RUM`, `Sentry`, `Embrace`, `Bugsnag`, `Firebase Crashlytics`, `Luciq` / Instabug, `Google Play Android Vitals`, `Xcode Organizer`): built to aggregate production telemetry across thousands of customer devices, priced by **1,000 sessions**, **events**, **profile hours**, or **DAU**, and dependent on shipping an SDK plus keeping cloud symbolication (`dSYM`, `build_id` ProGuard/R8 maps, NDK `.so` symbols) in sync.

Specifically on Datadog Mobile RUM (verified 2026-11-12):
- **Pricing meters sessions, not hangs:** RUM Measure is `$0.15 / 1,000` sessions/mo, RUM Investigate is `$3.00 / 1,000` retained sessions/mo, and Session Replay is `$2.50 / 1,000` sessions/mo (annual list). At 10M monthly sessions with 10% retained for Investigate + Replay, a mobile team pays roughly `$7,000/mo` (`$84,000/yr`) while still debugging one frozen screen at a time.
- **Wrong primitive on mobile:** Apple defines a hang at `>= 250 ms` off the UI run loop (WWDC21 10181, WWDC22 10082). Android triggers an `ANR` around `5,000 ms` of blocked input dispatch (and Google Play penalizes titles above a `0.47%` user-perceived ANR rate). Datadog splits responsiveness across opt-in hang-rate seconds/hour, `700 ms` frozen frames, `100 ms` long tasks, and an Android watchdog task whose counts diverge from Play Console and whose snapshot stack trace may miss the root cause (`dd-sdk-android` #1067, #2316).
- **Cloud symbolication fragility:** when Gradle `build_id` tags or `dSYM` UUIDs drift across CI assemble/distribute steps, stacks arrive obfuscated (`dd-sdk-android-gradle-plugin` #283).

Meanwhile, syndicated "Mobile APM" TAM reports (`$4.6B` in 2025 per Dataintelo vs `$2.69B` in 2024 per Grand View Research) measure enterprise Dynatrace/New Relic/Datadog contracts, not developer desk tools.

## Decision

We will build and sell Hangprobe as **one canonical hang report** across **two doors**, and explicitly refuse to become a session-metered RUM suite.

### 1. Canonical Hang Report Contract
Every target (`mac`, `simulator`, `android`, `ios`) produces the same JSON payload:
- `hung` (`bool`), `kind` (`busy` | `blocked` | `responsive`)
- `main_gap_ms` (`int`), `gap_at_least` (`bool`), `busy_ms`, `blocked_ms`, `event_wait_ms`, `window_ms`, `threshold_ms` (default `250`)
- `top` (heaviest leaf symbol) and `stack` (last 16 cleaned frames, leading app frame surfaced first)
- `where` (`mac` | `simulator` | `android` | `ios`), `note` (explicitly labeling `~5s` Android ANRs separately from `250 ms` hangs), and optional `context` (`commit`, `screen`, `device`, `os`, `arch`, `load_address`)

### 2. Door 1 — Desk Probe (Zero SDK, Local Only)
- **macOS & iOS Simulator:** shells out to `/usr/bin/sample` (`10 ms` interval). Wait traps (`mach_msg2_trap`, `kevent`, etc.) under `__CFRunLoopServiceMachPort` count as `responsive` event wait; wait traps under `__CFRunLoopDoSources` / `__CFRUNLOOP_IS_CALLING_OUT` count as `blocked`; on-CPU frames count as `busy`.
- **Android over `adb`:** queries connected emulators and physical phones via `debuggerd -b <pid>` (with `kill -3` / `/data/anr/traces.txt` fallback). `android.os.Looper` / `MessageQueue.nativePollOnce` / `epoll_wait` is `responsive`; monitor contention / `futex` off `Looper` is `blocked`; runnable app frames are `busy`.
- **Agent & CI native:** `hangprobe probe` exits `1` when hung (`0` responsive, `2` error); `hangprobe gate` enforces `main_gap_ms` and delta budgets in CI; `hangprobe mcp` exposes `probe_hang` over stdio (`Content-Length` and newline JSON-RPC).

### 3. Door 2 — Phone Hang APM (Debug / QA / TestFlight First, Symbolicated Before Storage)
- **Debug-only watchdogs (`HangprobeKit` for iOS/macOS, `HangprobeAndroidWatchdog.kt` for Android):** compile to a no-op in Release builds by default. When the main run loop / `Looper` fails to answer within `250 ms`, emit the exact `HangReport` JSON to `hangprobe inbox` (`POST /v1/hangs`, Bonjour `_hangprobe._tcp`).
- **System hang import:** `hangprobe import <mxhang.json>` ingests Apple MetricKit `MXHangDiagnostic` payloads into the same report format (`ApplicationExitInfo` `REASON_ANR` tombstones follow the same path on Android 11+).
- **Build-Mac symbolication:** `atos -o App.dSYM -l <load_address>` and `ndk-stack` run on the developer's Mac or CI runner *before* a report is stored, eliminating cloud symbol-tag mismatches.

### 4. Packaging, Licensing, and Pricing
- **Entire product (CLI, MCP, Mac window, inbox, gate, device SDKs):** MIT open source — see [ADR 0003](./0003-mit-open-source.md).

### 5. Hard Cuts (What We Never Build)
- Always-on production session recording, session replay, heatmaps, or DAU/session billing meters.
- CPU tick vitals, memory gauges, `700 ms` frozen-frame scores, or crash-free rate executive dashboards.
- Live 3D view hierarchy inspection (`Lookin`, `Reveal`, Android Studio Layout Inspector).
- Unsolicited background agents on release-build customer iPhones.

## Landscape Considered (Including Android Ecosystem, Nov 2026)

| Tool | Android / iOS Role | Pricing Model (Nov 2026) | Gap Hangprobe Fills |
|---|---|---|---|
| **Android Studio Profiler & Perfetto** | App CPU/memory traces & system-wide kernel/Binder traces (`ui.perfetto.dev`) | `$0` | Must be recording before the hang; heavy trace UI when you only want one main-thread verdict + MCP |
| **Google Play Android Vitals** | Store-level ANR rate (`0.47%` bad-behavior threshold) & field traces | `$0` | 24–48h reporting lag; zero help reproducing a 300 ms hang on a local Pixel/emulator |
| **Firebase Crashlytics** | Crashes + Android 11+ `ApplicationExitInfo` ANRs | `$0` | Reports fatal ANRs on *next* app launch; does not catch sub-5s (`250–2,000 ms`) UI freezes |
| **Embrace** | Mobile- specialized RUM; 100 ms main-thread ANR flame graphs + Play correlation | Free to 1M sessions/yr; Pro `$0.80 / 1k` sessions (`$80/mo` min) | Session-metered cloud SDK; not a zero-SDK local Mac/adb/MCP probe |
| **Sentry** | Errors, ANRs, and continuous/UI profiling (`anrProfilingSampleRate`) | Team `$26/mo` (`$312/yr`) + `$0.25 / UI profile hr` | Metered profile hours + SDK integration required |
| **Bugsnag (SmartBear)** | Release stability score mapped to Play Vitals (`0.47%` ANR) + NDK/R8 | Free 7.5k events; Select from `$20/mo` (annual, 50k events) | Event-metered; post-5s ANR focus rather than live `250 ms` main-thread sampling |
| **Luciq (formerly Instabug)** | Crashes, ANR v1/v2 (`ExitInfo`), bug reporting, batched APM (6h default) | Enterprise sales-led (DAU + seats; self-serve deprecated) | No self-serve, enterprise DAU contract, 6h default APM batching |
| **Datadog Mobile RUM** | Enterprise cross-stack RUM, Mobile Vitals, Session Replay | `$0.15` Measure + `$3` Investigate + `$2.50` Replay per 1k sessions | Per-session meter + synthetic watchdog ANR discrepancies |
| **Flipper (Meta)** | Former desktop mobile debugger | Archived / deprecated | Left a vacuum for lightweight, zero-bloat desktop companion tools |

## Consequences

- **Positive:** One mental model and JSON schema from local reproduction (`sample` / `adb`) to CI (`hangprobe gate`) to agent verification (`probe_hang` MCP) to on-device QA (`HangprobeKit` / `HangprobeAndroidWatchdog`). Predictable flat pricing cannot spike during a traffic surge.
- **Negative / Trade-off:** Hangprobe will not replace Crashlytics, Play Vitals, or Organizer for fleet-wide crash-free percentages in the App Store or Google Play — and our documentation and FAQ state that upfront so buyers pair Hangprobe with free store vitals rather than paying `$7k/mo` for mobile RUM.
