#!/usr/bin/env bash
# Exports the MIT `oss/` device-SDK subtree to a standalone hangprobe-sdk checkout.
# Blocks HangprobeCore/HangprobeApp imports and verifies `swift build` on the export.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OSS_DIR="${REPO_ROOT}/oss"
DEST="${1:-}"

if [[ -z "${DEST}" ]]; then
  echo "Usage: scripts/export-oss.sh <path-to-public-hangprobe-sdk-repo>" >&2
  exit 2
fi

if rg -n "import HangprobeCore|import HangprobeApp" "${OSS_DIR}/HangprobeKit" "${OSS_DIR}/android"; then
  echo "ERROR: HangprobeCore/HangprobeApp import detected inside oss/! Aborting export." >&2
  exit 1
fi

mkdir -p "${DEST}"
rsync -a --delete --exclude '.git' --exclude '.build' --exclude '.swiftpm' "${OSS_DIR}/" "${DEST}/"

swift build --package-path "${DEST}" >/dev/null
echo "Exported MIT hangprobe-sdk tree to ${DEST} (standalone swift build verified)."
