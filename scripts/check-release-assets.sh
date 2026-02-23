#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/version.env"

TAG="${1:-v${MARKETING_VERSION}}"
ARTIFACT_PREFIX="${2:-MicBridge}"

ARCHIVE_NAME="${ARTIFACT_PREFIX}-${MARKETING_VERSION}-macos.tar.gz"
SHA_NAME="${ARCHIVE_NAME}.sha256"
APP_ZIP_NAME="MicBridge-${MARKETING_VERSION}.zip"
APP_ZIP_SHA_NAME="${APP_ZIP_NAME}.sha256"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

ASSET_NAMES="$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null || true)"
if [[ -z "$ASSET_NAMES" ]]; then
  echo "No release assets found for tag $TAG" >&2
  exit 1
fi

if ! echo "$ASSET_NAMES" | grep -Fx "$ARCHIVE_NAME" >/dev/null; then
  echo "Missing asset on $TAG: $ARCHIVE_NAME" >&2
  exit 1
fi

if ! echo "$ASSET_NAMES" | grep -Fx "$SHA_NAME" >/dev/null; then
  echo "Missing asset on $TAG: $SHA_NAME" >&2
  exit 1
fi

if ! echo "$ASSET_NAMES" | grep -Fx "$APP_ZIP_NAME" >/dev/null; then
  echo "Missing asset on $TAG: $APP_ZIP_NAME" >&2
  exit 1
fi

if ! echo "$ASSET_NAMES" | grep -Fx "$APP_ZIP_SHA_NAME" >/dev/null; then
  echo "Missing asset on $TAG: $APP_ZIP_SHA_NAME" >&2
  exit 1
fi

echo "Release assets verified for $TAG:"
echo "  $ARCHIVE_NAME"
echo "  $SHA_NAME"
echo "  $APP_ZIP_NAME"
echo "  $APP_ZIP_SHA_NAME"
