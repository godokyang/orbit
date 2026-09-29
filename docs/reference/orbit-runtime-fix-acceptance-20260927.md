# Orbit 运行体验与成本修复：隔离 OMP 验收（2026-09-27）

> 类型：历史证据／研究，按标题及正文记录的日期、版本和配置解读。下文“当前”“本轮”及旧规则不代表现行行为或授权；当前状态见[交接](../plan/handoff.md)，现行语义见[任务合同](../../contracts/task-runtime.md)。

## 口径与构建

本记录只描述本次计划对应的源码和隔离安装，不把本机日常安装或历史任务算作新构建通过。项目源码版本 0.7.7，OMP 宿主 18.3.2；隔离根目录 `/tmp/orbit-live-acceptance-wAlxtU/`，独立 `bin/`、`runtime/`、XDG 配置和缓存、Git 项目及本地 bare 远端。候选安装均取本地源码 commit `57c827d1499ee5d367ba224719f4f69723c77b96` 的 **dirty** 工作树，不是已发布版本。最终安装 `content_digest=930e8379f0ec430a4b61b92d13bd57175b51c9d14982f717d4a1d10ab767c647`、`installed_at=2026-09-26T19:21:10Z`；本机日常 `orbit --version` 后续实测为 0.7.6，未更新到本轮隔离 0.7.7，未发布、未对生产远端推送。

隔离构建按顺序以内容摘要区别：

- `82a7728833e2b887c399ab7796efbf8db5cf0ef8159e941c592769e6f0cb1942`：暴露交付时机与结尾换行误读。
- `713b82098dacc0b5c68725604f39ecad12f79755f6773717929140d4bca4d09c`：验证前两项修复及同会话两任务。
- `ba544571639a446e2894650391d9d8edf572590e793c94cee5eaa9f5f886f3d8`：验证非显式入口失败只提醒一次。
- `501df716422935983a2f7abdd69066ecab68a97eaf19ab5197ccce3936cad834`：验证检查在途状态栏，并暴露旧未跟踪文件误归因。
- `930e8379f0ec430a4b61b92d13bd57175b51c9d14982f717d4a1d10ab767c647`：最终构建；检查者明确 Git 状态并在旧未跟踪文件夹具中复验。

这次没有把 `package.json` 的 0.7.7 改作发布号：本地候选由 `source.commit`、`source.dirty`、`content_digest` 和 `installed_at` 区分，完整验收用安装的内容摘要追溯，不把相同 semver 误当相同构建。当前计划未授权发布或升级日常安装；仓库规则规定**需要**升版时递增 patch，不规定每次开发任务都必须升版。

通过 Herdr 在新启动的 `orbit omp --model zhipu-coding-plan/glm-5.2` 中操作真实 OMP 会话，而不是仅调用底层 Ruby 测试。**该模型由本次验收的测试控制者写入隔离夹具提示，不是本仓用户在真实委托中指定的模型。**隔离候选池含 `kimi-code/k3-256k`；`orbit model-status` 实际报告此**精确身份** `evidence_status=absent`、`quality=not_judged`、`isolated_probe=not_probed`。既有 `k3` 等近似身份不能当成该候选质量事实；夹具中的 Root 按测试提示显式选择池外检查模型 `zhipu-coding-plan/glm-5.2`，没有写入全局候选池。显式选择只做隔离检查环境的可解析性／凭据预检，**不经过候选池证据和 JEV 检查者质量排序**；这些任务证明了检查与完成回路，不证明自动选模、异家族评审或成本优化。独立检查者实跑相同 provider/id；本记录不推断模型价格或 Root 的任务 token 数。
实际打开隔离 OMP 的 `/orbit-models` 交互选择器：勾选项 `kimi-code/k3-256k · 证据 absent` 可见；页脚显示“缺证据：orbit model-evidence --file FILE|-；质量与隔离环境尚未探测”，并明确候选池不切换当前 Root。按 Esc 取消，未保存新的池配置。这是实际 TUI 表面证据，不仅是 CLI 的 JSON。

## 真实场景与程序记录

| 场景 | 证据与结果 |
| --- | --- |
| 低收益普通小修改 | `project-negative/.orbit/entry/d5e6c08e.json`：真实 TypeSafe `jev-1.13.0` 评分授权 0.93、独立检查收益 0.68（两门槛均 0.80），`decision=root_decides`；Root 直接改一行 `README.txt`、核对 diff，未建 Orbit 任务，未派成员；入口用量 517 输入／46 输出。不能把普通完成说成受控完成。 |
| 自动入口选模失败仍可普通执行 | 入口提醒修复候选 `project-auto2/.orbit/entry/40909f47.json`：两模块 Ruby 任务真实 TypeSafe 授权 0.94、检查收益 0.91，均超过 0.80，自动 `decision=start`；池内精确 `kimi-code/k3-256k` 缺质量证据，**无 `.orbit/tasks/` 目录**。OMP 可见警告明确“本次不受 Orbit 监督，可普通执行”，且仅在首次请求出现一次。Root 正常修复 HTML 转义和 BOM/CRLF CSV，既有 4 项测试从 3 失败到 4/4 通过，没有假称受控完成。前一安装对同一用户消息的每次工具回合重播失败提醒，虽也完成工作，却造成重复操作和干扰；源码改为仅非显式失败通知一次，显式失败仍须跨请求保留恢复提示。入口判断用量 641 输入／46 输出，与任务级 checker 用量分开。 |
| 无证据的显式入口（隔离夹具） | `project-smoke` 首任务先因池内 `kimi-code/k3-256k` 缺精确质量证据而被明确告知无法自动选模；本次验收控制者编写的夹具用户消息要求显式选择 `zhipu-coding-plan/glm-5.2` 并在本 OMP 会话记住，夹具 Root 据此传入 `review_model` 和 `remember_review_model=true`。这是测试授权，**不是本仓用户指定该模型**；先前失败未误建任务。保留池外显式选择和建任务前可解析性／凭据预检。 |
| 新构建同一 OMP 会话两次受控任务 | `project-smoke/.orbit/tasks/3f921897-f3ae-449e-8008-fdc84353b445/state.json`：`release.txt` 为 `release=verified\n`，17 字节、一个 LF；检查 1 是 Root 工作中的自动 `continue/delivery.ready=false`，检查 2 是 Root 结束可见交付后的手动 `complete/delivery.ready=true`，无 finding；发当前版本通知，Root 申请完成，`status=complete`、`stop_confirmation.confirmed=true`，耗时 138.8 秒。第二任务 `project-smoke/.orbit/tasks/2cabf8ae-42ac-4d5e-9406-f92701288a89/state.json` 在**同一宿主会话**不再指定模型，`start` 返回 `remembered_review_model=true`，仍使用显式选择 `glm-5.2`；只提交 `shipment.txt`（`shipped=verified\n`，17 字节），推送临时 `origin/main`，本地 HEAD 与远端 `a3ee25912dcaca9d3511b604529a86b52a5752c0` 一致。自动检查 1 为工作中 `continue`，Root 答复后手动检查 2 `complete/delivery.ready=true`，无 finding，通知→完成申请→真实停止均完成，耗时 166.9 秒。两个任务均无执行成员，Root 任务级 token 仍未知。 |
| 在途状态栏与旧文件归因（后续发现的失败样本） | 安装摘要 `501df716…` 上的新会话 `project-smoke/.orbit/tasks/26d1a7c0-76ef-4c08-9bab-86a13939cd59/state.json`：检查在途时 OMP 实际显示“Orbit：独立检查进行中，等待结果”，不再要求 Root 重复 `check`。文件 `ui-check.txt` 为精确 13 字节。该任务沿用前两次任务所在工作区，而前一次留下的未跟踪 `release.txt` 在当前 Git HEAD 下仍被 `review_focus.added` 列出；独立检查 #2 **错误推断它是在本任务窗口新增**并给出 finding。Root 用前序任务的时间与原始要求证实该文件先于本任务存在，未删除它；Root 却将自己的措辞更正用自由文本 `amend` 写入输入版本，导致额外检查。检查 #3 `resolved_ids` 撤销该误归因，#4 才确认可交付、发通知并 `complete`、`stop_confirmation.confirmed=true`；4 次检查共 122538 checker tokens、耗时 478.8 秒。结论是状态栏通过但检查者归因失败，不能用这个样本声称费用已降低。随后合同与评审提示明确：`review_focus.added` 是 Git 相对索引／HEAD 的当前状态，**不是任务开始时差异**；旧未跟踪工件须有任务动作/基线证据才能归因。Root 把自己的更正误作任务修订是本次操作缺口，不是程序自动并入新用户问题。 |
| 旧未跟踪文件归因修复后的独立检查 | 最终安装 `930e8379…` 在全新 `project-preexisting` 项目先提交 `README.txt`、**在启动 Orbit 以前**写入并保留未跟踪 `legacy.txt`；真实任务 `project-preexisting/.orbit/tasks/9e5c1e3a-c7d5-4c47-8e02-d3a1fa44412e/state.json` 仅写 `result.txt`（`verified\n`，9 字节）。检查 #1 和手动终检 #2 均识别 `review_focus.added` 内的 `legacy.txt` 为既有未跟踪文件，未提误归因 finding，核对 `README.txt`、`legacy.txt` 未变，`result.txt` 字节正确；#2 `delivery.ready=true`、`verdict=complete`，通知、Root 申请完成、程序 `status=complete` 与停止确认全部实测。两次检查 36035 checker tokens，耗时 99.5 秒；和上一项不同的工作区/交互，不能仅凭数值推断提示改动节省比例。 |
| 独立问题不修改旧任务版本 | 在前一候选的分阶段任务 `project-final/.orbit/tasks/f05c4573-fe78-4832-bd41-4dc99c5747e1/`，检查期间提出独立只读 Git 问题：`events.jsonl` 记 `user_message_unassigned`，`state.json` 的 `amendments=[]`，先后检查的 `input_digest` 不变，未因此判旧检查过期。真正改变任务要求必须显式 `Orbit amend`；这次验收后来要求推送时反而错误地要求 Root **不要修改原始要求**，故下述分阶段样本不能算成功验收。 |
| 远端事实及纠错 | 上述分阶段任务的首次检查记录 `git_remote.status=mismatch`：本地 `fbbcb0ab603982bd6e790ead233e6821713145a9`、远端仍 `457b4174e2233b8c40f74c13626d365ce4e5f8cf`；推送临时 bare remote 后检查记录 `status=verified`。旧版受限读取工具把文件最后一个 LF 后的合成空元素误当第二行，给正确的 17 字节文件发出错误 finding；Root 用真实 hexdump、blob 申诉，裁决撤销该 finding，但因上述未记为 `amend` 的授权，另给出未经原任务授权推送的 finding 并以 `needs_user`、`stop_confirmation.confirmed=true` 停止，**不是 complete**。这个失败样本累计 4 次检查、232766 checker tokens、耗时 841.8 秒，不用它证明推送任务成功。修复后隔离只读 `read/grep` 均排除合成尾行，`read` 报 `[bytes=17; final_newline=LF; actual_lines=1]`；新构建上述两项同会话任务无换行误报，第二项的独立检查程序侧实测远端匹配并成功停止。 |
| 检查成本与交付门 | 较早候选 `project-final/.orbit/tasks/dfa8f52b-0db6-4440-a45b-1017535ae0a5/`：首轮受控任务完成并真实停止，但 Root 最初未主动在最终答复前请求手动检查，后一次检查在 Root 仍工作时拿到空 `agent_message`，4 次检查共 117211 tokens。最终指导明确要求先 `Orbit check`，运行时等当前答复完成才启动手动检查；新构建两项任务均为 1 次自动＋1 次手动，检查用量分别 49253、58513 tokens，均无失效检查。不同任务与交互路径的数字只能显示本次实际花费，**不能**当作同负载严格节省率；JEV 入口用量与 checker 用量分开，Root 任务级用量、钱数未知。 |

状态语义按合同区分检查结果、带产物＋输入版本的完成就绪、申请入队和 `stop_confirmation`；工作中的自动检查 `continue` 不产生最终通知，手动最终检查有真实交付后才 `delivery.ready=true`。只读 Git 事实不以 Root 自称推送替代远端引用。修订归属、清除会话选择、模型池变更/过期与跨会话不继承由确定性消费端回归覆盖，不声称这次隔离样本逐一实测了所有分支。

最后源码改动后完整 `npm test` 再次通过（Ruby、Node、Bun；Bun 10 pass/0 fail），`npm pack --dry-run --json` 返回 55 个打包文件，`git diff --check` 通过。真实 OMP 停止确认只针对上述隔离夹具；测试通过不替代 live 限界。

## 界限

明确受控短任务**仍然**调用必要独立检查（两项实测均两次）；不通过隐藏的自动 complete、省略检查、替换当前 OMP Root 模型或假造缓存证据换成本下降。此构建没有新的自动选出有证据池内模型的 live 正样本，也没有低成本成员自动委派正样本；已有原生成员协作路径与这次任务的无成员样本不能相互替代。用户要更低成本的 Root 可自行用原生 `orbit omp --model <provider/id>` 启动独立会话；未提供未经验证的逐任务供应商切换。
