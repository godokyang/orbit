# ADR-004：角色规则上下文与 EvidenceRecord 逐记录绑定

- 状态：Proposed
- 日期：2026-07-28
- 最近修订：2026-07-30
- 范围：运行时规则解析、角色上下文投递、implementation/review/test evidence、gate
- 当前实现状态：仅为设计结论，尚未修改 Orbit CLI、schema、模板或运行时规范
- 父架构：[ADR-003：Lead 编排的动态 Agent Team 与上下文治理](./003-lead-orchestrated-dynamic-agent-team.md)
- 切换约束：[ADR-005：Orbit v2 一次性切换与旧协议退役](./005-orbit-v2-clean-cut-and-legacy-retirement.md)

## 背景

Orbit 已经为 coding、review 和 testing 提供角色规范：

- `lead` / `coder` 默认读取 `coding-guideline.md`；
- `reviewer` 默认读取 `quality-outcome-and-review.md`；
- `tester` 默认读取 `testing-guideline.md`；
- 所有角色默认读取 `SKILL.md` 和 runtime guide；
- 项目可以在 `.orbit/roles.yaml` 中为 role 叠加规则；
- task contract 提供本轮 `quality_rules`、`acceptance`、`evidence_requirements`、`source_documents` 和停止条件。

默认映射由 [`DEFAULT_RULE_REFERENCES`](../../lib/orbit/core.rb) 确定；角色、项目和 task 规则由 [`identity_rules_context.rb`](../../lib/orbit/identity_rules_context.rb) 解析。`orbit rules print-context` 会生成 `load_order`、`required_files`、冲突信息和 context hash，`orbit start` / `orbit dispatch` 通过 `context_preflight` 告诉目标 agent 应运行哪些命令和读取哪些文件。

当前机制已经解决“规范在哪里”和“这个角色应该读取什么”两个问题，但还没有完整解决：

- 某一条 implementation/review/test evidence 当时绑定的是哪个角色规则快照；
- manifest 级单个 `rule_resolution` 被后续角色覆盖后，如何保留各记录自己的规则依据；
- `required_rule_files_read` 是 agent 自报时，如何避免把自报误当成读取证明；
- coding 是否需要模仿 review，逐条声明自己遵循了 guideline；
- 如何区分规则投递、模型阅读、规则应用和最终结果正确性。

本 ADR 是 [ADR-003](./003-lead-orchestrated-dynamic-agent-team.md) 的 evidence 信任链子协议。ADR-003 定义动态团队、WorkUnit、append-only WorkUnitAttempt 和上下文边界；本 ADR 只定义 attempt assignment 与每条 EvidenceRecord 如何绑定角色规则上下文。ADR 本身不属于默认运行规范，也不应自动加入每个 agent 的 required files。

## 当前实现核验

| 环节 | 当前状态 | 依据与边界 |
| --- | --- | --- |
| Coding / Review 规范文档 | 已有 | runtime references 已提供角色文档。 |
| 按角色选择默认规范 | 已实现 | 当前基于静态 `lead/coder/reviewer/tester` role 映射。 |
| 合并项目规则和 task contract | 已实现 | CLI 确定性解析；缺失 required 文件或身份冲突会使 resolution invalid。 |
| 生成结构化 `required_files` | 已实现 | `rules_context_pack` 生成有顺序、去重的读取清单。 |
| 将读取要求写入 start/dispatch | 已实现 | `context_preflight` 和派单文本要求 agent 读取清单。 |
| 证明规则内容已进入模型上下文 | 未实现 | 当前证明的是“生成了读取要求”，不是 trusted runtime injection。manual payload 也不是 delivery proof。 |
| Rule resolution 绑定 task/revision/role | 解析产物层面已实现 | cache identity 包含 task、revision、role 和 rules hash。 |
| 每个 EvidenceRecord 绑定自己的规则快照 | 未实现 | evidence manifest 目前只有一个可被替换的 `rule_resolution` 引用，也没有 `attempt_id`。 |
| Coding 过程证明 | 部分实现 | implementation record 有身份、task/revision、changed files、verification 和 artifact；没有 record 级规则上下文，也没有结构化 acceptance self-check。 |
| Review 过程证明 | 部分实现 | structured report 有 `rule_application` 和质量问题回答，但 `required_rule_files_read` 只做结构校验，仍是 agent 自报。 |
| 证明模型真正理解规范 | 不应作为技术目标 | 文件访问、prompt 注入或自报都不能证明模型内部理解和注意力。 |
| 验证输出是否符合规范 | 部分实现 | 依赖结构化 evidence、独立 review/test、task acceptance 和 gate；不能由规则读取记录单独证明。 |
| ADR-003 自动生效 | 不适用 | ADR 是架构决策来源，不是每轮 runtime rule。 |

具体实现边界包括：

- [`task_workflow.rb`](../../lib/orbit/task_workflow.rb) 在 task start 时为 implementation authority 生成 resolution，并挂到 evidence manifest；
- [`task_herdr_probe.rb`](../../lib/orbit/task_herdr_probe.rb) 为目标 instance 生成 `context_preflight`；
- [`task_herdr_exec.rb`](../../lib/orbit/task_herdr_exec.rb) 把读取要求写入 dispatch message；
- [`review-report.yaml`](../../skills/orbit/assets/templates/review-report.yaml) 要求 reviewer 填写 `required_rule_files_read` 和 `applied_checks`；
- [`evidence_submit_validate.rb`](../../lib/orbit/evidence_submit_validate.rb) 当前只校验 `required_rule_files_read` 是字符串数组，并校验 applied check 的结构；
- [`validate_gate_commands.rb`](../../lib/orbit/validate_gate_commands.rb) 在 strict write policy 下可以阻塞缺少 rules context hash 的 gate record，但没有证明该 hash 对应提交者自己的完整 role context；
- [`evidence_submit_validate.rb`](../../lib/orbit/evidence_submit_validate.rb) 的 `evidence_attach_rule` 当前把 manifest 的 `rule_resolution` 赋值为最新 attachment，而不是保留逐记录历史。

## 问题判断

### “给过文档”不等于“遵循了文档”

需要区分六个不同事实：

```text
rule exists
  -> rule selected for role/task
  -> read requirement delivered
  -> content injected or accessed
  -> output claims rule application
  -> observable outcome satisfies contract
```

前一个事实不能自动证明后一个事实：

- 文件存在不证明它适用于当前 role；
- `required_files` 已生成不证明消息已送达；
- 消息已送达不证明内容进入可信模型上下文；
- 文件被读取不证明模型理解或持续注意；
- agent 声明 applied 不证明实际行为符合规则；
- 输出格式合法不证明 quality outcome 达成。

因此，Orbit 不应建立一个名为“AI 已理解全部规则”的 verdict。可验证对象应是规则选择与版本、可信投递能力、可观察操作、输出 evidence 和独立结果判断。

### Manifest 级规则引用不能表达多 attempt、多角色任务

一个 TaskRevision 可以为同一 WorkUnit 创建多个 implementation attempts，也可以为 review、test 和 release 创建独立 attempts。它们的 agent instance、context generation、authority snapshot、role、required rules、提交时间和规则版本可能不同。

manifest 只有一个可变 `rule_resolution` 时，会产生以下歧义：

- task start 挂载 implementation resolution，successor attempt 或 reviewer 提交时仍可能引用 predecessor/implementation 规则；
- reviewer 重新 attach 后，manifest 只保留 reviewer resolution，implementation 原始上下文不可恢复；
- 后续规则文件变化时，无法判断某条旧 record 使用的是旧规则还是当前规则；
- handoff 只能总结 manifest 当前引用，不能逐条说明 evidence 的规则依据。

assigned 规则上下文属于 WorkUnitAttempt 的不可变 assignment snapshot；submitted 规则上下文属于 EvidenceRecord 的提交上下文。两者都不属于 manifest 的单一全局属性。

### Coding 不应增加仪式性合规自报

Review 的职责是作出独立判断，因此需要说明检查了哪些 outcome、反例、evidence 和 residual risk。Coding 的职责不同。

要求 coder 复制一份长 guideline checklist，并逐项写“已遵循”，主要产生的是作者自证，不能提高实现正确性的可信度。Coding 更有价值的结构化输出是：

- 改动为什么属于当前 scope；
- acceptance 各项的结果与证据；
- changed files 和 verification；
- root cause 或 change thesis 是否变化；
- 哪些假设被推翻；
- known gaps 和 residual risk。

这些事实可以被 reviewer、tester 和工具独立复核。

## 决策一：规则上下文逐 EvidenceRecord 绑定

每条会影响 task outcome 或关闭 gate 的 EvidenceRecord，必须绑定 `attempt_id` 和自己的 submitted rule resolution。WorkUnitAttempt 则绑定 assignment-time rule resolution。两者共同说明“agent 被什么规则授权”和“提交时实际适用什么规则”，但都不声称模型理解了规则。

建议概念结构如下：

```yaml
# Proposed，不是当前 schema。
work_unit_attempt:
  attempt_id: wattempt-...
  work_unit_id: wu-...
  agent_instance_id: reviewer-...
  context_generation: 2
  assigned_rule_resolution_id: rr-sha256-aaa...

evidence_record:
  evidence_record_id: evr-...
  attempt_id: wattempt-...
  submitted_rule_resolution_id: rr-sha256-aaa...
  rule_resolution_comparison: matched
```

约束包括：

1. `RuleResolutionArtifact` 由 Orbit CLI 的受控路径生成；正常 evidence payload 不能提交自选 hash、role、required rules 或 artifact body。当前信任级别仍是 audit-only，不声称抵抗具有同等文件系统权限的手工篡改。
2. 每个 resolution artifact 是 content-addressed、create-only 的不可变 artifact；`resolution_id` 由 canonical identity bytes 的 SHA-256 得出，目标路径已存在但 canonical identity 不同必须 fail closed，禁止 current 文件或同路径原地覆盖。
3. artifact payload 同时绑定 `protocol_epoch + task_id + task_revision_id + work_unit_id + attempt_id + resolved_role + agent_instance_id + context_generation`。
4. required rules 只属于各自的 resolution artifact，并保存稳定 `rule_id`、relation、canonical path 和 content digest；Attempt/EvidenceRecord 只引用 resolution ID，不复制 required rule 列表。
5. WorkUnitAttempt 的 `assigned_rule_resolution_id` 在 attempt 创建后不可替换；EvidenceRecord 的 `submitted_rule_resolution_id` 在 record 写入后不可替换。
6. v2 manifest 不保留可覆盖的全局 rule resolution；attempt 和 record 的引用是唯一权威依据。
7. compact summary、audit 和 handoff 应保留每个 accepted attempt/evidence/gate evaluation 的 resolution identity，不复制全部规则正文。

content-addressed artifact 概念结构：

```yaml
# Proposed，不是当前 schema。
schema_version: orbit-rule-resolution-v2
resolution_id: rr-sha256-...
identity:
  identity_schema: orbit-rule-resolution-identity-v1
  protocol_epoch: orbit-v2
  project_id: orbit-project-...
  task_id: otask-...
  task_revision_id: trev-...
  work_unit_id: wu-...
  attempt_id: wattempt-...
  resolved_role: reviewer
  agent_instance_id: reviewer-...
  context_generation: 2
  required_rules:
    - rule_id: orbit_default:reviewer:quality-outcome-and-review
      relation: baseline
      path: skills/orbit/references/runtime/quality-outcome-and-review.md
      content_sha256: ...
identity_sha256: ...
envelope:
  created_at: ...
```

Hash domain 与 canonicalization 冻结如下：

1. identity bytes 是 `identity` object 按 RFC 8785 JSON Canonicalization Scheme 序列化后的 UTF-8 bytes；schema 实现不得依赖 YAML key order、平台换行或语言 runtime 的 map iteration order。
2. resolver 在 canonicalization 前把 rule path 规范为经过 repository containment 与 symlink resolution 的 project-relative POSIX path，拒绝 absolute path、`.`/`..` segment 和同一文件的 alias；字符串使用 Unicode NFC。
3. `required_rules` 按确定性 tuple `(relation precedence, rule_id, path, content_sha256)` 排序，其中 relation precedence 是 schema 冻结的 ordinal；同时拒绝重复 `rule_id` 或重复 canonical path，array order 因而不取决于发现顺序。
4. `resolution_id = "rr-sha256-" + SHA256(identity_bytes)`，`identity_sha256` 是同一 digest。`resolution_id`、`identity_sha256`、top-level `schema_version`、`envelope.created_at`、存储路径和其他 envelope metadata 都不进入 hash domain，避免自引用和时间导致的非幂等。
5. assigned 与 submitted 解析相同 attempt identity/rules 时必须产生相同 identity bytes 和同一 resolution ID。若目标 artifact 已存在，writer 只能在其 identity 重新 canonicalize 后与预期 bytes、digest、ID 全部一致时复用现有完整 artifact；不得重写 `created_at`。任一不一致都 fail closed。
6. 同一输入重复解析是 required deterministic behavior，不是“创建另一个等价 artifact”。并发 create 使用 create-if-absent/atomic rename 等等价原语，loser 读取并执行上述 exact identity 复核。

## 决策二：Attempt assignment 与提交时解析必须分开记录

创建 WorkUnitAttempt 时先预分配 `attempt_id`，再生成 content-addressed assigned resolution，并通过单次 `AttemptCreated` event 固化 Assignment snapshot；`orbit evidence add --kind implementation` 和 `orbit evidence submit` 在写 EvidenceRecord 前重新生成 submitted resolution：

```text
preallocate attempt_id without creating an active Attempt
  -> resolve assigned rules for attempt identity/authority
  -> create assigned RuleResolutionArtifact
  -> atomically append AttemptCreated with assigned resolution ID
     -> event timestamp is the only started_at source
     -> event establishes initial active status
  -> dispatch or manual payload
  -> agent performs work
  -> resolve submitter identity
  -> load current TaskRevision, WorkUnit, Attempt and ChangeThesis revision/digest
  -> resolve submitted rules for the same attempt
  -> create submitted RuleResolutionArtifact
  -> compare assigned/submitted canonical identities
  -> reject missing/conflicting/stale/mismatched context for accepted evidence
  -> append EvidenceRecord with attempt_id and submitted resolution ID
```

`AttemptCreated` append 失败时不得 dispatch，也不得 post-create patch Attempt；刚创建但未被引用的 resolution artifact 保持 immutable，可在审计确认无引用后回收。terminal time/status 只来自后续 append-only lifecycle events。

Agent 不负责：

- 决定本轮 required rules；
- 计算或提供权威 rules hash；
- 声称一个别的 role resolution 也适用于自己；
- 通过手写 manifest 把旧 resolution 变成当前依据。

如果提交时规则内容已经变化，Orbit 不能把新规则静默归因给已经完成的工作，也不能用 submitted artifact 覆盖 assigned artifact。该 WorkUnitAttempt 不得产生可关闭 gate 的 accepted EvidenceRecord；lead 必须按变化影响追加 terminal attempt event，并以新的 context generation、authority snapshot 和 assigned resolution 创建 successor attempt，或显式终止工作。

## 决策三：读取声明与可信投递分离

`required_rule_files_read` 不再充当 gate 级读取证明。

v2 删除 `required_rule_files_read`。Orbit 已知的文件列表来自 resolver，不要求 agent 重复填写，也不以 agent 自报表达读取、投递或理解。

若未来 runtime 提供可信的 context injection 或文件读取 receipt，应使用独立事实表达：

```yaml
# Proposed。
rule_delivery:
  mode: trusted_context_injection | tool_access_receipt | manual_instruction
  delivered_rule_resolution_id: rr-sha256-...
  provider_assertion_ref: ...
  status: verified | unverified
```

其中：

- `trusted_context_injection` 只能由能证明输入内容和目标 session 的 provider/runtime 产生；
- `tool_access_receipt` 只证明发生了读取动作，不证明理解；
- `manual_instruction` 只证明生成了说明，不是 delivery proof。

当前 Herdr 能力边界仍以 [ADR-002](./002-herdr-runtime-identity-boundary.md) 为准，不能用 pane id、环境变量或派单文本伪造 verified delivery。

## 决策四：Coding 证明 Task 对齐，不自证 Guideline 合规

Coding evidence 不复制 Review 的 `rule_application` 模型。建议补充面向 task contract 的事实：

```yaml
# Proposed。
implementation_check:
  attempt_id: wattempt-...
  change_thesis_ref:
    change_thesis_id: thesis-...
    revision: 2
    digest: sha256:...
  scope_match:
    status: pass | partial | blocked
    evidence: ...
  acceptance_results:
    - acceptance_id: acc-...
      status: pass | fail | not_run
      evidence_record_refs: []
  change_thesis_status:
    status: supported | contradicted | revision_requested
    evidence: ...
  assumptions_changed: []
  known_gaps: []
```

`implementation_check.change_thesis_ref` 必须与 WorkUnitAttempt assignment snapshot 中的稳定 thesis revision/digest 完全一致；WorkUnit 只有不可变 `initial_change_thesis_ref`，没有可覆盖的 current pointer。如果 thesis 已修订，旧 attempt 不能提交看似支持新 thesis 的 evidence，必须创建 pin 新 revision/digest 的 successor attempt。`acceptance_results` 只允许引用当前 TaskRevision 定义、且被 WorkUnit `acceptance_refs` 选中的 acceptance IDs。

`changed_files`、verification、artifact provenance 和 attempt-bound role execution context 继续保留。实现者的判断仍然是 EvidenceRecord，不是独立 verdict；reviewer/tester 必须能从源码、命令、artifact 和真实路径复核。

如果 TaskRevision 缺少稳定 acceptance ID、quality outcome 或 WorkUnit 缺少明确 refs，应该先修合同，而不是让 coder 用自由文本弥补。

## 决策五：GateEvaluation 唯一拥有 evaluator verdict

Review/test 提交可以由一个受控命令接收，但必须拆成权威边界明确且不可双写的对象：

- evaluator `EvidenceRecord` 只保存 `attempt_id`、submitted rule resolution、artifact/observation provenance、commands/runtime receipts 和稳定 source refs；
- `GateEvaluation` 唯一保存 `quality_outcome_verdict`、`quality_question_answers`、`acceptance_results`、`counterexample_cases`、`confirmed/assumed/missing`、coverage、residual risk 和 `finding_refs`；
- `Finding` 唯一保存 finding body、severity、blocking identity 和 source evidence refs；GateEvaluation 只引用 `finding_id`，不复制 finding body；
- EvidenceRecord 不得保存 evaluator verdict、question/acceptance answers、finding body 或可被 Gate Engine 当作 verdict 的同义字段。

`GateRequirement` 先冻结 subject selector，而不是预先猜一个未来 attempt：

```yaml
# Proposed，不是当前 schema。
gate_requirement:
  gate_requirement_id: gr-...
  subject_selector:
    scope: task_wide | selected_work_units
    work_unit_refs: []
    implementation_attempt_policy: all_accepted_contributors_to_snapshot
    evidence_record_policy: all_accepted_required_evidence_for_selected_attempts
    repository_snapshot_required: true
    code_surface_required: true
    freshness: exact_current_subject
```

task-wide selector 的 `work_unit_refs` 为空表示从 active TaskRevision 确定性枚举所有 in-scope WorkUnit，不表示“没有 subject”。selector 解析必须生成 canonical、完整、有序的 subject manifest；漏掉一个符合 selector 的 WorkUnit/implementation Attempt/EvidenceRecord 即无效。

建议 GateEvaluation 至少包含：

```yaml
# Proposed，不是当前 schema。
gate_evaluation:
  gate_evaluation_id: ge-...
  gate_requirement_id: gr-...
  gate_requirement_digest: sha256:...
  task_id: otask-...
  evaluator_attempt_id: wattempt-review-...
  evaluator_submission_record_id: evr-review-...
  subject:
    task_revision_id: trev-...
    work_unit_refs: [wu-a, wu-b]
    implementation_attempt_refs: [wattempt-impl-a, wattempt-impl-b]
    evidence_record_refs: [evr-impl-a, evr-impl-b]
    repository_snapshot_ref:
      artifact_ref: artifact-repo-snapshot-...
      digest: sha256:...
    code_surface_ref:
      derivation_version: code-surface-v1
      digest: sha256:...
    subject_digest: sha256:...
  quality_outcome_verdict: pass | fail | partial
  quality_question_answers: []
  acceptance_results: []
  counterexample_cases: []
  confirmed: []
  assumed: []
  missing: []
  coverage: ...
  residual_risk: ...
  finding_refs: []
  supersedes_gate_evaluation_id: ge-previous
```

字段消费者、寻址和 provenance 约束如下：

- `quality_question_answers` 只能回答当前 TaskRevision 定义的稳定 task question IDs；对应 `GateRequirement` 必须明确列出 required question IDs，Gate Engine 按 ID 集合与 verdict 校验，不能按字段存在或数量关 gate；
- `acceptance_results` 只能引用 subject TaskRevision 的 acceptance IDs，并受全部 subject WorkUnit `acceptance_refs` 合集限定；
- `applied_checks` 从默认 v2 report/schema 删除。只有未来某个明确 `GateRequirement` 定义了稳定 rule IDs、每个 ID 的判定语义和消费者时，才可作为 rule-ID keyed 结果重新设计；不得恢复自由 check ID，也不得靠存在或数量关 gate；
- 每个 GateEvaluation 直接绑定 `evaluator_attempt_id`。`evaluator_submission_record_id` 必须唯一指向同一 evaluator attempt 的 reviewer/tester EvidenceRecord；该 record 的 submitted resolution 与 Attempt 的 assigned resolution 必须通过本 ADR 的 canonical identity 校验；
- subject task revision、WorkUnit refs、implementation Attempt refs、EvidenceRecord refs、repository snapshot 和 CodeSurface digest 必须形成 immutable canonical subject digest；`work_unit_id` 不得同时表示 evaluator provenance 与 subject；
- subject selector 为 task-wide 时必须覆盖全部匹配 WorkUnit 及其 accepted implementation attempts/evidence；selected-work-unit selector 必须精确覆盖 GateRequirement refs，不能由 evaluator 自选更小集合；
- validator 用所有 subject Attempt/EvidenceRecord producer agent identities 与 evaluator agent identity 计算 `GateRequirement.independence`，任一 self-review/不满足隔离约束都会使 GateEvaluation 无效；
- subject ref 缺失、未 accepted、与 subject revision 不一致，或在 closure 前出现 selector 应纳入的新 accepted Attempt/EvidenceRecord、repository snapshot/CodeSurface digest 变化时，GateEvaluation 变为 stale，不能关闭新结果；
- 受控 submit 可以原子创建 EvidenceRecord、GateEvaluation 与 Finding，但每个字段只写入上述唯一 owner；事务失败不得留下可关闭 gate 的半套对象。

`subject_digest` 使用与本 ADR rule identity 相同的 RFC 8785 canonical JSON + SHA-256 机制，hash domain 包含 GateRequirement ID/digest、subject TaskRevision、排序后的 WorkUnit/Attempt/EvidenceRecord refs 及各自 content digests、repository snapshot ref/digest、CodeSurface derivation version/digest；不包含 evaluator provenance、verdict 或时间。相同 subject 必须得到相同 digest。

因此，review/test EvidenceRecord 证明 evaluator submission 由哪个 attempt、agent 和规则集合产生；GateEvaluation 的 subject manifest 证明该 verdict 评了哪些不可变结果。GateEvaluation 才是 gate verdict，Finding 才是问题事实。任何 reader、template 或 compatibility path 都不能把 EvidenceRecord 中的旧 review verdict 提升为 GateEvaluation，也不能把旧 subject 的 pass 复用到新 implementation/snapshot。

## 决策六：Gate Engine 验证上下文身份和结果，不验证模型心理状态

对于需要结构化规则上下文的 implementation/review/test EvidenceRecord 和 GateEvaluation，Gate Engine 至少验证：

- 每个 EvidenceRecord 的 `attempt_id` 存在且与其 task/revision/WorkUnit 一致；GateEvaluation 的 `evaluator_attempt_id` 属于 evaluator WorkUnit，不把它解释为 subject WorkUnit；
- evaluator Attempt 的 agent instance、context generation、authority snapshot 和 assigned resolution 不可变且可复核；
- submitted resolution 是 content-addressed create-only artifact，role/instance/attempt 与 assigned resolution 一致；
- required rules 仅从对应 resolution artifact 读取，content digests 可验证且无 missing/conflicting rule；
- EvidenceRecord 绑定的 ChangeThesis revision/digest 与 Attempt 一致；
- GateEvaluation 直接绑定 evaluator Attempt，并通过唯一 `evaluator_submission_record_id` 指向同一 Attempt 的 EvidenceRecord；
- GateEvaluation 的 canonical subject 完整匹配 GateRequirement selector，所有 subject refs immutable/accepted/not stale，snapshot/CodeSurface digest 可复算；
- GateEvaluation 及其 submission record 继承同一 agent/context/authority、assigned/submitted resolution 和 role 校验，EvidenceRecord 不含第二份 verdict/finding；
- GateEvaluation 的 `quality_question_answers`、`acceptance_results` 精确覆盖对应 TaskRevision/GateRequirement 要求的稳定 IDs；
- GateEvaluation 属于明确 `GateRequirement`，对全部 subject producer agents 满足 evaluator independence；其 `finding_refs` 对应稳定 Finding 且不复制 finding body；
- blocking Finding 具有有效且 authority 正确的 FindingResolution；
- initial TaskRevision 绑定 ProtocolRoot 锚定的 valid `ProjectPolicyRevision` genesis/active lineage，protected gate/waiver/risk-owner/adjudicator 不弱于 policy；缺失或伪 policy ref fail closed；
- child TaskRevision 完整继承 protected gate lineage 和 unresolved Finding；任何 gate 降级、waiver policy/risk owner/adjudicator 变化都具有由父/当前 authority 或 active ProjectPolicyRevision 签发的 provenance；
- TaskRevision 要求的 outcome、evidence level、真实路径和 waiver policy 仍然满足。

Finding resolution authority 与 ADR-003 一致：

- implementation EvidenceRecord 只能提出 `addressed`；confirmation 必须引用 authorized evaluator `issuer_attempt_id`、同 attempt submission record、assigned/submitted rule context 和 implementation proposal/supporting refs；
- `disproved` 必须引用 authorized evaluator/adjudicator attempt、同 attempt submission record、assigned/submitted rule context 和反证 refs；
- `waived` 必须引用 active `ProjectPolicyRevision` 或由其授权的 TaskRevision authorization record；自由文本 issuer/risk-owner 名称无效；
- Gate Engine 只验证并派生 closure；Lead 默认不能单方面 waive required independent gate。

Lead 新建 TaskRevision 不能改变上述 authority。initial revision 必须从 ProtocolRoot 的 immutable policy genesis ref 解析出 active ProjectPolicyRevision；不存在“无 parent 时信任 candidate”。active policy 是受控 create-only store 中从 genesis 出发的唯一有效 linear lineage tip，不使用另一份可覆盖 pointer；successor 必须由当前 tip 已授权的 policy authority 签发并与 tip 原子 compare-and-append。后续 validator 必须将 candidate revision 与当前/父 revision/policy 比较，并使用变更前已经生效的 authority 验证 protected change；candidate revision 新声明的 risk owner/adjudicator 不能批准或裁决该 revision。旧 TaskRevision provenance 不改写但 closure stale，继续执行必须新 revision rebind active policy。missing/forged ref、digest mismatch、多个有效 tip 或 lineage fork fail closed。unresolved blocking Finding 跨 revision 保留，直到产生 authorized resolution。

### 权威记录使用 create-only lifecycle

`EvidenceRecord`、`GateEvaluation` 和 `Finding` 一经创建即 immutable；每个对象保存 canonical content digest，create-only store 拒绝同 ID 异内容、原地覆盖和删除。相同 create request 的 retry 只能在 ID/content digest 完全一致时幂等返回既有对象。

这里的 `accepted` 表示对象通过 controlled writer validation 后被 create-only store 接纳；invalid submission 不产生权威对象。后续 revision/subject/snapshot 变化只会确定性派生 `stale/invalid_for_closure`，不能回写 record status 或改旧内容。

纠错或重评创建新 ID，并使用类型化 `supersedes_evidence_record_id`、`supersedes_gate_evaluation_id`、`supersedes_finding_id` 或 `related_*_refs`。supersedes 两端必须属于兼容的 task/gate/subject lineage；它不把旧记录从审计历史中删除，也不自动解决旧 blocking Finding。Gate Engine 只接受符合 GateRequirement current subject/freshness policy 的 evaluation，但仍要求每个旧 blocking Finding 具有 authorized FindingResolution。

FindingResolution 继续作为 append-only event；除前述 issuer provenance 外不得原地修改 status、issuer、supporting refs 或 authority ref。被引用的 EvidenceRecord/GateEvaluation/Finding 缺失、被覆盖或 digest 不符时 closure fail closed。

Gate Engine 不产生以下结论：

- “模型完整读完了所有文件”；
- “模型理解并记住了所有规则”；
- “因为 context hash 存在，所以实现或 review 一定正确”。

语义正确性继续通过以下组合判断：

```text
Orbit schema / identity / revision / attempt 约束
  + 可复现的 implementation evidence
  + 独立 GateEvaluation 与 FindingResolution
  + TaskRevision acceptance 与 quality outcome
  + residual risk
```

最终 `AggregateOutcome` 只由 Gate Engine 对 active ProjectPolicyRevision/TaskRevision、当前 GateRequirement subject selector、canonical subject digest 完全匹配且未 stale 的 GateEvaluation、Finding/FindingResolution 和 evidence 确定性派生；它不是可提交、可覆盖或可由 Lead 直接写入的新 verdict。

## 决策七：Closure basis、Finding basis 与 verification_class

本决策由 [orbit-v2-agent-independent-control-amendments](../history/agent-independent-control-amendments.md)（owner approved 2026-08-11）引入。

### Closure basis digest 的 gate/evidence 消费边界

每次 dispatch 授权时，accepted `LeadCheckpoint` 冻结 `closure_basis_digest`，其 hash domain 只包含 dispatch 时点的 exact refs + digests：`TaskRevision`（goal、non_goals、quality outcome、acceptance、evidence_requirements、GateRequirements、task questions）、`WorkUnit`（objective、scope、authority_scope、stop_conditions、acceptance_refs）、本 Attempt 的 `change_thesis_ref`、assigned `RuleResolutionArtifact` ref、`effective_verification_plan_digest`（派生输入，派生链见下小节；单向依赖，`closure_basis_digest` 不进入其 hash domain）。排除 attempt/agent/session 身份、时间与对话内容。

消费边界：

- `EvidenceRecord`/`GateEvaluation` 只能相对其 dispatch 冻结的 `closure_basis_digest` 解释；reviewer 发现真问题只能走 `Finding`，**不得移动同一 Attempt 的完成标准**；
- **完成标准变化分级**：acceptance/evidence/gate 完成标准变化**必须**是 authorized `TaskRevision`/`GateRequirement` revision（protected lineage 校验，ADR-003/005）；仅 thesis revision、scope 或 verification-plan 变化可产生 successor basis（旧 Attempt terminal → 新 accepted checkpoint → 新 basis 的 successor dispatch），**不得借此改写 TaskRevision 完成标准**——acceptance/evidence requirement/GateRequirement 集合不变时，新 basis 必须与旧 basis 共享同一 TaskRevision 完成标准引用；
- 旧 Attempt 的 evidence/verdict 按原 basis 解释，不 latest-wins；
- `closure_basis_digest` 是 checkpoint 字段，引用权威对象 refs，不复制 task/evidence/gate truth，不成为第二事实源。

### Finding basis 与 blocking derivation

`Finding` 增加类型化 basis：`contract_violation`（偏离冻结 basis 的 acceptance/requirement/gate）、`regression`（稳定规则被破坏）、`newly_discovered_risk`（basis 之外新发现且真实影响用户/业务/稳定性）、`hardening_opportunity`（非 acceptance/core blocker 加固）。

blocking 由 Gate Engine 按 active `ProjectPolicyRevision` 映射机械派生，agent 自由文本无效：

- `contract_violation`、`regression`：默认 blocking（不得低于 policy 的 GateRequirement minimum）；
- `newly_discovered_risk`：blocking 与否由 policy/risk owner 裁决；若 blocking 且无法 authorized `addressed/disproved` → `needs_user`（risk acceptance）；
- `hardening_opportunity`：默认不阻塞，进入新 `WorkUnit`，不得抢占 active mainline（ADR-006）。

`FindingResolution` authority（addressed/disproved/waived）与 issuer provenance 不变。

### EvidenceRequirement verification_class

`EvidenceRequirement`（`TaskRevision` 拥有）增加 `verification_class` 枚举，dispatch 时随 closure basis 冻结。三类**互斥**：

- `regression`：稳定程序规则（合成 fixture 可复现）→ 永久自动化测试；
- `release_audit`：**动态/时效性数据与发布时检查**（当前数据质量、动态快照）→ 发布审计记录，不成为永久测试；
- `acceptance_evidence`：**本任务一次性 URL/截图/人工复验**（本轮验收证据）→ 绑定 Attempt 的 `EvidenceRecord`，证明本次交付，不承担未来防回归。

validator **只校验结构化 class 与证据用途兼容性**，机械兼容依据固定的最小结构化字段：`EvidenceRecord.implementation_check.evidence_requirement_results[].verification_use`（docs 设计，Slice 3 实现；**非 EvidenceRecord 顶层**）——`permanent_test_evidence`（配 `regression`）、`audit_record_evidence`（配 `release_audit`）、`acceptance_proof_evidence`（配 `acceptance_evidence`）。validator 按 result 的 `evidence_requirement_id` 解析 TaskRevision requirement 的 `verification_class`，校验 exact class/use 配对，并校验该 result 的 evidence_refs 解析到兼容的 `ArtifactClaim.kind`（`permanent_test_evidence` → `verification`；`audit_record_evidence`/`acceptance_proof_evidence` → `report`）。单个 record 可按不同 result 同时满足不同 verification_class。缺 use、未知 use、错配、引用不兼容 claim kind 全部 fail closed。**不解析、不判断自由文本里的动态数据或稳定 signal**；事实分类（稳定规则 vs 数据快照 vs 一次性复现）属 Lead/reviewer 语义判断，留 provenance。

### effective_verification_plan_digest 的 assignment/context 规则

**canonical `effective_budget_bindings`（预算派生的事实基础）**：每个 dispatch checkpoint 固定保存 `effective_budget_bindings`——恰好两项，按 `budget_scope_type` 固定顺序 `work_unit_lineage`、`task_lineage`，各 scope 唯一一项。每项包含：scope、exact active policy ref+digest、effective count/LOC limits、**canonical `measurements`：固定键序的 `measurements.test_count` 与 `measurements.test_code_lines` 两项，各自 `status=verified|unverified`**——verified 必须 `usage>=0` + exact provider/snapshot ref+digest；unverified 必须 usage/ref/digest 为 canonical null，并绑定 **typed `unverified_assessment`（固定字段顺序 `lead_disposition`、`lead_reason_code`、`lead_supporting_refs`、`review_status`、`review_gate_evaluation_ref`；`lead_disposition` 与 `review_status` exact mapping——pending→`proceed_pending_independent_review`、accepted→`proceed_after_independent_review`、rejected→`replan_after_independent_rejection`，unknown/mismatch fail closed；`lead_supporting_refs` 为 sorted unique exact ref+digest，`review_status=pending|accepted|rejected`——pending 时 review ref canonical null，accepted/rejected 时必须 exact independent GateEvaluation ref+digest **且该 GateEvaluation 必须携带评审当前预算 binding 的 `budget_assessment_result`（见下）**，普通无关 GateEvaluation 引用 fail closed；准入/切片规则见 ADR-006 Amendment 节）**；禁止把 null 当 0、禁止宣称 within-budget；数值预算机械 pass/overrun 只对 verified metric 派生；`source_kind=policy_default|lead_adjustment|user_override`，及对应 source：`policy_default` 用 canonical null/no-adjust 表示（明确无调整）；`lead_adjustment` 引用当前 checkpoint 内可独立求 digest 的 adjust payload（其 `budget_adjustment_digest`，current），或前序 accepted checkpoint ref+digest+其 `budget_adjustment_digest`（inherited）；`user_override` 引用预先存在的 `AuthorizationRecord` ref+digest 并带 `mode=consume|inherit`（consume 仅首次消费 checkpoint 可用、该 checkpoint 成为 `origin_consuming_checkpoint`；inherit 绑定 origin consuming checkpoint ref+digest + 原 AuthorizationRecord ref+digest 沿同 project/policy/TaskRevision/scope/`lead_control_id` 连续 accepted lineage，ceiling 不变且无 superseding source；第二次 consume、跨 lineage/task/policy/scope inherit、跳 origin、inherit 改 ceiling 均 fail closed；authority 规则见 ADR-006 Amendment 节）。**授权（adjust/override）只绑定 predecessor binding digest 间接冻结观测，不携带 measurement tuple**；writer 对新 checkpoint 的 current measurements 单独按 canonical verified/unverified 规则派生并以新 ceiling 判定。不得漏任一 scope、重复 scope、乱序或混用 source fields；缺任一 scope 的预算事实即 fail closed；measurement 缺/混合字段、unverified 带数值、verified 缺 ref/digest、把 unknown 当 0 均 fail closed。两层同时生效由两项 bindings 表达；旧有效调整/override 沿 accepted checkpoint lineage 精确引用，**不 latest-wins 猜测**。当前 checkpoint 最多零或一个 `test.budget.adjust` payload（reconcile 单动作）；`budget_adjustment_digest` 仅在有 adjustment 时存在，无调整时明确 absent、不伪造空 digest。**old/new 校验只适用于 current adjustment 的 authoring checkpoint**：`adjust.old_effective_budget` 必须等于该 scope 在 authoring checkpoint 时的前一 binding，`new` 必须在 policy ceiling 内；**inherited adjustment** 验证：origin payload 在 origin 当时与其 predecessor 匹配、当前 effective ceiling 等于 origin 的 `new`、accepted lineage 连续且无 superseding source。**`effective_verification_plan_digest` 消费完整 ordered bindings**（两项按序），而不是单个 adjustment/override。

**`budget_assessment_result`（预算评审的结构化结果，复用 GateEvaluation，不新建对象；非循环构造顺序）**：评审 unverified measurement 的 GateEvaluation 携带 `budget_assessment_result`，绑定被评 binding **所在的前序 accepted checkpoint**（`assessed_checkpoint_ref+digest`，即 review 消费前的 `C_pending`）、`assessed_effective_budget_binding_digest`、`lead_control_id`、`budget_scope_type`、固定 metric identities/status（`measurements.test_count`/`test_code_lines` 各自 status）；typed `outcome=accepted|rejected`，并与 `unverified_assessment.review_status`/`lead_disposition` exact mapping（accepted→`proceed_after_independent_review`、rejected→`replan_after_independent_rejection`）。**构造顺序（单向，无自引用）**：① 先接受 `C_pending` checkpoint——该 scope binding 为 unverified 且 `review_status=pending`、`review_gate_evaluation_ref` canonical null；② 独立 GateEvaluation 评审 `C_pending` 的 exact binding（`assessed_checkpoint_ref+digest=C_pending`、被评 binding digest、scope/control/metric statuses），产出 outcome，并将 `budget_review_subject_projection` hash 纳入 canonical subject；③ successor `C_reviewed` checkpoint 消费该 GateEvaluation ref+digest，binding `review_status`/`lead_disposition` 与 outcome exact match——**`C_reviewed` 只能引用 predecessor `C_pending` 的 assessment，不得让 evaluation 绑定 `C_reviewed` 自身**；④ successor 需 exact predecessor/accepted-lineage，且 `C_reviewed` 与 `C_pending` 的 `budget_review_subject_projection` byte-identical（stale 判定见下）。该 budget subject/result **纳入 GateEvaluation canonical subject manifest/digest**；**GateRequirement selector 必须明确要求该 budget assessment**（budget-assessment kind），不得复用普通 implementation gate。`review_gate_evaluation_ref` 仅当 exact subject/result match（assessed checkpoint/binding/scope/control/outcome 一致）、not stale、evaluator independent 时有效；same-checkpoint circular ref、跨 checkpoint/跨 binding 引用、普通无关 GateEvaluation、successor 引用非 predecessor 或 stale assessment 必须 fail closed。budget assessment 准入 authority 见 ADR-006 Amendment 节。

**`budget_review_subject_projection`（stale 判定的确定性投影，可重算、不持久化新对象）**：从被评 `effective_budget_binding`（`C_pending`）投影**除三个 review-result 字段外**的全部字段——仅排除 `unverified_assessment.review_status`、`lead_disposition`、`review_gate_evaluation_ref`；`lead_reason_code`、`lead_supporting_refs` 及 scope/policy/ceilings/measurements/source 等全部保留；该 projection 的 hash 纳入 GateEvaluation canonical subject。**stale 判定**：`C_reviewed` 必须与 `C_pending` 的该 projection byte-identical——只允许上述三字段按 evaluation outcome 从 pending/null 映射为 accepted|rejected、对应 disposition 与 exact evaluation ref；**任何其他字段变化即 stale，必须生成新的 pending checkpoint 后重评**。**不得要求 `C_reviewed` 完整 binding digest 等于 `C_pending`**（二者按设计不同，review-result 字段必然变化）；也不得以完整 binding digest 相等作为 fresh 依据。

不存在可写的 "effective verification plan" 对象；只有确定性派生的 `effective_verification_plan_digest`。唯一权威输入：active `ProjectPolicyRevision`（budget default/ceiling、verification policy）+ `TaskRevision`/`EvidenceRequirements`（acceptance、`verification_class` 集合、GateRequirements）+ assigned `RuleResolutionArtifact` ref + `effective_budget_bindings`（含 `test.budget.adjust` typed payload 与**预先存在的** `test.budget.override` `AuthorizationRecord`，create-only，独立于 checkpoint，consuming checkpoint 只引用 ref+digest）。

确定性派生顺序（单向、无自引用）：先独立 canonicalize `test.budget.adjust` payload 得 `budget_adjustment_digest`（预像绑定 active policy ref+digest、`budget_scope_type`、**exact predecessor checkpoint ref+digest、该 scope 的 predecessor effective-budget-binding digest、absolute requested effective count/LOC ceilings**、supporting refs；**排除 enclosing checkpoint ID/content digest，且不携带 measurement tuple**）——**该 digest 进入对应 binding 的 `lead_adjustment` source，仅当当前 checkpoint 存在 adjustment 时；无 adjustment 时 `budget_adjustment_digest` 明确 absent**——→ 再以**完整 ordered `effective_budget_bindings` + 其余权威输入**（不含 bindings 之外的任何 adjustment digest）计算 `effective_verification_plan_digest`（RFC 8785 canonical JSON + SHA-256，同本 ADR resolution identity 规则）→ 再作为派生输入纳入 `closure_basis_digest`。**覆盖规则**：enclosing checkpoint ID/content digest 不进入 `budget_adjustment_digest` 或任何上游派生预像；`effective_verification_plan_digest` 与 `closure_basis_digest` 始终是 checkpoint 正文字段并受最终 checkpoint identity/content digest 覆盖，`budget_adjustment_digest` 仅在当前 adjustment 存在时（iff present）同为正文字段并受覆盖；`closure_basis_digest` 不进入 `effective_verification_plan_digest` 的 hash domain——无 digest 循环、无自引用、无 plan truth 对象。

accepted `LeadCheckpoint` 只 pin source refs+digests，且**始终 pin `effective_verification_plan_digest` 与 `closure_basis_digest`；`budget_adjustment_digest` 仅当当前 checkpoint 存在 `test.budget.adjust` payload 时 pin，无 adjustment 时明确 absent**；任何 Attempt 若其 permission/capability profile 包含 test-write、verification-submit 或 gate-close 能力，其 context projection 必须重算或从 checkpoint 下发同一 `effective_verification_plan_digest` 及其 source refs；缺失/不一致则该 Attempt 的 evidence 不能关闭对应 requirement。`AttemptCreated` assignment 绑定 assigned `RuleResolutionArtifact`（本 ADR 决策一）与 dispatch checkpoint ref（ADR-006），受控 writer 在创建前校验 source refs 齐全、override 授权记录已预先存在且被引用、派生 digest 可复算，validator 复核 refs 一致。规则正文不复制进 Attempt，只引用 resolution ID。

## 不采用的方案

- 不把 ADR-003 或全部 ADR 自动加入每轮 required files。
- 不让 coder 复制完整 guideline checklist 并逐项自报 pass。
- 不把 `required_rule_files_read` 当作模型理解证明。
- 不把 prompt 长度、文件打开次数或 tool call 次数当作语义遵循指标。
- 不继续依赖一个可覆盖的 manifest 级 rule resolution 表达所有角色。
- 不用可覆盖的 `current-resolution.json`、路径或任意 hash 代替 content-addressed create-only artifact。
- 不让 agent 自己提供权威 rules hash、role 或 revision binding。
- 不因为已有 context hash 就跳过独立 review/test 或 outcome evidence。
- 不保留没有稳定消费者的 `applied_checks`。
- 不让 review/test EvidenceRecord 与 GateEvaluation 分别保存可独立修改的 verdict、answers 或 finding。
- 不让 GateEvaluation 只记录 evaluator identity 而不 pin canonical subject，或用 evaluator `work_unit_id` 代替 subject refs。
- 不让 initial TaskRevision/Lead 自报第一个 risk owner/adjudicator 作为 bootstrap authority。
- 不允许原地覆盖/删除 EvidenceRecord、GateEvaluation、Finding 或 FindingResolution。
- 不把 `resolution_id`、自身 digest 或 `created_at` 放入 hash domain。
- 不为了保存规则关系引入第二套任务事实源或图数据库。

## Orbit v2 一次性切换

本 ADR 按 [ADR-005](./005-orbit-v2-clean-cut-and-legacy-retirement.md) 实施，不提供 record 或 manifest 级兼容层：

1. 为 v2 rule resolution 定义 RFC 8785 canonical identity、明确 hash domain、content digest、create-only persistence 和 `orbit-rule-resolution-v2`。
2. 每个 WorkUnitAttempt 强制绑定 assigned resolution ID，每个 v2 EvidenceRecord 强制绑定 `attempt_id` 和 submitted resolution ID。
3. attempt creation 使用“预分配 ID → create/reuse assigned artifact → 单次 AttemptCreated event”的无 patch 流程；evidence submit 生成或复用 submitted artifact。
4. 删除 manifest 级 `rule_resolution`、旧 rules context SHA 双字段、可覆盖 current-resolution 路径和对应 fallback。
5. audit、handoff、validate 和 wait-gate 只从 attempt/record 引用加载 resolution artifact。
6. 删除 `required_rule_files_read` 与无消费者 `applied_checks` 的 schema、模板和 gate 逻辑。
7. review/test EvidenceRecord 不再保存 gate verdict/answers/findings；由 evaluator-attempt-bound、subject-pinned GateEvaluation 和独立 Finding 唯一拥有。
8. ProjectPolicyRevision genesis/rotation、ProtocolRoot genesis ref 与 initial TaskRevision bootstrap validator 一次切换。
9. EvidenceRecord、GateEvaluation、Finding 使用 create-only immutable store；FindingResolution 使用 append-only event store。
10. v1 evidence/manifest 直接返回 unsupported schema；不读取、不回填、不升级。

## 验证要求

后续实现至少需要覆盖：

- 同一 task 的 implementation、review、test record 各自绑定正确 role 的不同 context；
- 每条 EvidenceRecord 绑定正确 attempt，且 assigned/submitted resolution identity 一致；
- 相同 attempt/rules 重复解析以及 assignment/submit 两阶段解析得到 byte-identical canonical identity 与同一 resolution ID；
- 已存在 artifact 只有在 identity bytes/digest/ID 全部一致时复用；改变 `created_at`、hash 自身或字段顺序不改变 identity，任一 identity 内容差异都 fail closed；
- Attempt 不得在创建后 patch assigned resolution；AttemptCreated 失败时不得 dispatch，started_at/initial status 只来自该 event；
- reviewer 不能复用 implementation authority 的 resolution 关闭 review gate；
- task revision 变化后，旧 context 和旧 evidence 按 v2 revision invalidation contract 处理；
- rule 文件内容变化后，新 record 获得新 rules hash，旧 record 保留原 hash；
- resolution artifact 只能按 canonical content 创建；同 ID 内容不一致、同路径覆盖或 current 指针冒充 artifact 时 fail closed；
- missing/conflicting required rule 阻止 record 写入或 gate pass；
- evidence payload 不能提交自选 rules hash、role 或 manifest 引用形成有效 context；
- manual payload 只产生 unverified delivery，不升级为 trusted injection；
- implementation_check 引用错误或过期 ChangeThesis revision/digest 时被拒绝；
- `quality_question_answers` 和 `acceptance_results` 含未知、重复、缺失或越出 WorkUnit refs 的 ID 时被拒绝；
- GateEvaluation 没有 `evaluator_attempt_id`、submission record 属于不同 attempt、independence 不成立，或 EvidenceRecord 含第二份 evaluator verdict/finding 时被拒绝；
- GateEvaluation 缺 subject task revision/WorkUnit/implementation Attempt/EvidenceRecord refs、漏掉 task-wide subject、subject ref 非 accepted/已 stale、snapshot/CodeSurface digest 不匹配时被拒绝；
- 旧 pass 复用到新 implementation attempt/evidence/repository snapshot，或 evaluator agent 出现在任一 subject producer agent 集合时被拒绝；
- initial TaskRevision 自报 genesis risk owner/adjudicator、缺 user-controlled authority source、伪造 ProjectPolicyRevision ref/digest 或 policy lineage fork 时被拒绝；
- Lead 通过 child revision 删除/降级 protected gate、改 waiver/adjudication authority/risk owner、自我授权或清除 unresolved Finding 时被拒绝；
- EvidenceRecord/GateEvaluation/Finding/FindingResolution 原地覆盖、删除、同 ID 异内容或不兼容 lineage ID reuse 时被拒绝；
- addressed/disproved 缺 authorized issuer attempt/submission/rule context/supporting refs，或 waived 只提供自由文本 issuer/伪 authority ref 时被拒绝；
- implementation evidence 缺 required acceptance result 时按 TaskRevision/GateRequirement 策略 fail/partial；
- audit 和 handoff 能分别报告 accepted implementation/review/test 的 role rule context；
- v1 evidence 被明确拒绝，且 validator 不包含 fallback、guess 或 backfill 路径。

## 后果

- WorkUnitAttempt 和 EvidenceRecord 会增加少量 resolution 引用元数据，但不复制规则正文。
- 规则文件变化将更容易定位影响了哪些后续 evidence，不再依赖 manifest 当前指针推断。
- Coding 输出关注 task 对齐和可复核事实，减少仪式性自证。
- Review 仍需要人或模型作语义判断；Orbit 不声称解决模型注意力和理解不可观测问题。
- manifest、report template、evidence submit、validate、wait-gate、audit 和 handoff 必须在 v2 cutover 中一起替换，不能只修改一个 schema 字段。
- 本 ADR 不改变当前 runtime 行为；在 v2 原子切换完成前，现有规则解析和 evidence 仍按当前协议解释。
