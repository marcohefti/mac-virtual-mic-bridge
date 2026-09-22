#!/usr/bin/env python3
"""Live, reversible recovery regression. Does not change system default devices."""
import argparse, datetime, json, os, pathlib, signal, subprocess, time
parser=argparse.ArgumentParser();parser.add_argument('--cycles',type=int,default=10);parser.add_argument('--output',default='/tmp/micbridge-recovery-results.json');args=parser.parse_args()
app=pathlib.Path.home()/'Library/Application Support/MacVirtualMicBridge'
config=app/'config.json';original=config.read_bytes();base=json.loads(original)
exe=app/'bin/current/micbridge-audio-e2e-validate'; results=[]
def write(value):
    tmp=config.with_suffix('.test-tmp');tmp.write_text(json.dumps(value));os.replace(tmp,config)
    return time.time()-0.1
def state():return json.loads((app/'status.json').read_text())
def wait(expected,since):
    deadline=time.monotonic()+50
    while time.monotonic()<deadline:
        try:
            s=state()
            if s['state']==expected and (app/'status.json').stat().st_mtime>=since:return s
        except (OSError,ValueError,KeyError):pass
        time.sleep(0.5)
    raise RuntimeError(f'timed out waiting for {expected}: {state()}')
def verify(name,start):
    wait('running',start);time.sleep(2)
    test=subprocess.run([str(exe),'--check-live-signal'],capture_output=True,text=True,timeout=30)
    row=dict(scenario=name,seconds=round(time.time()-start,3),returncode=test.returncode,
             output=test.stdout+test.stderr,status=state())
    results.append(row);pathlib.Path(args.output).write_text(json.dumps(results,indent=2)+'\n')
    print(name, 'PASS' if test.returncode==0 else 'FAIL',row['output'],flush=True)
    if test.returncode:raise RuntimeError('Audio recovery check failed')
try:
    # Missing source and missing target must wait, never route to another device.
    for field in ['sourceDeviceUID','targetDeviceUID']:
        changed=dict(base);changed[field]='micbridge-regression-missing-device'
        start=write(changed)
        expected='restarting' if field=='sourceDeviceUID' else 'error'
        stopped=wait(expected,start)
        assert stopped.get('sampleRate') is None, stopped
        verify('recover missing '+field,write(base))
    changed=dict(base);changed['sourceInputChannel']=9999
    wait('error',write(changed));verify('recover invalid channel',write(base))
    for cycle in range(args.cycles):
        changed=dict(base);changed['enabled']=False;wait('stopped',write(changed))
        verify(f'disable-enable {cycle+1}',write(base))
    start=time.time();pid=int((app/'daemon.pid').read_text());os.kill(pid,signal.SIGHUP)
    verify('SIGHUP',start)
    start=time.time();os.kill(pid,signal.SIGKILL)
    deadline=time.monotonic()+30
    while time.monotonic()<deadline:
        time.sleep(0.5)
        try:
            if int((app/'daemon.pid').read_text())!=pid:break
        except (OSError,ValueError):pass
    else:raise RuntimeError('launchd did not replace killed daemon')
    verify('launchd crash recovery',start)
finally:
    tmp=config.with_suffix('.test-tmp');tmp.write_bytes(original);os.replace(tmp,config)
print('Recovery regression complete:',args.output,flush=True)
