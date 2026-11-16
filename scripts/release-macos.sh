#!/usr/bin/env bash
# Build Hangprobe release artifacts (MIT; ADR 0003).
# Optional Developer ID sign + notarytool when SIGN=1 and Apple credentials are set.
#
#   scripts/release-macos.sh
#   SIGN=1 APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=... scripts/release-macos.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

VERSION="${HANGPROBE_VERSION:-0.1.0}"
OUT="${REPO_ROOT}/dist/release/${VERSION}"
rm -rf "${OUT}"
mkdir -p "${OUT}/bin" "${OUT}/Hangprobe.app/Contents/MacOS" "${OUT}/Hangprobe.app/Contents/Resources/Fonts"

echo "==> Building release products (arm64)"
swift build -c release --arch arm64 --product hangprobe
swift build -c release --arch arm64 --product HangprobeApp

ARM_ROOT="${REPO_ROOT}/.build/arm64-apple-macosx/release"
ARM_CLI="${ARM_ROOT}/hangprobe"
ARM_APP="${ARM_ROOT}/HangprobeApp"
ARM_BUNDLE="${ARM_ROOT}/Hangprobe_HangprobeApp.bundle"
# SPM may also mirror into .build/release on some toolchains.
if [[ ! -x "${ARM_CLI}" && -x "${REPO_ROOT}/.build/release/hangprobe" ]]; then
  ARM_CLI="${REPO_ROOT}/.build/release/hangprobe"
  ARM_APP="${REPO_ROOT}/.build/release/HangprobeApp"
  ARM_BUNDLE="${REPO_ROOT}/.build/release/Hangprobe_HangprobeApp.bundle"
fi

echo "==> Attempting x86_64 companions for universal binaries"
X86_ROOT="${REPO_ROOT}/.build/x86_64-apple-macosx/release"
X86_CLI=""
X86_APP=""
if swift build -c release --arch x86_64 --product hangprobe && swift build -c release --arch x86_64 --product HangprobeApp; then
  [[ -x "${X86_ROOT}/hangprobe" ]] && X86_CLI="${X86_ROOT}/hangprobe"
  [[ -x "${X86_ROOT}/HangprobeApp" ]] && X86_APP="${X86_ROOT}/HangprobeApp"
fi

lipo_or_copy() {
  local arm="$1" x86="$2" dest="$3"
  if [[ -n "${x86}" && -x "${x86}" ]]; then
    lipo -create -output "${dest}" "${arm}" "${x86}"
    echo "    universal $(basename "${dest}")"
  else
    echo "    WARN: arm64-only $(basename "${dest}")" >&2
    cp "${arm}" "${dest}"
  fi
  chmod +x "${dest}"
}

lipo_or_copy "${ARM_CLI}" "${X86_CLI}" "${OUT}/bin/hangprobe"
lipo_or_copy "${ARM_APP}" "${X86_APP}" "${OUT}/Hangprobe.app/Contents/MacOS/Hangprobe"
if [[ -d "${ARM_BUNDLE}" ]]; then
  cp -R "${ARM_BUNDLE}" "${OUT}/Hangprobe.app/Contents/MacOS/"
fi
if [[ -d "${REPO_ROOT}/assets/fonts" ]]; then
  cp "${REPO_ROOT}/assets/fonts/"*.otf "${OUT}/Hangprobe.app/Contents/Resources/Fonts/" 2>/dev/null || true
  cp "${REPO_ROOT}/assets/fonts/OFL-IBM-Plex.txt" "${OUT}/Hangprobe.app/Contents/Resources/Fonts/" 2>/dev/null || true
fi
if [[ -f "${REPO_ROOT}/assets/AppIcon.icns" ]]; then
  cp "${REPO_ROOT}/assets/AppIcon.icns" "${OUT}/Hangprobe.app/Contents/Resources/AppIcon.icns"
fi

cat > "${OUT}/Hangprobe.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Hangprobe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.hangprobe.app</string>
  <key>CFBundleName</key><string>Hangprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "${SIGN:-0}" == "1" ]]; then
  IDENTITY="${CODESIGN_IDENTITY:-}"
  if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  fi
  if [[ -z "${IDENTITY}" ]]; then
    echo "ERROR: SIGN=1 but no Developer ID Application identity found." >&2
    exit 1
  fi
  echo "==> Codesigning with ${IDENTITY}"
  codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${OUT}/bin/hangprobe"
  codesign --force --deep --options runtime --timestamp --sign "${IDENTITY}" "${OUT}/Hangprobe.app"

  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "==> Notarizing Hangprobe.app"
    ZIP="${OUT}/Hangprobe-notarize.zip"
    ditto -c -k --keepParent "${OUT}/Hangprobe.app" "${ZIP}"
    xcrun notarytool submit "${ZIP}" \
      --apple-id "${APPLE_ID}" \
      --team-id "${APPLE_TEAM_ID}" \
      --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
      --wait
    xcrun stapler staple "${OUT}/Hangprobe.app"
    rm -f "${ZIP}"
  else
    echo "WARN: Skipping notarization (set APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD)." >&2
  fi
else
  echo "WARN: Unsigned build (SIGN=1 + Developer ID to sign)." >&2
fi

(
  cd "${OUT}"
  zip -qr "Hangprobe.app.zip" Hangprobe.app
  tar -czf "hangprobe-macos-universal.tar.gz" -C bin hangprobe
  shasum -a 256 Hangprobe.app.zip hangprobe-macos-universal.tar.gz > SHA256SUMS
)

echo "Release artifacts in ${OUT}"
ls -la "${OUT}"
