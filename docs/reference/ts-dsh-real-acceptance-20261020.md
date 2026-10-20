# DSH 真实模型验收（2026-10-20）

范围：隔离 `DSH_HOME` 下的 Root 真实模型 + 独立检查者真实模型，一次 hello.txt 交付。使用桌面版 DSH 0.2.1-rc.2，未改用户 `~/.dsh`。

## 环境

| 项 | 事实 |
| --- | --- |
| app home | `/tmp/orbit-real`（web 模板派生，装入 `@zeen/orbit` 单包） |
| checker home | `/tmp/orbit-real-checker`（sdk 模板 + 只读 overlay） |
| 模型 | `deepseek-account/deepseek-flash`（Root 与 checker 相同路由） |
| 凭据 | 将 `~/.dsh/.credentials.yaml` 只读复制到两个隔离 home（0600），验收后删除副本；原文件未修改 |
| 检查者 | `dsh-sdk` 子进程，独立 profile/home，只读 sandbox，读固定快照 |
| 驱动 | `tests/host_conformance/orbit-real-probe/index.js`，创建 standard preset Root，按脚本提示驱动工具 |

## 实际结果

- Root（真实模型）调用 `orbit start`、`declare`，用 write 工具写出 `hello.txt`（5 字节 `hello`），调用 `orbit check`。
- 检查者（真实模型、独立子进程）读取固定快照 `snapshots/check-1-*`，返回 `verdict=complete`、`delivery.ready=true`、`coverage.complete=true`、无 finding；摘要记录 hello.txt 的 5 字节与 SHA-256。
- Root 随后派发并登记了一个成员，`finish` 后 `accept`，再 `orbit complete`。
- 终止状态：`complete`；`completion.checkNumber=1`、`artifactDigest` 与检查快照一致；`stop/confirmed` 的四项证据均为 true；成员 `completed`。
- 事件链：`task/created → work-unit/declared → check/requested → finalization/notice → check/completed → member/registered → member/settled → work-unit/finished → work-unit/accepted → completion/requested → stop/confirmed → task/completed`。

## 证明与边界

证明：真实 Root 能驱动受控任务；检查者在独立进程/独立 home/只读快照上用真实模型完成结构化判定；完成门与实际停止证据可闭合；单包 bundle 在隔离 profile 中运行。

未证明：真实检查发现缺陷后的纠正回合（冻结验收 #1）、真实停止中断场景（#2）、多任务并发/重启、校准后的 JEV 选型、Loom 整链、发布安装路径。凭据复制方式只用于本地验收，不作为生产凭据方案。

证据目录保留在 `/tmp/orbit-real`（任务记录、快照、归档、驱动日志），未提交仓库。
