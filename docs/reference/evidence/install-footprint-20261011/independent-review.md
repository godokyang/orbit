# 安装体积修复只读核查报告（pK，未改任何文件/未执行状态动作）

## 病因实证（用户现行 11dc release 解剖，3.4G 构成）
- **混合版本**：declared `pi-ai 18.3.4` vs `pi-coding-agent/pi-utils 18.8.0`（旧代码只对齐两包）→ pi-coding-agent 内嵌第二套 node_modules（202M，含另一份 pi-ai@18.8.0）。
- **嵌套 native 重复**：`pi-natives-darwin-arm64`（每份 ~177M）在 omp-stats/pi-utils/snapcompact/pi-agent-core 的嵌套链下多份复制。
- **缓存保留**：`.bun-cache` 1.1G 留在 release 内。
修复后临时实装（footprint-j7pb7809）：**954M**（≈3.6× 缩减）。

## 三风险核验
**1. 多份 native 树消除 ✓**。`REVIEWER_PACKAGES` 三包全部要求 ==宿主版本，`--linker hoisted`；实装中三包全 **18.8.0**，全深度 find 仅各一份 pi-ai/pi-utils/pi-natives-darwin-arm64，pi-coding-agent 下无嵌套 node_modules（余下嵌套仅 @opentelemetry 54M 版本冲突 shim，hoisting 正常产物）。逐包 `installed+declared` 双重校验（manage-install.rb:356-360）比旧单点检查更强。

**2. 缓存删除不破坏运行时 ✓（带终验边界）**。两缓存仅 prepare 期使用（npm `--cache` flag / `BUN_INSTALL_CACHE_DIR` env），删除在 record 写与 switch 之前；release `files` 从不含缓存；发布内引用缓存名的文件仅 manage-install.rb 自身（lib/plugins/runners/node_modules 均无）；bun 装树为硬链接，删缓存链接不销毁 inode。**边界**：我只读未执行模块加载，最终以一次真实 check 运行终验。

**3. 失败路径/运行保护/18.4.9 补丁保留 ✓**。prepare 失败→abort 于 switch 前，ensure 恢复 legacy/created/replaced wrapper/marker 并清 stage/release；`current==previous` 守卫防并发安装；current 经 symlink+rename 原子切换；uninstall 遇 live lease 拒绝（603-608）；clean_release 兼容 LEGACY owned 列表，旧 release（11dc 记录含 .bun-cache）可被下次 update 的 cleanup 释放。测试覆盖：mismatch（fixture SDK 18.3.0→"does not match host OMP"→旧 release 保持）、bun 失败、failed_update 全链断言。**18.4.9 限定补丁逐字保留**（363-375，含源不符即 raise）。

## 真实缺陷/风险（均为低）
- **A**：18.4.9 补丁路径无 fixture 覆盖——测试走 MINIMUM=18.2.8 分支；fixture 假包无 src/sdk.ts，若测试用 18.4.9 会在 binread 处失败（测试基建限制；补丁代码本 diff 未改，沿用上轮独立核实）。
- **B（预先存在）**：`content_digest` 在 reviewer 对齐之前计算，宿主≠18.3.4 时 bun add 改写 staged package.json → digest 与盘上该文件不再逐字节一致（files 列表仍准、reviewer_sdk_version 记录了实际版本；本 diff 未改变该时序）。
- **C（既有语义）**：装后宿主升级 OMP，reviewer SDK 保持旧版直到下次 update（代码注释已声明）。
- **D**：`--linker hoisted` 需 bun ≥1.1；过旧 bun 会报错 fail-closed（旧 release 保持），prerequisites! 已检 bun。

## 通过范围与不能外推
通过：本 diff（29+13 行）+ 临时实装核对范围内，三包对齐、hoisted、缓存清理、原子切换/lease/回滚、失败路径、18.4.9 补丁全部成立，体积 3.4G→954M 机制实证。不能外推：未跑真实 release 模块加载与全仓测试（Root 统筹）；用户现存 3.4G release 的释放发生在下次 update 的 cleanup（本票不执行）。未重开旧验收矩阵，未动任何文件。
