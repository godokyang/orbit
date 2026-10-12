# 私有检查工具参数修正（2026-10-12）

ORBIT-REVIEWER-TOOLS-07 只读核查发现：0.8.9 的 `createConfinedTools` 将三个 Zod 对象直接交给 OMP 18.9.0，后者将非 ArkType 对象按普通 JSON Schema 处理，未生成 `properties/required`；请求意图注入后仅有 `i`。原 check1 的 12 次调用均仅含 `i`，对应 read 读根目录、grep 匹配全部行、glob 缺 pattern 报错。原件没有 HTTP 请求抓包，不补造供应商网络事实，也不追改原检查结果。

## 08 改动

- 三工具保留原字段与必填规则，用现有 Zod 的 `z.toJSONSchema` 生成 SDK 参数声明。
- `execute` 首先使用同一 Zod 定义解析参数；缺 `read.path` 或 `grep/glob.pattern` 即拒绝。Zod 默认剥离未知键，直接调用携带合法 `i` 不会误拒；OMP 原生路径仍按其惯例先剥离意图元数据再校验工具参数。
- 路径隔离、符号链接检查、文件/图片读取及 grep/glob 执行保持原规则。显式目录读取和空字符串的原有语义不变。
- 既有安装能力探针在 `host_probe` 分支增加实际 SDK 的 `toolWireSchema` 与 `validateToolArguments` 检查：所有字段存在、必填保留、合法参数保留、缺必填拒绝。仅探针产生 `tool_schemas` 内部证据，不改变集成合同或真实检查提示。

## 验证与边界

新增一组工具回归覆盖声明、缺必填及合法 intent；现有文本行/图片行为测试复用。隔离副本使用正式安装所锁定的 Zod 4.6.5，六文件 reviewer 套件 39 pass / 0 fail，既有 `confine-escape-test.ts` 通过绝对路径、相对越界、home/URL/内部 URI/符号链接拒绝及正常读取。

实际安装 OMP 18.9.0 通过现有 `OmpCheckRunner.run_probe` 驱动候选 reviewer（无模型参数、无 prompt）：三工具 schema/validator 通过，`problems=[]`、`session_disposed=true`、`host_completion=complete`，父进程按既有协议收尾退出 143。这是零模型宿主验证，不是真实模型检查认证。相关 Ruby runner 回归结果见证据。

首次在原工作区运行工具测试遇到未跟踪的旧 `runners/omp-reviewer/node_modules`：它解析的 Zod 不提供 `toJSONSchema`。保留该目录，改在隔离副本使用锁定正式依赖验证；没有修改全局依赖或增加旧 Zod 兼容层。

07 原件：Loom `.loom/local/evidence/orbit-rpc-ui-questions-completion/during-final-review-export.tar.gz`。07 诊断目录：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-reviewer-tools-07-0wa7qbw6`。

08 测试及审阅原件：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-reviewer-tools-08-8v5id2y_`，包含 `reviewer-tests.log`、`escape-tests.log`、`runner-tests.log`、`host-probe-result.json`、`sdk-host/evidence.json`、最终 diff/源码哈希。隔离 fixture 与探针资源归本席，验证后只保留可复核材料。

Root 已复核最终 diff、五文件 manifest、真实 SDK 零模型证据及测试，并确认三份 TS 源码与验证副本逐字节一致，现已触发用户持续有效的提交、正常推送 main 与本机 update 授权。按 patch 规范升至 0.8.10，合同仍为 1.4；提交及安装身份以 Git、公开 version 和上述证据目录的 `release/` 回执为准。不新增模型、不修改 Loom 或旧 task，不将完成或停止语义作为本票改动；此次发布不等于新构建真实模型验证。
