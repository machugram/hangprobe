# Hangprobe device SDKs (`oss/`)

MIT-licensed, zero-dependency debug watchdogs and wire schema. Part of the full MIT Hangprobe repo — this subtree is packaged for easy vendoring.

- **iOS / macOS (`HangprobeKit`):** ~250 lines of auditable Swift. Compiles to a zero-allocation no-op in Release builds. Pings `DispatchQueue.main` and posts a `HangReport` JSON payload when the main run loop fails to answer within `250 ms`.
- **Android (`android/HangprobeAndroidWatchdog.kt`):** Single Kotlin file watching `Looper.getMainLooper()` for `>= 250 ms` UI stalls while labeling `>= 5,000 ms` ANRs separately.
- **Wire Schema (`schema/hang-report.schema.json`):** Canonical JSON payload accepted by `hangprobe inbox` (`POST /v1/hangs`).

## Add via Swift Package Manager

Point Xcode or `Package.swift` at this repository (or an exported `oss/` tree):

```swift
.package(url: "https://github.com/machugram/hangprobe.git", from: "0.1.0")
```

```swift
import HangprobeKit

// Inside App.init() — automatically stripped in Release builds:
HangprobeWatchdog.shared.start(
    config: HangprobeWatchdogConfig(
        endpoint: URL(string: "http://127.0.0.1:9481/v1/hangs")!,
        thresholdMS: 250
    )
)
```

MIT License — see [LICENSE](LICENSE).
