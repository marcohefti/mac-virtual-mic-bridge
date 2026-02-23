#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/MacVirtualMicBridge"
CONFIG_PATH="$APP_SUPPORT_DIR/config.json"
STATUS_PATH="$APP_SUPPORT_DIR/status.json"
PID_PATH="$APP_SUPPORT_DIR/daemon.pid"

DEFAULT_SOURCE_UID="BlackHole2ch_UID"
DEFAULT_TARGET_UID="ch.hefti.micbridge.virtualmic.device"

SOURCE_UID="$DEFAULT_SOURCE_UID"
TARGET_UID="$DEFAULT_TARGET_UID"
INJECT_UID=""
CAPTURE_UID=""
WAIT_SECONDS=20
SAMPLE_RATE=48000
FREQUENCY_HZ=997
TONE_SECONDS=0.25
MIN_CAPTURE_RMS=0.002
MIN_CORRELATION=0.70
MAX_ERROR_RATIO=0.45

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-audio-e2e.sh [options]

Runs a deterministic end-to-end audio path check:
1) Temporarily sets daemon config source/target.
2) Injects a tone into a specific output device UID.
3) Captures from a specific input device UID.
4) Verifies correlation/error metrics.
5) Restores previous daemon config.

Defaults:
  source UID:  BlackHole2ch_UID
  target UID:  ch.hefti.micbridge.virtualmic.device
  inject UID:  same as source UID
  capture UID: same as target UID

Options:
  --source-input-uid <uid>      Bridge source device UID (default: BlackHole2ch_UID)
  --target-output-uid <uid>     Bridge target output UID (default: ch.hefti.micbridge.virtualmic.device)
  --inject-output-uid <uid>     Tone injection output UID (default: source UID)
  --capture-input-uid <uid>     Capture input UID (default: target UID)
  --wait-seconds <seconds>      Wait for daemon to converge (default: 20)
  --sample-rate <hz>            Validator sample rate (default: 48000)
  --frequency-hz <hz>           Validator tone frequency (default: 997)
  --tone-seconds <seconds>      Validator tone duration (default: 0.25)
  --min-capture-rms <value>     Pass threshold (default: 0.002)
  --min-correlation <value>     Pass threshold (default: 0.70)
  --max-error-ratio <value>     Pass threshold (default: 0.45)
  --help                        Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-input-uid)
      SOURCE_UID="$2"
      shift 2
      ;;
    --target-output-uid)
      TARGET_UID="$2"
      shift 2
      ;;
    --inject-output-uid)
      INJECT_UID="$2"
      shift 2
      ;;
    --capture-input-uid)
      CAPTURE_UID="$2"
      shift 2
      ;;
    --wait-seconds)
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --sample-rate)
      SAMPLE_RATE="$2"
      shift 2
      ;;
    --frequency-hz)
      FREQUENCY_HZ="$2"
      shift 2
      ;;
    --tone-seconds)
      TONE_SECONDS="$2"
      shift 2
      ;;
    --min-capture-rms)
      MIN_CAPTURE_RMS="$2"
      shift 2
      ;;
    --min-correlation)
      MIN_CORRELATION="$2"
      shift 2
      ;;
    --max-error-ratio)
      MAX_ERROR_RATIO="$2"
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

if [[ -z "$INJECT_UID" ]]; then
  INJECT_UID="$SOURCE_UID"
fi
if [[ -z "$CAPTURE_UID" ]]; then
  CAPTURE_UID="$TARGET_UID"
fi

mkdir -p "$APP_SUPPORT_DIR"
TMP_DIR="$(mktemp -d -t micbridge-audio-e2e.XXXXXX)"
BACKUP_CONFIG="$TMP_DIR/config.backup.json"
CONFIG_EXISTED=0
DAEMON_WAS_RUNNING=0
DAEMON_STARTED_BY_SCRIPT=0

if [[ -f "$PID_PATH" ]]; then
  PID="$(cat "$PID_PATH" | tr -d '[:space:]')"
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    DAEMON_WAS_RUNNING=1
  fi
fi

cleanup() {
  set +e
  if [[ "$CONFIG_EXISTED" -eq 1 ]]; then
    cp "$BACKUP_CONFIG" "$CONFIG_PATH"
    touch "$CONFIG_PATH"
  else
    rm -f "$CONFIG_PATH"
  fi

  if [[ "$DAEMON_STARTED_BY_SCRIPT" -eq 1 ]]; then
    "$ROOT_DIR/scripts/stop-daemon.sh" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ -f "$CONFIG_PATH" ]]; then
  cp "$CONFIG_PATH" "$BACKUP_CONFIG"
  CONFIG_EXISTED=1
fi

if [[ "$DAEMON_WAS_RUNNING" -eq 0 ]]; then
  "$ROOT_DIR/scripts/start-daemon.sh" >/dev/null
  DAEMON_STARTED_BY_SCRIPT=1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  cat >"$CONFIG_PATH" <<'EOF'
{
  "enabled": true,
  "sourceDeviceUID": null,
  "targetDeviceUID": null,
  "virtualMicrophoneName": "MicBridge Virtual Mic"
}
EOF
fi

python3 - "$CONFIG_PATH" "$SOURCE_UID" "$TARGET_UID" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source_uid = sys.argv[2]
target_uid = sys.argv[3]

config = json.loads(path.read_text())
config["enabled"] = True
config["sourceDeviceUID"] = source_uid
config["targetDeviceUID"] = target_uid
if "virtualMicrophoneName" not in config or not config["virtualMicrophoneName"]:
    config["virtualMicrophoneName"] = "MicBridge Virtual Mic"

path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
PY

touch "$CONFIG_PATH"

echo "[audio-e2e] Waiting for daemon session source=$SOURCE_UID target=$TARGET_UID"
DEADLINE=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < DEADLINE )); do
  if python3 - "$STATUS_PATH" "$SOURCE_UID" "$TARGET_UID" <<'PY'
import json
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
source_uid = sys.argv[2]
target_uid = sys.argv[3]

if not status_path.exists():
    sys.exit(1)

try:
    status = json.loads(status_path.read_text())
except Exception:
    sys.exit(1)

if status.get("state") != "running":
    sys.exit(1)
if status.get("sourceDeviceUID") != source_uid:
    sys.exit(1)
if status.get("targetDeviceUID") != target_uid:
    sys.exit(1)
sys.exit(0)
PY
  then
    break
  fi
  sleep 1
done

if ! python3 - "$STATUS_PATH" "$SOURCE_UID" "$TARGET_UID" <<'PY'
import json
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
source_uid = sys.argv[2]
target_uid = sys.argv[3]

if not status_path.exists():
    sys.exit(1)

status = json.loads(status_path.read_text())
ok = (
    status.get("state") == "running"
    and status.get("sourceDeviceUID") == source_uid
    and status.get("targetDeviceUID") == target_uid
)
sys.exit(0 if ok else 1)
PY
then
  echo "[audio-e2e] FAIL: daemon did not converge to requested source/target within ${WAIT_SECONDS}s" >&2
  if [[ -f "$STATUS_PATH" ]]; then
    cat "$STATUS_PATH" >&2
  fi
  exit 1
fi

cd "$ROOT_DIR"
swift run -c release micbridge-audio-e2e-validate \
  --inject-output-uid "$INJECT_UID" \
  --capture-input-uid "$CAPTURE_UID" \
  --sample-rate "$SAMPLE_RATE" \
  --frequency-hz "$FREQUENCY_HZ" \
  --tone-seconds "$TONE_SECONDS" \
  --min-capture-rms "$MIN_CAPTURE_RMS" \
  --min-correlation "$MIN_CORRELATION" \
  --max-error-ratio "$MAX_ERROR_RATIO"

echo "[audio-e2e] End-to-end validation succeeded"
