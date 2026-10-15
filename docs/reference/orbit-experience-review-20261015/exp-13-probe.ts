import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import path from "node:path";
export default async function(api: any) {
 const { AgentRegistry, createAgentSession, discoverAuthStorage, ModelRegistry, SessionManager, Settings } = api.pi;
 const root=process.env.EXP13_PROBE_ROOT!;
 const profile=path.join(root,"profile");const cwd=path.join(root,"workspace");
 mkdirSync(profile,{recursive:true});mkdirSync(cwd,{recursive:true});
 const result:any={binary:process.execPath,model_prompt_invoked:false};let session:any;let auth:any;
 try {
  auth=await discoverAuthStorage(profile);
  const registry=new AgentRegistry();
  const manager=SessionManager.create(cwd,path.join(profile,"sessions"));
  await manager.newSession();
  const made=await createAgentSession({cwd,agentDir:profile,authStorage:auth,modelRegistry:new ModelRegistry(auth),
   settings:Settings.isolated({"memory.backend":"off","memories.enabled":false,"stt.enabled":false,"fetch.enabled":false,"web_search.enabled":false,"github.enabled":false,"bash.enabled":false,"autolearn.enabled":false,"checkpoint.enabled":false,"goal.enabled":false,"retry.enabled":false,"prewalk.enabled":false}),
   sessionManager:manager,toolNames:[],restrictToolNames:true,
   enableMCP:false,enableIrc:false,enableLsp:false,disableExtensionDiscovery:true,skills:[],rules:[],contextFiles:[],promptTemplates:[],slashCommands:[],agentRegistry:registry,agentId:"Exp13Probe",hasUI:false,skipPythonPreflight:true});
  session=made.session;
  // No prompt or model request is made. Only native session transitions run.
  function capture(){const ref=registry.get("Exp13Probe");return {sessionId:session.sessionId,managerId:session.sessionManager.getSessionId(),liveFile:session.sessionFile,managerFile:session.sessionManager.getSessionFile(),registeredFile:ref?.sessionFile,registrySessionId:ref?.session?.sessionId,orbitCurrentLookup:ref?.sessionFile,proposedLiveLookup:ref?.session?.sessionFile};}
  session.sessionManager.appendMessage({role:"user",content:[{type:"text",text:"Local session-path probe; no model request."}],timestamp:Date.now()});
  await session.sessionManager.flush();
  result.before=capture();
  result.initialFileExists=!!readFileSync(result.before.liveFile,"utf8");
  result.newSessionReturned=await session.newSession();result.afterNew=capture();
  result.switchReturned=await session.switchSession(result.before.liveFile);result.afterSwitchBack=capture();
  result.switchNewReturned=await session.switchSession(result.afterNew.liveFile);result.afterSwitchNew=capture();
  result.liveFileMatchesManager=[result.before,result.afterNew,result.afterSwitchBack,result.afterSwitchNew].every(x=>x.liveFile===x.managerFile);
  result.reproduced=result.afterNew.sessionId!==result.before.sessionId && result.afterNew.registeredFile===result.before.registeredFile && result.afterNew.liveFile!==result.afterNew.registeredFile;
 } catch(e:any){result.error=String(e);result.stack=e?.stack;}
 finally {if(session)await session.dispose();if(auth?.close)await auth.close();writeFileSync(path.join(root,"probe-result.json"),JSON.stringify(result,null,2));}
 setInterval(()=>{},1000);
 return await new Promise(()=>{});
}
