#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVER_DIR="$ROOT_DIR/drivers/micbridge-hal"
BUILD_DIR="$DRIVER_DIR/build"
BUNDLE_DIR="$BUILD_DIR/MicBridge.driver"
BIN_DIR="$BUNDLE_DIR/Contents/MacOS"
RES_DIR="$BUNDLE_DIR/Contents"
SRC_FILE="$DRIVER_DIR/src/MicBridgePlugIn.mm"
PLIST_FILE="$DRIVER_DIR/resources/Info.plist"
OUT_BIN="$BIN_DIR/MicBridgeHAL"

DEVICE_NAME="MicBridge Virtual Mic"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device-name)
      DEVICE_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${DEVICE_NAME// /}" ]]; then
  echo "--device-name cannot be empty" >&2
  exit 1
fi

INPUT_STREAM_NAME="$DEVICE_NAME Input Stream"
OUTPUT_STREAM_NAME="$DEVICE_NAME Output Stream"

ESCAPED_DEVICE_NAME="${DEVICE_NAME//\\/\\\\}"
ESCAPED_DEVICE_NAME="${ESCAPED_DEVICE_NAME//\"/\\\"}"

ESCAPED_INPUT_STREAM_NAME="${INPUT_STREAM_NAME//\\/\\\\}"
ESCAPED_INPUT_STREAM_NAME="${ESCAPED_INPUT_STREAM_NAME//\"/\\\"}"

ESCAPED_OUTPUT_STREAM_NAME="${OUTPUT_STREAM_NAME//\\/\\\\}"
ESCAPED_OUTPUT_STREAM_NAME="${ESCAPED_OUTPUT_STREAM_NAME//\"/\\\"}"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

if ! rm -rf "$BUNDLE_DIR" 2>/dev/null; then
  BUILD_DIR="$(mktemp -d /tmp/micbridge-driver-build.XXXXXX)"
  BUNDLE_DIR="$BUILD_DIR/MicBridge.driver"
  BIN_DIR="$BUNDLE_DIR/Contents/MacOS"
  RES_DIR="$BUNDLE_DIR/Contents"
  OUT_BIN="$BIN_DIR/MicBridgeHAL"
fi

mkdir -p "$BIN_DIR" "$RES_DIR"

xcrun clang++ \
  -std=c++20 \
  -O2 \
  -Wall \
  -Wextra \
  -fobjc-arc \
  -bundle \
  -isysroot "$SDK_PATH" \
  -DMICBRIDGE_DEVICE_NAME="\"$ESCAPED_DEVICE_NAME\"" \
  -DMICBRIDGE_INPUT_STREAM_NAME="\"$ESCAPED_INPUT_STREAM_NAME\"" \
  -DMICBRIDGE_OUTPUT_STREAM_NAME="\"$ESCAPED_OUTPUT_STREAM_NAME\"" \
  -framework CoreAudio \
  -framework CoreFoundation \
  -Wl,-exported_symbol,_MicBridgePlugInFactory \
  "$SRC_FILE" \
  -o "$OUT_BIN"

cp "$PLIST_FILE" "$RES_DIR/Info.plist"

# Produce a valid bundle signature; unsigned/linker-signed bundles are often ignored by coreaudiod.
codesign --force --sign - --timestamp=none "$BUNDLE_DIR"
codesign --verify --deep --strict --verbose=2 "$BUNDLE_DIR" >/dev/null

echo "Built: $BUNDLE_DIR"
echo "Device Name: $DEVICE_NAME"
