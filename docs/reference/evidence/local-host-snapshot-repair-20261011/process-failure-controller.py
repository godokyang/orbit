import pathlib,json,time,os,subprocess,datetime,signal,sys
root=pathlib.Path(__file__).parent
fixture=root/'fixtures/process-failure'
out=root/'process-failure-evidence';out.mkdir(exist_ok=True)
(root/'process-failure-controller-pid.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp()}))
while True:
 for runfile in (fixture/'.orbit/tasks').glob('*/checks/*/run.json'):
  c=runfile.parent
  if (c/'lifecycle.json').exists() or not (c/'workspace').is_dir():continue
  try:
   run=json.loads(runfile.read_text());e=json.loads((c/'evidence.json').read_text())
   if not e.get('session_created') or not e.get('usage') or e.get('host_completion'):continue
   pid=run['pid'];pgid=run['pgid'];assert pid==pgid and pid not in [12801,12883,12966]
   os.kill(pid,0)
   q=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True,check=True)
   assert '--trusted-extension' in q.stdout and any(str(base/'installation/runtime/releases/3468fbcc398178aab350d9ec/runners/omp-reviewer/reviewer.ts') in q.stdout for base in [root,root.resolve()])
   assert run['output_dir']==str(c.resolve())
   for f in ['run.json','scope.json','snapshot-archive.json','evidence.json']:(out/('pre-fault-'+f)).write_bytes((c/f).read_bytes())
   (out/'pre-fault-state.json').write_bytes((c.parent.parent/'state.json').read_bytes())
   data={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'action':'SIGKILL owned independent checker process group','pid':pid,'pgid':pgid,'precondition':'real compiled trusted factory path + owned output_dir + full workspace + session_created + at least one actual usage receipt + no host completion/lifecycle','actual_reported_calls_before_fault':len(e['usage']),'task':c.parent.parent.name,'check':c.name,'source_modified':False,'provider_refusal_claim':False}
   (out/'intervention.json').write_text(json.dumps(data,indent=2));os.killpg(pgid,signal.SIGKILL);print(json.dumps(data),flush=True);sys.exit(0)
  except (OSError,ValueError,KeyError,AssertionError,subprocess.CalledProcessError):pass
 time.sleep(.2)
