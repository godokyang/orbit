## 窄复核结果：两项均通过，无误放/误判

**1. CLI declare 错位字段（cli.rb:633-637 + cli_test.rb）— 通过**
- 仅 `declare` 操作、仅 `model_requirements`/`execution` 两个精确键，在 `WorkUnitStore` 任何写入之前抛修复错误（642 行证实 declare 只取 `payload["spec"]`，顶层两键此前确实被静默丢弃）。
- 无误判合法调用：顶层携带这两键的 payload 从来无效，唯一行为变化是静默忽略→明确修复；报错文案指明正确位置（spec 内）。
- 无权限影响；测试断言拒绝后 `work-units.json` 不存在——无副作用取证到位。
- 边界（非阻断）：其他未知顶层键/拼写错误仍静默忽略，本变更刻意不覆盖，符合窄修范围。

**2. node→npm-cli.js 包根诊断（work-unit-scope.mjs:481-491 + scope 测试）— 通过**
- 只新增阻断条件，永不放行；静态 stat/access/realpath/2 字节读，无执行副作用，不开外部读取。✓
- 不误判核实逐条：
  - `/usr`、`/opt` 下的 npm 全局安装：`sandboxCanRead` 含 `SANDBOX_READ_ROOTS`，packageRoot 在其内 → 放行，与沙箱 profile 实际授予一致，无误阻断。
  - `.runtime` 完整包（含 package.json/lib/node_modules）→ 放行；仅声明入口文件 → 阻断并指明 "including package.json, lib and node_modules"。两侧测试均取证。
  - `node <flag> …/npm-cli.js`（flags 占 words[1]）→ 不匹配，保持 unknown，不误阻断——与"解释器参数仍 unknown"声明一致。
  - `node missing.js` 的 realpath ENOENT 向上抛 → fail-closed 阻断，行为正确（执行同样失败）。
  - `.runtime` 内 symlink 回指外部：realpath 后判定外部路径 → 阻断，防 symlink 绕行。
- 残留未知（照实列，不阻断交付）：`npx` 入口为 `npx-cli.js`，不命中本诊断（仅靠 shebang 规则覆盖外部位置；`.runtime` 内 npx 的包依赖未诊断，执行时内核强制、成员见真实错误，非静默错判）。
- 测试含真实内核执行正例（相对脚本经实际 cwd 解析执行成功、裸二进制执行 exit 0）与无副作用断言（`npm-ran` 不存在），方向完整。

**结论**：两项窄修均通过；无具体阻断。残留 unknown 已如实限定，本次 Orbit 窄适配不声称等价 Codex ToolOrchestrator 准入。