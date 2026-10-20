# D 阶段退场清单（待授权）

目标：新安装只依赖 DSH 与单一 npm 包 `@zeen/orbit`；仓库不再保留 Ruby/OMP 执行代码；`orbit doctor` 与 README 与现实一致。每个删除步骤需用户单独授权。

## 1. Orbit 仓库

| 项 | 动作 | 风险/前置 |
| --- | --- | --- |
| `contracts/host-omp.md` | 删除，新增 `contracts/host-dsh.md` | 需确认没有外部链接依赖旧路径 |
| Ruby 执行代码与 `runners/omp-reviewer` | 删除 | 先确认旧 OMP 任务已停止、无未归档记录 |
| `install.sh` 中 Ruby/OMP 探测与安装分支 | 删除/改写为 `orbit install` | 需要新安装脚本通过干净环境验证 |
| OMP 专用测试与 fixtures | 删除 | 先跑完整 DSH 测试替代覆盖 |
| `packages/*` 中 @orbit 私有包 | 保留为构建期 devDependencies；发布包已不依赖 | 确认 `pnpm pack` 内容 |
| `private: true`、`version: 0.0.0` | 改为发布版本并去掉 private | **需版本号与发布授权** |
| README/使用参考 | 已改写为 DSH；发布后补 npm 安装命令 | 发布前不要声称 npm 可用 |

## 2. Loom 仓库（工作树 `feat/dsh-migration`）

| 项 | 动作 | 风险/前置 |
| --- | --- | --- |
| `services/node/src/loom_node/orbit/session.py` | 删除（运行时已无 import） | 先删除 `tests/test_ask_dialog.py` 等 OMP 专用测试 |
| `services/node/src/loom_node/orbit/probe.py` | 删除或改写为 2.0 零模型探针 | 确认无脚本入口引用 |
| `tests/test_ask_dialog.py` | 删除/改写 | 覆盖由 DSH 会话投影测试替代 |
| `CONTRACT-CHECK.md` 1.x 描述 | 已改为 2.0 | 保持 |
| `docs/execution.md` 节点依赖章节 | 改为 DSH/2.0 | 需 Loom 文档评审 |

## 3. 切换顺序建议

1. 停止并归档所有旧 OMP 任务；确认 `stop_confirmation.confirmed=true`。
2. 在干净 `DSH_HOME` 用 `orbit install` 安装 2.0 profile，跑 `orbit doctor --t0`。
3. 新任务只由 DSH 核心创建；旧记录只读保留。
4. 验证 discovery、执行 run、停止、续接、重启游标。
5. 再删除旧代码与安装分支；发布版本与 npm 另取授权。

## 4. 需要用户确认

- 版本号（例如 `0.1.0`）与是否发布 `@zeen/orbit`。
- 是否授权删除上表代码与测试。
- Loom 分支推送与合并方式。
