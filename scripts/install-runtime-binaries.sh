#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/MacVirtualMicBridge"
BIN_ROOT="$APP_SUPPORT_DIR/bin"
RELEASES_DIR="$BIN_ROOT/releases"
CURRENT_LINK="$BIN_ROOT/current"
VERSION_FILE="$ROOT_DIR/version.env"

CONFIGURATION="release"
SOURCE_DIR=""
SKIP_BUILD=0
ENSURE_ONLY=0
KEEP_RELEASES=5
LABEL="build"

usage() {
  cat <<'EOF'
Usage: ./scripts/install-runtime-binaries.sh [options]

Installs MicBridge runtime binaries into:
  ~/Library/Application Support/MacVirtualMicBridge/bin
with versioned release directories and an atomic current symlink.

Options:
  --configuration <debug|release>  Build configuration (default: release).
  --source-dir <dir>               Source directory with binaries (skip Swift build).
  --skip-build                     Do not build Swift products.
  --ensure                         Install only if current daemon+menubar are missing.
  --keep-releases <n>              Keep latest n release dirs (default: 5).
  --label <name>                   Prefix for new release directory (default: build).
  --help                           Show help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --source-dir)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --ensure)
      ENSURE_ONLY=1
      shift
      ;;
    --keep-releases)
      KEEP_RELEASES="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
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

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "--configuration must be debug or release" >&2
  exit 1
fi

if ! [[ "$KEEP_RELEASES" =~ ^[0-9]+$ ]] || [[ "$KEEP_RELEASES" -lt 1 ]]; then
  echo "--keep-releases must be a positive integer" >&2
  exit 1
fi

CURRENT_DAEMON="$CURRENT_LINK/micbridge-daemon"
CURRENT_MENUBAR="$CURRENT_LINK/micbridge-menubar"

if [[ "$ENSURE_ONLY" -eq 1 ]] && [[ -x "$CURRENT_DAEMON" && -x "$CURRENT_MENUBAR" ]]; then
  echo "Runtime binaries already present:"
  echo "  $CURRENT_LINK"
  exit 0
fi

if [[ -z "$SOURCE_DIR" ]]; then
  if [[ "$SKIP_BUILD" -eq 0 ]]; then
    cd "$ROOT_DIR"
    swift build -c "$CONFIGURATION" \
      --product micbridge-daemon \
      --product micbridge-menubar \
      --product micbridge-audio-e2e-validate \
      --product micbridge-capture-fixture \
      --product micbridge-fixture-validate >/dev/null
  fi

  SOURCE_DIR="$ROOT_DIR/.build/$CONFIGURATION"
  if [[ ! -d "$SOURCE_DIR" ]]; then
    SOURCE_DIR="$(cd "$ROOT_DIR" && swift build -c "$CONFIGURATION" --show-bin-path)"
  fi
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Source binary directory not found: $SOURCE_DIR" >&2
  exit 1
fi

mkdir -p "$RELEASES_DIR"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_LABEL="${LABEL// /-}"
RELEASE_ID="${SAFE_LABEL}-${TIMESTAMP}"
TARGET_DIR="$RELEASES_DIR/$RELEASE_ID"
mkdir -p "$TARGET_DIR"

required_binaries=(
  "micbridge-daemon"
  "micbridge-menubar"
)

optional_binaries=(
  "micbridge-audio-e2e-validate"
  "micbridge-capture-fixture"
  "micbridge-fixture-validate"
)

for name in "${required_binaries[@]}"; do
  if [[ ! -f "$SOURCE_DIR/$name" ]]; then
    echo "Missing required binary: $SOURCE_DIR/$name" >&2
    exit 1
  fi
  cp "$SOURCE_DIR/$name" "$TARGET_DIR/$name"
  chmod +x "$TARGET_DIR/$name"
done

for name in "${optional_binaries[@]}"; do
  if [[ -f "$SOURCE_DIR/$name" ]]; then
    cp "$SOURCE_DIR/$name" "$TARGET_DIR/$name"
    chmod +x "$TARGET_DIR/$name"
  fi
done

if [[ -f "$VERSION_FILE" ]]; then
  source "$VERSION_FILE"
  if [[ -n "${MARKETING_VERSION:-}" ]]; then
    echo "$MARKETING_VERSION" > "$TARGET_DIR/VERSION"
  fi
fi

if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
  echo "Refusing to overwrite non-symlink path: $CURRENT_LINK" >&2
  exit 1
fi
rm -f "$CURRENT_LINK"
ln -s "releases/$RELEASE_ID" "$CURRENT_LINK"

current_target_name="$(readlink "$CURRENT_LINK" | awk -F/ '{print $NF}')"
typeset -a release_dirs=("$RELEASES_DIR"/*(/N))
if [[ ${#release_dirs[@]} -gt "$KEEP_RELEASES" ]]; then
  typeset -a release_names=()
  for dir in "${release_dirs[@]}"; do
    release_names+=("$(basename "$dir")")
  done

  IFS=$'\n' sorted_names=($(printf "%s\n" "${release_names[@]}" | sort))
  unset IFS
  excess=$(( ${#sorted_names[@]} - KEEP_RELEASES ))
  for ((i=1; i<=excess; i++)); do
    name="${sorted_names[$i]}"
    if [[ "$name" == "$current_target_name" ]]; then
      continue
    fi
    rm -rf "$RELEASES_DIR/$name"
  done
fi

echo "Installed runtime binaries:"
echo "  $CURRENT_LINK -> releases/$RELEASE_ID"
