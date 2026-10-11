import pathlib,json,time,os,subprocess,datetime,sys
root=pathlib.Path(__file__).parent
fixture=root/'fixtures/failure-v3'
task=fixture/'.orbit/tasks/b04bc927-ac24-455b-bb81-ba5cbd898de1'
out=root/'in-flight-cancel-evidence';out.mkdir(exist_ok=True)
(root/'cancel-controller-pid.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp()}))
while True:
 for c in (task/'checks').glob('*'):
  if not c.name.isdecimal() or int(c.name)<2 or (c/'lifecycle.json').exists() or not (c/'workspace').is_dir():continue
  try:
   run=json.loads((c/'run.json').read_text());os.kill(run['pid'],0)
   info=json.loads(subprocess.run(['herdr','agent','get','w23:p1E'],capture_output=True,text=True,check=True).stdout)['result']['agent']
   if not info.get('terminal_title_stripped','').startswith('π >'):continue
   state=json.loads((task/'state.json').read_text())
   assert any(x.get('status')=='in_flight' for x in state.get('check_observations',{}).values())
   (out/'pre-exit-state.json').write_text(json.dumps(state,indent=2));(out/'pre-exit-agent.json').write_text(json.dumps(info,indent=2))
   q=subprocess.run(['herdr','agent','read','w23:p1E','--source','recent-unwrapped','--lines','60'],capture_output=True,text=True);(out/'pre-exit-herdr.txt').write_text(q.stdout)
   for f in ['scope.json','snapshot-archive.json','run.json','evidence.json']:
    p=c/f
    if p.exists():(out/('pre-exit-'+f)).write_bytes(p.read_bytes())
   data={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'action':'native Ctrl+D','precondition':'real run PID alive + independent full workspace + no lifecycle marker + check_observation in_flight + Root TUI idle','checker_pid':run['pid'],'checker_pgid':run['pgid'],'check':c.name,'source_changed':False,'initial_failure_scenario':'selection picked opencode-go; no provider failure proof; checker1 finding corrected by Root, checker2 interrupted'}
   (out/'intervention.json').write_text(json.dumps(data,indent=2))
   q=subprocess.run(['herdr','agent','send-keys','w23:p1E','ctrl+d'],capture_output=True,text=True);(out/'native-exit-response.json').write_text(q.stdout+q.stderr);print(json.dumps(data),flush=True);sys.exit(q.returncode)
  except (OSError,ValueError,KeyError,AssertionError,subprocess.CalledProcessError):pass
 time.sleep(0.3)
