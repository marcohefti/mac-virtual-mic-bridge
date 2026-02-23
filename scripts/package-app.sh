#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/version.env"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing version file: $VERSION_FILE" >&2
  exit 1
fi

source "$VERSION_FILE"

if [[ -z "${MARKETING_VERSION:-}" || -z "${BUILD_NUMBER:-}" ]]; then
  echo "version.env must define MARKETING_VERSION and BUILD_NUMBER" >&2
  exit 1
fi

CONFIGURATION="release"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_NAME="MicBridge"
BUNDLE_ID="ch.hefti.macvirtualmicbridge.menubar"
SIGN_APP=1
CREATE_ZIP=1
REPO_ROOT_VALUE="$ROOT_DIR"
REPO_SLUG_VALUE=""

usage() {
  cat <<'EOF'
Usage: ./scripts/package-app.sh [options]

Create an internal-use macOS app bundle (ad-hoc signed by default).

Options:
  --configuration <debug|release>  Build configuration (default: release).
  --output-dir <dir>               Output directory (default: ./dist).
  --app-name <name>                App bundle display name (default: MicBridge).
  --bundle-id <id>                 CFBundleIdentifier.
  --repo-root <path>               Embed MicBridgeRepoRoot key in Info.plist.
  --repo-slug <owner/repo>         Embed MicBridgeRepoSlug key in Info.plist.
  --no-sign                        Skip ad-hoc signing.
  --no-zip                         Do not create .zip archive.
  --help                           Show help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$2"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT_VALUE="$2"
      shift 2
      ;;
    --repo-slug)
      REPO_SLUG_VALUE="$2"
      shift 2
      ;;
    --no-sign)
      SIGN_APP=0
      shift
      ;;
    --no-zip)
      CREATE_ZIP=0
      shift
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

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "--configuration must be debug or release" >&2
  exit 1
fi

if [[ -z "$REPO_SLUG_VALUE" ]]; then
  if remote="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null)"; then
    if [[ "$remote" == git@github.com:* ]]; then
      REPO_SLUG_VALUE="${remote#git@github.com:}"
    elif [[ "$remote" == https://github.com/* ]]; then
      REPO_SLUG_VALUE="${remote#https://github.com/}"
    elif [[ "$remote" == http://github.com/* ]]; then
      REPO_SLUG_VALUE="${remote#http://github.com/}"
    fi
    REPO_SLUG_VALUE="${REPO_SLUG_VALUE%.git}"
  fi
fi

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product micbridge-menubar >/dev/null

BIN_PATH="$ROOT_DIR/.build/$CONFIGURATION/micbridge-menubar"
if [[ ! -f "$BIN_PATH" ]]; then
  BIN_DIR="$(swift build -c "$CONFIGURATION" --product micbridge-menubar --show-bin-path)"
  BIN_PATH="$BIN_DIR/micbridge-menubar"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Could not locate built micbridge-menubar binary." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

APP_BUNDLE_PATH="$OUTPUT_DIR/${APP_NAME}.app"
EXECUTABLE_NAME="micbridge-menubar"
ZIP_PATH="$OUTPUT_DIR/${APP_NAME}-${MARKETING_VERSION}.zip"

rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$APP_BUNDLE_PATH/Contents/MacOS" "$APP_BUNDLE_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE_PATH/Contents/MacOS/$EXECUTABLE_NAME"

APP_COPYRIGHT="© 2026 MicBridge"

cat > "$APP_BUNDLE_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${MARKETING_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>${APP_COPYRIGHT}</string>
  <key>MicBridgeRepoRoot</key>
  <string>${REPO_ROOT_VALUE}</string>
  <key>MicBridgeRepoSlug</key>
  <string>${REPO_SLUG_VALUE}</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_BUNDLE_PATH" || true
find "$APP_BUNDLE_PATH" -name '._*' -delete

if [[ $SIGN_APP -eq 1 ]]; then
  codesign --force --sign - --timestamp=none "$APP_BUNDLE_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE_PATH" >/dev/null
fi

if [[ $CREATE_ZIP -eq 1 ]]; then
  rm -f "$ZIP_PATH"
  /usr/bin/ditto --norsrc -c -k --keepParent "$APP_BUNDLE_PATH" "$ZIP_PATH"
fi

echo "Created app bundle:"
echo "  $APP_BUNDLE_PATH"
if [[ $CREATE_ZIP -eq 1 ]]; then
  echo "Created archive:"
  echo "  $ZIP_PATH"
fi
