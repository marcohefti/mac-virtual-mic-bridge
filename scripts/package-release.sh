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

OUTPUT_DIR="$ROOT_DIR/dist"
ARTIFACT_PREFIX="MicBridge"

usage() {
  cat <<'EOF'
Usage: ./scripts/package-release.sh [options]

Builds release artifacts and creates a distribution archive with checksums.

Options:
  --output-dir <dir>        Output directory (default: ./dist)
  --artifact-prefix <name>  Archive prefix (default: MicBridge)
  --help                    Show help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --artifact-prefix)
      ARTIFACT_PREFIX="$2"
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

if [[ -z "${ARTIFACT_PREFIX// /}" ]]; then
  echo "--artifact-prefix cannot be empty" >&2
  exit 1
fi

STAGE_ROOT="$(mktemp -d -t micbridge-release-stage.XXXXXX)"
STAGE_DIR="$STAGE_ROOT/${ARTIFACT_PREFIX}-${MARKETING_VERSION}"
cleanup() {
  rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/driver" "$STAGE_DIR/docs"

cd "$ROOT_DIR"

echo "[package-release] Building Swift release binaries"
swift build -c release \
  --product micbridge-daemon \
  --product micbridge-menubar \
  --product micbridge-audio-e2e-validate \
  --product micbridge-capture-fixture \
  --product micbridge-fixture-validate >/dev/null

BIN_DIR="$(swift build -c release --show-bin-path)"

resolve_binary_path() {
  local name="$1"
  local candidate="$BIN_DIR/$name"
  if [[ -f "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  candidate="$ROOT_DIR/.build/release/$name"
  if [[ -f "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  candidate="$(find "$ROOT_DIR/.build" -type f -path "*/release/$name" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$candidate" && -f "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  return 1
}

copy_resolved_binary() {
  local name="$1"
  local source_path
  source_path="$(resolve_binary_path "$name" || true)"
  if [[ -z "$source_path" || ! -f "$source_path" ]]; then
    echo "Could not resolve built binary: $name" >&2
    exit 1
  fi
  cp "$source_path" "$STAGE_DIR/bin/"
}

echo "[package-release] Building HAL driver bundle"
"$ROOT_DIR/drivers/micbridge-hal/scripts/build-driver.sh" >/dev/null

copy_resolved_binary "micbridge-daemon"
copy_resolved_binary "micbridge-menubar"
copy_resolved_binary "micbridge-audio-e2e-validate"
copy_resolved_binary "micbridge-capture-fixture"
copy_resolved_binary "micbridge-fixture-validate"
cp -R "$ROOT_DIR/drivers/micbridge-hal/build/MicBridge.driver" "$STAGE_DIR/driver/"

cp "$ROOT_DIR/README.md" "$STAGE_DIR/docs/"
cp "$ROOT_DIR/CHANGELOG.md" "$STAGE_DIR/docs/"
cp "$ROOT_DIR/version.env" "$STAGE_DIR/"

BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"

cat > "$STAGE_DIR/RELEASE-MANIFEST.txt" <<EOF
Project: mac-virtual-mic-bridge
Marketing Version: ${MARKETING_VERSION}
Build Number: ${BUILD_NUMBER}
Git Commit: ${GIT_COMMIT}
Built At (UTC): ${BUILD_TIMESTAMP}

Contents:
- bin/micbridge-daemon
- bin/micbridge-menubar
- bin/micbridge-audio-e2e-validate
- bin/micbridge-capture-fixture
- bin/micbridge-fixture-validate
- driver/MicBridge.driver
- docs/README.md
- docs/CHANGELOG.md
- version.env
EOF

mkdir -p "$OUTPUT_DIR"

ARCHIVE_NAME="${ARTIFACT_PREFIX}-${MARKETING_VERSION}-macos.tar.gz"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
SHA_PATH="$ARCHIVE_PATH.sha256"

tar -C "$STAGE_ROOT" -czf "$ARCHIVE_PATH" "$(basename "$STAGE_DIR")"
shasum -a 256 "$ARCHIVE_PATH" > "$SHA_PATH"

echo "[package-release] Created:"
echo "  $ARCHIVE_PATH"
echo "  $SHA_PATH"
