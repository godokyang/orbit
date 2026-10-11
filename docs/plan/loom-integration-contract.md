# Loom 集成合同实施（总 TODO）

状态：2026-10-11 用户经协作会话转交并授权实现下述四项（范围见下）；升版、提交、推送、发布、打 tag、更新日常安装**未授权**。决定与理由见 [ADR-010](../adr/010-integration-contract.md)，合同见 [integration.md](../../contracts/integration.md)。

## 目标

让集成方（首个是 Loom）依赖 Orbit 声明的合同而不是内部结构：独立合同版本、按能力判断可用、检查项与任务的通用互引、发布前契约测试。全部向后兼容；Orbit 不引入集成方的业务概念，也不依赖它。

## 非目标

- `needs_user` 终态接续（只给看法，见限制清单）。
- 自动入口建立任务时的外部引用；Loom 侧 CI；真实会话/真实模型验收；升版、提交、推送。

## 已实现与验证

| 项 | 状态 |
| --- | --- |
| 集成合同 `contracts/integration.md/.json`，版本 1.0，已加入 `package.json` files | 完成 |
| `orbit capabilities [--json]`，读 integration.json，不连会话 | 完成；安装测试断言打包版可用 |
| 覆盖项可选 `ref`：schema、Ruby/TS 校验、覆盖存储（写死的字段检查已同步）、检查者提示、共享样例 | 完成；既有校验与覆盖测试通过 |
| `start --external-ref`（及扩展 `external_refs` 参数）、`state.external_refs`、status/export 原样输出 | 完成 |
| 契约测试 `tests/integration_contract_test.rb`，已入 `npm test`（3 个测试函数） | 完成；变异检查（丢弃 `ref`）能使其失败 |

## 边界与限制

- 契约测试的 OMP 会话与检查模型是替身，只证明合同面与字段形状；`ref` 在真实检查者上的抄录行为未实测。
- 全套 `npm test` 在 `tests/prestart_test.rb` 处有环境相关失败，在未改动的 HEAD 副本上同样复现，与本改动无关；其余步骤独立运行结果见交接。
- 测试规模：新增 3 个测试函数，测试文件约 240 行，另有安装测试 3 行；共享校验夹具增加 5 条样例（展开约 200 行 JSON 数据，只验证 Ruby/TS 两个校验器对新字段的一致性）。代码行数在建议内，加上夹具数据后合计超过“≤300 行”的建议；必要性：契约测试是本任务明确要求的交付，样例是新字段在两种语言校验器间唯一的一致性防线，已有测试不覆盖该字段。
