#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$(mktemp -d -t micbridge-release-smoke.XXXXXX)"
cleanup() {
  rm -rf "$OUT_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

echo "[validate-release] Packaging release artifacts"
./scripts/package-release.sh --output-dir "$OUT_DIR" >/dev/null

source "$ROOT_DIR/version.env"
ARCHIVE="$OUT_DIR/MicBridge-${MARKETING_VERSION}-macos.tar.gz"
SHA="$ARCHIVE.sha256"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Missing archive: $ARCHIVE" >&2
  exit 1
fi
if [[ ! -f "$SHA" ]]; then
  echo "Missing checksum: $SHA" >&2
  exit 1
fi

echo "[validate-release] Validating internal updater behavior"
./scripts/validate-internal-update.sh \
  --archive "$ARCHIVE" \
  --checksum "$SHA" \
  --version "$MARKETING_VERSION" >/dev/null

echo "[validate-release] OK"
