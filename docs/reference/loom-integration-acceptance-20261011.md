# Loom 集成合同有界验收（2026-10-11）

本轮在 Orbit main 开发；Codex 经 Herdr 使用已有 OMP 执行席并审核，未操作 Loom/Zeen 产品。合同版本独立于软件版本 0.8.5，未更新日常安装或发布。

## 阶段 A（合同 1.2）

- 基线：`52bb3848a706013fbbb8ddc7d6613e6564e093a9`。真实 RPC 使用含待交付文件改动的隔离快照，SHA-256 `4f66d16a2bd2c264941f2cbef4d2bd7c4af7d08d2bc6470eb1d94b0daec90f6d`；不是仅旧 HEAD 的 archive。锁定依赖只在该副本 npm ci，未升级。
- 实际宿主：OMP 18.9.0，Root 模型 `minimax-code-cn/MiniMax-M3.1-Flash-Preview`。使用快照的 orbit omp --mode rpc，原生 get_state 在首条消息之前返回 sessionId；指定控制路径提前连通。
- 首条「请用 Orbit 受控执行…」完成后任务数 0、无入口判定文件；随后公开 start 成功，external_refs 原样回读；按引用查询得到同一任务。
- 公开 stop 最终为 paused 且 stop_confirmation.confirmed=true。正常关闭 RPC 输入后进程退出码 0，运行时 PID 已退出；调用方目录和 sentinel 保留，socket 释放，所记录进程组无存活进程。
- 自动化：G8 精确/多任务/终态/无匹配/互斥/坏记录错误；G9 原有默认入口与外部模式、会话切换、caller 替换文件保留、活 socket 拒绝、非私有目录拒绝与同 uid 死 socket 回收。动态模型响应未固化为单测断言。
- 独立只读审核发现 alias 身份采集竞态；Root 用独立脚本实际复现会误删调用方替换的活 socket。修正为在硬链接前取内部自有 socket 身份后，同脚本证明替换 socket 保留，已有 G9 测试通过；不新增模型输出断言。
- 最终快照 SHA-256 `51ffbb03202bea8f15d44d820f240125f59a890504dcfc848e764df46cd2dcda` 已包含该修复和 project 非目录校验，全量 npm test 与真实 RPC 退出码均为 0；首轮全量亦通过。最终生产四文件和实际 RPC 快照一致，Codex 定点复核竞态与非目录校验，审核通过。原首轮实测保留为修复前记录，未混称最终构建。阶段 A 已完成 main 本地提交 `86d09af`（杨科，无 AI 署名），随后启动 B。

限制：真实验证只覆盖 macOS、上述 OMP 版本与单一 Root 模型；安全分支与切换由自动化覆盖，未逐一真实模型验证。Unix socket 硬链接需指定目录与私有临时目录在同一文件系统；其他平台/跨文件系统不认证。Root 显式 start 仍可用，调用方须核对 external_refs；未提供会话登记或 status --session。Loom 持续集成尚未对本成果运行。

资源纪律偏差：G9 执行席在 Root 制止未知目录清理前，已 rmdir 13 个归属未经逐一确认的空 /tmp/orbit-omp-* 目录；回执称仅为空目录、无文件删除，剩余活动目录未触碰。该行为不符合任务资源边界，已冻结清理，后续只核对明确自建资源，不能把这次收尾写成全程无越界。

## 阶段 B（合同 1.3）

阶段 A 本地提交 `86d09af930ca139300f398d8f5a797caba270086` 后开始 B。含当前待交付文件的快照 SHA-256 为 `b6287992d2fb65233bbe4c2aa4e7ddc5f8d15717402d6cf9029aa8500722b461`；锁定依赖仅在副本准备，全量 npm test 退出 0。最终 main 的生产、合同 JSON 和测试文件逐字节与该快照一致；收口只补文档。

- 独立 save 核查：未参与 B 实现的既有 OMP w23:pK 只读检查权威旧计数、排除清单、错误不重置、原子写与锁边界，未发现新增缺陷。审核对应 TaskRecord SHA-256 `e4115b62dd6c20b836d75fc1522280cc0147cfa3d5507d3def99deb27d70af9d`。未穷举所有 save 调用或模拟磁盘掉电，不扩大成全面故障认证。
- 新增测试：B 三个函数约 99 行，A/B 合计约 291 行（含既有 CLI 断言适配），覆盖持久变更/忽略用量/坏旧状态、phase 谓词、完成/失败/陈旧及旧 scope 回退。模型输出未固化为断言。
- 真实任务使用 OMP 18.9.0 与指定 MiniMax，marker.txt 最终是字节 `114,101,97,100,121,10`。任务 `088bea92-59f1-4108-ac03-2157e21b3f47` 的已观测 revision 为 2→7→11；连续三次 status 的 revision/updated_at 相同。实际检查的两条调用回执均为该型号，latest_check 去重只返回一个完整 provider/model，时间、输入与产物摘要逐项吻合，input_current=true，白名单未输出路径、文本、响应编号或用量。检查者实际输出不合规 ref，因此 terminal=failed、failure_kind=invalid_result；任务随后 failed 且停止已确认。**这是失败检查摘要的真实证据，不是成功检查或覆盖完成证明。**
- 同一交付的合法 paused 接续任务 `0a2b1f41-cf33-4a2b-a9d5-567ba9c084a1` 用真实原生消息启动，Root 以 bash od 核对上述文件。仅在自有运行时尚无 in-flight 检查时杀掉 PID 65674，再沿正常 run 入口启动 PID 65705；同一任务 revision 4→5，未回退。实际运行时 tick 观测（super 前后原始状态，未改产品行为）证明重启前 4→4、重启后 5→5，updated_at 不变；它们不是 status 读取的替代证据。随后正常暂停、确认停止，最终 revision=7、attention={phase:stopped,needs_user:false}，连续三次 status 不变，无已完成检查时 latest_check 确实省略。
- 原始驱动未全部绿灯：早期 CLI --prompt-file 冷启动失败（hub_events requires a bound task session）；Root 两次 write 产物缺换行，改用明确的 bash printf 后符合字节要求；一次 Root start 携带错误 native message id，沿 context 取得实际 id 后通过。bytes 驱动额外要求“检查完成后的无变化 tick”而超时；context 驱动用索引误取应省略的 latest_check 而 KeyError。保留错误原件，没有把退出码 1 改写为成功。Codex 另以原始状态、检查回执、真实 tick、进程记录和公开 status 交叉核验冻结字段门槛（两条受控边界分别证明检查摘要与重启），核验脚本退出 0；不追加上述额外门槛或重跑模型来追求驱动全绿。

真实观察到 starting/implementing/checking/stopped/failed；needs_user、stop_unconfirmed、complete、reworking、unknown，以及 stale/旧 scope 回退仅有确定性覆盖。无成功模型检查的证明，Loom CI、多模型/其他宿主版本/平台未验证；input_current 不证明产物覆盖有效。临时模型池及 runner 授权 guard 只允许指定模型，不替换检查或构造回执，拒绝未授权 fallback 不代表产品一般选模能力。

资源纪律另有偏差：B 执行席用 `rm -f /tmp/b-*.log` 清理，回执称仅匹配四个自建日志；Root 撤回该席全部写权与资源权，有界接管。无法独立证明 glob 只命中自有文件，不能声称全程无越界。

原始证据保留于本次 Codex 自建临时目录的 evidence：快照 manifest/diff、npm 日志、独立审核回执、RPC 原件、实际 tick 与 `b-acceptance-reconciled.json`。重建/交叉核验脚本及原生会话材料一并保留；已确认自有进程/组均退出、无自有监听 socket，调用方目录保留验证后只清理本任务明确自建者。既有执行席、用户目录、日常安装与未知临时目录不清理。最终保留位置见本次中文交付报告。
