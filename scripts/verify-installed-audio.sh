#!/usr/bin/env zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
python3 - <<'PY'
import pathlib,json,time,subprocess,os
app=pathlib.Path.home()/'Library/Application Support/MacVirtualMicBridge'
p=app/'config.json'; exe=app/'bin/current/micbridge-audio-e2e-validate'
if not exe.exists():exe=pathlib.Path.cwd()/'.build/release/micbridge-audio-e2e-validate'
if not p.exists():
    subprocess.run([str(exe),'--inject-output-uid','ch.hefti.micbridge.virtualmic.device',
        '--capture-input-uid','ch.hefti.micbridge.virtualmic.device'],check=True,timeout=45)
    print('Driver waveform verified. Configure/start the physical bridge to validate that route.')
    raise SystemExit(0)
original=p.read_bytes()
def wait_state(state, since):
    for _ in range(45):
        try:
            s=json.loads((app/'status.json').read_text())
            if s['state']==state and (app/'status.json').stat().st_mtime>=since:return
        except (OSError,ValueError,KeyError):pass
        time.sleep(1)
    raise RuntimeError('Timed out waiting for '+state)
try:
    c=json.loads(original); c['enabled']=False; since=time.time();p.write_text(json.dumps(c))
    wait_state('stopped',since)
    subprocess.run([str(exe),'--inject-output-uid','ch.hefti.micbridge.virtualmic.device',
        '--capture-input-uid','ch.hefti.micbridge.virtualmic.device'],check=True,timeout=45)
finally:
    since=time.time();p.write_bytes(original)
    wait_state('running' if json.loads(original).get('enabled',True) else 'stopped',since)
if json.loads(original).get('enabled',True):
    time.sleep(2)
    subprocess.run([str(exe),'--check-live-signal'],check=True,timeout=30)
PY
