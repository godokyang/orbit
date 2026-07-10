# Orbit 用户视角功能评估

评估日期：2026-07-10

## 评估边界

本次评估没有读取 `docs/` 下任何既有文档。结论只来自：

- CLI、Ruby 实现、安装/卸载脚本、配置与报告模板；
- 从安装到 task、evidence、state、gate、audit、dispatch 的实际命令行旅程；
- 现有自动化测试及额外反例测试。

测试环境为 macOS arm64、Ruby 2.6.10、Herdr 0.7.1、Orbit 0.1.10。临时目录中的本地安装、初始化和手工工作流均使用仓库当前代码。

## 一句话结论

**当前 Orbit 已经是一个功能扎实的 agent 工作流审计/治理内核，但还不是一个能开箱完成自动多 agent 闭环的产品。**

它确实能缓解角色越权、证据失配、旧 verdict 冒充当前结果、状态与 artifact 不一致、长任务难交接等真实问题；但自动运行链路目前无法取得可信 runtime identity，任务合同又允许在没有具体用户结果和验收标准时通过结构校验。因此它更适合愿意接受严格流程、并能手工协调角色的高风险团队，不适合作为普通开发者处理日常任务的低摩擦默认工具。

综合判断：**有条件达标**。

- 作为手工/半自动协议与审计工具：达标，且可靠性基础较好。
- 作为防止 agent “假完成”的完整证据系统：部分达标，能防结构错误，不能独立证明事实真实。
- 作为自动多 agent 调度与闭环运行时：未达标。
- 作为面向普通用户的开箱产品：未达标，认知和操作成本偏高。

## 用户问题与当前效果

| 用户实际问题 | 当前效果 | 判断 |
| --- | --- | --- |
| 不知道当前 agent 是谁、能做什么 | `whoami`、role、instance、capability、execution contract 能 fail closed | 已解决 |
| agent 做了动作就声称任务完成 | quality outcome、review/test gate、audit、stale revision 检查能显著降低风险 | 部分解决 |
| 多角色结果互相覆盖或错人提交 | gate role、task hash、runtime attribution、verdict arbitration 校验较完整 | 基本解决 |
| 长任务中断后难接手 | state、evidence、handoff、compact summary 提供了可恢复 artifact | 基本解决 |
| 自动启动和派发 reviewer/tester | `start` 能操作 Herdr，但可信身份无法建立，direct dispatch 不能进入 ready | 未解决 |
| 小任务也要维护大量协议字段 | 默认 task 和输出过重，缺少渐进式交互 | 未解决 |
| 判断自然语言请求应走什么流程 | 分类器能处理显式关键词，但常见中文表达会误判 | 部分解决 |

## 已经做得好的地方

### 1. 协议安全边界是认真实现的

身份、角色、instance、task revision、gate verdict 和 runtime attribution 不是只靠提示词约定，而是进入了结构化校验。错误角色、错误 instance、过期 task hash、stale verdict、伪造 runtime marker、缺失 test environment 等情况都有对应 guard。对一个目标是约束 agent 行为的工具，这是最有价值的部分。

文件更新使用锁和原子替换，安装与卸载也会检查目标归属，体现了对并发写入和用户文件安全的关注。

### 2. 对“质量结果”而非“动作完成”的建模方向正确

task 中已经有 quality outcome、invalid completion、review questions、risk level、test environment、release readiness、destructive action、retention 等结构。这些字段覆盖的正是 agent 工程中最常见的假完成、证据污染、危险操作和发布遗漏。

### 3. 回归测试覆盖广

完整 `npm test` 通过，测试脚本报告 `REAL_TESTS_PASS count=951`，退出码为 0，耗时约 88.8 秒。19 个测试分片覆盖安装、身份、task/evidence、gate、handoff、破坏性操作、runtime reconcile、retention、release readiness、dogfood governance 等路径。对当前版本来说，协议内部一致性有较强保障。

### 4. 手工工作流能够实际使用

真实走通了以下路径：本地安装 → `init` → `whoami` → `new-task` → `validate` → `evidence init` → `rules resolve/print-context` → `state start` → `wait-gate` → `audit` → manual dispatch。

缺少 review/test evidence 时，`wait-gate` 正确返回非 ready；身份不匹配和证据结构错误也会失败。对于明确接受手工派单和人工维护报告的团队，这已经能提供实用价值。

## 关键问题

### P0：自动 Herdr 闭环在当前实现中不可达

这是影响产品定位的首要问题。

- `runtime_trusted_caller_proof` 固定返回 `available: false`（`lib/orbit/runtime_commands.rb:166`）。
- resolver 的 proof provider 也固定返回 `false`（`lib/orbit/runtime_resolver.rb:30`）。
- 因此 runtime 只能停在 `identity_pending`，无法产生可信的 `herdr_verified` session，也无法让 `dispatch_ready` 变成 true。
- gate 默认只接受 `herdr_verified` 或 `manual_runtime`，不接受 `identity_pending`。实际在 Herdr pane 中提交 implementation pass evidence 会被 validate 拒绝。
- 测试套件的成功闭环会主动清除 Herdr 环境变量，以 `manual_runtime` 注册角色（`tests/orbit_test.sh:173`）。这验证了手工协议，但没有证明自动 runtime 可闭环。
- `tools detect` 只要发现 Herdr 就宣称存在 `direct.dispatch` capability（`lib/orbit/audit_tools.rb:859`），与实际可用性不一致。

用户后果：界面和命令让人以为 Orbit 能启动、识别并直接派发 agent，但真正需要自动派单时只能退回 manual payload。安全上 fail closed 是正确的，产品上则意味着核心自动化尚未交付。

建议：

1. 在 Herdr 提供不可伪造的 caller/session proof 前，把产品明确分成 `manual` 与 `automatic-preview` 两种模式，不再报告 `direct.dispatch` 可用。
2. 设计带 nonce、project hash、instance hash 和短 TTL 的可信握手，由 Herdr/受控服务签发，而不是读取进程环境变量。
3. 增加真正的 provider E2E：`start -> verified -> dispatch_ready -> direct dispatch -> role evidence submit -> wait-gate ready`。这条路径没有通过前，不应把 automatic runtime 作为已实现能力。

### P1：空任务合同可以被判定为 valid

默认 task 的 `source_contract.required_outcomes`、`traceability`、`acceptance`、`evidence_requirements` 都为空，quality outcome 仍是通用占位文案（`skills/orbit/assets/templates/task.yaml:17`、`:38`、`:49`）。实测新建一个 `coding` task 后，生成文件约 237 行、6.9 KB，但未经任何业务填写就能通过 `orbit validate --task ...`。

原因是 validator 主要检查字段是否存在、类型是否正确；`required_outcomes` 和 `traceability` 允许空数组（`lib/orbit/validate_task_contract.rb:720`），通用 task 也没有要求 `acceptance` 非空。

用户后果：Orbit 能证明“协议文件结构正确”，却不能证明“任务描述足以验收”。如果 reviewer/tester 继续提交形式正确但内容空泛的报告，流程仍可能形成自洽的假完成。

建议：

- 区分 `draft-valid` 与 `execution-ready`；前者允许模板占位，后者必须有具体 user problem、至少一个 required outcome、acceptance、evidence requirement 和 traceability。
- standard/strict/release task 在 `state start` 前强制执行 execution-ready 校验。
- 检测仍等于默认模板的占位文案，不能把模板原文视为真实 quality outcome。
- light task 可以走精简合同，但仍需一个明确结果和一个可观察验收项。

### P1：证据系统强于“声明格式”，弱于“事实绑定”

implementation evidence 当前可以只记录 `kind/status/summary/created_at`，再附角色上下文（`lib/orbit/evidence.rb:693`）。review/test 的 `artifacts` 也是字符串列表；系统会校验字段、身份和状态，但不会普遍验证 artifact 是否存在、是否新鲜、是否由对应命令产生、是否与当前 commit/task revision 一致。

项目自己也明确以 `audit_only` 描述 trust model。这是诚实的边界，但意味着 Orbit 主要防误用和流程漂移，不能防止 agent 认真地提交一份内容不真实但 schema 合法的报告。

建议：

- 为 artifact 引入结构化引用：`path`、`sha256`、`producer_command`、`created_at`、`git_head`、`task_sha256`、生命周期。
- coding/implementation pass 至少要求 changed files + verification，或明确的 no-change reason。
- review/test pass 应能引用并交叉校验 implementation artifact，而不是只引用自由文本路径。
- 将“文件存在、hash 匹配、生成时间晚于 task revision”做成通用 verifier。

### P1：安装要求与手工模式能力矛盾

安装脚本无条件要求 Herdr（`install.sh:126`），但 `tools doctor` 的设计又承认没有 Herdr 时 manual protocol 和 JSON/file handoff 仍然有效。当前用户即使只想用手工审计模式，也无法通过正式安装脚本安装。

建议提供：

- `install.sh --mode manual|automatic`，默认先安装可工作的 manual 模式；
- automatic 模式再检查 Herdr 和可信 proof provider；
- `orbit tools doctor` 输出“已安装但自动能力不可用”的可执行修复步骤。

### P1：意图分类会把常见任务降级为 discussion/light

分类器按第一个关键词命中，且 `问题` 的 discussion 规则排在 `分析/修复/实现` 之前（`lib/orbit/identity_rules_context.rb:618`）。反例测试结果：

| 输入 | 实际分类 |
| --- | --- |
| `审视一下当前项目是否解决用户问题` | discussion / light |
| `评估一下当前功能是否达到效果` | discussion / light |
| `修复这个问题` | discussion / light |
| `分析并修复这个问题` | discussion / light |
| `检查这个实现有没有问题` | discussion / light |

本次用户请求本身也被误判为 discussion。虽然分类结果是建议而非最终权限判断，但它会让依赖 CLI 建议的 agent 跳过 formal task/evidence。

建议：

- 不要用 `问题` 单独判定 discussion；动作词应高于主题词。
- 返回所有命中信号、冲突和置信度，而不是只返回第一个结果。
- 支持 `--intent review|coding|...` 显式覆盖，并记录 override reason。
- 把真实中英文用户表达加入 table-driven regression cases。

### P2：认知与上下文成本过高

默认 `coding` task 实测生成 237 行；一次 lead 的 required context 包括 skill、runtime guide、coding guideline 和 task，约 1,185 行。`rules print-context`、`audit`、`dispatch` 的 JSON 常达到数百行。对 agent 这是显著 token 成本，对人类则很难快速回答“现在卡在哪里、下一步做什么”。

建议：

- 增加 `orbit status` / `orbit next`，默认输出 10～20 行人类摘要；`--json` 再输出完整协议。
- `rules print-context` 默认只输出 active required files、hash 和冲突，完整 resolution 用 `--verbose`。
- task 采用 light/standard/strict/release 的渐进 schema 或生成视图；不适用字段不要全部铺在默认文件里。
- 增加一个高层命令完成常见手工链路，例如创建 task 时同时初始化 evidence、解析 rules、启动 state。

### P2：CLI 帮助与分发界面不完整

`audit --help`、`start --help` 等命令可用，但 `init --help`、`new-task --help`、`instances --help`、`state --help`、`tools --help`、`whoami --help`、`bind-pane --help` 会返回 usage error。路由差异可以从 `lib/orbit/cli.rb:29` 看到。

此外，npm package metadata 没有 `bin` 或 `main`（`package.json:1`）。如果 npm 包只用于分发 skill 资源，应在名称/metadata 中明确；如果期望用户通过 npm/npx 使用 CLI，则需要提供可执行入口。

## 建议的产品优先级

### 第一阶段：先让能力边界真实、手工模式好用

1. 将 manual mode 定义为当前稳定主路径，安装不再强依赖 Herdr。
2. 修复 `tools detect` 对 `direct.dispatch` 的误报。
3. 增加 execution-ready 校验，禁止空 acceptance/contract 进入执行。
4. 增加 `orbit status` / `orbit next` 和全命令一致的 `--help`。

这一阶段完成后，Orbit 可以成为可信、可推荐的“agent 工作流审计 CLI”。

### 第二阶段：让证据真正绑定事实，并降低流程成本

1. 结构化 artifact 引用、hash/freshness/git head 校验。
2. 精简 task profile 和一键常见工作流。
3. 改进中英文意图分类，加入显式 override。
4. 为人类输出 compact summary，保留 JSON 作为机器接口。

### 第三阶段：完成真正的自动多 agent 闭环

1. 与 Herdr 建立不可伪造的 runtime identity proof。
2. 打通 direct dispatch、ack、completion notice 和 gate evidence。
3. 用真实 provider E2E 验证整条路径，而不是用 handwritten session 或 manual runtime fixture 代替。

## 建议的验收标准

下一版若要宣称“解决用户实际问题”，至少应满足：

- 无 Herdr 时可以安装并完整使用 manual workflow。
- standard 及以上 task 在 acceptance、required outcomes 或 traceability 为空时不能进入 working。
- `orbit status` 能用一屏说明 phase、阻塞项、最近 verdict、下一条命令。
- 常见手工任务从 init 到可执行状态不超过 5 条命令。
- 中文 `修复这个问题`、`审视当前项目`、`评估功能效果` 不再被降级为 discussion/light。
- artifact pass 可验证文件存在、hash、task revision 和 git head。
- 至少一条真实 Herdr E2E 能稳定得到 `dispatch_ready: true`，完成 direct dispatch，并由目标 role 提交可关闭 gate 的 evidence。

## 最终判断

Orbit 不是“没有效果”。相反，它已经解决了 agent 工程中很难、也很真实的一部分问题：**如何把身份、任务、证据、gate、审计和交接从聊天约定变成结构化协议。** 这部分代码质量和测试基础值得保留。

但用户真正想要的通常不是维护一套协议文件，而是让任务更可靠地完成。当前版本在“可靠审计”上强，在“低摩擦完成”和“自动协作”上弱。最合理的产品策略不是继续横向增加 schema 字段，而是先收紧任务语义、诚实区分 manual/automatic 能力、做出一屏可理解的状态与下一步，然后再完成可信 runtime identity。做到这些，Orbit 才会从一个扎实的协议内核变成能持续解决用户问题的产品。
