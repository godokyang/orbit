import * as sdk from '@oh-my-pi/pi-coding-agent';
import { installOmpExtension } from './omp-host.mjs';
export default pi => installOmpExtension(pi, sdk);
