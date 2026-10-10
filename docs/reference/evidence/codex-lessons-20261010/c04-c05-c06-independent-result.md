## 独立只读核查报告：C04/C05/C06 集成

核查基线：omp-host.mjs#4CC6、work-unit-scope.mjs#D97F、native-task-preflight.mjs#266B、18.8.0 真实 SDK（agent-session.ts / job-manager.ts）、tests 两文件。未写代码、未跑测试、未重研究。

### C04 原生 task 门 + preflight — 成立

- `validateNativeTaskTools`（native-task-preflight.mjs:6-15）在 caller 身份、绑定核验、注册门之后、型号解析与派发之前执行（omp-host.mjs:2920-2926）；整调用原子阻断，无部分派发；`native_task_preflight_failed` 事实带 `session_id/agent_id/tool_call_id/dispatched:false`，满足"阻断不记成派发"。阻断原因含具体修正指示（移除 tools、禁止绕行 eval agent）——针对 §173 原件 `call_44f1c28beab9424ea5fdb7bd` 的真实接口失败，诊断指向改变下一次调用。
- 边界：自定义工具名（非 builtin 集合）直接放行，注释明示不推断——符合冻结范围。gate 测试 30-32 为单元级断言；**事实落账的 gate 级断言未见**（`native_task_preflight_failed` 仅被实现写入，无测试取证）——Root 正在做的 native gate 取证可覆盖，非代码缺陷。

### C05 busyFlags / 停止准入 — 成立，缺口诚实

- `hasAdmittedSubmission` 是 18.8.0 真实 getter（agent-session.ts:2896，`#admittedSubmissionCount>0`：已受理未派发/入队/放弃的提交）——正是旧 busy 判定漏掉的"唤醒在途但 isStreaming=false"窗口。三处使用（state 观察 2181、retained 停止 2603、live 停止 2665）语义正确。
- live 路径顺序正确：cancelAll→（busy 才 abort）→reap（5s 截止）→50×100ms 轮询 busyFlags 清零→工具状态实测为零才确认；post-hoc 跟踪不冒充全程证据（2675）。
- retained 路径：abort→cancel+reap→幂等 dispose 屏障→dispose 后再验 busy/工具（2617-2624），不凭 tombstone 确认。
- 无会话路径返回 `confirmed:false` + 结构化证据（2651-2661），`stop_unconfirmed` 保留；`beginDispose`/`registry.release`/`park` 全文件未使用（grep 证实），与"beginDispose 单会话不可逆、无团队原子关闭"的缺口记录一致。
- **小缺陷**（防御纵深，非现行路径）：retained 路径 `owner = getAgentId ? getAgentId() : ref.id` 静默回退（2606），live 路径无 owner 即抛错（2664）。若 getAgentId 缺失，cancel/reap 打到错误 owner、reap 平凡 settle，可能在后台作业未清时确认停止。AgentSession 实际恒有 getAgentId，当前不可触发。

### C06 首执行定位 / X_OK / shebang / NVM — 成立，一处诊断精度缺陷

- 静态首跳：bare-word 提取（shell 语法不解析、直接跳过静态判定由内核强制，注释明示）；X_OK 过滤；realpath 后 2 字节 `#!` 判定；shebang 脚本落在沙箱数据读集外 → 带 `.runtime` 副本方案的恢复指引；裸二进制不扩大拒绝（466-469 注释与实际测试 172-180 一致）。EACCES 仅对 runtime 工具升级为阻断，其余保持 unknown+内核强制。
- work_unit_scope_test 覆盖 NVM 正/负例：外部 npm-cli.js 阻断含 `.runtime` 指引、内部副本放行、外部 node 裸二进制不误伤。
- **缺陷（诊断精度，fail-safe，无越界面）**：`assertCommandReadable` 对含 `/` 的相对 token 一律 `path.resolve(root, token)`（443-444），而 `validateMemberTool` 允许成员 `input.cwd` 为 root 子目录（503），bash 实际按 cwd 解析相对路径。组合 `./script.sh` + 子目录 cwd 时：root 下无该文件 → 误阻断"no executable on member PATH"；root 下有而 cwd 下无 → 预检通过但执行失败。两个方向都不造成沙箱逃逸（内核在实际 exec 时强制），仅诊断失真。修复方向：把实际 exec cwd 传入 assertCommandReadable 作相对路径基址。

### 资源与结论

- 不需要新资源/新进程。
- 无阻断性缺陷；两项小缺陷（retained owner 回退、相对路径 cwd 基址）均 fail-safe，是否修由 Root 裁决。C04 gate 级事实取证待 Root 正在进行的 native gate 验证覆盖。