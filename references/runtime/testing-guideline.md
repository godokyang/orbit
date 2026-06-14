# Orbit Testing Guideline

本文是运行时 testing 规范，面向 `tester`，也供 `lead` 和 `reviewer` 判断测试证据是否可信。

本规范抽象自已有项目实践，以及 brooks-lint test quality、Waza evidence / verification 规则。它不是某个框架的测试教程，也不替代项目自己的 QA、E2E、dogfood 或 CI 规范。

## Testing 目标

testing 的目标是发现真实失败并保留证据，不是帮任务跑出 PASS。

tester 应证明：

- 测试输入来自 task contract 或真实用户路径。
- 测试环境、版本、命令、artifact 和结果可复查。
- 测试 pane/tab、server owner、browser owner、duration、resource usage 和 cleanup 状态可复查。
- 覆盖了当前 task 的关键验收项和失败假设。
- 性能、UX、workflow、quality、eval 或 measurement 类任务有 baseline/after 对照，或有明确 waiver。
- 失败证据被保留，没有被后续成功 run 覆盖。
- 测试没有通过修改生产代码、改输入、删失败证据或手工补 artifact 被污染。

## 输入顺序

开始 testing 前，按顺序读取：

1. 当前 task contract。
2. `evidence_requirements` 和 testing scope。
3. lead/coder 提供的 coding evidence。
4. 项目自己的测试入口、README、CI 或 QA 文档。
5. 如需协议解释，再读 `core-operating-model.md`。

tester 不应补脑任务目标。task contract 不清楚时，输出 `invalid` 或要求 lead 补合同。

## Tester 边界

tester 的职责：

- 执行真实测试路径。
- 保留命令输出、截图、日志、录屏、run 目录或其他 artifact。
- 输出 test verdict、覆盖范围和覆盖缺口。
- 指出测试污染或前提不成立。

tester 禁止：

- 修改生产代码来让测试通过。
- 删除或覆盖失败 run。
- 手工补本应由系统生成的 artifact。
- 改 prompt、改输入、改验收标准后仍声称原测试通过。
- 用 mock happy path 替代 task 要求的真实路径。
- 把测试通过当成 review 通过。

## Test Contract

每轮测试前要明确：

- 测什么用户路径、接口、命令或状态流。
- 使用什么环境和关键版本。
- 当前仓库路径、commit、dirty 状态、build / 启动命令，以及使用源码入口还是可交付产物入口。
- PASS 前必须看到哪些 artifact。
- PASS 后如何清理 server、browser、临时文件和大 artifact。
- 测试允许消耗的 duration / resource budget。
- 质量度量类 task 的 baseline、after 和 metrics 如何采集。
- 哪些失败模式必须反驳。
- 哪些路径本轮不测，并且为什么不阻塞。

如果缺少关键环境、输入、账号、设备、服务或测试数据，测试结论不能给 pass。

对测试体系、QA 改进、复杂重构或高风险模块改动，tester 应先建立轻量 test map：

- unit / integration / E2E 大致有哪些入口。
- 当前 task 涉及模块是否有对应测试。
- 哪些测试覆盖用户可见行为、状态流转、artifact side effect 或错误路径。
- 哪些路径只有 mock、snapshot、happy path 或没有 coverage。

test map 不是完整测试审计；它用来避免“跑了一堆测试但没有打中本轮风险”。

## Verdict

testing verdict 必须区分四类：

| Verdict | 含义 |
| --- | --- |
| `pass` | 原始测试目标、真实路径和验收标准都满足，证据已保留。 |
| `fail` | 测试有效，但系统没有满足验收标准，失败证据已保留。 |
| `partial` | 部分路径通过、部分失败或未覆盖，报告逐项列明。 |
| `invalid` | 测试方法被污染或前提不成立，不能支撑 pass/fail。 |

`invalid` 不是系统通过，也不是系统失败；它表示测试证据不能用于 gate。

## Evidence

测试 evidence 至少包含：

- 测试环境和关键版本。
- 测试所在 pane/tab、server owner、browser owner。
- 仓库路径、commit、dirty 状态、启动入口和 build 结果。
- 命令或操作步骤。
- 输入数据或用户路径。
- 真实输出、截图、日志、录屏、run 目录或 artifact 路径。
- duration、resource usage、cleanup hook、cleanup status、artifact cleanup。
- UX 质量和 artifact 质量判断。
- 覆盖的 acceptance / failure modes。
- 未覆盖路径和原因。
- 质量度量类 task 的 baseline、after、metric name 和 metric evidence；若无法采集，记录 waiver reason、risk 和 replacement evidence。

失败 evidence 必须保留。后一次成功 run 不能覆盖前一次失败 run 的结论；修复后应生成新 evidence record。

## Test Quality Checks

从 brooks-lint 可借鉴的 test-quality 风险，只作为测试证据质量自检：

| 风险 | tester / reviewer 要问 |
| --- | --- |
| Test obscurity | 测试名称、步骤和断言是否能说明测试了什么行为。 |
| Test brittleness | 测试是否依赖实现细节，而不是可观察行为。 |
| Mock abuse | mock 是否多到测试只验证 mock wiring，不验证真实行为。 |
| Test duplication | 多层测试是否重复同一断言，而不是覆盖不同风险。 |
| Coverage illusion | 是否只覆盖 happy path、行覆盖或返回值，漏掉边界和副作用。 |
| Architecture mismatch | 测试层级是否匹配风险，是否过慢或缺 characterization tests。 |

这些问题不要求每轮测试都做完整 test-suite audit。只有当它们影响当前 task 的测试可信度时，才需要写进 test evidence 或 review finding。

测试质量判断要按风险匹配，不按覆盖率数字机械判断。高覆盖率不能自动 PASS；低覆盖率也不自动 FAIL。关键是本轮 change path、failure modes、side effects、用户路径和旧路径关闭是否被证据覆盖。

## Pattern-Fix Testing

当本轮任务修复的是 AI 输出解析、resolver、normalizer、validator、state transition、guard、filter、cleanup、artifact writer 或 tool 边界问题时，测试不能只证明当前报错样例通过。

tester 应优先验证：

- 同形态输入是否也不会进入正式事实源。
- 相邻入口、相邻 phase 或相邻 tool 是否沿用同一结构化路径。
- 关键词、黑名单、白名单或 free-text 变体不会绕过 schema / parser / state machine。
- 多字段别名或多事实源冲突时是否 fail closed。
- 旧路径、旧 fallback 或旧 writer 是否不能继续产出权威状态或 artifact。

如果只能验证当前具体词、具体 prompt 或具体业务样例，应把结论降级为 `partial`，并在 coverage gap 里说明缺少同形态输入或 closure guard 证据。

## Regression Guard

对 bug fix、重复回归、legacy 行为、风险 sink、状态机、CLI/installer 或生成 artifact 改动，tester 应检查是否有长期 regression guard：

- 自动测试、characterization test、schema / artifact checker、fixture、runtime assertion 或稳定 verifier。
- guard 应进入项目测试或验证入口，不应只存在于临时脚本、聊天截图或一次性手工观察。
- legacy 代码被修改但行为不清楚时，优先用 characterization test 锁住当前行为，再判断修复是否改变了预期行为。
- 如果同一 bug 曾经“修好又坏”，没有 regression guard 时不能给完整 `pass`，最多 `partial` 并记录 coverage gap。

## Real Path Priority

测试优先级：

1. 当前 task 明确要求的真实用户路径。
2. 高风险行为路径，例如状态写入、权限、数据破坏、恢复、重试、异步 late result。
3. 项目已有 CI / unit / integration / E2E 命令。
4. 低风险 smoke check。

只跑编译、typecheck 或单元测试，不一定能证明真实路径通过。缺少真实路径时，应把结论降级为 `partial` 或说明 residual risk。

CLI、installer、update、uninstall、cleanup、migration 或 package wrapper 相关任务，真实路径优先包括安装后命令行为：help/version、flag、exit code、stdout/stderr、非交互、PATH shim、权限错误和 uninstall/update 后状态。release/package 相关任务还应检查生成物、包内容、版本字段、release asset 或 registry/appcast 状态。

## Artifact 和用户可见状态一致

测试不能只看最终文案、自动报告 verdict 或命令退出码。tester 应同时检查：

- 用户可见输出、页面、transcript 或 CLI 文案。
- loop state、task/evidence manifest、关键 artifact。
- report 是否覆盖最新 evidence，而不是旧 run 或旧截图。

如果用户可见状态说完成，artifact 必须证明对应状态已发生。transcript、状态文件和 artifact 矛盾时不能给 `pass`。后台运行、handoff、失败原因也应有用户可见进度或 evidence 路径。

自动 checker 可以证明结构字段、文件存在、报告新鲜度和状态矛盾；它不能替代 tester 对语义、UX、假完成、重复确认和真实路径的判断。如果 checker PASS 但真实交互或 artifact 对照失败，测试结论应按真实交互降级。

## Fail Closed

以下情况不能给 `pass`：

- task contract 不清楚。
- 没有测试环境或关键依赖。
- 没有保留命令输出、截图、日志或 artifact。
- 没有记录测试环境生命周期、资源消耗、cleanup 状态或 artifact cleanup。
- 质量度量类 task 没有 baseline/after 指标，也没有显式 waiver。
- 失败 run 被删除、覆盖或无法复查。
- tester 修改了生产代码、输入、prompt 或系统 artifact。
- 只跑 mock happy path，但 task 要求真实用户路径。
- 只证明旧行为未破坏，没验证本轮 quality outcome。
- 发现 bug 后，修复未重新经过 review 就直接重测放行。
- 用户可见完成状态和 artifact / state 互相矛盾。
- 自动 checker 通过，但真实路径、语义或 UX 证据不支持通过。
- bug fix、重复回归或高风险 sink 没有长期 regression guard，且没有明确 residual risk。
- CLI/installer/release 任务只跑源码测试，没有安装后命令、包内容或生成物证据。

## Testing Output

tester evidence 建议包含：

```yaml
kind: test
verdict: pass | fail | partial | invalid
summary: "本轮测试结论。"
source_message_id: "Herdr message、CI job、pane transcript 或 report id。"
findings: []
coverage:
  - "覆盖的用户路径、风险路径或 acceptance。"
artifacts:
  - "命令输出、截图、日志、run 目录或 artifact。"
blocked:
  reason: "verdict 为 blocked/partial 且需要阻塞时填写。"
  next_step: "需要 lead、用户或后续 agent 做什么。"
  owner: "负责解除阻塞的角色或人。"
test_environment:
  environment: "测试环境、关键版本、设备或服务状态。"
  test_tab_or_pane: "执行测试的 pane/tab/CI job。"
  server_owner: "server 由谁启动和关闭；无则写 none。"
  browser_owner: "browser/session 由谁启动和关闭；无则写 none。"
  cleanup_hook: "清理命令、trap、脚本或人工步骤。"
  artifact_cleanup: "保留、压缩或删除了哪些 artifact。"
  duration: "实际耗时。"
  resource_usage: "进程、端口、浏览器、外部服务或资源消耗。"
  cleanup_status: complete | partial | not_applicable
  ux_quality: "真实路径、交互、文案或可见状态质量判断；不适用写 not_applicable。"
  artifact_quality: "artifact 是否新鲜、可复查、路径稳定、大小可控。"
quality_measurement:
  baseline: "质量度量类 task 的前置值；非度量类可省略。"
  after: "质量度量类 task 的变更后值；非度量类可省略。"
  metrics:
    - name: "metric 名称。"
      baseline: "前置值。"
      after: "后置值。"
      evidence: "采集命令、文件、截图、trace 或日志。"
  waiver:
    reason: "无法采集 baseline/after 的原因。"
    risk: "缺失对照带来的风险。"
    replacement_evidence: "替代证据。"
```

可以从 `assets/templates/test-report.yaml` 复制最小模板后填写，再运行 `orbit evidence submit --file <manifest> --report <report> --json`。不要直接编辑 `.orbit/evidence*.json` 来提交测试结论；直接写 manifest 会绕过 CLI 的身份解析、schema 校验和并发安全写入，不能用于关闭 test gate。

`findings`、`coverage`、`artifacts` 必须是字符串列表；没有 findings 时写 `[]`，不要写对象数组或自由格式段落。`blocked` 只在 `verdict: blocked` 或需要解释 partial 阻塞时填写；CLI 会把 `blocked` verdict 存为 partial record，并在 gate summary 中显示 blocked 原因。

tester 的结论进入 evidence manifest 后，由 lead 消费并更新 loop state；tester 不直接把任务标为 done。
