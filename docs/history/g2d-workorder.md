# G.2d 工单：`orbit v2 rules update`

> **历史记录（2026-08-17 归档）**：已完成。裁决在 [`../plan/vision-completion-plan.md`](../plan/vision-completion-plan.md)。

- 日期：2026-08-17
- 基线 HEAD：`682c38c`
- 执行：grok（wA:pG）
- 性质：**派发文件，不拥有裁决。** 裁决在 [`vision-completion-plan.md`](./vision-completion-plan.md) D1–D11；切分与更新策略在 [`g1-rule-library-design.md`](./g1-rule-library-design.md) Q5。冲突以计划为准。

## 范围

实现 `orbit v2 rules update`，按设计稿 Q5：

| 工作区文件 vs `.orbit-source.yaml` 里上次装入的 sha256 | 动作 |
| --- | --- |
| 相等（项目没改过） | 用新母版覆盖，更新 manifest。git diff 就是升级评审面 |
| 不相等（项目改过） | **跳过覆盖**。另写 `rules/<name>.md.upstream`，命令结束时打印跳过清单 |
| 项目没有该文件 | 按新母版创建 |
| 项目多出来的、manifest 没有的文件 | 不动 |

约束：

- 不在活规则里插冲突标记。合并由人用 git 做，合并结果再进下一次 dispatch。
- 只拷文件、写 manifest，不改已钉死 attempt 的 digest。
- 参考层同样按上述规则更新 `docs/orbit/reference/`。
- `AGENTS.md` 本命令不创建、不覆盖（那是 `init` 的事，且目标已存在则永不覆盖）。

## 必须证明的两件事

1. **未改过的文件被覆盖**：改母版一个字节，项目文件仍等于上次装入 sha256 → update 覆盖它，`.orbit-source.yaml` 更新，新 digest 等于新母版。
2. **改过的文件被跳过**：项目文件与上次装入 sha256 不等 → 活文件字节不变，写出 `.upstream`，stderr / stdout 列出跳过项。已存在的 attempt 的 `content_sha256` 不变。

## 不做

- 按 `description` 做机器选择。
- 用户项目 `AGENTS.md` 模板（Q6）——另派。
- 退役 ADR-004 里的角色映射——另派修订记录。
- 不宣称阶段 G 完成。

## 约束

- 不放宽 `canonicalize_path!`。
- 不改本仓库根 `AGENTS.md`。
- 测试预算：≤2 个方法、≤150 行。
- CPU 纪律：单方法迭代用 `ORBIT_V2_ONLY`；focused 全量最多 2 次。
- 否定断言用 `include?` 不用 `start_with?`。
- `install.sh` 若新增文件，同步列入 `runtime_files`（G.2c 刚栽过）。

## 停止条件

- 更新策略做不到「改过就跳过、未改过才覆盖」而不削弱 pin。
- 发现 Q5 或 D11 有误。
