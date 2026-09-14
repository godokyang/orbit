---
description: Use when changing a CLI, installer, uninstall/cleanup, migration, package, release asset, or other command that mutates user state.
---

# 可变命令表面

**所有权边界**：本文只拥有「本次改动触及的命令／安装／发布表面有没有被真实路径证明」。库测试取舍归 `test-selection`。停下与交接见 [共用职责](../shared/escalation-payload.md)。

本文是判断依据，不是可以机械勾选的清单。复核只报告不修改。不要把一次局部修改扩成完整发布或恢复验收。

## 判据

- 改的是会改用户状态的命令（CLI、installer、uninstall、cleanup、migration、package wrapper）时，只跑了库测试吗？是 → 不能标完整通过。库测试不证明命令可用。
- 本次实际改动的 help/version、flag、exit code、非交互路径或安装后真实命令，有没有被跑过或明确标为未验证？都没有 → 不能标完成。
- mutating 命令有没有 dry-run 或确认、回滚、idempotency、partial-failure 说明？没有且本次危险路径无法补 → 记剩余风险，不包装成已验证。
- 只验证本次触及的表面与真实风险层。未改的发布／registry／远程状态层不要默认列入必过矩阵。
- 发布、卸载或删除用户数据，若已在当前授权内 → 不重复确认；尚未授权才交用户。

## 反向约束

| 看起来像没验表面 | 为什么放行 |
| --- | --- |
| 本次只改库内纯函数，不碰入口 / 包装 / 安装 | 不在本文触发面 |
| 项目流程已有安装后套件且本轮跑过 | 真实表面已被覆盖 |
| 本次未改 checksum / registry / appcast | 不是本任务的发布验收 |

## 降级路径

- 某一项本次触及的表面无法在本环境验证 → 写剩余风险，不包装成已验证；需要人接受该风险且当前授权未覆盖时才升格。
- uninstall 删除内容可本地重建 → 放行；删的是用户数据且当前授权未覆盖 → 交用户。

## 规则内优先级

先证明本次改动的安装后真实命令和危险路径，再谈文案。一层缺失就记一层，不拿源码绿替代，也不补跑无关发布矩阵。

## 升格条件

只有当本次触及的真实命令表面无法在本环境验证、且当前授权未覆盖该剩余风险时，才算边界。只跑库测试就标 CLI / release 完成，不是边界。
