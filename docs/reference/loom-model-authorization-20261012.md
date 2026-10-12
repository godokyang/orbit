# Loom 联动：严格模型授权与停止判断（2026-10-12）

本票属于 Loom 持续 Goal，由 Orbit Agent（w23:p1）实施并向 Loom Root（w22:p1）回报。完成本票不代表 Loom 首版验收。实现与模型实测的 Orbit 源码基线为 `4a529aa9337cf1115f9a824ef9589e6bd6b8e85c`（0.8.6 加本票差异）。用户随后明确授权 patch 升至 0.8.7、提交并推送 main、执行本机 orbit update；版本元数据不重标旧实测。最终提交身份见 Git 历史，安装与能力回读原件见本票证据目录的 `installed-version.json`/`installed-capabilities.json`。未发布、未打 tag。新增合同 1.4，与软件版本独立。

## 交付接口

- 能力：`model_authorization`。`orbit start --allowed-model provider/model` 可重复传；原生 start 工具用 `allowed_models` 数组。
- 首条消息和任务建立前也需受限时，在 `orbit omp` 进程启动时设置 `ORBIT_ALLOWED_MODELS='["minimax-code-cn/MiniMax-M3.1-Flash-Preview"]'`。会话上限冻结进新任务，任务参数只能缩小，不改全局池/配置。
- 公开状态新增 `model_authorization.allowed_models` 与 `auxiliary_judgments="disabled"`。任务内不扩大；paused 接续默认继承或显式缩小。Root/原生成员/检查者调用前受限，耗尽阻断。严格模式关闭可选 JEV；原生循环选模拒绝，使用精确授权型号；普通任务的偏好池/循环保留。
- 新能力和限制以 `contracts/integration.md/.json` 为准，Loom 检查 capability 后适配，不依赖内部 state/socket/名单实现。

## 原 Loom 停止判断

原件：`/Users/yangke/Personal/omen/loom/.loom/local/evidence/node-task-13/root-final-public-status.json` 及同项目任务原始记录。`0595af38-11bb-4ca1-bbfe-685172fd9ee5` 的实际检查为 `opencode-go/deepseek-v4.1-flash`；现有 selector 在输入变化后重选、池作为偏好，造成调用前授权边界缺口。新增严格能力处理此问题，普通偏好语义不重开。

停止原件的失败是 `Root: omp connection: Connection refused - connect(2) for /tmp/loom-n07-XwrQx1/c.sock`；成员结果为空、checker_cleanup_error 为 null，Root 桥不可达，不能核实 Root、工具或 detached 工作已结束。`stop_unconfirmed` 是诚实阻断，当前没有该次停止确认机制的真实缺陷证据。恢复仍要求同项目/Root、真实原生用户消息与 confirmed paused；未知停止不能作为新写者许可。

本票最后经公开按引用 CLI 只读回查：上述任务仍 revision 12/stop_unconfirmed/confirmed=false，同引用的 `b061cdd1-4373-46f3-819b-4ca1e0a92320` 仍 revision 7/paused/confirmed=true。没有改写 Loom probe 状态、执行 stop 重试、杀其进程或据竞争覆盖的 s12/s13 重建成功事实。

## 验证与原件

原件根目录（0700）：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-auth-zt4walug/evidence`。保留模型实测与零模型核查的隔离源码快照 `../snapshot`（0.8.6 加差异，区别于随后0.8.7安装）供 Loom Root 审阅/复验；测试依赖只装在该快照，仓库没有安装 node_modules。

| 层级 | 实际结果与边界 |
| --- | --- |
| 零模型测试 | 输入变化仍仅授权候选；授权耗尽/不可用不探测外部回退；可选 JEV 调用数为0；普通任务仍回退。调用/凭据计数器证明 Root、child、未知辅助会话、缓存 resolver、原生 setModel/cycleModel 在边界拒绝；公开名单与接续不扩张成立 |
| 回归 | 隔离快照全套 npm test 两次退出0，原件 `npm-test.log`/`npm-test-final.log`；最终收紧原生 cycleModel、共享 Root 选模核心后，相关 model_authorization、native gate、session agents 再验证，原件 `authorization-final.log`/`native-gate-final-current.log`/`session-agents-final.log`。全套结果不重标为最后两处改动后的全套重跑 |
| 独立核查 | 复用已确认空闲的 w23:pK，仅只读、不运行/写文件/新模型探针；核查公开 SDK stream、resolver/getApiKey、辅助判断、late attach 与 native setModel/Root 选型接缝，结论及最终收紧复核见 `independent-review-pK.txt`/`independent-review-pK-final.txt` |
| OMP 18.9.0 真实有限路径 | `live3`：socket 首消息前建立；授权外原生 set_model 和 CLI 检查型号在调用前拒绝；仅 MiniMax 显式 start→Root 写 artifact→独立 artifact check（terminal=continue，实际 models 仅 MiniMax）→公开 stop→paused/confirmed=true；进程退出0，socket释放，调用方 sentinel保留 |
| 模型回执 | `actual-model-summary.json`：最终 Root 原生 assistant 回执4条、检查 usage.calls 2条，均为 MiniMax。另有一次驱动中断的 MiniMax aborted 回执，费用/配额不从条数或耗时推算。不是上游实际路由身份全认证 |
| 驱动失败保留 | 首轮错误假设 RPC set_model 会走 getApiKey，实际只改配置、没有模型调用；新增 setter 调用前拒绝后实际前置通过。第二轮驱动把多行公开 JSON 当首行解析，引发 KeyError，已修正；该任务后来公开回读 confirmed paused，只证明停止。首次日志、live2 原件不删除，不据其倒填成功检查 |
| 最终代码身份 | 模型实测后的源码候选（升版前，基线SHA加当时未提交差异）；源码清单 `validated-code-manifest.json`，SHA256 `fbdeec3bfa738d99f776bc57cdbf38b1050a753bfdb3b35baf75e9b1eae98020`。真实 live3 早于最后两处仅收紧选模的改动；最后相关零模型/原生替身复核后没有为此重复付费探针 |

未证明：Loom 端对新接口的完整采用、严格名单下真实原生成员/失败回退/恢复组合、成功逐标准最终验收/complete、多平台或所有 OMP 版本。原 paused 接续已有 Loom 原 s11 记录，本票新增硬名单的真实接续未重新宣称通过。

## 收尾

真实三个 OMP 进程均已退出，自有任务停止已确认；调用方路径释放由 Orbit 原件证明后，临时 socket 目录由其创建者清理。全套测试、预检及定点回归遗留的五个 reviewer/model-probe 进程只在 command 精确指向本票唯一快照、PGID/CWD核对后发 TERM，退出核对见 `probe-cleanup.json`；其目录只在无进程使用后清理。没有杀未知进程，没有创建/关闭 pane，没有改全局环境/账户/供应商/密钥。保留证据、源码候选、实际原生会话与隔离项目供回查；这些是交付原件，不当作对外发布或 Loom 完整验收。随后本机更新不改变上述有界实测范围。
