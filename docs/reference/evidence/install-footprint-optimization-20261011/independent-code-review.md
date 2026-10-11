# 独立代码核查 — 可选依赖精简 v3（--omit peer）

- 核查者：Root 之外只读独立核查（本会话）。时间：2026-10-11。
- 对象：当前工作区 diff（`scripts/manage-install.rb`、`tests/install_test.rb`、`runners/omp-reviewer/reviewer.ts`）与 v3 真实冷安装 `/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-slim-82nka8ra/runtime-final/current`（release `df8ab7046aab8ff1ded3cf82`，SDK 18.8.0，0.8.4／`5e781e4` dirty）。
- 模式：只读。本报告全部数字与树扫描为本次独立测量；`footprint-*.json`、`minimum-sdk-settings.json` 等为 Root 产物，只作对照，不当作本轮证明。
- 结论：未发现阻断项。v3 的 `--omit peer` 实际生效，必需 peer 全部显式满足，原生包与加载、SDK 对齐、失败保留均成立；本轮远程检查模型/受限 headless 会话实际未触发本地推理/语音下载——这是本轮实测的接线行为边界，不构成 SDK 级保证（§6）。最低 SDK 18.2.8 的新 settings 键仍仅源码级兼容证据，缺真实旧版本运行验证（见 §7，非当前阻断）。

## 1. 实际依赖区别（v2 → v3）

- 源头：`@oh-my-pi/pi-mnemopi@18.8.0` 的 `peerDependencies` 含 `fastembed 3.0.0`、`onnxruntime-node 1.21.0`（optional peer；本机安装树内 `node_modules/@oh-my-pi/pi-mnemopi/package.json`）。Bun 默认自动安装 peer，故 v2 仅 `--omit optional` 时 onnx 仍在。
- `@oh-my-pi/pi-coding-agent@18.8.0` 的 `optionalDependencies` 含 `@huggingface/transformers ^4.2.0`、`sherpa-onnx-node 1.13.2`，由 `--omit optional` 省略。
- 安装器现状（`scripts/manage-install.rb:357-358`）：`install_flags = ["--omit","optional","--omit","peer","--omit","dev","--linker","hoisted"]`，`bun install --frozen-lockfile` 与 `bun add --exact` 共用。
- 实测 v3 树（独立 `find` + manifest 扫描）：`onnxruntime-node`、`fastembed`、`@huggingface/transformers`、`sherpa-onnx-*` 全部不存在；与 Root `footprint-v3.json` 的 `omitted_presence` 一致。v2 release 实测 `du -sk` 756,696 KiB，v3 实测 457,580 KiB，差 299,116 KiB（约 292 MiB）即省略的 onnx/transformers 树；两个数字与 `footprint-v2/v3.json` 完全一致。v2 不记最终通过（用户已裁定）。

## 2. 必需 peer 是否显式满足

对整个 release 树（宿主 `node_modules` 与 reviewer `node_modules`，含嵌套）扫描 34 个声明 peer 的包，逐一 `require.resolve`：

- 唯一"未解析"必需 peer：`chromium-bidi → devtools-protocol`。核实结果：`devtools-protocol 0.0.1638949` 实际在树内——它是 `puppeteer-core` 的普通 dependency（精确版本），不是被 `--omit peer` 删掉；`require.resolve` 失败是因为该包无 JS 入口（无 main/index，仅 types/json），chromium-bidi 对它的引用全部是 `.d.ts` `import type`，运行时擦除。非缺陷。
- `@opentelemetry/*` 各包必需 peer `@opentelemetry/api` 全部可解析（普通依赖带入）。
- `pi-mnemopi` 必需 peer 为空；两个 optional peer 被省略正是本票目的。
- 运行时兜底：安装器载入检查（§3）与两次已装 reviewer readonly probe（Root `probe-0/1.json`，指纹不变）覆盖实际 import 链。

## 3. Bun 平台原生版本与加载

- 安装器用 `bun -e 'process.stdout.write(JSON.stringify([process.platform, process.arch]))'` 取运行进程平台（含 Rosetta 差异），白名单 `NATIVE_PLATFORMS`（`manage-install.rb:29`）与 SDK loader `SUPPORTED_PLATFORMS`（`pi-natives/native/loader-state.js:35-42`）逐项一致，6/6。
- 显式 `bun add --exact @oh-my-pi/pi-natives-<tag>@<version>`；macOS 非 compiled 加载候选顺序（`resolveLoaderCandidates`）：leaf 包（显式安装的 `pi-natives-<tag>`）→ `pi-natives/native` → bun 可执行文件同目录（execDir）。`versionedDir`（`~/.omp/natives/<版本>`）与 `~/.local/bin` 候选仅出现在 compiled binary / win32 staging 路径，本安装不走。
- 校验语义（`validateLoadedBindings`，loader-state.js:679-723）：安装树（node_modules 内）必校验；bindings 报告版本 == 包版本即通过；已标识的异版 addon 被拒。但"加载成功"不等于"加载的就是显式安装的 leaf 文件"：候选链上的其它同版本 `.node` 同样可满足；且存在**旧 ABI 桥接例外**——`isCompatiblePreSentinelNativeAddon`（loader-state.js:640-657）接受磁盘无当前戳、bindings 无发布身份但具备旧核心符号集的 pre-sentinel addon，桥接包版本跳跃。安装器载入检查 `await import("@oh-my-pi/pi-coding-agent")` 会触碰 natives 符号，若桥接的旧 addon 缺当前链所需符号会在 import 期抛错（`missingNativeExport`），这是行为级兜底；它证明"候选链存在可加载且兼容的 addon"，不证明来源文件是 leaf 包。
- 独立复跑（只读加载）：`bun 1.3.14`，在 v3 runner 目录 `await import("@oh-my-pi/pi-natives"); await import("@oh-my-pi/pi-coding-agent")` → OK；单独 `import pi-mnemopi` → OK（无 eager onnx import）。`pi-natives-darwin-arm64@18.8.0` 在树内且含 `pi_natives.darwin-arm64.node`。
- 前置闸门：`manage-install.rb:249-257` 要求 bun ≥ 1.3.14，覆盖 `--omit peer` 所需能力。

## 4. SDK 对齐

- v3 release 记录 `reviewer_sdk_version: 18.8.0`；已装 runner `package.json` dependencies：pi-ai / pi-coding-agent / pi-utils / pi-natives-darwin-arm64 全部 18.8.0（host 18.8.0 ≠ 源码 pin 18.3.4 → 走 `bun add` 对齐分支，符合预期）。
- 安装器逐包断言 installed == declared == host version（`manage-install.rb:378-386`），任一不符 raise 且不切换 current。源码 `runners/omp-reviewer/package.json` 三包 18.3.4 为 host 未检出时的回退 pin；18.4.9 导入修正分支原样保留。

## 5. 失败切换保护与 lease

- 载入检查（`await import` pi-natives + pi-coding-agent，`manage-install.rb:393-395`）发生在 stage 准备内、current 切换前；函数注释与实现一致："Any failure aborts preparation without switching the active release"。
- 新增测试 `reviewer_native_failure_keeps_old_release`（`tests/install_test.rb:504-513`）覆盖 native 缺失（`ORBIT_FIXTURE_NATIVE_MISSING`）与加载失败（`ORBIT_FIXTURE_NATIVE_LOAD_FAIL`）两条路径，断言更新失败后旧 release 仍 active；既有 `reviewer_install_failure_keeps_old_release`、`reviewer_sdk_version_mismatch_keeps_old_release`、`failed_update` 保留。lease/卸载边界（`OWNED_DIRECTORIES`、`release_lease.rb`）本票 diff 未触碰。
- stage 缓存收口：reviewer 安装后删除 `.npm-cache`／`.bun-cache`（`manage-install.rb:299-300`），测试断言安装后不存在；缓存目录仍在 `OWNED_DIRECTORIES`，卸载语义不变。最终整套 installer tests（`install-tests-final.log`）我直接核对：14 条 `INSTALL_TEST_PASS`（含 `shell_configuration` 收尾），无失败行（4 处 "FAIL" 匹配均为 PASS 行内的测试名 `failed_update`/`*_failure_*`/`failed_legacy_*`），与 exit 0 一致；本轮未重复执行。

## 6. 受限检查器：本轮远程模型/受限会话实际未触发本地推理/语音（边界表述）

- 会话侧（`runners/omp-reviewer/reviewer.ts:397-432`）：`Settings.isolated` 新增 `"memory.backend":"off"`、`"memories.enabled":false`、`"stt.enabled":false`；会话 `restrictToolNames: true`、`toolNames` 仅 read/grep/glob、`enableMCP/enableLsp/enableIrc:false`、`disableExtensionDiscovery:true`、`hasUI:false`。
- SDK 18.8.0 源码（已装包内 `src/`）：
  - 记忆：`memory.backend` 默认即 `"off"`，`resolveMemoryBackend` 对其余值走 `offBackend`，mnemopi/hindsight 等后端仅在选择时动态 `import`；且 `sdk.ts:3756` 在 `restrictToolNames` 时直接跳过 resolve。`memories.enabled` 默认 false（legacy 迁移输入）。三项设置在 18.8.0 是对默认值的显式固定，防未来默认漂移。
  - **本地推理注册链（修正先前绝对表述）**：`createAgentSession` 入口无条件 `registerLocalInferenceApi()`（`sdk.ts:297` import、`:1652-1654` 调用），向 pi-ai API registry 注册 `"local-inference"` transport。注册本身不 spawn、不下载；触发仅当流式调用的 Model 满足 `api === "local-inference"` 且 id 为 tiny 本地模型键（`runLocalInference` 守卫，`tiny/local-inference-api.ts:100-105`），随后经 `tinyModelClient.chat` 连接或 detached spawn worker（`tiny/title-client.ts`，`Bun.spawn`），worker 加载 transformers/onnxruntime 并下载权重；darwin 另有 MLX 路径（`mlxLaunch` → `ensureTinyMlxRuntime` 拉取 mlx-lm python 运行时 + HF `mlxRepo` 权重），**不依赖被省略的 npm 包**。
  - 会话内 tiny 消费点：judgment 的 `"local"` 判定（消费者为 auto-thinking/auto-graph/slash-commands/eval bridge，均不在受限 headless 会话激活）、标题生成（仅 interactive 模式控制器）、mnemopi embeddings（memory off → 后端未被 import）。
  - STT：`stt.enabled` 仅被 `src/modes/interactive-mode.ts`（TUI）消费；headless SDK 会话不进入该路径。
- 本轮实际成立的边界（非 SDK 级保证）：实际检查模型由 Orbit checker 选择，为远程 provider 模型；reviewer 对无 `request.model` 快速失败（`model not in catalog` / `model requires a prompt file`）；`runLocalInference` 守卫对非 tiny id 直接报错、不 spawn。因此 tiny worker/模型下载在本轮远程模型/受限会话下**实际未触发**——这是本轮实测的接线行为（远程模型 + 受限会话）叠加树缺包 fail-closed 的结果：onnx 路径因 onnxruntime-node/@huggingface/transformers 缺失而无法加载（树内实测无，§1），但 transport 在每个 SDK 会话都注册，MLX 路径不依赖被省略的 npm 包；"无可加载包"不构成对所有下载路径的绝对排除，也不排除其它安装/选择配置下的触发。
- 重复运行不回装：多次独立加载后重新 `find`，省略包未恢复，无新下载产物。加载检查走非 compiled 路径，不写 `~/.omp/natives`（现仅 18.8.0，为宿主既有目录）。

## 7. 最低受支持 SDK 兼容风险

- `MINIMUM_OMP_VERSION = "18.2.8"`（`lib/orbit/omp_entry.rb:48`）。settings 键为纯 Record override：`Settings.isolated` 不做 schema 校验（`src/config/settings.ts:745-753`），旧 SDK 未知键最坏是惰性读取，不会抛错。
- 源码级证据：Root `minimum-sdk-settings.json` 显示 18.2.8 官方源码中三键均有 schema 定义与消费点（memory.backend、memories.enabled、stt.enabled；后者含 `settings-schema.ts` 等 4 处）。实际 SDK 18.3.4（源码 pin）只读探测已成功：`source-pin-probe-v4.json` `ok:true`，16/16 边界探针 pass，active tools 仅 glob/grep/read、无禁止工具、confined read 生效、私有注册仅 OrbitReviewer、前后快照指纹一致（`sha256:8cff8591…`），`source-pin-probe-v4.stderr` 为 0 字节。此前的 v1–v3 探测失败不是 SDK 失败：`source-pin-probe-v3.stderr` 实为 compat 夹具缺 `lib/orbit/workspace_snapshot.rb`（Controller 组装遗漏 plugins/contracts/lib）导致的 `LoadError`；v1–v3 stderr 全部保留于 `source-pin-probe*.stderr`。注意：18.3.4 探测是源码 pin 兼容证据，仍非 18.2.8 运行验证。
- 边界（必须如实声明）：以上是源码/构造兼容证据，**不是** 18.2.8 真实运行验证。未验证：18.2.8 上 memory 默认后端与 legacy `memories.enabled→memory.backend` 迁移在真实 reviewer 会话中确实不触发本地推理/下载。必要验证：在一台 host OMP=18.2.8 的环境冷装后跑 reviewer 只读 probe，确认会话无 memory/STT 启动、无模型下载、探针全过。该验证在当前机器（host 18.8.0）不可得，不阻断本轮 18.8.0 验收；若文档声称"最低 18.2.8 支持"，则该运行验证在声称前需要完成。

## 8. 发现与严重性

无阻断项。低severity记录：

1. ~~fixture 未断言 `--omit peer`~~ 已由 Root 补齐：fixture bun 现对 `optional`/`peer`/`dev` 三组逐一断言 `--omit <group>` 存在（`tests/install_test.rb` 当前 diff，`for group in optional peer dev`），覆盖实测 ONNX 回归；含此断言的整套 installer tests 已由 `install-tests-final.log` 收口（14×PASS、无失败行，§5）。
2. `chromium-bidi` 的必需 peer 仅由 `puppeteer-core` 普通依赖间接满足（当前树成立）；上游任一方变动都可能改变该事实，届时树扫描会暴露。无需动作。
3. 冻结锁分支下 `bun add` 会改写 release 内 `package.json`/`bun.lock`（native 加入、peer 条目移除），属既有 release 派生设计，与源码锁文件回退并存；`content_digest` 为源码包摘要的既有边界不变。

## 9. 证据边界与未覆盖

- 真实正例/负例矩阵的最终实质正例仍在原生成员内运行，本报告不预记通过；installer 全套已由 `install-tests-final.log` 收口（§5，我核对日志标记，未重复执行）。
- 18.4.9 补丁分支、18.2.8 真实运行（§7）、跨平台（仅 darwin-arm64 实测）未在本轮重跑；`du` 为目录占用，不等于物理释放字节（APFS clone）。
- 未修改任何文件（本报告除外）、未启动模型、未下载依赖、未写用户安装；`~/.omp/natives` 仅观察未变更。

## 身份与用量

- 会话配置身份：provider `zhipu-coding-plan`，model `glm-5.3-flash`，reasoning `high`（workstation 配置标注）。
- 本回合实际 token/费用等用量回执：由 Root 另从本会话原生记录提取；本报告不作推算。
