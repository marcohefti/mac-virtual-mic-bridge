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
./scripts/package-cask-assets.sh --output-dir "$OUT_DIR" >/dev/null

source "$ROOT_DIR/version.env"
ARCHIVE="$OUT_DIR/MicBridge-${MARKETING_VERSION}-macos.tar.gz"
SHA="$ARCHIVE.sha256"
APP_ZIP="$OUT_DIR/MicBridge-${MARKETING_VERSION}.zip"
APP_ZIP_SHA="$APP_ZIP.sha256"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Missing archive: $ARCHIVE" >&2
  exit 1
fi
if [[ ! -f "$SHA" ]]; then
  echo "Missing checksum: $SHA" >&2
  exit 1
fi
if [[ ! -f "$APP_ZIP" ]]; then
  echo "Missing app zip: $APP_ZIP" >&2
  exit 1
fi
if [[ ! -f "$APP_ZIP_SHA" ]]; then
  echo "Missing app zip checksum: $APP_ZIP_SHA" >&2
  exit 1
fi

ARCHIVE_SHA_EXPECTED="$(awk '{print $1}' "$SHA")"
ARCHIVE_SHA_ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ -z "$ARCHIVE_SHA_EXPECTED" || "$ARCHIVE_SHA_EXPECTED" != "$ARCHIVE_SHA_ACTUAL" ]]; then
  echo "Archive checksum mismatch for $ARCHIVE" >&2
  exit 1
fi

APP_SHA_EXPECTED="$(awk '{print $1}' "$APP_ZIP_SHA")"
APP_SHA_ACTUAL="$(shasum -a 256 "$APP_ZIP" | awk '{print $1}')"
if [[ -z "$APP_SHA_EXPECTED" || "$APP_SHA_EXPECTED" != "$APP_SHA_ACTUAL" ]]; then
  echo "App zip checksum mismatch for $APP_ZIP" >&2
  exit 1
fi

echo "[validate-release] Validating internal updater behavior"
./scripts/validate-internal-update.sh \
  --archive "$ARCHIVE" \
  --checksum "$SHA" \
  --version "$MARKETING_VERSION" >/dev/null

echo "[validate-release] OK"
