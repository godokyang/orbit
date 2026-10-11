# Orbit 检查证据写入与快照占用调查、待审核方案

日期：2026-10-11。用户本轮要求先调查并分别给方案审核；本文不是实施授权、产品合同或已完成验收。源码基线 `25f0104`（Orbit 0.8.4）；现场 `/Users/yangke/Personal/omen/zeen/.orbit` 只读，未修改任务、删除副本或停止用户进程。未创建测试 pane、安装或模型验收任务。

最新范围：用户要求先不处理 Zeen 本身的日志清理，改为检查 **Orbit 保存日志与检查证据的代码是否存在问题**。以下 Zeen 统计作为定位依据保留；当前建议只修产品新增检查的存储路径，不包含 Zeen 存量迁移、清理或迁移预览，也不把它们作为本项验收前置。

## 1. 实际占用

方法：`du -sk` 分别统计 `.orbit`、一级目录、任务目录及全部 `checks/*/workspace`；读取 25 个 `state.json`、309 个 `scope.json` 的状态与清单。GB 为十进制；GiB/MiB 为二进制。`du` 是文件系统报告的占用，不等同于 APFS 删除后必然释放的独占物理块；不同 inode 也不能证明不存在 APFS 共享块。

| 项目 | 实测 | 判断 |
| --- | --- | --- |
| `.orbit` | 30,075,984 KiB＝30.798 GB＝28.683 GiB | 与截图 30.80 GB 吻合 |
| `tasks` | 29,300,032 KiB | 主要来源 |
| 309 个检查工作区 | 28,536,724 KiB＝29.222 GB | 占 `.orbit` 94.88% |
| `.orbit/work` | 775,396 KiB | 独立工作产物，不归入检查副本回收 |
| 工作区以外全部内容 | 约 1.576 GB | 方案不承诺将整个 `.orbit` 压成 303 MB |
| 检查目录非工作区文件 | 384,475,136 bytes（分配块合计） | 其中 scope 225.7 MB、events 82.0 MB、profile 39.5 MB、prompt 30.2 MB；不是主要膨胀来源 |

最大的两个任务：

| 任务 | 状态 / 检查数 | 任务占用 | 工作区占用 |
| --- | --- | --- | --- |
| `147962d3-67cf-49df-867d-2e6f9d712efc` | `needs_user` / 148 | 11,259,696 KiB | 11,069,740 KiB |
| `b4f955d1-58fe-47c1-a33f-37980081f683` | `paused` / 49 | 5,976,748 KiB | 5,885,716 KiB |

两个任务合计 17.650 GB；现有 `runtime_pid` 均未记录，且各自保留停止确认。它们仍有后续业务价值，不能因此删除任务或假定所有历史 checker PID 都已安全退出。全场另有三项 `stop_unconfirmed`，迁移必须另核对运行归属和清理状态。

现场依据：[148 次任务状态](/Users/yangke/Personal/omen/zeen/.orbit/tasks/147962d3-67cf-49df-867d-2e6f9d712efc/state.json)、[49 次任务状态](/Users/yangke/Personal/omen/zeen/.orbit/tasks/b4f955d1-58fe-47c1-a33f-37980081f683/state.json)、[49 次任务事件](/Users/yangke/Personal/omen/zeen/.orbit/tasks/b4f955d1-58fe-47c1-a33f-37980081f683/events.jsonl)。未检查或清理用户要求保留的 iOS DerivedData、Android 构建、项目依赖。

## 2. 重复与异常

309 份清单共记录 800,656 个普通文件条目，内容字节合计 27,438,358,352。按声明的 `content_digest` 合并后，6,651 个不同内容合计 **302,988,833 bytes＝约 303 MB＝288.95 MiB**；声明层面的重复比例约 98.90%。整树摘要有 176 个不同值，所以只复用「完全相同的整树」仍会反复存放略有改动版本的大量相同图片。

例：`apps/mobile/assets/secretary-orb-purple-cropped.png` 在所有检查中声明的累计字节约 580 MB，现场 309 份文件有 309 个不同 inode。重复路径还包括 `.pen` 设计、图片、生成合同与原型 HTML。这不是复制 `node_modules` 的证据；当前 Git 快照遵循 Git 文件清单与忽略规则，`.git`／`.orbit` 被排除。

额外只读校验：每个不同声明内容选取一个实际文件，读取并计算 SHA-256，总计约 303 MB；**181 个代表文件摘要不符、1 个不存在**，均位于 9 月 19 日的旧任务 `147962d3…`。这是代表样本，不是全量 800,656 个副本逐文件校验，也不能证明其余重复副本全部一致。异常的成因未裁定，不据此宣称当前实现损坏快照。

例：[check 61 清单](/Users/yangke/Personal/omen/zeen/.orbit/tasks/147962d3-67cf-49df-867d-2e6f9d712efc/checks/61/scope.json)：`apps/mobile/app/feedback-task/[feedbackId].tsx` 声明摘要 `ddff3bc5…`，实测 `3983ae9d…`，长度同为 47,419 bytes；该文件 mtime 为 12:55:46 UTC，检查开始为 11:40:06 UTC。另有声明与实测仅一个十六进制字符不同的摘要；仅凭时间或差异形状不能判断是谁改动。缺失项为 check 50 的 `docs/decisions/0116-feedback-completes-on-release-merge.md`；代表异常分布在 38 份 scope，未作全量校验，不能认定其他 scope 无异常。303 MB 因此只是基于历史声明的容量估计，不能作为「完整证据已验证」或最终迁移体积承诺。

## 3. 源码与历史调用原因

当前 [TaskRuntime#start_check](../../lib/orbit/task_runtime.rb#L2657) 为每次检查指定 `checks/<number>/workspace`，调用 [WorkspaceSnapshot.capture](../../lib/orbit/workspace_snapshot.rb#L44)，生成独立 staging 后 rename。文件通过 [materialize](../../lib/orbit/workspace_snapshot.rb#L265) 的 `File.binwrite` 全量写出；摘要用于身份和过期判断，**当前没有内容去重存储**。正常结束、失败、停止路径清理进程并保留回执，没有历史工作区回收。

原有固定快照正确性必须保留：脏文件、非忽略新文件、删除、权限、内部符号链接与外部链接拒绝；读取和集合变化检测；检查前后指纹与版本绑定。[检查结果门](../../lib/orbit/omp_check_runner.rb#L388) 与[运行合同](../../contracts/task-runtime.md#L142)不能为了省空间而降级。

两个任务的检查次数并非同一原因：

- 148 次任务是 2026-09-19 的旧 Codex runner（例 [check 135 run](/Users/yangke/Personal/omen/zeen/.orbit/tasks/147962d3-67cf-49df-867d-2e6f9d712efc/checks/135/run.json)），143 次 stale；原因中 host 143、artifact 71、input 21 可重叠，旧 scope 未记录 trigger。不能把这些历史调用归因于当前 OMP 18.8.0 或宣称新版本仍会同样频率运行。
- 49 次任务时间为 2026-10-07—08，29 次 artifact、20 次 process；trigger 包括 model_fallback 19、member_block_stall 12、manual_check 7、manual_dispute 5、checker_interval 3、amendment 2、change 1。19 次失败分为 invalid_result 12、unavailable 5、auth_or_quota 2；其 [request 49](/Users/yangke/Personal/omen/zeen/.orbit/tasks/b4f955d1-58fe-47c1-a33f-37980081f683/checks/49/request.json) 明确 SDK18.4.9。后备、争议与手动检查各有理由，不能仅为节省磁盘删除检查或降低频率。

当前自动 observation 去重与 artifact 的 host stale 修正已经存在，保留其已有验证边界；它们不回收旧数据，也不解决不同版本文件的大量重复。[check_history_for](../../lib/orbit/task_runtime.rb#L652) 读取历史结果与 scope 身份，通常不需要旧工作区常驻；但 [TaskEvidence.export](../../lib/orbit/task_evidence.rb#L47) 当前递归打包任务内快照，因此存储改动必须保持导出自包含，不能只留下失效路径或外部 blob 引用。

### 3.1 日志与证据写入代码核对

| 写入对象 | 当前代码与实际行为 | 本次判断 |
| --- | --- | --- |
| 检查 `workspace` | `task_runtime.rb:2657` 每次 capture；`workspace_snapshot.rb:265-273` 按完整文件字节重新写入；相同摘要不会复用内容 | **确认的容量缺口**：完整副本按检查次数增长，略有变化的树也重复保存未变资产 |
| 检查结束后的 workspace | `finish_check`（3063）、`handle_check_failure`（2816）、`stop`（3720）收集结果/回执与停止事实；没有成功、失败或取消后的工作区归档/回收 | **确认的生命周期缺口**：已经结束的检查仍长期占一份完整目录；修正需先保全历史内容、确认进程退出 |
| `state.json` | [TaskRecord#save/write](../../lib/orbit/task_record.rb#L143)：临时文件写入、flush/fsync、rename 覆盖；ensure 删除临时文件（278-291） | 没有每次保存追加整份状态或永久保留所有写入临时文件的证据 |
| 任务 `events.jsonl` | [TaskRecord#event](../../lib/orbit/task_record.rb#L294)：每次调用追加一条事件，不重写既有日志再追加 | 正常按事件数增长；不能由“追加”认定重复写入 bug；未做所有运行事件的全量审计 |
| 协作 `collaboration.jsonl` | [collabWriteLine](../../plugins/omp-host.mjs#L250)：以 append 打开并写一条 JSON；每任务串行队列，不把旧文件整份再追加 | 所查写入路径没有发现整份日志重复追加；完整事件与桥接截断文本用途不同，不据此删除原始事件 |
| `native-model-calls.json` | [publish](../../plugins/native-call-recorder.mjs#L53)：按 call_id 更新 calls；临时文件写完再 rename；同 call 的 pending/final 覆盖 | 未见将同一调用每次同步再追加成新记录；gap 日志单独保留真实写入失败 |
| 检查 `evidence.json` | [reviewer.ts](../../runners/omp-reviewer/reviewer.ts#L157) 原子覆盖 checkpoint；532-542 重算无 call_id 的回执；557 起只处理 message_start/end；当前 runner 的 events_path 也指向这一文件（omp_check_runner.rb:349） | 没有按每个流式 token 追加完整证据的路径；保留之前已修正的回执去重，不把旧 Codex events 文件归因于当前 OMP writer |
| 检查 `stderr.log`、scope/profile/prompt | runner 每次检查独立目录；stderr 以 `wb` 打开（[spawn_reviewer](../../lib/orbit/omp_check_runner.rb#L504)），scope 保存完整清单，profile/prompt 保留检查证据 | 有每次检查的固定/清单开销，现场合计约384 MB，远小于29.22 GB工作区；当前不另扩日志轮转或删除策略 |

结论限于已核对的源码和现场容量：主要问题是**检查证据把完整项目副本永久保存且不去重**，不是已证明的文字日志递归膨胀。`.orbit` 已被快照枚举排除，因此没有发现“把自己的日志再复制进自己的日志”的当前路径。现有完整快照有检查隔离与历史证据价值，不能直接删掉；要改变存储方式。旧任务的181个摘要异常和1个缺失没有足够证据归因于当前日志写入代码，本项不宣称已定位或修复其成因。

## 4. 推荐方案：历史内容去重，检查时保留独立工作区

这是待用户审核的新存储方案，实施后需同步合同中的快照保存与导出说明。

1. **项目内按内容保存历史文件**：在 `.orbit` 下保存以 SHA-256 寻址的只读内容对象；每份检查继续保留自己的原始 scope／manifest、结果、版本、finding、模型与用量回执、日志。所有历史版本都可重建，不用按天数或数量删除证据。不同任务只在同一项目内共享内容，不引入外部服务、全局缓存或数据库。
2. **在途检查仍用独立的完整目录**：沿当前 capture 原子 staging、变化检测和只读工具路径生成快照；并从同一批已读取、已校验字节保存内容对象。执行时不让 checker 或源项目与对象存储共享可写 inode，不采用指向实时源码的 hardlink／symlink。保持图片原始字节和指纹事实。
3. **检查真正结束后移除可重建的工作区**：先保存并校验对象与归档引用，再确认检查进程组退出、回执已收集，才删除这一份临时 `workspace`。失败或取消也适用，但 `cleanup_error`、未确认退出、归档失败、摘要不符、孤儿目录一律保留并报告；不以任务显示 paused 或历史 PID 不存在单独作安全依据。任务重启后有明确归属且满足同样条件时补做收尾，不能在模型未结束时拆目录。
4. **恢复与导出接入同一存储**：增加明确的只读检查历史恢复入口，按清单重新生成独立目录并核对摘要、mode、删除与链接规则；现有 `orbit export` 从归档流式带入内容，继续形成自包含证据包。不能要求用户手工拼接对象，不能将旧 scope 的历史 digest 改写成新事实。第一版只处理检查快照，不扩到 takeover snapshot／work 产物。

收益：新增检查的长期存储从「每次完整项目」变为「新内容对象＋每次清单和回执」，同时保留现有真实目录检查路径。Zeen 声明清单的约303 MB不同内容相对29.22 GB工作区说明按文件去重有价值，但当前不迁移它的存量，**实施本方案不会自动释放 Zeen 已有的30.80 GB**。后续只用新构建的隔离项目测量新增存储、元数据与在途副本；不以旧清单估计冒充已经节省。

不选：只删除已完成任务（最大两项并非 complete）；仅压缩每个完整副本（重复图片通常难压且仍按次数增长）；只共享相同整树（176 个版本仍重复资产）；hardlink 实时源码或共享可写快照（历史内容可能随写入变化）；全局保留天数／自动销毁任务（没有当前授权依据）。

## 5. 当前方案与授权范围

本次建议用户审核的实施边界为：**修正 Orbit 新检查的快照存储、结束后安全归档/回收、历史恢复和自包含导出**。先跑已有相关测试；直接核对 capture → checker 启动 → 正常/失败/取消结束 → 回执与退出确认 → 归档 → 恢复/导出这一条调用链，并保留旧完整目录格式的读取与导出能力。

Zeen 存量迁移、预览和实际删除全部暂缓，只有后续用户重新要求时才提出具体范围。当前不删除任务、不改变 needs_user／paused／stop_unconfirmed 状态、不清 `.orbit/work`、用户源码、依赖和移动端构建；不新增硬预算、不改变检查频率或模型后备策略、不建设通用日志清理框架。产品存储修改仍是待审核方案，当前只进行了源码调查和文档更新。

## 6. 冻结验收建议（尚未运行）

- 重复检查同树及小改动树，内容对象只增长新字节；独立工作区按已确认进程退出收口，长期占用不再随完整项目乘以检查次数增长。
- 既有 snapshot 测试加少量关键回归：脏/新增/删除/mode/链接还原一致；改实时源码或一个检查目录不污染其他历史版本；存储失败与中断保留原副本并可重试。
- 隔离夹具验证旧完整目录仍可读取与自包含导出，未触发自动迁移；新检查的 stop_unconfirmed 与在途检查拒绝回收。独立核查归档完整性及回收门，不只重复实现者回报。
- 真实已安装 `orbit omp` 完成独立只读检查、图片读取、失败/取消回执、停止确认；归档后恢复及 `orbit export` 仍自包含，按实际新构建复验。测试 pane、进程及临时安装逐项清理，固定用户资源保留。
- 用隔离项目量测多次新检查前后的 `du`，分别报告对象内容、元数据、在途/异常保留量；不宣称估计的98.90%是整体磁盘节省，不把 Zeen 清理作为验收条件。

本轮仅形成研究与方案；没有启动新 Goal。此前安装可选依赖优化 Goal 的 complete 是历史事实，不覆盖这两项新问题。
