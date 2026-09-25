import { installOmpExtension } from './omp-host.mjs';

// Use the SDK instance injected by the OMP host (pi.pi). Importing the bare
// '@oh-my-pi/pi-coding-agent' specifier from an extension file can resolve to
// a different module instance than the host's live one, which would give the
// registration gate a dead AgentRegistry (members would start unregistered).
export default pi => installOmpExtension(pi, pi.pi);
