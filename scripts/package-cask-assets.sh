#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/version.env"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing version file: $VERSION_FILE" >&2
  exit 1
fi
source "$VERSION_FILE"

if [[ -z "${MARKETING_VERSION:-}" ]]; then
  echo "version.env must define MARKETING_VERSION" >&2
  exit 1
fi

OUTPUT_DIR="$ROOT_DIR/dist"
APP_NAME="MicBridge"

usage() {
  cat <<'USAGE'
Usage: ./scripts/package-cask-assets.sh [options]

Build cask-distribution app artifacts:
- MicBridge.app
- MicBridge-<version>.zip
- MicBridge-<version>.zip.sha256

Options:
  --output-dir <dir>    Output directory (default: ./dist)
  --app-name <name>     App name used by package-app (default: MicBridge)
  --help                Show help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

"$ROOT_DIR/scripts/package-app.sh" \
  --output-dir "$OUTPUT_DIR" \
  --app-name "$APP_NAME" \
  --repo-root "" >/dev/null

APP_ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-${MARKETING_VERSION}.zip"
APP_ZIP_SHA_PATH="$APP_ZIP_PATH.sha256"

if [[ ! -f "$APP_ZIP_PATH" ]]; then
  echo "Missing packaged app zip: $APP_ZIP_PATH" >&2
  exit 1
fi

shasum -a 256 "$APP_ZIP_PATH" > "$APP_ZIP_SHA_PATH"

echo "[package-cask-assets] Created:"
echo "  $APP_ZIP_PATH"
echo "  $APP_ZIP_SHA_PATH"
