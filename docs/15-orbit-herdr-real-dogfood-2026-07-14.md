# Orbit × Herdr 真实多 Agent Dogfood 报告

- 执行日期：2026-07-14
- Orbit：仓库当前实现，package version `0.1.11`
- Herdr CLI：`0.7.1`
- Herdr 上游参考：`upstream/herdr`，配置跟踪 `master`
- 总结论：manual 权威闭环 PASS；Herdr `automatic-preview` 启动与观察 PASS；production automatic 因缺少可信 caller-to-pane 身份原语而保持不可用，这是正确的 fail-closed 结果

## 为什么要做这次测试

此前 Orbit 的测试 fixture 自行实现了真实 Herdr 不存在的 `orbit-proof` 命令，导致内部模拟协议被误认为真实集成。代码审计可以证明这个依赖是错误的，但不能证明纠正后的用户路径真的可用。

本轮因此使用一次性项目、三个真实 Agent 客户端和真实 Herdr pane，完整执行 task、implementation evidence、manual payload、独立 review、独立 test、artifact provenance、gate、state、audit 与 handoff。Codex observer 只做初始化、调度、监听和最终审计，不修改 fixture 的业务实现，也不代替 reviewer/tester 写结论。

## 环境与角色

一次性项目：`/tmp/orbit-herdr-dogfood-20260714.tNAnq3`

| 角色 | 客户端 | Herdr pane | 权限模式 | 结果 |
| --- | --- | --- | --- | --- |
| lead-main | Claude Code 2.1.195 | `w653be9c1f92241:pX` | `--dangerously-skip-permissions` | 实现完成 |
| reviewer-main | OMP 16.2.7 | `w653be9c1f92241:pY` | `--approval-mode yolo` | PASS |
| tester-main | OpenCode 1.17.15 | `w653be9c1f92241:pZ` | `--auto` | PASS |

三个 pane 均位于 observer 所属 workspace `w653be9c1f92241`。Herdr 只承担 pane 启动、读取和消息传输；所有 gate-closing evidence 均明确使用 `manual_runtime`，没有把 Herdr 环境变量或 pane 状态伪装为可信身份。

## 被测用户任务

fixture 要求实现一个仅使用 Ruby 标准库的 TinyCalc：

- `TinyCalc.divide(8, 2)` 返回 `4.0`；
- 除数为零时抛出带清晰信息的 `ArgumentError`；
- CLI 成功路径输出 `4.0` 并返回 0；
- CLI 除零路径输出错误并非零退出；
- 提供自动测试与 README；
- lead、reviewer、tester 必须相互独立。

任务身份与实现：

- task：`.orbit/tasks/tinycalc.yaml`
- task id：`otask_268ec4feb8c4d075e0b49a24`
- revision：`r1-c5861cceda15`
- fixture baseline：`2f34e97`
- implementation commit：`13a453c52cb8a487fa69ab3badc851a114eb7c6a`

## 实际执行结果

### 1. Capability 与启动边界

真实 `orbit start` 报告：

- `mode: automatic-preview`
- `manual_protocol: available`
- `automatic_start: preview`
- `verified_identity: unavailable`
- `direct_dispatch: unavailable`
- runtime session 保持 `pending`
- `dispatch_ready: false`

这证明 Herdr 可以作为启动和观察 adapter，但不会再因为 Herdr 存在就虚构 verified identity。Orbit direct dispatch 正确拒绝未验证目标，任务通过 `orbit dispatch --manual-payload` 生成可审计投递包，再由 observer 使用 Herdr 传送。

### 2. Lead 实现

Claude lead 创建并冻结 task contract，完成实现、README 和 16 项自动检查，提交 implementation evidence，并拒绝替自己完成 review/test gate。

独立复核的关键行为：

```text
ruby bin/tiny-calc 8 2  -> stdout 4.0, exit 0
ruby bin/tiny-calc 8 0  -> stderr divide-by-zero message, exit 65
ruby test/test_tiny_calc.rb -> 16/16 passed
```

implementation evidence 的 runtime identity 为 `manual_runtime`。

### 3. 独立 Review

OMP reviewer 独立读取 task、commit、规则与实现，重新运行成功、除零、非法参数、项目 test hook 和完整测试。结论：

- review verdict：PASS
- evidence level：`outcome_quality`
- High/Medium findings：0
- Low：CLI 使用一位小数格式，`10/3` 会显示为 `3.3`；当前验收只要求整数输入和 `8/2`，因此不阻塞
- report：`.orbit/reports/review-tinycalc-reviewer-main.yaml`

### 4. 独立 Test 与 artifact provenance

OpenCode tester 独立执行库、CLI、失败路径、项目 hooks、README 和依赖约束测试。首次提交虽然行为全部通过，但因两个 user journey 没有绑定真实输出 artifact，被 Orbit 自动降为 PARTIAL。这是预期的 fail-closed 行为。

tester 随后生成并检查三个项目内 artifact：

| Artifact id | 路径 | 用途 |
| --- | --- | --- |
| `tinycalc-cli-success-transcript` | `.orbit/artifacts/tinycalc-cli-success.txt` | CLI 成功路径 |
| `tinycalc-cli-zero-transcript` | `.orbit/artifacts/tinycalc-cli-zero.txt` | CLI 除零路径 |
| `tinycalc-test-suite-transcript` | `.orbit/artifacts/tinycalc-test-suite.txt` | 16 项回归测试 |

`orbit artifact inspect` 将文件字节、SHA-256、producer command、Git HEAD、task id 和 revision 绑定。runtime binding 将短生命周期进程如实记录为 `server.name=ruby-cli-subprocess`、`server.owner=tester-main`，没有伪造浏览器或长驻服务。

第二次提交结果：

- test verdict：PASS
- evidence level：`real_path_test`
- journey validation：两个 journey 均 `valid: true`
- artifact validation：3 个引用均有效
- report：`.orbit/test-report-tinycalc.yaml`

### 5. Gate、Validate、Audit 与 Handoff

最终机器结果：

```text
wait-gate.ready: true
aggregate_verdict: pass
review: pass / reviewer / outcome_quality
test: pass / tester / real_path_test
validate.valid: true
state.phase: done
audit.done_ready: true
audit.warnings: []
retention_drift_summary.has_drift: false
handoff.gate_summary.ready: true
handoff.known_gaps_count: 0
handoff.runtime_gaps_count: 0
```

这证明在没有 production automatic identity 的前提下，用户仍能通过明确的 manual protocol 完成一条真实、独立且可追溯的交付闭环。

## Dogfood 发现并修复的问题

### High：layout 查询可能选择错误 workspace

原实现调用 `herdr pane layout` 时没有传 observer pane。在多 workspace 环境中，Herdr 会返回当前 focused workspace，导致 Orbit 可能把新 agent 启动到无关项目。

修复：存在 `HERDR_PANE_ID` 时调用 `herdr pane layout --pane <source-pane>`，并增加 fixture 强制断言。真实 dry-run 修复后从错误的 `w4` 回到 `w653be9c1f92241`。

### Medium：OpenCode 已启动却被 readiness 误判失败

OpenCode 1.17.15 的启动界面包含 `Ask anything`，不包含原匹配式期待的小写 `opencode` 或 `>`。pane 已可用，但 `orbit start` 返回 `start_failed`。

修复：OpenCode readiness matcher 增加当前稳定提示 `OpenCode|opencode|Ask anything`，并增加 start plan 回归断言。

### High：`wait-gate` 与 `validate` 对 user journey 的语义不一致

真实 gate 已全部通过，但 `orbit validate` 错误要求 review evidence 也携带 tester 专属 `user_outcomes`。这会造成“gate ready 但 validate invalid”的矛盾状态。

修复：user journey assessment 只应用于 test gate；review 继续执行其质量问题覆盖校验。回归测试现在要求同一 real-path task 同时具有 review/test gate，并确认没有 user outcomes 的 review PASS 可与完整 test PASS 一起通过 validate。

### Medium：共享 checkout 中 Agent 擅自切换 HEAD

tester 为检查实现运行了 `git checkout 13a453c`，使所有角色共享的 worktree 进入 detached HEAD。observer 发现后要求 `git switch main`，最终未丢失、reset 或覆盖任何文件，测试有效性未受影响。

现有 runtime guide 已禁止未经授权的 checkout/switch/reset/stash/clean，但长文规则的显著性不足。修复：dispatch packet 新增机器可读 `worktree_safety`，并在实际投递消息中直接提示共享 checkout、禁止改变 HEAD、检查其他提交应使用 `git show`。

### 观察：Agent reply 不能依赖 UI 状态

Claude lead 完成后只在自己的 pane 输出结果，没有主动用 `herdr-msg` 回复；OMP 的 agent status 在工作期间也曾显示 idle。observer 通过主动读取 pane 才发现完成状态。

当前结论：Herdr agent status 只能作为诊断线索，Orbit completion 必须以 structured evidence、gate 和 audit 为准。后续若要减少人工监听，应增加可验证的 completion notification，但不能把 UI idle/done 当成 evidence。

## 最终能力判定

| 能力 | Verdict | 原因 |
| --- | --- | --- |
| manual task/evidence/gate/audit/handoff | PASS | 三个真实独立客户端完成闭环 |
| Herdr pane start/inspect | PASS | 三个客户端均成功启动并可观察 |
| automatic-preview | PASS | 正确创建 pending session 且不越权 |
| manual payload delivery | PASS | 可审计且没有伪装成 direct dispatch |
| verified runtime identity | BLOCKED_BY_UPSTREAM_CAPABILITY | Herdr 无可信 caller-to-pane assertion |
| production direct dispatch | BLOCKED_BY_UPSTREAM_CAPABILITY | 缺少 verified identity，Orbit 正确拒绝 |
| production automatic | BLOCKED_BY_UPSTREAM_CAPABILITY | 不得用 fake provider 或环境变量升级能力 |

## 回归基线

本轮修复后完整测试套件 `1089/1089` 通过，`npm pack --dry-run` 也确认发布包包含新的 `runtime_identity_boundary.rb` 且不再包含旧 proof provider。测试覆盖包括：

- Herdr 存在时只报告 `automatic-preview`；
- fake Herdr 即使提供虚构 `orbit-proof` 也不能升级能力；
- runtime register 保持 pending；
- direct dispatch 对 pending identity fail closed；
- layout 查询绑定 source pane；
- OpenCode 当前启动提示可被识别；
- review 不承担 tester user journey evidence；
- dispatch 消息显式携带 shared-worktree 安全约束。

## 关于 Herdr 子仓库版本

`.gitmodules` 为 `upstream/herdr` 配置 `branch = master`，用于 `git submodule update --remote upstream/herdr` 跟随上游。Git submodule 在每次父仓库提交中仍会记录一个可复现的 commit，这是 Git 的固有机制；这里没有固定 tag 或版本分支。
