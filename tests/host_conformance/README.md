# 宿主一致性测试

这里放宿主接入的一致性探针，判定规则见 `docs/plan/host-conformance.md`。

- `../../tests/host_conformance_test.rb`：合同形状与适配层声明的静态一致性；随 `npm test` 运行。
- `zero_model/`：不需要模型调用的探针（状态、目录、绑定、空闲停止）。
- `real_model/`：需要真实模型与可运行宿主的探针（登记失败、停止确认、只读检查者）。

真实模型组要求 `ORBIT_REAL_ACCEPTANCE=1`，未设置时记为 skipped，不记为通过。探针结果按 `docs/plan/host-conformance.md` §6 的 JSON 形状保存。
