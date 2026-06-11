# Orbit Coding Guideline

本文是运行时 coding 规范，面向 `lead` 和 `coder`。它回答一个问题：实现代码时怎样保证改动能被 review/test 独立验证，而不是只靠实现者自述。

本规范抽象自已有项目实践，以及 Waza / brooks-lint 中关于证据、scope、维护性和代码衰减的可迁移规则。它不是通用代码风格大全，也不替代项目自己的语言、框架和架构规范。

## Coding 目标

coding 的目标不是“把代码写出来”，而是让 task contract 中的质量结果变成可验证的软件变化。

每次实现至少要留下：

- 改了哪些文件。
- 为什么这些文件属于当前 scope。
- 哪些旧路径、旧状态或旧 artifact 被关闭或降级。
- 哪些命令、测试、截图、日志或 artifact 证明实现可用。
- 哪些风险仍未覆盖，并且为什么不阻塞当前任务。

## 输入顺序

开始 coding 前，按顺序读取：

1. 当前 task contract。
2. 本项目 `.orbit/roles.yaml` 中当前 role 的 rules。
3. 相关 source documents、design docs 或 issue。
4. 当前代码、测试和配置。
5. 如需协议解释，再读 `core-operating-model.md`。

不要从记忆里猜路径、接口或历史结论。当前代码、diff、测试、日志和 task contract 优先于聊天历史。

## Scope Discipline

实现时必须守住 scope：

- 只改当前 task 需要的文件。
- 不把后续任务、未来扩展或顺手重构混进当前交付。
- 如果发现必须扩大 scope，先更新 task contract 或向用户说明原因。
- 没写进 `out_of_scope` 的原始要求，默认仍然需要满足。
- 对同类问题可以做 pattern sweep，但只能修同一类、同一风险面；扫出来的无关问题只报告，不顺手改。

反例：

- 为了修一个入口，顺手重构无关模块。
- 当前任务只要求 review 文档，却改了 CLI 行为。
- 发现一个未来可能需要的配置项，于是提前加通用 abstraction。

## Source Contract

coding 前必须确认本轮任务的 source contract：

- 原始用户问题是什么。
- 原始来源在哪里，例如用户消息、设计文档、issue、测试记录、真实 URL 或仓库路径。
- 哪些行为、状态、artifact 或用户路径必须保持。
- 哪些验收项可以被命令或人工 evidence 验证。
- 哪些内容明确不做。
- 每个关键要求对应哪个 slice、实现点和 evidence。

如果 task contract 只有动作，没有 quality outcome，lead/coder 应先补合同，而不是直接实现。

没写进 `out_of_scope` 的原始要求默认仍要满足。实现过程中发现原设计不可行时，先更新 task contract、记录用户确认或进入 blocked；不能在代码里静默缩小目标。

## Implementation Discipline

实现应优先选择能减少长期复杂度的路径：

- 复用项目已有 parser、schema、repository、state、logger、test helper 和 boundary API。
- 新增 abstraction 只有在减少真实复杂度、收敛重复决策或匹配现有架构时才成立。
- 不用自然语言名单、关键词表或多处 fallback 冒充结构化事实源。
- 新状态、新字段、新 artifact 必须有 writer、reader、schema、验证路径和迁移策略。
- 修改一个 class-of-bug 后，检查同形态 sibling 入口；修或报告，不静默忽略。
- 替换旧逻辑时，要说明旧入口如何关闭，避免双写或第二事实源。
- 关键流程动作应尽量 tool 化或 service-controlled，例如写权威 artifact、推进 loop state、提交 review/test verdict、记录 evidence。
- CLI 存在不等于 agent 会可靠调用；关键动作必须留下工具调用证据或明确说明为什么本轮只能手动执行。

## Bugfix Root Cause Discipline

修 bug 前，lead/coder 应能用一句话说明 root cause，并指向具体文件、函数、状态、条件或入口：

```text
Root cause: <文件/函数/条件> 因为 <当前 evidence> 导致 <用户可见症状>。
```

如果只能说“状态管理问题”“可能是异步问题”“看起来像缓存”，说明还没有 root cause。此时先补 evidence：复现命令、日志、runtime state、下层服务 baseline、最小 fixture、截图对照或 targeted test。

默认规则：

- 同一症状在一次修复后仍存在，停止继续叠 patch，重新读执行路径并重建假设。
- 行为、lifecycle、async、race、state-machine 类问题，应先加能区分假设的 probe / log / assertion，再改逻辑。
- 视觉、rendering、native app、生成 artifact 类问题，compile/typecheck 不能证明修复；需要真实运行、截图、artifact 检查或明确 handoff。
- 反复出现的 bug 必须有 regression guard：测试、schema check、runtime assertion、fixture 或文档化 verifier。临时脚本和一次性观察不能替代长期 guard。
- 三次假设失败后，应进入 blocked/handoff，列出已验证、已排除、未知项和下一步需要的外部信息。

## Structural Guardrails

这些规则默认适用于 bug fix、状态流转、artifact 写入、AI 输出解析、resolver、normalizer、validator、gate 和 tool 边界相关改动。

### 不用增长名单当主要安全边界

不要把黑名单 / 白名单、自然语言关键词表、产品名、模型名、角色名、结果描述、工具名或 option id 变体，作为限制 AI 产出或输入的主要方案。

优先使用：

- schema、parser、validator 和稳定 enum。
- 状态机、phase id、action id、tool result 和 service command。
- provenance、source evidence、引用关系和已确认上下文。
- 结构化 classifier 输出，而不是 free-text 命中。

允许使用名单的场景很窄：

- 稳定协议枚举，例如 status、verdict、event type、severity、phase id。
- 安全兜底或诊断统计，例如危险命令、稳定泄漏标记。

如果确实使用名单，必须说明它为什么不会随着用户输入、产品领域、模型措辞或测试场景继续增长。测试不能只证明某个具体词被修掉，还要证明同形态输入不会进入正式事实源。

### 字段族和单一事实源

涉及结构化 payload、source / citation、provenance、artifact link、state file、CLI JSON 或文件协议时，不要只修当前报错字段。

必须检查：

- 当前字段是否只是同一语义的一个别名。
- 同一语义字段族是否都指向同一事实源。
- 谁写、谁读、谁校验这个事实。
- 是否已有 helper、parser、resolver 或 protocol API 负责这类字段。
- 多个等价字段互相矛盾时是否 fail closed。

危险信号：

- 不断追加字段名、字符串、状态名或路径片段来追 agent/provider 输出。
- normalizer 先“修好”payload，再让 validator 无条件通过。
- 新增字段别名导致旧 artifact、fixture、CLI/tool 输出或 UI metadata 协议漂移。

### 扩散一致性

点状修复如果只处理当前症状，但同层级其他入口仍然犯同样的错，本身就是未来 bug 来源。

修 bug 时至少检查：

- guard / filter / cleanup 是否只加在当前报错调用链上。
- 新状态更新逻辑是否在所有应该触发的地方调用。
- 特殊 phase、tool 或 artifact 是否沿用已有模式，而不是各自发明分支。
- 其他函数是否也写同一字段但没有同步更新。
- 迁移或重命名是否留下永久新旧 fallback，而没有移除条件。

发现同类问题时，当前 scope 内的同类入口应一起修；超出 scope 的同类风险要写入 known gaps 或 handoff，不能静默忽略。

### Closure Guard

替换旧逻辑、旧入口、旧 fallback、旧 artifact writer 或旧状态路径时，完成条件必须包含 closure guard：

- 旧入口已删除、不可达或降级为 validator / pre-filter。
- 旧路径不能继续产出权威状态或 artifact。
- 有 grep、targeted test、schema validation 或 runtime check 证明旧路径不会继续污染结果。

新旧双路径都能写权威结果时，不能宣称完成。永久 fallback 必须有迁移窗口、使用条件和移除条件。

### 禁止假完成

coding 不能用下列方式让当前 slice 看起来通过：

- 删除、绕过或弱化已有 gate。
- 把原始必须项静默改成 out of scope。
- 用“后续再补”替代当前 slice 的必须能力。
- 为了通过 E2E / dogfood 加业务层兜底，掩盖 runner、schema、状态机、provider、tool 或真实入口未接通。
- 原地改写 confirmed artifact、历史证据或失败 run。
- 让 AI 同时手写多个必须一致的流程 artifact，而没有单一 writer、校验工具或后续收口点。
- 把 late result 自动应用到不同对象、run、phase、attempt 或 revision。

如果必须保留兼容 fallback，应写清楚迁移窗口、移除条件和为什么不会继续写权威状态。

## CLI / Installer / Mutating Command Surface

当改动触及 CLI 入口、installer、update、uninstall、completion、config/env、package wrapper、migration、cleanup、prune、reset、cache removal 或其他会改用户状态的命令时，不能只跑库测试。

coding evidence 应覆盖实际命令表面：

- help/version、subcommand、flag、exit code、stdout/stderr。
- JSON/schema 输出、TTY 与非交互路径、env/config 优先级。
- shebang、executable bit、PATH shim、安装后真实命令路径。
- package-manager、本地安装、公开仓库安装或用户文档声明的安装方式。

对 mutating command 还要说明：

- 是否有 dry-run 或确认路径。
- 操作日志、回滚方式、重试/idempotency、signal/partial-failure 处理。
- auth prompt、真实系统变更或危险命令是否有 test-mode guard。
- uninstall/cleanup 选择的目标，普通用户能否验证安全；删除内容是否可本地重建，而不是用户数据或只能重新下载的依赖。

如果以上任一项无法验证，不能把 CLI 改动标成完整通过，只能给 `partial`、`blocked` 或明确 residual risk。

## Release / Package Artifact Surface

如果当前 task 影响发布、安装、打包、生成物、registry、appcast、release note、checksum、站点下载文案或 public asset，source tests 通过不等于 release-ready。

coding evidence 至少说明：

- 版本字段、manifest、lockfile、changelog、tag 或 release note 是否同步。
- tracked archive、ignored dist、bundled/minified file、installer metadata、checksum、站点下载文案是否需要重新生成。
- 打包脚本是否从 `git ls-files`、allowlist、生成 manifest 或源目录取文件。
- 新增 helper、reference、template、script、asset 是否进入 package/archive。
- publish/release 后是否需要重新读取 registry、release asset、appcast 或 CI 状态。

从 brooks-lint 可借鉴的 code-quality 风险，只作为 coding 自检问题使用：

| 风险 | coding 时要问 |
| --- | --- |
| Cognitive overload | 新增函数、分支、参数、命名是否让维护者必须读完整实现才能理解。 |
| Change propagation | 一个需求是否迫使无关模块一起改；是否说明了依赖方向。 |
| Knowledge duplication | 同一业务决策是否在多个地方重复表达。 |
| Accidental complexity | 新 abstraction、配置、扩展点是否服务当前真实需求。 |
| Dependency disorder | 高层策略是否依赖低层细节，是否引入循环或不稳定依赖。 |
| Domain distortion | 命名和边界是否符合项目领域语言，而不是技术临时名。 |

这些风险不是机械阈值。只有当它们影响当前 task 的可维护性、可验证性或质量结果时，才需要进入 evidence 或 review 风险说明。

## Evidence

coding 完成时，不能只说“已完成”。至少保留：

- `changed_files`：真实文件路径。
- `commands`：跑过的命令和结果。
- `tool_calls`：关键工具调用的名称、输入身份、结果、artifact 路径和调用方；没有调用时说明原因。
- `self_check`：逐条对照 task acceptance。
- `known_gaps`：非当前 scope 或真实阻塞，不能用来绕过必做项。
- `handoff_notes`：reviewer/tester 应重点检查的风险。

如果没有运行验证命令，必须写清楚：

- 为什么没跑。
- 当前结论是 inferred 还是 blocked。
- 哪个角色或环境需要补证据。

## Fail Closed

以下情况不能把 coding 标成完成：

- 缺 task contract 或 quality outcome。
- 无法说明改动和 task scope 的关系。
- 关键路径只靠实现者自述，没有命令、测试、artifact 或日志。
- 新增状态或 artifact 没有 reader / writer / schema 对齐。
- 替换旧路径但旧路径仍能写权威结果。
- 为了通过测试而删 gate、改测试输入、手工补系统应生成的 artifact。
- review/test 发现高或中问题后，未重新修复并走 gate。

用户可以接受风险，但 agent 必须把风险显式写入 evidence 或 handoff，不能包装成已验证完成。

## Coding Output

lead/coder 的 coding evidence 建议包含：

```yaml
coding_evidence:
  status: pass | fail | partial | invalid
  changed_files:
    - path/to/file
  scope_match:
    summary: "为什么这些改动属于当前 task。"
  verification:
    - command: "..."
      result: pass | fail | not_run
      evidence: "输出摘要或 artifact 路径。"
  tool_calls:
    - name: "..."
      input_identity: "task/state/evidence 文件或 hash。"
      status: passed | warning | blocked | failed | not_invoked
      evidence: "artifact 路径或摘要。"
  closure:
    old_paths_closed:
      - "旧入口或旧 fallback 如何处理。"
    ssot:
      - "当前权威 writer / reader / schema。"
  known_gaps:
    - "仍未覆盖但不阻塞当前 task 的风险。"
  reviewer_focus:
    - "希望 reviewer 重点检查的结构或行为风险。"
```

如果后续 tester 发现 bug，修复属于新的 coding 轮次；修完后必须重新经过 review，再交 tester 回归。
