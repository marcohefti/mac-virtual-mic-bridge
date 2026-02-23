#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$(mktemp -d -t micbridge-internal-update.XXXXXX)"
HOME_TMP="$(mktemp -d -t micbridge-internal-update-home.XXXXXX)"
ARCHIVE=""
SHA=""
VERSION_OVERRIDE=""

cleanup() {
  rm -rf "$OUT_DIR" "$HOME_TMP"
}
trap cleanup EXIT

cd "$ROOT_DIR"
source "$ROOT_DIR/version.env"

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-internal-update.sh [options]

Options:
  --archive <path>   Use existing release archive (skip packaging).
  --checksum <path>  Use existing checksum file.
  --version <ver>    Version for provided archive/checksum.
  --help             Show help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      ARCHIVE="$2"
      shift 2
      ;;
    --checksum)
      SHA="$2"
      shift 2
      ;;
    --version)
      VERSION_OVERRIDE="$2"
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

if [[ -n "$VERSION_OVERRIDE" ]]; then
  MARKETING_VERSION="$VERSION_OVERRIDE"
fi

if [[ -n "$ARCHIVE" || -n "$SHA" ]]; then
  if [[ -z "$ARCHIVE" || -z "$SHA" ]]; then
    echo "--archive and --checksum must be provided together" >&2
    exit 1
  fi
else
  echo "[validate-internal-update] Building release artifact"
  ./scripts/package-release.sh --output-dir "$OUT_DIR" >/dev/null
  ARCHIVE="$OUT_DIR/MicBridge-${MARKETING_VERSION}-macos.tar.gz"
  SHA="$ARCHIVE.sha256"
fi

if [[ ! -f "$ARCHIVE" || ! -f "$SHA" ]]; then
  echo "Missing release archive/checksum for internal-update validation." >&2
  exit 1
fi

echo "[validate-internal-update] Installing baseline runtime binaries into temp HOME"
SOURCE_BIN_DIR="$ROOT_DIR/.build/release"
if [[ ! -d "$SOURCE_BIN_DIR" ]]; then
  SOURCE_BIN_DIR="$(swift build -c release --show-bin-path)"
fi
HOME="$HOME_TMP" ./scripts/install-runtime-binaries.sh --skip-build --source-dir "$SOURCE_BIN_DIR" >/dev/null

CURRENT_LINK="$HOME_TMP/Library/Application Support/MacVirtualMicBridge/bin/current"
if [[ ! -x "$CURRENT_LINK/micbridge-daemon" || ! -x "$CURRENT_LINK/micbridge-menubar" ]]; then
  echo "Baseline runtime install missing required binaries." >&2
  exit 1
fi

echo "[validate-internal-update] Applying internal update from local artifact"
HOME="$HOME_TMP" ./scripts/internal-update.sh \
  --version "$MARKETING_VERSION" \
  --archive-url "file://$ARCHIVE" \
  --checksum-url "file://$SHA" \
  --skip-restart \
  --skip-health-check >/dev/null

if [[ ! -f "$CURRENT_LINK/VERSION" ]]; then
  echo "Updated runtime did not write VERSION file." >&2
  exit 1
fi
updated_version="$(tr -d '[:space:]' < "$CURRENT_LINK/VERSION")"
if [[ "$updated_version" != "$MARKETING_VERSION" ]]; then
  echo "Unexpected updated version: $updated_version (expected $MARKETING_VERSION)" >&2
  exit 1
fi

before_bad_update_target="$(readlink "$CURRENT_LINK" || true)"
if [[ -z "$before_bad_update_target" ]]; then
  echo "Could not read current runtime symlink target after successful update." >&2
  exit 1
fi

BAD_SHA="$OUT_DIR/bad.sha256"
echo "0000000000000000000000000000000000000000000000000000000000000000  $(basename "$ARCHIVE")" > "$BAD_SHA"

echo "[validate-internal-update] Verifying rollback/atomicity on bad checksum"
BAD_VERSION="${MARKETING_VERSION}.badcheck"
if HOME="$HOME_TMP" ./scripts/internal-update.sh \
  --version "$BAD_VERSION" \
  --archive-url "file://$ARCHIVE" \
  --checksum-url "file://$BAD_SHA" \
  --skip-restart \
  --skip-health-check >/dev/null 2>&1
then
  echo "Internal update unexpectedly succeeded with bad checksum." >&2
  exit 1
fi

after_bad_update_target="$(readlink "$CURRENT_LINK" || true)"
if [[ "$after_bad_update_target" != "$before_bad_update_target" ]]; then
  echo "Runtime symlink changed after failed update attempt." >&2
  echo "Before: $before_bad_update_target" >&2
  echo "After:  $after_bad_update_target" >&2
  exit 1
fi

echo "[validate-internal-update] OK"
