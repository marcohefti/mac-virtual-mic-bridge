#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/MacVirtualMicBridge"
BIN_ROOT="$APP_SUPPORT_DIR/bin"
RELEASES_DIR="$BIN_ROOT/releases"
CURRENT_LINK="$BIN_ROOT/current"
LOCK_DIR="$APP_SUPPORT_DIR/update.lock"

VERSION=""
REPO_SLUG=""
ARCHIVE_URL=""
CHECKSUM_URL=""
ARTIFACT_PREFIX="MicBridge"
APPLY_DRIVER_UPDATE=0
SKIP_RESTART=0
SKIP_HEALTH_CHECK=0
KEEP_RELEASES=5
PROGRESS_FILE=""
TMP_DIR=""

APPLIED_SWITCH=0
ROLLBACK_TARGET=""
NEW_RELEASE_DIR=""

usage() {
  cat <<'EOF'
Usage: ./scripts/internal-update.sh --version <version> [options]

Downloads release artifacts, verifies checksum, switches runtime binaries atomically,
and restarts/validates local services with rollback on health failure.

Options:
  --version <ver>        Release version (e.g. 0.1.0).
  --repo <owner/repo>    GitHub repo slug for default download URLs.
  --archive-url <url>    Explicit archive URL (.tar.gz).
  --checksum-url <url>   Explicit checksum URL (.tar.gz.sha256).
  --artifact-prefix <n>  Archive prefix (default: MicBridge).
  --apply-driver-update  Install bundled MicBridge.driver (requires sudo).
  --skip-restart         Skip daemon/menubar restart and live validation.
  --skip-health-check    Skip post-update live validation.
  --keep-releases <n>    Keep latest n runtime release dirs (default: 5).
  --progress-file <path> Write update stage to file for UI progress.
  --help                 Show help.
EOF
}

set_progress() {
  local stage="$1"
  if [[ -n "$PROGRESS_FILE" ]]; then
    mkdir -p "$(dirname "$PROGRESS_FILE")"
    print -r -- "$stage" > "$PROGRESS_FILE"
  fi
}

resolve_current_target() {
  if [[ -L "$CURRENT_LINK" ]]; then
    local linked
    linked="$(readlink "$CURRENT_LINK")"
    if [[ -n "$linked" ]]; then
      if [[ "$linked" = /* ]]; then
        echo "$linked"
      else
        echo "$BIN_ROOT/$linked"
      fi
      return
    fi
  fi
  echo ""
}

switch_current_link() {
  local absolute_target="$1"
  local relative_target
  relative_target="${absolute_target#$BIN_ROOT/}"

  if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
    echo "Refusing to overwrite non-symlink path: $CURRENT_LINK" >&2
    exit 1
  fi

  rm -f "$CURRENT_LINK"
  ln -s "$relative_target" "$CURRENT_LINK"
  APPLIED_SWITCH=1
}

rollback_switch() {
  if [[ "$APPLIED_SWITCH" -ne 1 ]]; then
    return
  fi

  if [[ -n "$ROLLBACK_TARGET" && -d "$ROLLBACK_TARGET" ]]; then
    switch_current_link "$ROLLBACK_TARGET"
  else
    rm -f "$CURRENT_LINK"
  fi
  APPLIED_SWITCH=0
}

prune_releases() {
  local keep="$1"
  mkdir -p "$RELEASES_DIR"
  local current_target_name=""
  if [[ -L "$CURRENT_LINK" ]]; then
    current_target_name="$(basename "$(readlink "$CURRENT_LINK")")"
  fi

  typeset -a release_dirs=("$RELEASES_DIR"/*(/N))
  if [[ ${#release_dirs[@]} -le "$keep" ]]; then
    return
  fi

  typeset -a release_names=()
  for dir in "${release_dirs[@]}"; do
    release_names+=("$(basename "$dir")")
  done

  IFS=$'\n' sorted_names=($(printf "%s\n" "${release_names[@]}" | sort))
  unset IFS
  local excess=$(( ${#sorted_names[@]} - keep ))
  for ((i=1; i<=excess; i++)); do
    local name="${sorted_names[$i]}"
    if [[ "$name" == "$current_target_name" ]]; then
      continue
    fi
    rm -rf "$RELEASES_DIR/$name"
  done
}

restart_services() {
  local uid
  uid="$(id -u)"

  local daemon_label="ch.hefti.macvirtualmicbridge.daemon"
  local menubar_label="ch.hefti.macvirtualmicbridge.menubar"
  local daemon_plist="$HOME/Library/LaunchAgents/$daemon_label.plist"
  local menubar_plist="$HOME/Library/LaunchAgents/$menubar_label.plist"

  if [[ -f "$daemon_plist" ]]; then
    launchctl kickstart -k "gui/$uid/$daemon_label" >/dev/null 2>&1 || true
  else
    "$ROOT_DIR/scripts/stop-daemon.sh" >/dev/null 2>&1 || true
    "$ROOT_DIR/scripts/start-daemon.sh" >/dev/null 2>&1 || true
  fi

  if [[ -f "$menubar_plist" ]]; then
    launchctl kickstart -k "gui/$uid/$menubar_label" >/dev/null 2>&1 || true
  fi
}

on_exit() {
  local exit_code=$?
  trap - EXIT

  if [[ $exit_code -ne 0 ]]; then
    set_progress "failed"
    rollback_switch
    if [[ $SKIP_RESTART -eq 0 ]]; then
      restart_services || true
    fi
    if [[ -n "$NEW_RELEASE_DIR" ]]; then
      rm -rf "$NEW_RELEASE_DIR" || true
    fi
  fi

  if [[ -n "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR" || true
  fi

  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --repo)
      REPO_SLUG="$2"
      shift 2
      ;;
    --archive-url)
      ARCHIVE_URL="$2"
      shift 2
      ;;
    --checksum-url)
      CHECKSUM_URL="$2"
      shift 2
      ;;
    --artifact-prefix)
      ARTIFACT_PREFIX="$2"
      shift 2
      ;;
    --apply-driver-update)
      APPLY_DRIVER_UPDATE=1
      shift
      ;;
    --skip-restart)
      SKIP_RESTART=1
      shift
      ;;
    --skip-health-check)
      SKIP_HEALTH_CHECK=1
      shift
      ;;
    --keep-releases)
      KEEP_RELEASES="$2"
      shift 2
      ;;
    --progress-file)
      PROGRESS_FILE="$2"
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

if [[ -z "$VERSION" ]]; then
  echo "--version is required" >&2
  exit 1
fi

if ! [[ "$KEEP_RELEASES" =~ ^[0-9]+$ ]] || [[ "$KEEP_RELEASES" -lt 1 ]]; then
  echo "--keep-releases must be a positive integer" >&2
  exit 1
fi

if [[ $SKIP_RESTART -eq 1 ]]; then
  SKIP_HEALTH_CHECK=1
fi

if [[ -n "$ARCHIVE_URL" || -n "$CHECKSUM_URL" ]]; then
  if [[ -z "$ARCHIVE_URL" || -z "$CHECKSUM_URL" ]]; then
    echo "--archive-url and --checksum-url must be provided together" >&2
    exit 1
  fi
elif [[ -n "$REPO_SLUG" ]]; then
  ARCHIVE_NAME="${ARTIFACT_PREFIX}-${VERSION}-macos.tar.gz"
  ARCHIVE_URL="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/${ARCHIVE_NAME}"
  CHECKSUM_URL="${ARCHIVE_URL}.sha256"
else
  echo "Provide --repo or explicit --archive-url + --checksum-url" >&2
  exit 1
fi

mkdir -p "$APP_SUPPORT_DIR" "$RELEASES_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another update is currently running. Try again in a moment." >&2
  exit 1
fi

current_target="$(resolve_current_target)"
if [[ -f "$CURRENT_LINK/VERSION" ]]; then
  current_version="$(tr -d '[:space:]' < "$CURRENT_LINK/VERSION" || true)"
  if [[ "$current_version" == "$VERSION" ]]; then
    echo "[internal-update] Already on version $VERSION"
    set_progress "completed"
    exit 0
  fi
fi

TMP_DIR="$(mktemp -d /tmp/micbridge-update.XXXXXX)"

set_progress "downloading"
echo "[internal-update] Downloading release artifacts for v$VERSION"
curl -fL --retry 3 --retry-delay 1 "$ARCHIVE_URL" -o "$TMP_DIR/archive.tar.gz"
curl -fL --retry 3 --retry-delay 1 "$CHECKSUM_URL" -o "$TMP_DIR/archive.tar.gz.sha256"

set_progress "verifying"
expected_sha="$(awk '{print $1; exit}' "$TMP_DIR/archive.tar.gz.sha256" | tr -d '[:space:]')"
actual_sha="$(shasum -a 256 "$TMP_DIR/archive.tar.gz" | awk '{print $1}' | tr -d '[:space:]')"

if [[ -z "$expected_sha" ]]; then
  echo "Checksum file did not contain a SHA-256 hash: $CHECKSUM_URL" >&2
  exit 1
fi

if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Checksum mismatch for downloaded artifact." >&2
  echo "Expected: $expected_sha" >&2
  echo "Actual:   $actual_sha" >&2
  exit 1
fi

set_progress "extracting"
echo "[internal-update] Extracting archive"
mkdir -p "$TMP_DIR/extracted"
tar -xzf "$TMP_DIR/archive.tar.gz" -C "$TMP_DIR/extracted"

STAGE_DIR="$TMP_DIR/extracted/${ARTIFACT_PREFIX}-${VERSION}"
if [[ ! -d "$STAGE_DIR" ]]; then
  typeset -a extracted_dirs=("$TMP_DIR/extracted"/*(/N))
  if [[ ${#extracted_dirs[@]} -ne 1 ]]; then
    echo "Could not determine extracted release directory." >&2
    exit 1
  fi
  STAGE_DIR="${extracted_dirs[1]}"
fi

if [[ ! -d "$STAGE_DIR/bin" ]]; then
  echo "Release archive missing bin directory: $STAGE_DIR/bin" >&2
  exit 1
fi

if [[ ! -f "$STAGE_DIR/bin/micbridge-daemon" || ! -f "$STAGE_DIR/bin/micbridge-menubar" ]]; then
  echo "Release archive missing required binaries (micbridge-daemon/micbridge-menubar)." >&2
  exit 1
fi

set_progress "installing"
echo "[internal-update] Installing runtime binaries"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NEW_RELEASE_DIR="$RELEASES_DIR/update-v${VERSION}-${TIMESTAMP}"
mkdir -p "$NEW_RELEASE_DIR"

for source_binary in "$STAGE_DIR"/bin/*; do
  [[ -f "$source_binary" ]] || continue
  cp "$source_binary" "$NEW_RELEASE_DIR/$(basename "$source_binary")"
  chmod +x "$NEW_RELEASE_DIR/$(basename "$source_binary")"
done
echo "$VERSION" > "$NEW_RELEASE_DIR/VERSION"

ROLLBACK_TARGET="$current_target"
switch_current_link "$NEW_RELEASE_DIR"

if [[ $APPLY_DRIVER_UPDATE -eq 1 ]]; then
  DRIVER_BUNDLE="$STAGE_DIR/driver/MicBridge.driver"
  if [[ ! -d "$DRIVER_BUNDLE" ]]; then
    echo "--apply-driver-update requested but archive has no driver bundle." >&2
    exit 1
  fi
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "--apply-driver-update requires sudo/root permissions." >&2
    exit 1
  fi
  echo "[internal-update] Installing driver bundle"
  "$ROOT_DIR/scripts/install-driver-bundle.sh" "$DRIVER_BUNDLE"
fi

if [[ $SKIP_RESTART -eq 0 ]]; then
  set_progress "restarting"
  echo "[internal-update] Restarting local services"
  restart_services
fi

if [[ $SKIP_HEALTH_CHECK -eq 0 ]]; then
  set_progress "validating"
  echo "[internal-update] Running live validation gate"
  "$ROOT_DIR/scripts/validate-live-stack.sh" >/dev/null
fi

set_progress "completed"
prune_releases "$KEEP_RELEASES"
APPLIED_SWITCH=0

echo "[internal-update] Update complete."
echo "Runtime path: $CURRENT_LINK"
echo "Version: $VERSION"
