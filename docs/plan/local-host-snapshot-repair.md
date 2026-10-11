# 本地 OMP 与检查历史存储修复（2026-10-11）

唯一总 TODO。最新用户授权实施两项修复，覆盖研究报告旧待审核标签；旧安装优化 Goal 和 25f0104／0.8.4 不重开。本轮实际 Goal 于2026-10-11T05:57:01Z启动，全部门完成后工具于07:43:39Z确认complete；不设资源硬预算。

依据：[宿主调研](../reference/omp-local-reviewer-host-research-20261011.md)、[存储调研](../reference/orbit-snapshot-storage-research-20261011.md)、任务运行合同及 ADR-008/009。Root 负责依赖、集成、验收、沟通；固定 H/J/K 用 Herdr 实际身份复核后协作，不用内部 subagent。供应商实测 UI：H K3-256k、J Grok 4.7 500k Fast、K GLM-5.3-Flash，OMP18.8.0；可得费用/配额 unknown。

## 冻结验收（实现前）

1. 安装 shell 本地/远程与 Ruby 直接入口提前核对 OMP：未安装、不可执行、版本/能力不支持分别中文诊断，失败无后续源码/依赖下载、不切换旧安装；help/卸载可用，不自动安装升级 OMP、不退回私有 SDK。
2. 先用实际本地 compiled OMP 做无模型探针：导出、可信 factory 加载、初始化副作用、隔离设置及 TERM/dispose/退出。成功后适配现行检查器并移除私有 SDK；精确选模、源认证、独立 registry/profile、受限 read/grep/glob、图片 bytes/digest、schema、usage/error 与取消清理保持。
3. 项目内 SHA-256 文件内容对象＋逐检查归档；在途独立完整 workspace，无共享可写 inode。归档保存/验证、进程组退出确认、回执完成三门全部成立才回收；正常/失败/取消/恢复收尾均归属明确，异常保留并报告。
4. 历史恢复独立目录并核验内容/mode/链接；orbit export 自包含；旧完整目录可读可导出、不自动迁移。
5. 先跑相关已有测试，再补少量高价值回归；实质独立核查原件。按 orbit-real-acceptance 在临时 Git 项目和临时安装运行真实 orbit omp：必要负例/推荐原生 task-hub 集成/独立检查/停止矩阵，以及安装失败保留、权限图片、失败取消回执、重复/小改动增长、恢复导出。失败和干预保留，改代码后新构建复验。
6. 记录源码/构建/安装身份、体积和资源实测，合同文档同步；所有自开任务/进程退出确认后再关 pane 清所属目录/安装。完成全部门后才 complete。

## 范围与资源

不升版、提交、推送、发布、改日常/全局安装、替换宿主或维护 Fork。不处理 Zeen 存量迁移/预览/日志，不改其任务状态与证据，不宣称旧摘要异常已修复。保留所有既有 dirty/untracked；隔离工程若使用须携带当前实际状态。

启动基线：Root w23:p1，H/J/K w23:pH/pJ/pK；OMP PID12801/12883/12966 及关联 MCP，主 Herdr与归属不明 w23:p16 均保留。详细 baseline（Git diff/untracked 备份、全进程、pane、日常安装）在本轮临时根，由验收报告吸收必要身份；不凭历史列表清资源。

## TODO

- [x] 实际 Goal 启动、规则/调研加载、固定身份和资源基线核对、验收冻结。
- [x] 相关已有测试基线：snapshot／OMP runner／CLI checker／export／install 五组 exit0，原件 baseline/tests.log。
- [x] 宿主无模型探针与入口适配；安装前置门、移除私有依赖。
- [x] 内容归档、运行生命周期、恢复与导出实现。
- [x] 集成回归及实质独立核查：npm test 全量 exit0；H 存储、K 宿主实质只读核查，所发现回执/版本子进程问题已修正。
- [x] 新临时安装真实验收与必要修正后复验：冻结v2必要矩阵、推荐原生协作、失败/取消/归档异常、存储增长及历史恢复导出通过；校准失败/人工干预及限制保留。
- [x] 合同/ADR/文档同步、最终检查和资源收口：H/J/K独立核查完成，三测试pane/临时安装/进程/约1.80GB临时材料清，九份导出原件已核对留仓，固定和归属不明资源保留。
- [x] 实际 Goal complete：工具2026-10-11T07:43:39Z确认，计数1,226,664 tokens／6,397秒，无硬预算，非账单；[实际回执](../reference/evidence/local-host-snapshot-repair-20261011/goal-complete.json)。
