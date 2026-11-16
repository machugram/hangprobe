# ADR 0002: Borrow the High-Signal Android Mechanics & Build a Fast Desk-First macOS UX

- **Status:** Accepted
- **Date:** 2026-11-12
- **Deciders:** Hangprobe maintainers
- **Builds on:** [ADR 0001](./0001-hang-first-mobile-apm.md)

## Context

Reviewing the Android and iOS diagnostics ecosystem revealed why single-snapshot ANR tools frustrate developers—and which specific mechanics actually solve hangs:

1. **Single-snapshot traces lie about transient stalls.** Datadog (`dd-sdk-android` #2316) and Luciq ANR v1 take a single main-thread snapshot when a watchdog trips; by that millisecond the culprit method may already have unwound. **Embrace** solves this by taking **repeated `100 ms` main-thread samples** across the stall window and ranking the hottest frames. We can bring multi-sample burst probing (`3–5` rapid `debuggerd -b` snapshots over the `1–3s` probe window) directly to zero-SDK `adb` probing so Android gets real `busy_ms` / `blocked_ms` / `event_wait_ms` ratios and frame frequency hotspots—just like `/usr/bin/sample` on macOS.
2. **Android 11+ already keeps ground-truth fatal ANRs on the device.** **Firebase Crashlytics**, **Luciq v2**, and **Google Play Android Vitals** rely on `ApplicationExitInfo` (`REASON_ANR`), which matches Google Play's `0.47%` bad-behavior threshold—except developers normally have to wait for the next app launch or 24–48h Play Console ingestion. Over `adb`, `dumpsys activity exit-info [package]` exposes those exact historical `REASON_ANR` records immediately at the desk with zero SDK.
3. **Perfetto & Instruments fail on ergonomics, not data.** Engineers hate scrolling past 14 `CoreFoundation` / `AppKit` / `Looper` / `Zygote` frames to find the one line of app code (`SportProfileEditorView.body.getter` or `CatalogRepository.loadBlocking`), and they hate losing track of whether their fix actually reduced `main_gap_ms` across runs.
4. **Flipper's death proved desktop companions must be instant, native, and zero-bloat.** A developer utility on macOS succeeds when it feels like **Proxyman** (`⌘R` to probe, instant filter bar, system/app frame folding, one-click Markdown/JSON export, and a clean visual verdict), not an Electron browser tab.

## Decision

### 1. Mechanics We Borrow into `HangprobeCore` (Zero Cloud SDK Required)

| Source Platform | Mechanic We Keep | What We Leave Behind | Implementation in Hangprobe |
|---|---|---|---|
| **Embrace** | Multi-sample main-thread burst across the stall window + frame hotspot frequency (`hits / samples`) | Production session SDK & `$0.80 / 1k` session meter | `AndroidDevices.probe` runs a timed burst of `debuggerd -b` snapshots across `seconds`, computing true `busy_ms`, `blocked_ms`, `event_wait_ms`, and `hotspots: [FrameHotspot]` |
| **Crashlytics / Play Vitals** | Android 11+ `ApplicationExitInfo` (`REASON_ANR`) ground-truth exit records + severity awareness (`250 ms` hang vs `5,000 ms` Play ANR) | Waiting 24–48h or next-session cloud upload | `AndroidExitInfoParser` + `hangprobe appexit [package]` (and toolbar action in Mac app) pulls `adb shell dumpsys activity exit-info` directly into the Phone Inbox |
| **Perfetto** | Explicit thread-state & layer tagging (`App`, `Lock / Contention`, `UI Framework`, `RunLoop / Looper`, `Kernel`) | Multi-gigabyte protobuf timelines for simple freezes | `FrameInspector` classifies every stack frame by layer and extracts lock/contention hints (`__psynch_mutexwait`, `waiting to lock <0x...>`, `dispatch_sync`) |
| **Bugsnag** | Clear threshold health badges (`Healthy < 250 ms`, `Apple Hang >= 250 ms`, `Severe >= 1,000 ms`, `Android Play ANR Risk >= 5,000 ms`) | Per-event billing tiers | `HangSeverity` computed directly on `HangReport` and surfaced in the Mac verdict header and CLI gate |

### 2. Native macOS App (`HangprobeApp`) UX & Visual Architecture

Replace the bare form-and-plain-text detail pane with a structured, keyboard-driven three-zone workspace:

1. **Sidebar — Unified Filterable Target & Inbox Navigator**
   - Instant search field (`⌘F` / sidebar filter) matching process name, bundle/package ID, or PID.
   - Grouped sections with platform badges (`Simulator`, `Mac`, `Android adb`, and `Phone & ExitInfo Inbox`) plus live status pill when the `:9481` Bonjour `_hangprobe._tcp` inbox listener is active.
   - Quick actions in sidebar/toolbar: **Pull Android ExitInfo ANRs**, **Import MXHang JSON**, **Listen `:9481`**, **Reload Targets**.

2. **Top Deck — Action Bar & Verdict Hero Card**
   - Always-reachable controls: `1s / 2s / 3s` segmented window, preset threshold chips (`100 ms` strict, `250 ms` Apple floor, `500 ms`), primary **Probe (`⌘R`)**, **Watch (`⇧⌘W`)**, and **10s Worst (`⌥⌘R`)** buttons with live sampling progress indicator.
   - **Verdict Hero Card:** color-coded status badge (`RESPONSIVE`, `BUSY — CPU LOOP`, `BLOCKED — LOCK / WAIT`), large tabular `main_gap_ms` readout, `HangSeverity` callout (including `5s Play Vitals ANR` vs `250 ms` hang distinction), **Culprit App Frame** spotlight card with copy-symbol button, and a labeled proportional **Time Breakdown Bar** (`Busy` orange, `Blocked` red, `Event Loop Wait` green).

3. **Bottom Deck — Segmented Stack & History Inspector**
   - **App Focus (default):** collapses contiguous system/run-loop boilerplate into quiet disclosure pills (`6 system frames`) so the developer's own frames and lock wait leaf stand out immediately with layer badges (`APP`, `LOCK`, `UI`, `KERNEL`).
   - **Full Stack:** numbered leaf-to-root or root-to-leaf monospaced trace with inline search/highlight and one-click `Copy Markdown` / `Save JSON`.
   - **Hotspots:** ranked frame frequency bars (`% of samples`) across the sample tree or multi-burst `adb` capture (Embrace-style flame summary without flame-graph clutter).
   - **Before / After & Trend:** visual run-over-run `main_gap_ms` sparkline strip from `ProbeStore` on disk plus structured frame diff (`Frames Gone` in green, `Frames Added` in amber) so engineers immediately verify their fix worked.

## Consequences

- **Positive:** Android `adb` probes stop being single-frame guesses and become timed multi-sample reports with real off-loop durations; Android 11+ `REASON_ANR` history works offline in one click; and the Mac app now reads the culprit frame in under two seconds instead of dumping raw `libsystem_kernel` text.
- **Negative / Trade-off:** A `1s` Android burst probe executes `4–5` rapid `debuggerd -b` calls over USB/emulator `adb` (adding modest `adb` shell overhead compared to a single dump), so we cap burst samples cleanly to the requested `seconds` budget and fall back to single-dump `kill -3` traces when `debuggerd` is restricted on non-debuggable builds.
