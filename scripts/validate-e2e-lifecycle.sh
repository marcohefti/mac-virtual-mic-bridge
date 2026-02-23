#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_BUNDLE="/Library/Audio/Plug-Ins/HAL/MicBridge.driver"

TEST_DRIVER_NAME="MicBridge Virtual Mic E2E Test"
SOURCE_UID="BlackHole2ch_UID"
TARGET_UID="ch.hefti.micbridge.virtualmic.device"
WAIT_SECONDS=30
RESTORE_ORIGINAL=1

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-e2e-lifecycle.sh [options]

Lifecycle validation with explicit pass/fail signals:
1) Safe install test-named driver.
2) Validate driver visibility.
3) Validate live stack.
4) Validate end-to-end audio integrity.
5) Uninstall driver.
6) Validate driver absence.
7) Restore pre-existing driver bundle (if one existed before run).

Options:
  --test-driver-name <name>   Driver name used for test install.
                              Default: "MicBridge Virtual Mic E2E Test"
  --source-input-uid <uid>    Source UID for audio e2e test (default: BlackHole2ch_UID)
  --target-output-uid <uid>   Target UID for audio e2e test (default: ch.hefti.micbridge.virtualmic.device)
  --wait-seconds <seconds>    Timeout for state checks (default: 30)
  --no-restore                Do not restore pre-existing driver bundle after test.
  --help                      Show help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-driver-name)
      TEST_DRIVER_NAME="$2"
      shift 2
      ;;
    --source-input-uid)
      SOURCE_UID="$2"
      shift 2
      ;;
    --target-output-uid)
      TARGET_UID="$2"
      shift 2
      ;;
    --wait-seconds)
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --no-restore)
      RESTORE_ORIGINAL=0
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

if [[ -z "${TEST_DRIVER_NAME// /}" ]]; then
  echo "--test-driver-name cannot be empty" >&2
  exit 1
fi

if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$WAIT_SECONDS" -lt 1 ]]; then
  echo "--wait-seconds must be a positive integer" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d -t micbridge-e2e-lifecycle.XXXXXX)"
BACKUP_BUNDLE="$TMP_DIR/MicBridge.driver.backup"
ORIGINAL_PRESENT=0
ORIGINAL_RESTORED=0
TEST_DRIVER_ACTIVE=0

step() {
  local title="$1"
  shift
  echo "[e2e-lifecycle] STEP: $title"
  if "$@"; then
    echo "[e2e-lifecycle] PASS: $title"
  else
    echo "[e2e-lifecycle] FAIL: $title" >&2
    exit 1
  fi
}

restore_original_bundle() {
  if [[ "$ORIGINAL_PRESENT" -eq 1 && "$RESTORE_ORIGINAL" -eq 1 && "$ORIGINAL_RESTORED" -eq 0 ]]; then
    echo "[e2e-lifecycle] Restoring pre-existing MicBridge.driver bundle"
    sudo rm -rf "$TARGET_BUNDLE"
    sudo ditto "$BACKUP_BUNDLE" "$TARGET_BUNDLE"
    sudo chown -R root:wheel "$TARGET_BUNDLE"
    sudo codesign --verify --deep --strict --verbose=2 "$TARGET_BUNDLE" >/dev/null
    sudo killall coreaudiod >/dev/null 2>&1 || true
    "$ROOT_DIR/scripts/validate-driver-state.sh" --expect present --timeout-seconds "$WAIT_SECONDS"
    ORIGINAL_RESTORED=1
    echo "[e2e-lifecycle] PASS: pre-existing driver restored"
  fi
}

cleanup() {
  set +e
  if [[ "$ORIGINAL_PRESENT" -eq 0 && "$TEST_DRIVER_ACTIVE" -eq 1 ]]; then
    echo "[e2e-lifecycle] Cleanup: removing test driver"
    sudo ./scripts/uninstall-driver.sh >/dev/null 2>&1 || true
  fi
  restore_original_bundle
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ -d "$TARGET_BUNDLE" ]]; then
  ORIGINAL_PRESENT=1
  echo "[e2e-lifecycle] Existing driver detected; creating backup"
  sudo ditto "$TARGET_BUNDLE" "$BACKUP_BUNDLE"
fi

cd "$ROOT_DIR"

step "safe install test driver ('$TEST_DRIVER_NAME')" \
  sudo ./scripts/safe-install-driver.sh --device-name "$TEST_DRIVER_NAME"
TEST_DRIVER_ACTIVE=1

step "validate driver visible with test name" \
  ./scripts/validate-driver-state.sh --expect present --name "$TEST_DRIVER_NAME" --timeout-seconds "$WAIT_SECONDS"

step "validate live stack health" \
  ./scripts/validate.sh --live

step "validate audio e2e path" \
  ./scripts/validate-audio-e2e.sh \
    --source-input-uid "$SOURCE_UID" \
    --target-output-uid "$TARGET_UID" \
    --wait-seconds "$WAIT_SECONDS"

step "uninstall driver" \
  sudo ./scripts/uninstall-driver.sh
TEST_DRIVER_ACTIVE=0

step "validate driver absent post-uninstall" \
  ./scripts/validate-driver-state.sh --expect absent --timeout-seconds "$WAIT_SECONDS"

restore_original_bundle

echo "[e2e-lifecycle] DONE: install, audio validation, uninstall completed with explicit checks"
