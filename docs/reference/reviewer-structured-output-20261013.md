# 私有检查者的原生结构化提交

ORBIT-REVIEW-OUTPUT-10 已经 Loom Root 复核，按持续授权进入 0.8.11 发布收尾；集成合同仍为 1.4。提交、远端与本机安装身份以本票 release 回执及公开 version 为准。

## 接口与接纳

私有 reviewer/adjudicator 使用 OMP `createAgentSession({ outputSchema, outputSchemaMode: "strict", requireYieldTool: true })`，检查者通过原生 `yield({ data: <完整七字段报告> })` 提交。声明来自 `contracts/check-result.schema.json`，当前检查明确要求包括逐要求 coverage 的七字段；历史 schema 读取及业务完成门不变。

程序从公开 `tool_execution_end.result.details` 收集原生 yield 结果，调用 OMP 公开导出的 `finalizeSubprocessOutput`，显式传入 strict 模式，再对 `structuredOutput.data` 运行原 `validateCheckResult`。SDK `src/index.ts` 导出 `task/executor`；终结器处理原生结果组装、表示规范化、schema 校验及 `schemaOverridden` 拒收。仅传 createAgentSession 的 strict 选项不替代这次实际终结调用。

本票请求一次完整报告。原生工具声明、strict 属性、execute 和会话终止处理全部保留。Orbit 不维护第二份提交成功状态、不扫描 toolCall/toolResult 来构造成功回执。最后一次 yield 错误传为终结失败，不能沿用较早结果；缺 yield、原生 aborted/invalid/unavailable、非零终结或业务校验失败均拒收。终结器的 rawOutput 固定为空且不传 lastAssistantText，末尾文字不能补成提交。

OMP 的通用参数校验会删除额外字段或转换字段类型。为防止这些修复掩盖坏报告，在现有 `agent.beforeToolCall` 接缝用**同一原生严格终结器**校验原始完整 data，再运行 Orbit 业务校验；有错返回工具错误，供模型修正。可选字段的 provider null→省略按 SDK 正常表示处理，未知字段、拼写错误、findings 对象、必填 null 和数字字符串仍拒收。该接缝保留原 beforeToolCall 链，不换写权限、不扩大模型授权。

`evidence.raw_text` 保留末尾 assistant 文本。私有 `structured_submission` 保存公开 yield 参数原件、原生工具结束事件与实际 strict 终结结果；有效七字段报告继续写入既有 result。原参数指 SDK 解析后的公开 tool-call 对象，不是 HTTP 原始字节。旧原件与历史任务不追改；新结果不从自由文本或围栏恢复。模型仍可能不提交或持续提交错误，不能保证所有模型遵守。

## 零模型证据

原件目录：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-review-output-10-8_4zg_nk`。

- 最终 4 组新增回归通过：原生 strict 结果映射；缺提交/原生失败/较晚错误；原业务校验；原参数交给同一终结器。原有 17 项 schema/恢复/只读工具测试、Ruby OMP runner 测试及实际路径逃逸负例结果沿用。候选入口编译通过。
- `sdk-check.json`：实际执行官方 18.9 的 YieldTool、toolWireSchema、validateToolArguments、结果组装及 strict finalizeSubprocessOutput。9 个提交输入、4 个终结门通过预期；其中 optional ref=null 经原生规范化接纳，额外字段/坏类型保持拒收，schemaOverridden 和后续错误拒收。
- 测试只重定位官方源码 import；终结器纯函数体从发布 executor 原样提取，组装函数来自官方 pi-tui 18.9 发布包。来源、哈希与提取边界见 sdk-source-manifest.json、finalizer-source.json、tui-source.json。日志、描述渲染、缓存及未执行 ArkType/renderer 服务使用隔离辅助适配。未启动 SDK 宿主，不据此证明真实 session/provider 路径。
- `original-replay.json`：Kimi findings 对象、GLM 额外字段、GLM evidence 拼写、坏括号四份原文仍拒收，哈希不变。Kimi 此次唯一原合同错误是 findings must be an array，不是围栏恢复故障。

过程中动态 import 映射失败后改静态重定位；路径逃逸测试首次误用相对 TMPDIR，修为绝对临时目录后通过。原生 wire 对字符串枚举补 type 属于等价声明，校验记录已按真实声明核对。未以生产规则迁就测试。superseded-* 文件只保留先前候选证据，最终依据见 final-manifest.json。

实施阶段无新宿主、模型、任务、弹窗复测或历史资源操作。Root 发布复核要求将真实会话逃逸测试的工具集合断言补入 yield，禁写和路径限制不变。发布阶段该零模型 OMP 18.9.0 测试通过，快照指纹不变，会话已释放；入口实际经过 finalizeSubprocessOutput 函数可用性与 yield 存在检查。首次因本次测试 PATH 顺序误选旧 OMP 18.1.16，在模块加载阶段缺 getBaseConfigRoot；修正进程级 PATH 后一次通过，未改全局配置。失败及通过原件均保存在 release 目录。安装器能力探针、源码字节与资源收尾另保留 release 回执。无真实模型验证，不能据此宣布供应商链通过。
