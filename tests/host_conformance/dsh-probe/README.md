# DSH 宿主探针（2026-10-20）

空壳插件，不含 Orbit Core。用脚本化的假模型适配器（provider `probe`）驱动真实的 DSH agent 循环，逐项验证
[实施计划](../../../docs/plan/dsh-implementation-plan.md)依赖的宿主接缝。结论见
[探针记录](../../../docs/plan/dsh-host-probes.md)。

前提：本机安装 DeepSeek Harness 桌面版 0.2.1-rc.2 并注册 `dsh` 命令；Node 24。探针在独立的 `DSH_HOME` 下运行，
不碰用户的 `~/.dsh`。P6 另需把 `@deepseek-ai/dsh-subagent-dsh-sdk` 与 `@deepseek-ai/dsh-sdk-client` 装进 profile。

```sh
export DSH_HOME=/tmp/orbit-dsh-probe
tests/host_conformance/dsh-probe/run-probe.sh p7-credentials p1-registration p2-toolgate p3-projection p4-archive p5-answerer
tests/host_conformance/dsh-probe/run-probe.sh s1-stop-member s2-stop-job s3-s5-fence s4-resume-fence
tests/host_conformance/dsh-probe/run-probe.sh s6-kill-host; tests/host_conformance/dsh-probe/run-probe.sh s6-after
dsh plugin --profile orbit-probe add @deepseek-ai/dsh-subagent-dsh-sdk@0.2.1-rc.2 @deepseek-ai/dsh-sdk-client@0.2.1-rc.2
tests/host_conformance/dsh-probe/run-probe.sh p6-checker
```

不接入 `npm test`：它依赖本机 DSH 安装与真实进程，不是确定性回归。
