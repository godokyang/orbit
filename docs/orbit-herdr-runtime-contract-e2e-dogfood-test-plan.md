# Orbit-Herdr runtime contract 真实端到端测试计划

本文用于 Orbit-Herdr runtime contract 实施完成后的真实 dogfood 验收。目标不是让当前 Codex agent 自己跑几条命令证明“代码能跑”，而是在一个干净临时项目里，让当前 Codex agent 只做外部观测和调度，用 Herdr 启动多个真实被测 agent，通过 Orbit 的 task / evidence / gate / audit 流程完成一个小型真实任务。

核心原则：

- 当前 agent 是 Codex，只作为 observer / operator / recorder，不加入被测实现、评审或测试循环。
- 当前 Codex agent 可以创建 fixture、写入 Orbit 配置、启动/分派/读取/汇总、执行 gate/audit/handoff，但不能替任何被测 agent 修改业务代码、写 review/test report、提交 evidence verdict、修复失败或补做测试。
- coder / reviewer / tester 必须是通过 Herdr + Orbit 启动或复用的独立被测 agent。
- 被测 agent client 只能从 Claude Code、OMP、OpenCode 中分配；三个 client 可自由分配或复用 client 类型，但每个 role 必须有独立 Herdr pane / Orbit instance / runtime session。
- 禁止把 Codex 配置为任何被测 role 的 agent client；本次会话里的 Codex 只作为外部观察者。
- 测试必须验证真实 CLI 行为、真实文件副作用、真实 evidence/gate，而不是只 review 代码或只跑单元测试。
- 测试目录必须是 disposable fixture project，不能污染 Orbit repo 主目录。
- Herdr 是 automatic runtime 的必需依赖；无 Herdr 路径只用于安装器和 explicit manual protocol 测试，不用于自动 runtime dogfood。manual protocol 不触发 automatic runtime。

## 测试目标

本测试要证明实施后的 Orbit 能在真实多 agent 环境里回答这些问题：

- `orbit start INSTANCE` 是否能创建或复用 Herdr agent。
- pending session 是否在当前版本保持 fail closed：`orbit runtime register --json` 和 piggyback register 只能记录 diagnostics，不能变成 verified。
- `.orbit/instances.yaml` 是否仍只是 expected config / last-known hint，而不是 alive proof。
- `.orbit/runtime` 是否正确记录 session、instance pointer、replacement diagnostics、ack 和 heartbeat。
- `instances status`、`start`、`dispatch`、gate-closing evidence 是否共用同一个 resolver。
- direct dispatch 是否只允许投递到 live + verified + available + canonical pane。
- `manual_runtime`、`identity_pending`、`stale`、`replaced`、`override` 是否 fail closed 或按 policy 明确处理；manual_runtime 不得冒充 Herdr-verified。
- 用户关闭某个已完成阶段的 agent 后，`instances status` / `start` 是否能把旧 session 识别为 stale，并重新启动或提示 explicit manual protocol path。
- binding 丢失或 stale 时，Orbit 是否不会把手写/旧 `herdr_verified` session 当成可信复用来源。
- 用户显式 `--repair-binding` 或 `--force` 时，版本化 config 和 runtime state 是否按规则写入。
- review/test evidence 是否带 runtime identity attribution，gate/audit/handoff 是否能暴露 verification gap。

## 参与角色

### 当前 agent: Codex observer

职责：

- 创建临时测试项目。
- 用当前 Orbit 实现初始化 `.orbit`。
- 创建 task contract、evidence manifest、loop state。
- 通过 `orbit start` 启动或复用 coder/reviewer/tester 被测 agent。
- 通过 `orbit dispatch` 分派任务。
- 观察 Herdr panes、收集 structured reply、运行 gate/audit/handoff。
- 需要给 pane 发送内容时，只发送 coordinator 指令，不替目标 agent 编写实现、评审或测试结论。
- 记录所有命令、输出摘要、文件副作用和失败点。

禁止：

- 不作为 `coder-main`、`reviewer-main` 或 `tester-main`。
- 不启动或配置任何 role 使用 `codex` command。
- 不直接修改 fixture project 的业务代码。
- 不直接编辑 reviewer/tester evidence JSON 来关闭 gate。
- 不把 Herdr `done` 当成 Orbit task done。
- 不把 explicit `--pane` override 当成 verified identity。
- 不进入目标 pane 代替被测 agent 运行 implementation / review / test 命令。

### 可用被测 agent client

本计划只允许以下 client 作为被测 agent：

- Claude Code：使用当前机器真实可用的 Claude Code 命令。
- OMP：使用当前机器真实可用的 `omp` 命令。
- OpenCode：使用当前机器真实可用的 `opencode` 命令。

推荐分配示例：

- `coder-main`: Claude Code，必须开启 full-access / no-approval 模式。
- `reviewer-main`: Claude Code，必须开启 full-access / no-approval 模式。
- `tester-main`: Claude Code，必须开启 full-access / no-approval 模式。

如果要使用 OMP 或 OpenCode，必须先确认 `orbit start INSTANCE --dry-run --json` 或真实 start 输出里的 `client.full_permission.configured` 为 `true`。如果 Orbit 当前版本不能识别该 client 的无审批参数，即使该 client 自己支持 auto-approve，也不能作为本轮被测 agent；改用另一个能被 Orbit 审计通过的 Claude Code / OMP / OpenCode client。不能回退到 Codex。

### coder-main

职责：

- 必须由 Claude Code / OMP / OpenCode 中的一个承担，不得是 Codex。
- 接收 implementation task。
- 修改 fixture project 的业务代码。
- 运行相关测试或至少运行实现自检。
- 写 implementation evidence。
- 回复 Codex observer：改了哪些文件、跑了哪些命令、证据在哪里。

### reviewer-main

职责：

- 必须由 Claude Code / OMP / OpenCode 中的一个承担，不得是 Codex。
- 独立读取 task、diff、implementation evidence。
- 不复述 coder 的结论。
- 使用 review report 模板提交 structured review evidence。
- 高/中风险未关闭时不得放行。

### tester-main

职责：

- 必须由 Claude Code / OMP / OpenCode 中的一个承担，不得是 Codex。
- 独立执行真实行为测试。
- 使用 test report 模板提交 structured test evidence。
- 至少覆盖成功路径和一个失败/边界路径。
- 报告环境、命令、输出摘要、artifact、未覆盖风险。

## 前置条件

在开始前确认：

```bash
command -v herdr
herdr --version
command -v claude || command -v claude-code
command -v omp
command -v opencode
command -v ruby
```

如果本机 Claude Code 命令名不是 `claude` 或 `claude-code`，改用真实命令检查并记录。被测 agent client 只能使用 Claude Code、OMP、OpenCode；不能使用 `codex`。

确认当前 Orbit CLI 使用的是实施完成后的版本。推荐显式指定本 repo 的脚本，避免 PATH 里旧版本干扰：

```bash
ORBIT_REPO=/path/to/orbit
ORBIT_BIN="$ORBIT_REPO/scripts/orbit"
"$ORBIT_BIN" version
```

如果当前 shell 在 Herdr 内，记录当前 observer pane：

```bash
printf '%s\n' "${HERDR_PANE_ID:-not-in-herdr}"
```

测试执行者本身也必须运行在 full-access / no-approval 环境中。observer 需要创建 disposable fixture、写入 `.orbit` 配置、启动 Herdr agent、读取 pane 输出、运行 gate/audit/handoff，并可能清理临时目录；如果当前 Codex / observer 会话处在受限 sandbox、需要逐步审批 shell/file 操作，测试会卡在执行环境上，不能作为 Orbit-Herdr runtime contract 的有效结论。若发现 observer 侧缺少 full-access，先切换执行环境，再重新创建干净 fixture project。

### Full-access / no-approval 模式

本测试是真实多 agent dogfood，不是人工逐步审批测试。所有被测 agent client 必须以 full-access / no-approval 模式启动，否则 agent 在编辑文件、运行命令或写 report 时会卡在交互审批提示上，测试结果会变成“审批环境不可用”，而不是 Orbit runtime contract 结果。

启动前必须确认 `.orbit/instances.yaml` 中每个被测 instance 的 `command` 已包含对应 client 的无审批参数：

```yaml
instances:
  coder-main:
    role_ref: coder
    command:
      - claude
      - --dangerously-skip-permissions

  reviewer-main:
    role_ref: reviewer
    command:
      - claude
      - --dangerously-skip-permissions

  tester-main:
    role_ref: tester
    command:
      - claude
      - --dangerously-skip-permissions
```

当前机器上如果 client 参数不同，以真实 `--help` 输出为准，但还必须满足 Orbit start plan 的 `client.full_permission.configured: true`。目标 agent 在 fixture project 内必须可以直接编辑文件、运行命令、创建 report 和提交 Orbit evidence，不需要 observer 手工批准每一步。若启动后仍出现 edit / command approval prompt，或 start result 的 `full_permission.configured` 为 `false`，必须停止本轮、修正 `command`，重新创建干净 fixture project 再跑；不要通过 observer 逐个批准来“继续测试”。

Claude Code 可能仍会出现一次 workspace trust / startup 类确认；这类一次性确认可以记录并处理。但 task 执行期间的文件编辑、shell 命令、report 写入和 evidence 提交不得再依赖人工确认。

## 临时项目准备

创建 disposable fixture project：

```bash
WORKDIR=$(mktemp -d /tmp/orbit-herdr-e2e.XXXXXX)
cd "$WORKDIR"
mkdir -p lib test
```

最小 Ruby fixture 示例：

```bash
cat > lib/tiny_calc.rb <<'RUBY'
class TinyCalc
  def add(a, b)
    a + b
  end

  def divide(a, b)
    a / b
  end
end
RUBY

cat > test/tiny_calc_test.rb <<'RUBY'
require "minitest/autorun"
require_relative "../lib/tiny_calc"

class TinyCalcTest < Minitest::Test
  def test_add
    assert_equal 5, TinyCalc.new.add(2, 3)
  end

  def test_divide
    assert_equal 2, TinyCalc.new.divide(6, 3)
  end
end
RUBY

ruby -Ilib test/tiny_calc_test.rb
```

初始化 git，方便 reviewer/tester 看 diff：

```bash
git init
git add .
git commit -m "initial fixture"
```

## Orbit 初始化

在 fixture project 中初始化 Orbit：

```bash
"$ORBIT_BIN" init
mkdir -p .orbit/tasks .orbit/evidence .orbit/reports
"$ORBIT_BIN" whoami --json || true
"$ORBIT_BIN" instances status --json
```

如果默认 `instances.yaml` 不包含 `coder-main`、`reviewer-main`、`tester-main`，按当前项目模板补齐。每个 instance 的 command 必须从 Claude Code、OMP、OpenCode 中选择，例如 `omp`、`opencode` 或本机真实可用的 Claude Code 命令。不要配置 `codex`，也不要为了测试通过而把多个 role 指向当前 Codex observer pane。

推荐初始分配：

- `coder-main`: Claude Code，示例 command 为 `["claude", "--dangerously-skip-permissions"]`。
- `reviewer-main`: Claude Code，示例 command 为 `["claude", "--dangerously-skip-permissions"]`。
- `tester-main`: Claude Code，示例 command 为 `["claude", "--dangerously-skip-permissions"]`。

如果 OMP 或 OpenCode 的 full-access 参数在当前版本不能被 Orbit start plan 审计为 `configured: true`，该 client 不能作为本轮被测 agent；改用 Claude Code、OMP、OpenCode 中另一个能被 Orbit 审计通过并无审批执行的 client。

记录初始化后的配置：

```bash
sed -n '1,220p' .orbit/instances.yaml
sed -n '1,220p' .orbit/roles.yaml
```

## Task 设计

创建一个小型真实 coding task。推荐任务：

```text
为 TinyCalc#divide 增加除以 0 的明确错误语义：
- 当 b == 0 时抛出 ArgumentError，message 包含 "division by zero"。
- 保持现有 add/divide 正常路径不变。
- 增加真实测试覆盖正常 divide 和除 0 失败路径。
```

创建 task、evidence、state：

```bash
"$ORBIT_BIN" new-task \
  --task-type coding \
  --implementation-authority coder \
  --assigned-instance coder-main \
  --owner-role lead \
  --owner-instance lead-main \
  --output .orbit/tasks/tiny-calc-divide-zero.yaml

"$ORBIT_BIN" evidence init --output .orbit/evidence/tiny-calc-divide-zero.json
ORBIT_INSTANCE=lead-main ORBIT_ROLE=lead \
  "$ORBIT_BIN" state start --task .orbit/tasks/tiny-calc-divide-zero.yaml --state .orbit/loop-state.yaml
```

这里的 `lead-main` 只是 Orbit task owner 的配置标签，不代表当前 Codex agent 加入被测实现、评审或测试流程。

如果当前 task 模板路径不同，可以调整输出路径，但必须记录最终 task/evidence/state 文件。

## Runtime 合约预检

先做不依赖业务实现的 runtime contract 检查。

### runtime CLI 可达

```bash
"$ORBIT_BIN" runtime --help
"$ORBIT_BIN" runtime register --json || true
```

期望：

- `runtime --help` 通过 `run_orbit_cli` 可达。
- 不在 Herdr/无 matching session 时，`register` 不得产出 `herdr_verified`。
- forged env 不得产出 verified。
- 当前版本没有独立 heartbeat 子命令，测试脚本不得依赖历史刷新命令。

### start dry-run

```bash
"$ORBIT_BIN" start coder-main --dry-run --json > /tmp/orbit-e2e-start-dry-run.json
```

必须检查：

- result 包含 `ORBIT_SESSION_ID` 和 `ORBIT_LAUNCH_ID`。
- `context_preflight.commands[0]` 等于：

```json
["orbit", "whoami", "--json"]
```

- `context_preflight.commands` 不包含 `["orbit", "runtime", "register", "--json"]`。当前版本的 register 和 piggyback register 只能记录 diagnostics，不能把 pending session 升级为 verified。

### piggyback eligibility

在没有 `.orbit` 的目录验证不会误触发：

```bash
NO_ORBIT_DIR=$(mktemp -d /tmp/orbit-no-config.XXXXXX)
cd "$NO_ORBIT_DIR"
HERDR_ENV=1 "$ORBIT_BIN" --help >/tmp/orbit-e2e-help.txt
HERDR_ENV=1 "$ORBIT_BIN" version >/tmp/orbit-e2e-version.txt
test ! -e .orbit/runtime
cd "$WORKDIR"
```

期望：

- `help/version/init/runtime *` 不触发 global piggyback。
- 没有 `.orbit` 时即使存在 Herdr env，也不写 runtime state。

## 启动真实 agents

由当前 Codex observer 在 fixture project 中启动被测 agents：

```bash
"$ORBIT_BIN" start coder-main --json | tee /tmp/orbit-e2e-start-coder.json
"$ORBIT_BIN" start reviewer-main --json | tee /tmp/orbit-e2e-start-reviewer.json
"$ORBIT_BIN" start tester-main --json | tee /tmp/orbit-e2e-start-tester.json
```

对每个 start result：

- `full_permission.configured` 必须为 `true`。如果为 `false`，停止本轮，修正 `instances.yaml` 的 command，重新创建干净 fixture project 再跑。
- 当前版本没有 trusted caller-pane proof provider，正常结果应保持 `dispatch_ready: false` / `identity_verification: pending`，并提示 manual protocol。未来如果 proof provider 可用且 `dispatch_ready: true`，记录 `pane`、`identity_verification`、`runtime_session`。
- 如果 `action: started_identity_pending`，Codex observer 必须读取目标 pane，然后要求目标 agent 在自己的 pane 内运行 `orbit runtime register --json`。
- Codex observer 不得在自己的 pane 里替目标 agent 运行 register。

检查状态：

```bash
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-after-start.json
```

期望：

- 当前版本 agent 显示 `identity_verification: pending` 且 `dispatch_ready: false`；不得把 pending agent 当作 verified。
- pending/absent agent `dispatch_ready: false`。
- `.orbit/instances.yaml` 在 `instances status --json` 后没有默认 git diff。

```bash
git diff -- .orbit/instances.yaml
```

## 分派实现任务

向 coder direct dispatch：

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to coder-main \
  --json | tee /tmp/orbit-e2e-dispatch-coder.json
```

期望：

- 如果 coder 未 verified，dispatch fail closed，并给 remediation。
- verified 后 direct delivery 到 session `canonical_pane`。
- dispatch result 不应把 explicit `--pane` override 当成 verified。

Codex observer 观察 coder pane，但不修改代码：

```bash
herdr pane read <coder-pane> --source recent-unwrapped --lines 120
```

coder 完成后应提交 implementation evidence，并回复 Codex observer。

## Review 和 test gate

向 reviewer 分派 review：

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to reviewer-main \
  --json | tee /tmp/orbit-e2e-dispatch-reviewer.json
```

向 tester 分派 test：

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to tester-main \
  --json | tee /tmp/orbit-e2e-dispatch-tester.json
```

reviewer/tester 必须各自生成 report，并通过 structured submit 写入 evidence。Codex observer 可以检查但不能手写 verdict：

```bash
"$ORBIT_BIN" evidence show --file .orbit/evidence/tiny-calc-divide-zero.json --json
```

必须检查：

- review/test record 有 `runtime_identity`。
- `herdr_verified` evidence 记录包含 `session_id` 和 `herdr_pane`。
- `manual_runtime` evidence 在默认 policy 下可以参与 gate，但 audit/handoff 标注 verification gap。
- `stale` / `replaced` session evidence 不能关闭 gate。

### Evidence 写入要求

coder 可以提交 implementation evidence，但 reviewer/tester 的 gate-closing verdict 必须来自各自 agent 的 structured report submit。Codex observer 不得直接编辑 evidence JSON，也不得替 reviewer/tester 写 pass verdict。

coder 在自己的 pane 内完成实现后，至少运行：

```bash
"$ORBIT_BIN" evidence add \
  --file .orbit/evidence/tiny-calc-divide-zero.json \
  --kind implementation \
  --status pass \
  --summary "Implemented divide-by-zero ArgumentError behavior and tests." \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml
```

reviewer 在自己的 pane 内创建 report，并提交：

```bash
cp "$ORBIT_REPO/assets/templates/review-report.yaml" .orbit/reports/tiny-calc-review.yaml
# reviewer 填写 .orbit/reports/tiny-calc-review.yaml，必须包含独立 findings/verdict。
"$ORBIT_BIN" evidence submit \
  --file .orbit/evidence/tiny-calc-divide-zero.json \
  --report .orbit/reports/tiny-calc-review.yaml \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --json
```

tester 在自己的 pane 内创建 report，并提交：

```bash
cp "$ORBIT_REPO/assets/templates/test-report.yaml" .orbit/reports/tiny-calc-test.yaml
# tester 填写 .orbit/reports/tiny-calc-test.yaml，必须记录真实命令、输出摘要、覆盖路径和未覆盖风险。
"$ORBIT_BIN" evidence submit \
  --file .orbit/evidence/tiny-calc-divide-zero.json \
  --report .orbit/reports/tiny-calc-test.yaml \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --json
```

Codex observer 验收 evidence 时检查：

- review/test record 的 `author` 来自对应 instance。
- review/test record 的 `runtime_identity` 与提交 agent 的 active session 匹配。
- report 中的命令和 artifact 能在 fixture project 中复核。
- 如果 report 是 `pass`，没有未关闭的 high/medium findings 或 blocking test gap。

## 阶段完成后关闭并重启 agent

真实用户经常会在一个阶段完成后关闭某个 agent pane，之后再启动同一 role 继续下一阶段。本测试必须覆盖这个生命周期，而不是只测试“所有 agent 从头到尾一直开着”的理想路径。

推荐在 reviewer 完成 review evidence 后执行这一段，模拟用户关闭 reviewer，然后重新启动 reviewer 处理后续补充 review 或 handoff check。

记录 reviewer 当前 pane 和 session：

```bash
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-before-close-reviewer.json
```

从 status 输出中取出 `reviewer-main` 的 `canonical_pane` / `pane` 和 `session_id`，记为：

```text
REVIEWER_PANE=<reviewer-pane>
OLD_REVIEWER_SESSION=<old-session-id>
```

关闭 reviewer pane，模拟用户手动结束该 agent：

```bash
herdr pane close "$REVIEWER_PANE"
```

关闭后立即检查 status：

```bash
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-after-close-reviewer.json
```

期望：

- `reviewer-main` 不再是 `dispatch_ready: true`。
- 旧 session 被解析为 `stale` / `not_alive`，或至少不能作为 verified live participant。
- `.orbit/instances.yaml` 默认不被 `instances status --json` 修改。
- direct dispatch 到 reviewer fail closed，并给出 `start` 或 remediation。

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to reviewer-main \
  --json | tee /tmp/orbit-e2e-dispatch-reviewer-after-close.json
```

重新启动 reviewer：

```bash
"$ORBIT_BIN" start reviewer-main --json | tee /tmp/orbit-e2e-restart-reviewer.json
```

如果返回 `started_identity_pending`，必须让新 reviewer pane 自己运行 `orbit runtime register --json`，或等待它第一次 Orbit CLI 命令 piggyback register。Codex observer 仍不得在自己的 pane 里替 reviewer 注册。

重启后检查：

```bash
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-after-restart-reviewer.json
```

期望：

- 新 session id 与 `OLD_REVIEWER_SESSION` 不同，除非 Herdr/agent 实际恢复了同一 live verified session。
- `reviewer-main` 重新满足 `identity_verification: verified` 后，才允许 direct dispatch。
- `.orbit/runtime/instances/reviewer-main.json` 保留 previous/stale/replaced 线索，不被裸 `orbit-start-replacement-v1` 覆盖。
- 后续 reviewer evidence 必须归属新 active session；旧 stale session 的 gate-closing evidence 不得关闭 gate。

再向 reviewer 发送一个补充检查任务，验证重启后的 direct dispatch 和 evidence attribution：

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to reviewer-main \
  --json | tee /tmp/orbit-e2e-dispatch-reviewer-after-restart.json
```

这个生命周期测试也可以对 tester 重复一次。至少覆盖一个 agent 的 close -> status stale -> start -> identity_pending/manual-payload artifact 路径；当前版本不应期待 register 或独立 refresh 命令恢复 `dispatch_ready`。

## Binding 丢失后的复用和 repair

真实用户可能会手动编辑 `.orbit/instances.yaml`、切换分支、恢复旧配置，导致 binding 丢失或 stale，但 Herdr agent 仍然活着。当前版本没有 trusted caller-pane proof provider，因此 Orbit 不能通过 `.orbit/runtime` 和 Herdr live probe 自动证明唯一 verified session；它也不能把手写/旧 `herdr_verified` 文件当成复用依据。

推荐在 tester 仍然 live 但 Orbit 无法 verified 的状态下执行这一段。

先记录 tester 当前状态：

```bash
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-before-binding-removal.json
cp .orbit/instances.yaml /tmp/orbit-e2e-instances-before-binding-removal.yaml
```

模拟用户丢失 tester binding。可以手动编辑 `.orbit/instances.yaml`，只删除 `tester-main` 的 `binding` / `herdr` handle 字段，不删除 instance 本身和 role/command。完成后记录 diff：

```bash
git diff -- .orbit/instances.yaml | tee /tmp/orbit-e2e-binding-removal.diff
```

运行 start：

```bash
"$ORBIT_BIN" start tester-main --json | tee /tmp/orbit-e2e-start-tester-no-binding.json
```

期望：

- 不返回 `reuse_discovered` 或任何 `dispatch_ready: true` verified reuse action。
- 不把手写/旧 `herdr_verified` runtime session 写成可信 current pointer。
- 不默认把 repaired binding 写回 `.orbit/instances.yaml`。
- 如果存在多个手写/旧 verified candidates，当前版本应忽略它们或 fail closed，不能自动选择。

检查 default status 仍不写 config：

```bash
cp .orbit/instances.yaml /tmp/orbit-e2e-instances-before-status-after-reuse.yaml
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-after-reuse-discovered.json
cmp .orbit/instances.yaml /tmp/orbit-e2e-instances-before-status-after-reuse.yaml
```

然后测试用户显式修复配置：

```bash
"$ORBIT_BIN" instances status --repair-binding --json | tee /tmp/orbit-e2e-status-repair-binding.json
git diff -- .orbit/instances.yaml | tee /tmp/orbit-e2e-repair-binding.diff
```

期望：

- 只有 `--repair-binding` 路径写回 `.orbit/instances.yaml`。
- 写回的是当前 verified session 的 stable Herdr handle。
- `.orbit/runtime` 仍是 runtime authority；config binding 只是 last-known hint。

最后恢复测试现场，避免影响后续步骤：

```bash
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-after-binding-repair.json
```

## Force replacement

真实用户遇到身份冲突、重复候选或不信任旧 pane 时，会选择强制替换。`orbit start INSTANCE --force` 应替换 Orbit 信任关系，但不要求自动 kill 旧 agent。

推荐对 reviewer 或 tester 执行一次 force replacement：

```bash
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-before-force.json
"$ORBIT_BIN" start tester-main --force --json | tee /tmp/orbit-e2e-force-tester.json
"$ORBIT_BIN" instances status --json | tee /tmp/orbit-e2e-status-after-force.json
```

期望：

- 新 start 生成新的 `ORBIT_SESSION_ID` / `ORBIT_LAUNCH_ID`。
- 只有拿到新 Herdr pane id 后才写 `.orbit/instances.yaml` binding。
- `.orbit/runtime/instances/tester-main.json` 使用 `orbit-runtime-instance-v1`，保留 `current_session_id`、`previous_sessions[]`、`replacement_diagnostics[]`。
- 旧 session 被标记为 `replaced` 或至少不能继续作为 active verified session。
- 后续来自旧 session 的 review/test gate-closing evidence 不能关闭 gate。
- 如果旧 agent 仍在运行，它不能通过 register 抢回 active session；当前版本没有独立 heartbeat 子命令。

force 后必须重新验证新 tester：

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to tester-main \
  --json | tee /tmp/orbit-e2e-dispatch-tester-after-force.json
```

如果 force 后返回 pending，按前文要求由新 tester pane 自己 register 或 piggyback register，verified 前 direct dispatch 必须 fail closed。

## 负向路径

至少覆盖这些负向行为：

### pending 不能 dispatch

人为选择一个 `started_identity_pending` session，或构造 fake pending session，验证：

```bash
"$ORBIT_BIN" dispatch --task .orbit/tasks/tiny-calc-divide-zero.yaml --to <pending-instance> --json
```

期望 fail closed，不投递到 pane。

### manual payload artifact

当 direct dispatch 因 pending/stale/absent/mismatch 被拒绝时，用户仍应能显式生成 manual delivery artifact，而不是被迫向不可信 pane 直投。这个 artifact 是 manual protocol path，不触发 automatic runtime。

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to reviewer-main \
  --manual-payload \
  --json | tee /tmp/orbit-e2e-manual-payload.json
```

期望：

- 输出 `mode: manual_artifact` 或等价字段。
- 不调用 Herdr direct pane delivery。
- 不把 manual payload 结果写成 verified runtime identity。
- remediation 清楚说明需要人工复制/转交 payload。

### forged env 不能 verified

在 Codex observer pane 或普通 shell 中伪造：

```bash
HERDR_ENV=1 HERDR_PANE_ID=fake ORBIT_SESSION_ID=fake "$ORBIT_BIN" runtime register --json
```

期望不能写出 `herdr_verified`。

### status 默认不写 config

```bash
cp .orbit/instances.yaml /tmp/orbit-e2e-instances-before.yaml
"$ORBIT_BIN" instances status --json >/tmp/orbit-e2e-status.json
cmp .orbit/instances.yaml /tmp/orbit-e2e-instances-before.yaml
```

期望默认不改 `.orbit/instances.yaml`。

### explicit pane override 不继承 identity

```bash
"$ORBIT_BIN" dispatch \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --to reviewer-main \
  --pane <some-pane> \
  --json | tee /tmp/orbit-e2e-explicit-pane.json
```

期望：

- 输出 `identity_verification: override`。
- 输出 risk。
- 不写 active runtime session。
- 不让 evidence/gate 继承该身份。

### available_needs_seen 需要 ack

如果 Herdr 报告目标 `done`，Orbit 应映射为 `available_needs_seen`。验证：

- 未 ack 前 direct dispatch fail closed。
- 非 owner / 非 lead role 的 `ack-session` 不解除 block。
- owner / lead role 运行 `orbit runtime ack-session INSTANCE --json` 后，在 TTL 内可以继续 dispatch。

## Gate、audit、handoff

Codex observer 最后运行：

```bash
"$ORBIT_BIN" wait-gate \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --evidence .orbit/evidence/tiny-calc-divide-zero.json \
  --json | tee /tmp/orbit-e2e-wait-gate.json

"$ORBIT_BIN" validate \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --evidence .orbit/evidence/tiny-calc-divide-zero.json \
  --state .orbit/loop-state.yaml \
  --json | tee /tmp/orbit-e2e-validate.json

"$ORBIT_BIN" audit \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --evidence .orbit/evidence/tiny-calc-divide-zero.json \
  --state .orbit/loop-state.yaml \
  --json | tee /tmp/orbit-e2e-audit.json

"$ORBIT_BIN" handoff \
  --task .orbit/tasks/tiny-calc-divide-zero.yaml \
  --evidence .orbit/evidence/tiny-calc-divide-zero.json \
  --state .orbit/loop-state.yaml \
  --json | tee /tmp/orbit-e2e-handoff.json
```

通过标准：

- required review/test gates ready。
- validate 无 blocking error。
- audit 不把 Herdr `done` 当作 Orbit done。
- handoff 暴露 runtime verification state 和 known gaps。

## 最终报告格式

Codex observer 最终输出必须包含：

```text
Environment:
- Orbit command:
- Herdr version:
- Fixture project:
- Observer: Codex, not a test participant
- Participant agent client commands:

Agents:
- coder-main: pane, session_id, identity_verification
- reviewer-main: pane, session_id, identity_verification
- tester-main: pane, session_id, identity_verification

Lifecycle checks:
- close/restart agent checked: yes/no, old_session, new_session, result
- binding removal/untrusted verified reuse blocked checked: yes/no, result
- repair-binding checked: yes/no, config diff summary
- force replacement checked: yes/no, previous_sessions/replacement_diagnostics summary
- manual-payload artifact checked: yes/no, result

Commands run:
- ...

Evidence:
- task:
- evidence:
- state:
- review report:
- test report:
- audit:
- handoff:

Pass:
- ...

Findings:
- High:
- Medium:
- Low:

Not covered:
- ...

Verdict:
- PASS / FAIL
```

## 可直接发给 AI 的指令

```text
请做一次 Orbit + Herdr 真实端到端 dogfood 测试。

要求：
1. 当前 agent 是 Codex，只作为 observer/operator/recorder，不加入被测实现、评审或测试循环。
2. 新建一个干净临时项目目录，不污染当前 Orbit repo。
3. 使用当前 Orbit 实现初始化该项目。
4. 用 Herdr/Orbit 启动 coder-main、reviewer-main、tester-main；被测 agent client 只能从 Claude Code、OMP、OpenCode 中分配，不能使用 Codex。
5. 创建一个小型真实 coding task，让 coder 实现、reviewer 独立 review、tester 独立真实测试。
6. 全流程必须使用 Orbit task/evidence/state/gate/audit。
7. 验证 runtime contract：start、register、instances status、dispatch、pending fail closed、manual/override/stale/replaced 语义、evidence runtime_identity；不要依赖独立 heartbeat 子命令。
8. 必须覆盖真实用户生命周期：阶段完成后关闭一个 agent pane，再 status/start 恢复；binding 丢失后的 untrusted verified reuse blocked；显式 --repair-binding；显式 --force replacement；manual-payload artifact。
9. 当前 Codex agent 只监听、分派、检查和汇总；不得亲自修改业务代码、写 review/test report、提交 evidence verdict、修复失败或补做测试。
10. 最后输出测试报告：环境、命令、pane、证据文件、生命周期检查、通过项、失败项、未覆盖风险。

请按 docs/orbit-herdr-runtime-contract-e2e-dogfood-test-plan.md 执行。
```

## 非目标

- 不要求覆盖所有 unit tests；本测试关注真实 runtime workflow。
- 禁止当前 Codex agent 自己实现业务任务或替被测 agent 完成 review/test/evidence verdict。
- 不要求把临时 fixture project 保留进 repo。
- 不用 watcher / daemon 证明正确性。
- 不用 tmux/zellij/wezterm 兼容路径。
