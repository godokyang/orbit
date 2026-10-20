# 真实项目完整验证（2026-10-21）

对象：`/tmp/orbit-project-validation`，一个带失败测试的最小 Node 项目。

## 任务

Root 真实模型指令：实现 `src/sum.js`、运行 `npm test`、`orbit check`、修正后复检、finish/accept、complete。

## 结果

- `src/sum.js` 实现正确；手工 `npm test`：1 pass / 0 fail。
- 任务终态 `complete`，停止确认：
  - `confirmed=true`、`missing=[]`；
  - fence/root_idle/members_stopped/checks_settled 全 true。
- 检查：
  - check #1 artifact/continue，`delivery.ready=true`、coverage 完整、0 findings；
  - check #2 artifact/complete，`delivery.ready=true`、coverage 完整、0 findings。
- 成员/单元：
  - 1 个成员 `completed`；
  - 1 个工作单元 `accepted`，attempts=1。
- 事件链 14 条：task/created → work-unit/declared → check/requested/completed → member/registered → member/settled → work-unit/finished → accepted → finalization/notice → completion/requested → stop/confirmed → task/completed。
- 合同面：`status --external-ref` 命中；`export` 生成 20 files/约 1 MB；`events` 返回 14 条 + 不透明 `next_cursor`。
- 全程 headless（`ELECTRON_RUN_AS_NODE=1`，无窗口）。

## 覆盖到的老 Orbit 功能

任务与输入、工作单元、成员派发/结算、独立 artifact 检查、覆盖与交付就绪、finalization/完成门、停止证据、严格模型授权、外部引用、事件游标、export、headless 启动。

## 本次未覆盖

JEV（未配置）、候选选型、争议/修订、resume（此前单独验证过）、Loom 后台/Temporal 整链、面板 UI（此前单独验证过）。
