## 窄复核结论：通过

**`workUnitOperationError`（native-task-preflight.mjs:19-24）逻辑穷举核实：**

| 调用形态 | 结果 | 判定 |
|---|---|---|
| action≠work-unit | null 放行 | ✓ 不扰其他 action |
| `work_unit.operation` 嵌套存在 | 拒绝 | ✓ 正是 V4 事故形态（finish/read 被吞为 declare） |
| 顶层 operation 缺省/'declare' + `work_unit.id` | 拒绝 | ✓ 堵住"finish 忘顶层 operation→默认 declare 空单元"真实缺口；declare 自带 id 本无意义，非误判合法调用 |
| 缺省 operation + 无 id（合法 spec declare） | null 放行 | ✓ 保留合法省略 |
| 顶层 finish/read/list/select + id | null 放行 | ✓ 合法路径不受影响 |
| 无 work_unit（如 list） | null 放行 | ✓ |

纯函数只读 args，无状态/权限/选型改变；报错给出顶层 finish/read 具体示例与 declare spec 形态，"Repair the call rather than supplying a new spec to a finish" 直指事故语义。

**调用顺序：**
- host.execute:103-104 —— 在 `bind()`/`listen()`/任何 CLI run 之前抛出；execute 抛错即工具失败回执，不会落 CLI declare。
- native.execute:4163-4164 —— 在 declare 预检（4166-4178，避免误导性 preflight 先于真错误）和 host.execute（4184/4187）之前；host 层同函数复验幂等，无顺序冲突。root-model 分支经 host 时 helper 首行即 null，无干扰。
- 无任何现存合法调用方读嵌套 `work_unit.operation`（host 用顶层 `a.operation`，176 行），拒绝不破坏既有路径。

**通过边界（照实）：** 缺省 declare + 完全空 `work_unit`（无 id 无 spec）仍放行——既有可能性、非本变更引入；绑定任务下由 native 层 validateWorkUnitPreflight（无 tools/commands 即拒绝）承接。在途旧构建（a201/V4 已完成的推荐→执行→finish 链）不重标本修复，正确。