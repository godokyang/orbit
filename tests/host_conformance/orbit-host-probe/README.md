# Orbit DSH host probe (T1)

Loads the built `@orbit/dsh-host` plugin into an isolated DSH home and drives a
real agent loop with a scripted fake model. This is a zero-model wiring test:
it proves the plugin registers, the `orbit` tool reaches Core, a controlled
subagent dispatch is registered before model work, and the stop fence refuses a
later dispatch. It is not a real-model or full B1 acceptance.

```sh
pnpm --filter @orbit/dsh-host build
DSH_HOME=/tmp/orbit-host-probe tests/host_conformance/orbit-host-probe/run-probe.sh
```

Output is JSON lines in `$DSH_HOME/results/orbit-host.out`. The script copies
the bundle into the profile so `@deepseek-ai/*` imports resolve inside DSH, as
the host probe notes require. Nothing touches the user's `~/.dsh`.

Not part of `npm test`: it needs the desktop DSH installation and real child
processes.
