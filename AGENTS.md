# AGENTS.md — 工程协作与测试规范

> 本文件约束在本仓库工作的开发 Agent。核心目标：**正确、高质量、可维护地完成用户任务**，防止协作、测试或协议操作偏离交付目标。
>
> 本文件及 `docs/agents/` 是**开发 Orbit 的客户端纪律**，不产生 Orbit 产品运行事实。产品规则由 `contracts/task-runtime.md` 与 ADR-008/009 定义；[ADR-011](docs/adr/011-agent-autonomy-and-runtime-responsibility.md) 已替代部分职责与限制，Orbit 阶段一已实施，Loom 阶段二的实现与验证状态见交接及待办（对外集成合同见 `contracts/integration.md`、ADR-010）。实际会话、检查和停止结果由运行程序记录。用户明确指令优先；改变产品语义时先处理对应合同和决策，不用开发规范伪造完成或停止。

## 按需加载（动手前先读）

本文给出开发规则入口、测试与范围纪律。产品裁决不在这里，**不要凭本文推断该做什么**。

- 在本仓做任何实现、重构或文档改动前，先读 [docs/README.md](docs/README.md)：它说明哪类事实归哪个文件，以及哪些层没有裁定权。
- 开始方案评估、实现、验证或协作前，读取 [docs/agents/development-workflow.md](docs/agents/development-workflow.md)，按其中任务类型选择直接处理或协作。只放链接不算已加载；派发时按该文传递相关规则与当前授权。
- 承接交付任务前，先读 [docs/plan/handoff.md](docs/plan/handoff.md)（含当前实际任务计划指向）。用户新要求涉及既有决定时明确差异后再修改权威正文；已结束的旧阶段不是待办，历史按需从 Git 查阅。
- 动 `lib/` 或 `contracts/` 前，查 [docs/plan/debt-ledger.md](docs/plan/debt-ledger.md)：有意推迟的项目及其解除条件都在那里。
- 现行语义以 `contracts/task-runtime.md`、检查结果 schema 与 `docs/adr/008-omp-native-collaboration-base.md`、`docs/adr/009-user-selected-model-pool.md` 为准。散文与合同冲突时以合同为准。
- 面向外部集成方的命令、字段与能力以 `contracts/integration.md/.json` 和 `docs/adr/010-integration-contract.md` 为准，改动前先看其兼容规则（同一主版本只加不改不删）。
- 历史方案、阶段计划、验收记录与证据原件已不在当前树：需要时用 `git show aa089bb:<原路径>` 查阅（见 [docs/README.md](docs/README.md)），不要据此推断当前能力。
- 外部项目资料只按当前任务需要读取，不产生本仓执行规则，也不是使用或开发 Orbit 的前置条件。不自动加载外部项目规范或执行其专用命令。

同一上下文已读且未变的规则不重复全量加载；任务范围变化时只补相关来源。恢复会话时核对当前有效版本和未完成事实。

已确认并将作为执行依据的架构或产品决定，写入对应权威文件并记录理由。讨论中的候选方案留在方案材料中，不提前写成已生效规则。

## 版本号管理

需要更新产品版本号时，默认只将最后一位（patch）加一，例如 `0.6.0 → 0.6.1`。前两位（major、minor）由用户决定，只有用户明确指定时才调整，不根据功能规模或破坏性变更自行提升。

默认使用 `npm version patch --no-git-tag-version` 同步 `package.json` 与锁文件。此规则不要求每次文档修改或提交都升版，也不自动授权打标签、发布或推送。

## 任务优先级

1. 理解真实需求
2. 完成核心功能
3. 保持修改范围可控
4. 验证关键行为
5. 补充必要测试

不要为了追求完整性或覆盖率而扩大任务范围。

## 测试定位

测试是辅助验证手段，不是目标本身。它用于：

- 验证业务正确性
- 防止核心功能回归
- 提供修改信心

## 编写测试前

新增测试前必须回答：

1. 这个修改影响什么用户行为？
2. 哪些业务规则必须保证？
3. 哪些场景存在真实回归风险？

只有能提供实际价值的场景才写测试。

## 测试范围

**优先测试：**

- 核心成功流程：正常创建、更新、提交、状态流转
- 重要业务分支：权限不足、状态不允许操作、关键参数校验失败
- 历史问题与高风险逻辑：曾出 bug 的场景、容易被改坏的规则

**避免测试：**

- 框架自身行为：Spring/MyBatis 已保证的功能、第三方 SDK 内部逻辑
- 无业务价值的边界：极端字符串长度、不可能出现的数据、人工无法触发的异常
- 实现细节：私有方法步骤、getter/setter、临时变量、重构不影响的结构
- 假设性风险：仅"理论上可能发生"，而非真实影响业务

## 测试规模建议

- 新增测试数量建议 ≤ 10 个
- 新增测试代码建议 ≤ 300 行

超过建议时说明必要性、真实业务风险和已有测试为何不足；范围需要扩大时取得确认，已有明确授权不重复询问。数字不是自动拒绝、拆票或降低验收的理由。这是开发本仓的测试建议，不是 Orbit 产品的资源硬上限。

## 实施顺序

理解需求 → 拆解核心流程 → 实现主要功能 → 运行已有测试 → 补充必要测试 → 验证需求完成

禁止：

- 因测试覆盖不完整而暂停主功能开发
- 在核心功能未完成前大量编写测试
- 为测试而改变业务实现

## 覆盖率原则

覆盖率不是最终目标。不要因为覆盖率下降或分支未覆盖而机械加测试。

判断标准：删除这个测试后，团队发现真实问题的能力会下降吗？不会 → 不保留。

## 测试设计方式

用 Given / When / Then 描述用户行为：

- Given 一个待支付订单 / When 用户取消订单 / Then 订单状态变为取消

不推荐：null 组合、随机字符串、不可能状态、内部方法调用路径。

## 任务范围控制

完成当前任务即可，不主动：

- 重构无关代码
- 修改无关模块
- 引入新测试框架
- 优化已有架构
- 清理历史代码

除非用户明确要求。

## 代码审查标准

新增测试前问自己：一个有经验的工程师是否愿意长期维护这个测试？答案是否定 → 不要添加。

## 需求与测试冲突时

优先完成需求主线；测试只能作为辅助验证手段，不能阻塞核心功能实现。

> 遇到"为了覆盖用例连主线任务都不管"的情况，本质是优先级排序错误，不是测试能力不足。

## TeamAI 共享规范与技能

共享源为 [team-rules](https://github.com/zeen-chat/team-rules)。默认只选 `core`：8 个 global、21 个 project 技能；不选可选技能组和 MCP。项目事实、已有规范与当前用户授权继续生效。

新电脑先按 [首次安装](https://github.com/zeen-chat/team-rules/blob/main/docs/agent-integration.md#新电脑首次安装)准备环境，再在本仓根目录运行：

```bash
teamai init https://github.com/zeen-chat/team-rules.git --scope project --role core
```

选择实际使用的工具；OMP、OpenCode、Kimi 按共享指南用 `--agent` 指定。已有安装用 `teamai pull` 同步，检查 `teamai doctor` 和 `.teamai/native-skills-result.json`；报告须为 `complete` 且指向当前项目，再新开会话。

按任务读取项目根目录 `.teamai/docs/README.md` 所列正文；同步和网页链接不代表模型已读取。技能由 npx skills 管理，TeamAI 按组调用安装；安装目录、缓存、链接和本机凭据不提交。项目自定义技能继续在 `.agents/skills/orbit-real-acceptance/` 维护。

使用 OpenCode 时，先读取项目根目录 `.opencode/rules/engineering.md`、`.opencode/rules/testing.md`、`.opencode/rules/workflow.md`。共享文件缺失时先 `teamai pull`；仍不可读则报告具体缺失。
