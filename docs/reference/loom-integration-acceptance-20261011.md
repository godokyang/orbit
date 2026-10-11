# Loom 集成合同有界验收（2026-10-11）

本轮在 Orbit main 开发；Codex 经 Herdr 使用已有 OMP 执行席并审核，未操作 Loom/Zeen 产品。合同版本独立于软件版本 0.8.5，未更新日常安装或发布。

## 阶段 A（合同 1.2）

- 基线：`52bb3848a706013fbbb8ddc7d6613e6564e093a9`。真实 RPC 使用含待交付文件改动的隔离快照，SHA-256 `4f66d16a2bd2c264941f2cbef4d2bd7c4af7d08d2bc6470eb1d94b0daec90f6d`；不是仅旧 HEAD 的 archive。锁定依赖只在该副本 npm ci，未升级。
- 实际宿主：OMP 18.9.0，Root 模型 `minimax-code-cn/MiniMax-M3.1-Flash-Preview`。使用快照的 orbit omp --mode rpc，原生 get_state 在首条消息之前返回 sessionId；指定控制路径提前连通。
- 首条「请用 Orbit 受控执行…」完成后任务数 0、无入口判定文件；随后公开 start 成功，external_refs 原样回读；按引用查询得到同一任务。
- 公开 stop 最终为 paused 且 stop_confirmation.confirmed=true。正常关闭 RPC 输入后进程退出码 0，运行时 PID 已退出；调用方目录和 sentinel 保留，socket 释放，所记录进程组无存活进程。
- 自动化：G8 精确/多任务/终态/无匹配/互斥/坏记录错误；G9 原有默认入口与外部模式、会话切换、caller 替换文件保留、活 socket 拒绝、非私有目录拒绝与同 uid 死 socket 回收。动态模型响应未固化为单测断言。
- 独立只读审核发现 alias 身份采集竞态；Root 用独立脚本实际复现会误删调用方替换的活 socket。修正为在硬链接前取内部自有 socket 身份后，同脚本证明替换 socket 保留，已有 G9 测试通过；不新增模型输出断言。
- 最终快照 SHA-256 `51ffbb03202bea8f15d44d820f240125f59a890504dcfc848e764df46cd2dcda` 已包含该修复和 project 非目录校验，全量 npm test 与真实 RPC 退出码均为 0；首轮全量亦通过。最终生产四文件和实际 RPC 快照一致，Codex 定点复核竞态与非目录校验，审核通过。原首轮实测保留为修复前记录，未混称最终构建。阶段 A 即将本地提交，B 尚未启动。

限制：真实验证只覆盖 macOS、上述 OMP 版本与单一 Root 模型；安全分支与切换由自动化覆盖，未逐一真实模型验证。Unix socket 硬链接需指定目录与私有临时目录在同一文件系统；其他平台/跨文件系统不认证。Root 显式 start 仍可用，调用方须核对 external_refs；未提供会话登记或 status --session。Loom 持续集成尚未对本成果运行。

资源纪律偏差：G9 执行席在 Root 制止未知目录清理前，已 rmdir 13 个归属未经逐一确认的空 /tmp/orbit-omp-* 目录；回执称仅为空目录、无文件删除，剩余活动目录未触碰。该行为不符合任务资源边界，已冻结清理，后续只核对明确自建资源，不能把这次收尾写成全程无越界。

## 阶段 B（合同 1.3）

阶段 A 全量测试、真实 RPC、独立审核与 Codex 收口通过；本地提交后开始 B。
