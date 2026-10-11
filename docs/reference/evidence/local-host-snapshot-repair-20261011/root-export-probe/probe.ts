import {writeFileSync} from "node:fs";
import * as utils from "@oh-my-pi/pi-utils";
export default async function(api) {
 const pi=api.pi;
 const exports=Object.fromEntries(["createAgentSession","discoverAuthStorage","ModelRegistry","AgentRegistry","SessionManager","isAuthenticated"].map(k=>[k,typeof pi[k]]));
 exports["Settings.isolated"]=typeof pi.Settings?.isolated;
 const dirs=Object.fromEntries(["getBaseConfigRoot","getModelDbPath","getProfileRootDir","resolveProfileEnv"].map(k=>[k,typeof utils[k]]));
 writeFileSync(process.env.ORBIT_PROBE_OUT,JSON.stringify({ok:Object.values(exports).every(v=>v==="function")&&Object.values(dirs).every(v=>v==="function"),exports,dirs,factory_reached:true,exit_before_host_session:true,agent_dir:process.env.PI_CODING_AGENT_DIR,pid:process.pid}));
 process.exit(0);
}
