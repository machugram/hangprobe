# Contributing

Hangprobe is MIT. Patches welcome.

## Develop

```bash
swift build
swift test
swift run hangprobe ui
swift run hangprobe probe Finder
```

## Boundaries

- Keep the whole repo MIT — no paid feature gates.
- `oss/` stays a thin device SDK (no `import HangprobeCore` / `HangprobeApp`).
- Prefer small, reviewable PRs with a test when behavior changes.

## Release

1. Bump `HangprobeVersion.marketing` if needed.
2. Tag `vX.Y.Z` and push — `.github/workflows/release.yml` builds artifacts.
3. Update `Formula/hangprobe.rb` `sha256` from the GitHub source tarball.
4. Optional notarized `.app`: `SIGN=1` with a **Developer ID Application** identity.
