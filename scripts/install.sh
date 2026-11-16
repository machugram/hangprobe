#!/usr/bin/env bash
# One-command install for Hangprobe (MIT). Builds the CLI from source on this Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/machugram/hangprobe/main/scripts/install.sh | bash
#
# Optional:
#   PREFIX=~/.local bash scripts/install.sh
#   REPO_URL=... INSTALL_APP=1 bash scripts/install.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/machugram/hangprobe.git}"
REF="${REF:-main}"
PREFIX="${PREFIX:-/usr/local}"
INSTALL_APP="${INSTALL_APP:-0}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: $1 is required." >&2
    exit 1
  }
}

need git
need swift

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: Hangprobe installs on macOS only." >&2
  exit 1
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

echo "==> Cloning ${REPO_URL} (${REF})"
git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${TMP}/hangprobe"
cd "${TMP}/hangprobe"

echo "==> Building hangprobe (release)"
swift build -c release --product hangprobe

BIN_DIR="${PREFIX}/bin"
mkdir -p "${BIN_DIR}"
install -m 755 .build/release/hangprobe "${BIN_DIR}/hangprobe"
echo "Installed ${BIN_DIR}/hangprobe"

if [[ "${INSTALL_APP}" == "1" ]]; then
  echo "==> Building Hangprobe.app"
  HANGPROBE_VERSION="$(swift run --skip-build hangprobe version 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  HANGPROBE_VERSION="${HANGPROBE_VERSION:-0.1.0}"
  scripts/release-macos.sh
  APP_SRC="dist/release/${HANGPROBE_VERSION}/Hangprobe.app"
  if [[ -d "${APP_SRC}" ]]; then
    APP_DEST="${HOME}/Applications"
    mkdir -p "${APP_DEST}"
    rm -rf "${APP_DEST}/Hangprobe.app"
    cp -R "${APP_SRC}" "${APP_DEST}/Hangprobe.app"
    echo "Installed ${APP_DEST}/Hangprobe.app"
    echo "Note: unsigned local build — right-click → Open the first time if Gatekeeper prompts."
  fi
fi

echo
echo "Done. Try:"
echo "  hangprobe version"
echo "  hangprobe ui"
echo "  hangprobe probe Finder"
