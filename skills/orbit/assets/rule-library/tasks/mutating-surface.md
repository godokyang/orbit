---
description: Use when changing a CLI, installer, uninstall/cleanup, migration, package, release asset, or other command that mutates user state.
---

# 可变命令表面

**所有权边界**：本文只拥有「命令 / 安装 / 发布表面有没有被真实路径证明」的判定。库测试取舍归 `test-selection`。产品 gate 分层由 GateEvaluation 拥有。

本文是判断依据，不是可以机械勾选的清单。复核任务只报告不修改。

## 判据

- 改的是会改用户状态的命令（CLI、installer、uninstall、cleanup、migration、package wrapper）时，只跑了库测试吗？是 → 不能标完整通过。
- help/version、flag、exit code、非交互路径、安装后真实命令，有没有被跑过或明确标为未验证？都没有 → 不能标完成。
- mutating 命令有没有 dry-run 或确认、回滚、idempotency、partial-failure 说明？没有且无法补 → `partial` / blocked。
- 发布 / 打包 / checksum / registry 相关改动，源码测试通过能否当作 release-ready？不能。缺的层是 explicit gap。

## 反向约束

| 看起来像没验表面 | 为什么放行 | 备注 |
| --- | --- | --- |
| 本次只改库内纯函数，不碰入口 / 包装 / 安装 | 不在本文触发面 | |
| 项目流程已有安装后套件且本轮跑过 | 真实表面已被覆盖 | |

## 降级路径

- 某一项表面无法在本环境验证（无安装权、无 registry）→ 升格缺口，写 residual risk，不包装成已验证。
- uninstall 删除内容可本地重建 → 放行；删的是用户数据或只能重新下载的依赖 → 阻塞。

## 规则内优先级

先证明安装后真实命令和危险路径，再谈文案和 checksum。一层缺失就记一层，不拿源码绿替代。

## 升格条件

只有当真实命令表面无法在本环境验证、需要人接受 residual risk 时，才算边界。只跑库测试就标 CLI / release 完成，不是边界。

停下时交什么：见本次 attempt 已钉的 `rules/escalation-payload.md`，不要在本文件复写格式。

## 发布分层

release-ready 必须分层说明：source、CI、generated artifact、package/archive、version fields、release assets、registry/appcast、remote state、runtime smoke。缺失层写明，不是 pass。
