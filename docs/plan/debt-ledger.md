# Orbit 当前未完成事项

本页只列阶段一之后仍未解决的事项。产品规则以[任务运行合同](../../contracts/task-runtime.md)和 ADR 为准；阶段二任务见[唯一总待办](agent-autonomy-implementation.md#阶段二loom-协同清单等待用户通知)。

| 事项 | 当前事实 | 收口条件 |
| --- | --- | --- |
| EXP-11 的检查者漏判 | 检查者曾读完标准，却未读取可访问的页面材料并误报完成。开放相关任务记录只解决材料入口，不证明检查者会自主取证或正确判断。 | 在真实检查中核对要求、实际读取材料和逐项结论；不把程序提供入口当作问题已解决。 |
| Loom 阶段二尚未执行 | Orbit 阶段一接口已更新；Loom 尚未据此修改或验证。本次不修改 Loom。 | 等用户另行通知后，按总待办核对 Loom 当前工作树、适配需求与验证范围。 |
| 真实运行验收未收口 | 已完成的真实运行与仍待验证路径见下方记录。 | 用新鲜隔离任务完成正向成员交付、Root 集成、真实测试、独立终检及正常停止；另完成工作区 rebind 的旧检查 stale/新根取证验证。上述路径完成前不宣称真实验收通过。 |

## 真实运行记录（2026-10-16）

- 安装构建：Orbit 0.8.11，源码 `b1920b078ea8302a56d288e10385f4955bb21cae`，dirty=false，digest `8f6d6be2ed320850a932981ff2090f2e737890a7b45a65d5c05e996b5dddda2a`，安装时间 `2026-10-16T01:08:20Z`；OMP 18.9.0。安装检查确认 single-host 入口，plain `omp` 不加载 Orbit。
- 负例：任务 `57453c7d-d10d-4a47-a518-a18a02c05990`，项目及证据目录 `/private/tmp/orbit-live-acceptance-U3iIkR/negative`，开始 `01:11:14Z`，最终 `complete`，停止确认通过。产物 digest `542d7b39b0ad3f1556938d8b00488d47134f1079c5372f721c3a670395e30f9f`，输入 digest `117cae66ca58fcb7f25540483d520097b3742fd19760f38de607b39ab3cbc8a0`。独立 OMP checker 在固定快照于 `01:11:42Z` 检查，结果 `complete`、无发现；Root 运行 `sh scripts/check-readme.sh`，退出码 0。限制：初始用户消息因控制台转义丢失了命令文本；Root 识别空命令后改用仓库脚本，未假称按原命令验证。JEV `typesafe/jev-1.13.0`，observation-2：1530 输入、55 输出 tokens，分数 stuck 0.18 / off_track 0.74 / artifact_ready 0.24。检查记录中的 3 次 `opencode-go/deepseek-v4.1-flash` 调用合计 13,247 input、2,181 output、28,544 cache-read、800 reasoning tokens；Root 调用成本及 checker/Root 分拆费用未知。
- 正例：任务 `36545ecf-4628-48f8-b7a6-61cd73b46eea`，项目及证据目录 `/private/tmp/orbit-live-acceptance-U3iIkR/positive`，开始 `01:14:48Z`。真实收到并跟随版本绑定的 task-fit hint，创建 bounded work unit，并于 `01:18:42Z` 注册 `kimi-code/k3-256k` 原生成员。成员 bash 调用被 work-unit allowed command 列表拒绝；Root 未收集到交付或 `hub` 结果，未集成、未运行 `node --test`、未请求终检。于 `01:24:39Z` 用户中断；Root 和成员停止均确认，活动工具为 0、异步任务已结清。终态前最近一次 JEV `jev-1.13.0` 记录于 `01:22:39Z`，分数 stuck 0.27 / off_track 0.20 / artifact_ready 0.24（1970 input、55 output tokens）。这不是正例通过证据。
- 未运行：新鲜成功正例的成员交付/`hub` 收集/Root 集成/`node --test`/独立终检/正常退出；workspace rebind 的旧检查 stale 与新根检查。负例只能证明有界单文件修改、独立检查与已确认停止。两个隔离任务仍保存在 `/private/tmp/orbit-live-acceptance-U3iIkR-*` 供复核；本记录不把模型调用费用推算成金额。
