# Orbit 当前交接

最后核对：2026-10-01。**当前源码 0.8.0（commit `3865b76`，已推送）**；混合模型交付 Goal 已完成，无当前产品实现待办。

## 版本事实（区分记录）

- **源码**：0.8.0／`3865b76`——仅版本号提升（0.7.37→0.8.0），未新增实机验收；full 与 0.7.37 实机样本以 `4cc957e` 冻结（full 197.31956s exit 0／83 pack 逐字一致）；其他真实验收样本按完成记录各自构建身份（pair4＝0.7.25、033＝0.7.33 等）。
- **本机安装**：0.7.37（doc-only source commit `b705344`／digest `49cf34bc…`／release `5828b3c1…`）。文档清理不构成升级安装；下次 `orbit update` 才落 0.8.0。

## 收口依据

- 原混合模型交付目标（54 项＋W1–W10）逐项判定、证据与边界＝[完成记录](../reference/mixed-model-delivery-completion-20261001.md)；Root 最终审计＝`/private/tmp/orbit-stop-guard-037/ROOT-54-FINAL-COMPLETION-AUDIT.json`。
- 运行代码基线的真实验收：pair4 自主成员完整链、033 强检查发现→纠正→resolved→停、35 失败原件（不改判）、regress37 过程换型＋合法阻断 confirmed stop、W9 同质量配对（旗舰 observed 0 vs 7）、单文件负例真实 entry 不启动。原件均在 `/private/tmp/orbit-*` 各目录。

## 当前有效限制

见[当前限制](debt-ledger.md)：未测自然分支（Root-stage switch live、非 stale process finding 恢复、stop marker 精确复现、failed-unit 释放）、平台未知（park/dispose、devin hooks）、现金/扣减 unknown——均非完工门，随未来普通运行自然累积。

## 现场与操作约定

- 开发沿 [AGENTS.md](../../AGENTS.md) 与[开发流程](../agents/development-workflow.md)；文档/合同语义改动须同步权威文件。
- 本地 commit 可；推送/发布/tag/SDK 升级/购买额度按用户当次明确授权执行。
- 历史版本流水、失败与中间状态不在本页复制：`git show 3865b76:PATH` 查阅。
