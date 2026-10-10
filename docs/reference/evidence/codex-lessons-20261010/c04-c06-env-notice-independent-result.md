## 窄复核结论：两项均通过

**1. `bareCommandWords` 字面赋值剥离（work-unit-scope.mjs:416-425）— 通过，无误判/无权变**
- 白名单仅 `TMPDIR`/`NPM_CONFIG_CACHE`，值字符集 `[A-Za-z0-9_./:-]+`：引号、空格、`$`、`~`、glob、空值、`PATH=` 全部不命中 → 落入既有 SHELL_SYNTAX → unknown。bash 对该字符集赋值不做 tilde/glob 扩展，与 probe 解析无分歧。
- 授权不变：`allowed_commands` 精确匹配仍对**原始** command 字符串（剥离只影响诊断 probe，validateMemberTool 500 行在前），不扩可执行集合。
- npm 包根核对层正确：482 行复用 `bareCommandWords`，`TMPDIR=.test-tmp node <相对npm-cli>` 在实际成员调用（execCwd=root）解析并判定；声明期相对路径仍 return unknown。测试 192/194 行把包根正/负断言放在成员调用层——与"声明期不认证"语义一致，未弱化。
- 多赋值连续剥离（`TMPDIR=x NPM_CONFIG_CACHE=y npm test`）正确；cache 目录本身不探测，注释保持"caches unproved"，内核执行时强制——未冒充已证。

**2. facts_only 空指标 notice（host.mjs:187-188）— 通过，无伪造推荐**
- 条件双门：`decision === 'facts_only'` 且实际声明的 `result.unit.model_requirements.relevant_indices` 为空——读的是 declare 真实落账单元，非推断。非空指标下的 facts_only（事实不足）不触发，不误指。
- 只加 `notice` 字段：selection/分数/阈值/模型不动；文案明示"当前没有适配推荐""不要把 facts_only 当推荐"，方向是防伪造而非制造推荐；"新声明的 spec"措辞与 work-unit 不可变语义一致。
- 未分类保持未知+说明自选依据的出路保留，不强制填指标。

无阻断，无越权，两改动的 unknown 边界声明与代码实际一致。