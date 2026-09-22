#!/usr/bin/env python3
"""Passive soak telemetry: no routing changes, recordings, or device wake locks."""
import argparse,datetime,json,pathlib,re,time,subprocess
p=argparse.ArgumentParser();p.add_argument('--hours',type=float,default=8);p.add_argument('--interval',type=float,default=10);p.add_argument('--output',required=True);a=p.parse_args()
app=pathlib.Path.home()/'Library/Application Support/MacVirtualMicBridge';out=pathlib.Path(a.output);out.parent.mkdir(parents=True,exist_ok=True)
start=time.time();end=start+a.hours*3600;count=0;issues=[];previous=None
with out.open('a',buffering=1) as f:
 while time.time()<end:
  row={'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
  try:
   status=json.loads((app/'status.json').read_text());row['status']=status
   row['pid']=int((app/'daemon.pid').read_text());row['runtime']=(app/'bin/current').resolve().name
   age=time.time()-(app/'status.json').stat().st_mtime
   if age>15:row['issue']='stale heartbeat'
   elif status['state']!='running':row['issue']='not running: '+status['state']
   metrics=dict(re.findall(r'(\w+)=([-\d.]+)',status.get('message','')));row['metrics']=metrics
   if previous and previous.get('pid')==row['pid']:
    old=previous.get('metrics',{})
    for metric in ['underflow','dropped','errors']:
     delta=float(metrics.get(metric,0))-float(old.get(metric,0))
     if delta>0:row.setdefault('counterIncreases',{})[metric]=delta
   if float(metrics.get('output_peak',0))>0.00001 and float(metrics.get('delivered_peak',0))==0:
    row['issue']='source output present but virtual monitor silent'
   row['process']=subprocess.run(['ps','-p',str(row['pid']),'-o','pcpu=,rss=,etime='],capture_output=True,text=True).stdout.strip()
  except Exception as e:row['issue']=str(e)
  if 'issue' in row:issues.append({'observedAt':row['observedAt'],'issue':row['issue']})
  f.write(json.dumps(row)+'\n');previous=row;count+=1
  time.sleep(min(a.interval,max(0,end-time.time())))
 summary={'startedEpoch':start,'endedEpoch':time.time(),'samples':count,'issues':issues,
          'note':'Counter increases and physical transition records require review; silence alone is not proof of failure.'}
 out.with_suffix('.summary.json').write_text(json.dumps(summary,indent=2)+'\n')
