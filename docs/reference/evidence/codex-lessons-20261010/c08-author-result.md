# C08 完成回报（GLM pK，主写）

## 五维事实

**1. 当前问题影响**：TS `validateCheckResult` 与 Ruby `validate_result`/`validate_coverage` 手写重复 schema 的键表（RESULT/FINDING/DELIVERY/coverage keys）、verdict/status/scope 枚举、1..64/1000 边界、额外键拒绝规则——schema 变更不会传导到校验，漂移无防护（重评 C08 结论：重复维护本身即改进依据）。

**2. Codex 位置前提**（固定提交 36ae1561，只读）：单一 Rust 类型 `#[derive(Serialize, Deserialize, JsonSchema, TS)]`（`codex-rs/app-server-protocol/src/protocol/v2/turn.rs:30,45,75`），`export.rs` 的 `generate_ts_with_options`/`generate_json` 构建期双导出 TS+JSON Schema，`precomputed_exports_tests.rs::precomputed_exports_are_written_to_disk` 断言再生成==盘上预生成，`export_user_verification.rs` 过滤导出面。**阅读边界**：仅读上述 4 文件+lib.rs 的 schema_fixtures 引用行；未读全部 protocol 测试（common_tests 等）。

**3. Orbit 差异**：无 Rust 单一类型；结构权威已是 `contracts/check-result.schema.json`（且原样喂给模型）。采用**运行时派生**（两侧各 ~50 行派生函数，无生成步骤、无新依赖），非 Codex 的构建期代码生成。

**4. 采用理由**：schema 成为可执行的单一定义源——改 schema 即改两侧校验与 prompt 枚举；`$id` 身份门 fail-closed（测试实证：错 `$id`/缺事实即拒绝，派生路径写错时正是此门拦下）。

**5. 验证边界/剩余**：确定性测试+派生追随证明；无 live 模型路径（Root 统筹）。诚实声明——**已派生**：所有 schema-expressible 的强制事实（键表、枚举、bounds、ready/complete 布尔、各层 additionalProperties 闭合）。**仍手写**：schema 自身声明不可表达的语义门（非空、正整数、trim/去重、verified⇒evidence、scope 缺省 delivery）及错误消息里的字段名；prompt Output 散文与 `requirement_coverage_note` 的 1000 字符文案未派生（指令文案非强制逻辑，改则动 prompt 字节，未授权）。

## 长度单位修正（按 Root 指示）

合同 UTF-16 表述仅限程序上下文压缩回执（task-runtime.md:111），不覆盖结果校验；JSON Schema maxLength 按 code point 计（RFC 8259），Ruby `String#length` 同单位，TS `.length` 是 UTF-16 units——非 BMP 文本曾会仅 TS 拒收。已修：TS 新增 `codePointLength`（`[...text].length`）用于 coverage requirement/evidence；两侧共享场景补边界断言（600🎯+400x=1000 code points/1600 units 双侧接受，1001 code points 双侧拒绝）。日志/请求预算单位未动。

## 改动（schema 本体未动，未碰 omp-host/task_runtime/总TODO/docs）

- `lib/orbit/check_runner.rb`：硬编码 5 组常量 → `CHECK_RESULT_SCHEMA_PATH/ID` + 类级 `check_result_schema`/`result_structure`/`derive_result_structure`（properties=allowed、required 独立、closed=additionalProperties、boolean_properties 派生）；`result_problems`/`findings_problems`/`delivery_problems`/`coverage_problems` 结构全走派生；prompt 枚举派生（字节不变）
- `lib/orbit/omp_check_runner.rb`：Output 枚举派生（1 行）
- `runners/omp-reviewer/check-result.ts`：同构重写（`loadCheckResultSchema`/`deriveCheckResultStructure`/`checkResultProblems`；`validateCheckResult` 签名不变）
- 新增 `tests/fixtures/check-result-samples.json`（5 样例）+ 两侧各 1 个共享结构场景（TS 29 行/Ruby 46 行，≤3 场景≤100 行达标）

## 测试（先基线后收口）

- 基线（实现前）：bun 9 pass/0 fail、`CHECK_RUNNER_CONTEXT_TEST_PASS`、`PASS omp check runner`
- 收口：bun 6 文件 **34 pass/0 fail**；Ruby 两套 PASS（含新场景：样例双侧一致、删 enum 值/开 additionalProperties 后校验随之改变、错 `$id` fail-closed、非 BMP 边界）

## 身份与资源

- Provider/model/reasoning：`zhipu-coding-plan/glm-5.3-flash`，reasoning high
- 原生 session：`/Users/yangke/.omp/agent/sessions/-Personal-omen-orbit/2026-10-10T03-25-10-220Z_01a123d7-d6cc-750d-aa75-4eb4611fcfee.jsonl`
- 资源用量/费用：**unknown**（无回执可读）；未升版、未提交、未动全局安装；工作区其他 dirty 文件属他票未触碰；handoff/debt-ledger/reevaluation 的 C08 状态同步留 Root