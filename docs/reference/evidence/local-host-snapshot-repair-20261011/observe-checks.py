import pathlib,json,time,os,hashlib,signal,datetime
root=pathlib.Path(__file__).parent
running=True
seen=set()
def stop(*args):
 global running
 running=False
signal.signal(signal.SIGTERM,stop)
signal.signal(signal.SIGINT,stop)
def size(p):
 fs=[x for x in p.rglob('*') if x.is_file() and not x.is_symlink()] if p.exists() else []
 return {'files':len(fs),'logical_bytes':sum(x.stat().st_size for x in fs),'allocated_bytes':sum(x.stat().st_blocks*512 for x in fs)}
(root/'observer-pid.json').write_text(json.dumps({'pid':os.getpid(),'pgid':os.getpgrp()}))
while running:
 for fixture in (root/'fixtures').iterdir():
  for run in (fixture/'.orbit/tasks').glob('*/checks/*/run.json'):
   try:
    key=str(run)
    if key in seen:continue
    d=json.loads(run.read_text());os.kill(d['pid'],0)
    workspace=run.parent/'workspace'
    if not workspace.is_dir():continue
    row={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'fixture':fixture.name,'task':run.parent.parent.parent.name,'check':run.parent.name,'pid':d['pid'],'pgid':d['pgid'],'workspace':size(workspace),'objects':size(fixture/'.orbit/snapshot-objects'),'files':[]}
    for source in fixture.iterdir():
     snap=workspace/source.name
     if source.is_file() and snap.is_file() and not snap.is_symlink():row['files'].append({'path':source.name,'source_inode':source.stat().st_ino,'workspace_inode':snap.stat().st_ino,'same_inode':source.stat().st_ino==snap.stat().st_ino,'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'workspace_sha256':hashlib.sha256(snap.read_bytes()).hexdigest()})
    with (root/'in-flight-storage-observations.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
    print(json.dumps({'observed':fixture.name,'check':run.parent.name,'pid':d['pid']}),flush=True);seen.add(key)
   except (OSError,ValueError,KeyError):pass
 time.sleep(0.5)
print('observer stopped',flush=True)
