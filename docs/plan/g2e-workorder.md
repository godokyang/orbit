# G.2e 工单：用户项目 AGENTS.md 模板（Q6）

- 日期：2026-08-17
- 基线 HEAD：`b07780f`
- 执行：grok（wA:pG）
- 性质：**派发文件，不拥有裁决。** 规格在 [`g1-rule-library-design.md`](./g1-rule-library-design.md) Q6；裁决在 [`vision-completion-plan.md`](./vision-completion-plan.md) D5 / D7。冲突以计划为准。

## 范围

做常驻层，对象是**用户项目**的 `AGENTS.md`，不是本仓库根 `AGENTS.md`。

1. 母版：`skills/orbit/assets/rule-library/resident/AGENTS.md.template`
2. `orbit v2 init`：目标不存在才从模板创建；已存在则打印「请把路由器表附到现有 AGENTS.md」，**绝不覆盖**。
3. `orbit v2 rules update` **不碰** `AGENTS.md`（G.2d 已如此，保持）。

模板正文按 Q6「放什么 / 不放什么」。路由器表用设计稿已写好的那张（触发 → `rules/*.md` 路径），不抄任何任务规则判据。目标 80–120 行，硬上限 150。

占位（项目是做什么的、安装/测试命令）用明显可替换的标记，不要填 Orbit 本仓的内容。

## 必须证明的两件事

1. 空项目 `init` 后存在 `AGENTS.md`，且含路由器表里的八条路径，不含任何任务规则的判据正文（例如「删掉这处改动」）。
2. 已有 `AGENTS.md` 时 `init` 不改它的字节，stderr 提示附路由器表。

## 不做

- 改本仓库根 `AGENTS.md`。
- 按 `description` 机器选规则。
- ADR-004 修订记录。
- 阶段 H。
- 不宣称阶段 G 完成——本工单只收 Q6。

## 约束

- 不放宽路径契约。模板不是 `--rule` 目标，不要拷进 `rules/`。
- 新文件列入 `install.sh` 的 `runtime_files`（G.2c 栽过）。
- MANIFEST 若要记 resident，`layer: resident`，`default: false`，不进 dispatch 钉入。
- 测试预算：≤2 个方法、≤80 行。
- CPU 纪律：单方法迭代 `ORBIT_V2_ONLY`；focused 最多 2 次。
- 否定断言用 `include?`。

## 停止条件

- 模板写着写着开始抄规则正文。
- 发现必须改本仓库根 `AGENTS.md` 才能交差。
