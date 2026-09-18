import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// A loaded host keeps resolving files (for example the CLI entry) from the
// release it was imported from. The pid lease tells the installer to keep
// that release alive until this process exits.
export function holdReleaseLease() {
  try {
    const modulePath = fs.realpathSync(fileURLToPath(import.meta.url));
    const root = path.dirname(path.dirname(modulePath));
    if (!fs.existsSync(path.join(root, '.orbit-release.json'))) return null;
    const directory = path.join(root, '.leases');
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const file = path.join(directory, `${process.pid}.json`);
    fs.writeFileSync(file, JSON.stringify({ pid: process.pid, held_at: new Date().toISOString() }), { mode: 0o600 });
    return file;
  } catch {
    return null;
  }
}
