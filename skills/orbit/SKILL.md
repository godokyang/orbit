---
name: orbit
description: 用于 AI agent 在项目中感知或执行 Orbit 工作流：发现 .orbit 配置后先进入 Orbit-aware 模式；当目标明确且进入实现、评审、测试、验收、交接或 long-running/multi-agent workflow 时，再自动调用 orbit CLI 建立风险匹配的 task/evidence/state/gate 闭环。manual protocol 是稳定默认路径；Herdr 仅作为 automatic-preview 的 pane start/inspect adapter。需求澄清阶段不要创建 task/state/gate。
metadata:
  short-description: Orbit 风险匹配的任务闭环
---

# Orbit

Orbit 是面向 AI agent 的任务闭环协议。它把“做过动作”和“结果已被证明”分开，用 task、revision、evidence、state、gate 与 handoff 保存可接手的事实。

## 触发边界

发现 `.orbit` 配置、用户明确提到 Orbit，或当前任务进入非平凡的实现、评审、测试、验收、发布准备、交接、long-running / multi-agent 协作时，进入 Orbit-aware 模式。

只有目标、范围和验收标准已经足够明确，且工作正式进入执行或独立验证时，才启动正式闭环。需求澄清、方案讨论和探索性结对只保持 aware：不创建 task，不推进 state，不要求 gate。

仓库没有 `.orbit`、用户也未要求 Orbit，且只是简单问答或一次性低风险小改时，不自动启用。

## 风险选择

创建 task 时按结构化 change surface 与 risk sink 选择级别；自然语言分类只能给建议，不能降低 task 已声明的风险或绕过 gate。

- `light`：局部、可逆、没有敏感 sink；允许最薄验证。
- `standard`：常规产品或代码变更；要求具体 outcome、acceptance 与 implementation evidence。
- `strict`：认证、权限、持久化数据、跨系统、破坏性路径、真实用户关键链路；要求独立 review/test 与真实路径证据。
- `release`：发布、迁移、回滚或生产变更；在 strict 基础上要求 release readiness。

不能确认风险时使用更高一级，并把原因写入 task。涉及 `auth`、`data_loss`、`external_side_effect`、`billing`、`privacy` 或 `production` sink 时不得只按关键词降级。

## 最短闭环

CLI 可用时由 agent 自己执行，不要求用户代跑常规命令：

1. 首次接入运行 `orbit init --operation-mode solo|team`。
2. 用 `orbit task draft --task-type TYPE --output .orbit/tasks/NAME.yaml ...` 创建风险感知草稿，填入真实 outcome、acceptance、evidence 与 traceability。
3. 用 `orbit task start --task .orbit/tasks/NAME.yaml` 一次完成 execution-ready 校验、revision 冻结、evidence 初始化、规则解析/挂载和 state start。
4. 用 `orbit status` / `orbit next` 读取一屏状态；实现后提交 changed files、verification 与需要的 artifact provenance。
5. required review/test 必须由对应独立角色通过结构化 report 和 `orbit evidence submit` 提交；用 `orbit wait-gate`、`orbit validate`、`orbit audit` 验证，不直接编辑 evidence 伪造 verdict。
6. 完成前生成 `orbit handoff`；长任务按需运行 `orbit compact-evidence` 保存一份 durable summary。

task 启动后合同语义变化必须运行 `orbit revision create`，让 Orbit 精确失效受影响的 evidence。solo 实现与自测完成、但独立验收尚缺时，状态必须是 `implemented_not_independently_accepted`，不能宣称 done。

## Runtime 真实性

manual file/JSON protocol 是稳定默认路径。pane、tab、环境变量、旧 binding、client name、手写 session 或 `automatic-preview` 都不是可信 identity / delivery proof。

只有 capability truth source 明确返回 `automatic`，且目标 resolver 返回 `dispatch_ready: true`，才能 direct dispatch。否则用 `orbit dispatch --manual-payload`；manual payload 只证明生成了投递 artifact，不证明目标已收到。

Herdr 是独立项目。其公开 CLI、socket API、integration 和 plugin 可以启动、观察或控制 pane，但不能认证“当前 Orbit 调用进程属于哪个 pane”。因此当前产品只有 `automatic-preview`，不得生成 `herdr_verified`、`dispatch_ready: true` 或可信 direct dispatch。未来只有 Herdr 公开提供可独立复核的 server-owned caller-to-pane assertion 后，才能另行设计和验收 automatic 模式；不得用环境变量、pane id、plugin context 或模拟 provider 替代该信任根。

notice 是 protocol inbox record，不等于 pane delivery。无法验证的 `herdr_verified`、stale/replaced/override identity 不能关闭 gate。

## 按需读取

正式执行先运行 `orbit rules print-context --task PATH`，只读取其 active `required_files`。需要完整审计记录时加 `--json` 或 `--verbose` 并用 `--output` 保存。

- 最小运行说明：`references/runtime/guide.md`
- 字段和状态语义：`references/runtime/core-operating-model.md`
- 实现规则：`references/runtime/coding-guideline.md`
- review / quality outcome：`references/runtime/quality-outcome-and-review.md`
- 测试与真实路径证据：`references/runtime/testing-guideline.md`
- 文档地图：`references/overview.md`

role identity 以 `orbit whoami --json` 为准；有 conflicts 就停止执行并报告。项目规则只能叠加，不能替代 Orbit 默认规则。

## 停止与升级

目标不明确、缺少外部权限或密钥、需要破坏性操作或公开发布、规则/身份冲突、required evidence 缺失时停止并请求用户或 owner 决策。缺 verdict、质量问题未关闭或真实路径未覆盖时默认 fail / escalation。

初始化模板位于 `assets/templates/`；review/test report 使用其中对应模板。汇报时说明当前 gate、已验证结果、剩余风险和下一步。
