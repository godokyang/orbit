# 报告与证据格式示例

本文不是任务规则，不进 `--rule`，也不拥有 schema。权威仍是 v2 `EvidenceRecord` / `GateEvaluation` / `TaskRevision.quality_outcome`。下面是从旧角色文件降级下来的提交格式与自检表：v2 输入模板尚未替换 `.v1-deprecated` 那批，所以先留作人读示例，不是合同。

不要把这里的字段名、命令或 verdict 枚举当成现行产品面。`user_journeys`、`test-hook`、`orbit artifact inspect`、`test_level` 作为 verdict、`orbit new-task` 在 v2 合同与 CLI 里都解析不到。

## Quality outcome 字段形状

```yaml
quality_outcome:
  user_problem: "当前系统给维护者、用户或运营流程造成的真实问题。"
  desired_property: "改完后系统应具备的质量属性。"
  measurable_thresholds:
    - "能用测试、指标、代码结构、用户流程或 artifact 证据判断是否达成。"
    - "至少包含一个结果阈值，而不只是动作完成。"
  invalid_completions:
    - "只完成表面动作，但用户问题或维护问题仍然存在。"
    - "只证明没有破坏旧行为，不能证明质量属性改善。"
```

阈值不必是数字，但 reviewer 必须能判断「变好」而不是「做了」。字段集合以 `TaskRevision.quality_outcome` 为准。

## Implementation check 人读骨架

v2 必填面是 `implementation_check` 的 `changed_paths` / `verification_refs` / `scope_match` / `acceptance_results` / `known_gaps`。下面只帮助对照，不要手写平行清单。

```yaml
coding_evidence:
  status: pass | fail | partial
  changed_files:
    - path/to/file
  scope_match:
    summary: "为什么这些改动属于当前 task。"
  verification:
    - command: "..."
      result: pass | fail | not_run
      evidence: "输出摘要或 artifact 路径。"
  closure:
    old_paths_closed:
      - "旧入口或旧 fallback 如何处理。"
    ssot:
      - "当前权威 writer / reader / schema。"
  known_gaps:
    - "仍未覆盖但不阻塞当前 task 的风险。"
```

## Test evidence 人读骨架

v2 `EvidenceRecord` 没有 tester 四分类 verdict。污染或前提不成立时，不要提交能关 gate 的 evaluation。

测试 evidence 至少让复查者看到：环境与版本、命令或操作步骤、输入或用户路径、真实输出路径、覆盖了哪些 acceptance / failure modes、未覆盖路径和原因。失败 run 不能被后一次成功覆盖。

```yaml
kind: test
summary: "本轮测试结论。"
coverage:
  - "覆盖的用户路径、风险路径或 acceptance。"
artifacts:
  - "命令输出、截图、日志或 artifact。"
```

下面这些名字是格式史料，不是 v2 合同字段：`user_journeys`、`test-hook`、`test_level` 当作 verdict、`orbit artifact inspect`、`blocked` 当作独立 verdict。现行提交是 `orbit v2 evidence submit --task ID --proposal FILE`。

## 编码自检问题

只有当它们影响当前 task 的可维护性、可验证性或质量结果时，才写进 evidence 或 residual risk。

| 风险 | 要问 |
| --- | --- |
| Cognitive overload | 新增函数、分支、参数、命名是否让维护者必须读完整实现才能理解。 |
| Change propagation | 一个需求是否迫使无关模块一起改；是否说明了依赖方向。 |
| Knowledge duplication | 同一业务决策是否在多个地方重复表达。 |
| Accidental complexity | 新 abstraction、配置、扩展点是否服务当前真实需求。 |
| Dependency disorder | 高层策略是否依赖低层细节，是否引入循环或不稳定依赖。 |
| Domain distortion | 命名和边界是否符合项目领域语言，而不是技术临时名。 |

## 测试质量自检问题

不按覆盖率数字机械判断。只有当它们影响当前 task 的测试可信度时，才写进 evidence 或 finding。

| 风险 | 要问 |
| --- | --- |
| Test obscurity | 测试名称、步骤和断言是否能说明测试了什么行为。 |
| Test brittleness | 测试是否依赖实现细节，而不是可观察行为。 |
| Mock abuse | mock 是否多到测试只验证 mock wiring。 |
| Test duplication | 多层测试是否重复同一断言，而不是覆盖不同风险。 |
| Coverage illusion | 是否只覆盖 happy path、行覆盖或返回值。 |
| Architecture mismatch | 测试层级是否匹配风险。 |
