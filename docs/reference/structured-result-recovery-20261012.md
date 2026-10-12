# ORBIT-STRUCTURED-RESULT-05

基线 `5c7a318decf1d5e1cfd2fbb4d6aa32790263ccb3` / 0.8.8。Loom Root 接受 04 的最小方案并授权实施；实现与零模型验证交回后，Root 独立核对候选源码/测试/原件重放通过，并触发用户持续有效的提交、推送和本机更新授权。发布 patch 升至 0.8.9，合同保持 1.4；提交身份见 Git 历史，更新日志与公开安装/能力回读保存在下述证据根的 `release/`。没有 tag 或额外对外发布；发布不重标为新构建真实模型验证。

## 恢复边界

完整回答先走原来的 `JSON.parse` 和严格结果校验。解析失败时，新增仅覆盖整个回答的单一完整小写 `json` 围栏（允许外围空白和 CRLF），内部仍由 `JSON.parse` 和原 `validateCheckResult` 判定。围栏外文字、多块、缺闭合、坏 JSON、额外字段均不接受；失败围栏不会再进入尾部对象选择。没有围栏时保留已有前置说明＋末尾完整对象恢复。

围栏识别跳过 JSON 字符串内容（包括转义引号），因此字段原文含三个反引号不会破坏已有前置说明恢复。Root 复核发现最初 `text.includes` 判断过宽后，已改成这个小范围词法判断；不是通用 Markdown 解析器。

`raw_text` 的赋值仍为原始回答；只有候选通过原严格校验才记录 `json_recovery`：围栏为 `single whole-message json fence; contract-valid JSON object`，既有前置说明标记保持原值。schema、供应商接线、工具集合、完成/停止门及模型授权不变。旧任务和历史判定不回填；候选结构有效不等于业务验收完成。

## 验证与证据

证据根：`/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-structured-result-05-fdftsi_p`。

- `final-tests.log`：恢复、check-result、provider-error 三套相关测试共18项通过。仅在已有恢复测试文件新增4组，既有前置说明测试也改走生产使用的新入口；Root 指出的字符串原文兼容场景加入第4组，没有第5组。
- 既有 `tests/omp_check_runner_test.rb` 通过（本次终端工具输出 `PASS omp check runner`）；随后只改 JSON 字符串围栏识别，相关三套测试重新通过。没有为了此小修补重复全仓测试或启动 OMP/模型。
- `replay-results.json` / `final-replay.log`：用官方 export 的原 raw_text 零模型调用生产恢复函数与原校验器。Kimi 2976字符围栏结果候选有效，GLM额外 `reasoning_compressed` 仍拒收，GLM多余 `}` 仍拒收。三份原文本 SHA256 均保持不变；`cases.json` 留官方归档地址和哈希。原任务没有任何写操作，不把离线候选通过写成旧任务检查通过。
- Kimi 原文 SHA256：`42b080879c54a4f74b8feda36302a0320507398d992afea49513be2ce2fb0d6a`。最终文件摘要与差异另存本目录供 Root 复核。

没有新增模型调用、新任务、供应商、代理派票或 Goal；没有操作 Loom 后台、PID、socket 或数据库。所有自有短验证进程已结束，保留零模型证据。真实新构建 Kimi 检查未执行，也不据本票宣称任何模型稳定产出合法结果。
