import {writeFileSync} from "node:fs";
import {postmortem} from "@oh-my-pi/pi-utils";
export default async function(api) {
 const pi=api.pi; const receipt={ok:false,factory_reached:true,model_requests:0,pid:process.pid,session_created:false,session_disposed:false,signal_cleanup:false};
 const save=()=>writeFileSync(process.env.ORBIT_PROBE_OUT,JSON.stringify(receipt));
 let session;
 postmortem.register("orbit-owned-private-probe",async(reason)=>{if(session){await session.dispose(); receipt.session_disposed=true;} receipt.signal_cleanup=true;receipt.cleanup_reason=reason;save();});
 try {
  const profile=process.env.PI_CODING_AGENT_DIR;const cwd=process.cwd();
  const authStorage=pi.discoverAuthStorage(profile);
  const modelRegistry=new pi.ModelRegistry(authStorage,profile+"/models.yml");
  ({session}=await pi.createAgentSession({cwd,agentDir:profile,authStorage,modelRegistry,
   settings:pi.Settings.isolated({"memory.backend":"off","memories.enabled":false,"stt.enabled":false,"fetch.enabled":false,"web_search.enabled":false,"github.enabled":false,"bash.enabled":false,"autolearn.enabled":false,"checkpoint.enabled":false,"goal.enabled":false,"retry.enabled":false}),
   sessionManager:pi.SessionManager.create(cwd,profile+"/sessions"),toolNames:[],restrictToolNames:true,
   enableMCP:false,enableIrc:false,enableLsp:false,disableExtensionDiscovery:true,skills:[],rules:[],contextFiles:[],promptTemplates:[],slashCommands:[],agentRegistry:new pi.AgentRegistry(),agentId:"OrbitNoModelProbe",hasUI:false,skipPythonPreflight:true}));
  receipt.session_created=true; await session.dispose(); session=undefined; receipt.session_disposed=true;receipt.ok=true;
 } catch(error) {receipt.error=String(error);}
 save(); await new Promise(()=>{});
}
