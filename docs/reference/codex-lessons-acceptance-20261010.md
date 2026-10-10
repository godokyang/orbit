# 剩余 Codex 借鉴项交付与真实验收（2026-10-10）

状态：实际开发 Goal **complete**（2026-10-10T06:10:16Z工具回执），本轮必要真实矩阵、静态验证、独立复核与资源清理已通过。唯一总清单与冻结验收沿[实施 §9](../plan/codex-lessons-implementation.md#9-剩余问题交付2026-10-10当前执行)，本文只记录证据。旧 Goal complete、C01/C05/C07/C09 与 T01—T13 的历史边界保持，不将本轮失败改写为通过。

## 构建与来源

源码0.8.3，HEAD `9f5e66db681ac312d12f2f1f1c70cc804bcaad38` 加完整dirty/untracked现状；未reset/提交/推送/升版或升级日常安装。固定Codex commit `36ae1561b9324c93d5638b45eb19fe2cc070a581`，主要写者直接读对应源码、调用链与测试；Orbit是现有JS/Ruby/TS、OMP公共接缝的局部适配，不是Rust移植、行为全等或成熟度认证。

受测临时安装用支持的install.sh --runtime-dir/--bin-dir --no-modify-path：初版 `123f8e83876d5970a52374c4ac5200d915adc58b58c3f2b10cad904bcc4e0e16`；修复版 `b4085db46ed3e2aaabd6d9461ca665a53df8cde7b2c4f471ac32321fb141f87b`；npm包/字段诊断 `a201a4e867b4d4aac330cf6f1f8076290d44923e2a245abe370d393590c99b08`；字面TMPDIR探测/未知选型提示 `5627dd25d05b20bbf69635179483fc954f796a9141382ab089e4ac45694c877d`。operation层级修复 `8906c1877f8ce2c4ec3465e38999d245fe867093f1cc860482ea2f62dfc06c15`。各运行保留原受测构建，不重标新版本。实际pi-coding-agent18.8.0、pi-ai18.3.4，不能宣称全部依赖已对齐。

## 当前真实矩阵

| 场景 | 当前状态与范围 |
| --- | --- |
| plain omp | passed：独立bare OMP没有Orbit extension/工具；新pane及其PID退出后删除 |
| 一文件负例 | passed：123f构建、原生真实需求，一文件修正验证，无evidence request/hint/native member；独立OMP固定只读检查和manual stop confirmed；原OMP/MCP均退出，pane已删除 |
| 正例v1 | partially exercised：123f无Controller催办/代写，自行实现127cases；错误agent-model调用后Root接管，独立检查促成原生只读核查成员/Root收结果再检/stop confirmed。能证明自主推进和原生审查闭环；没有推荐、实质实现交接、成员npm环境恢复，不能算必要推荐正例 |
| 正例v2 | partially exercised：b408，Root从未实现夹具原生委派importer实质编码，修正Missing context后实际派发；成员首调用前登记、真实deepseek-v4.1-flash，Root集成、127cases及独立OMP检查后confirmed stop。spec外model_requirements被忽略、facts_only；成员重复npm包读取EPERM及测试/tmp写拒绝，Root测试通过不等于成员恢复。追加窄诊断后须新构建复验 |
| 正例v3 | failed/Controller cancelled：a201成员重复npm包EPERM、没有合法推荐；已实现的importer不替代必要环境恢复。保存31+实际失败调用后native Esc取消，任务confirmed paused、OMP/MCP退出并删pane，不宣称自主成功 |
| 正例v4 | partial/collection failed：5627，K3 Root修正错层选型要求后获得真实版本绑定K3推荐；成员原生登记、实质实现、npm127通过、显式hub成功，Root独立复测。Root把finish/read operation放入work_unit，实际变成declare，原单元仍bound并误建空单元；文件终检后来通过和stop confirmed不替代该收集失败。四次独立检查结构失败原件保留，未放宽协议。无Controller催办，进程退出/pane已删除；据真实事故补调用前层级诊断，新构建另测。 |
| 正例v5 | failed/Controller cancelled：8906，fresh K3 Root连续8次write缺content，未完成CLI写入或原生派发；Controller native Esc取消，confirmed paused、OMP/MCP退出、pane关闭；不计自主推进或operation修复真实成功。 |
| 正例v6 | partial：8906 GLM Root修正Missing context后真实K3推荐/预注册/实质编码；成员修正缺content及不匹配命令后npm127通过，Root独立npm127/正确finish→accepted/独立终检/stop confirmed。成员只yield返回，没有hub/peer发送；Root“已经hub报告”自述与原件不符，不能记完整必要正例。没有Controller催办；OMP/MCP退出、pane已删除。 |
| 正例v7 | passed于冻结范围：同8906/CSV验收，fresh GLM Root；初始需求明确保留原有hub报告约束并区分yield；K3实现成员npm122过后CLI失败，实际遗漏CLI读范围；向all报告被拒，改Main成功。Root自主新增包含CLI的复验单元，Deepseek成员实际npm127通过并经Main消息成功；Root修正错误unit id，两个实际执行单元accepted，手动独立OMP只读固定快照check3 complete、finalization wake、Root调用stop后两成员owner jobs settled/confirmed；OMP/MCP及checkers PID退出，pane已删除。没有中途改变标准、Controller代写或新供应商/伪事件。 |
| 生命周期 | passed于实际范围：b408真实amend入有效要求，活动member native Esc确认暂停/owner jobs settled，明确只讨论后文件hash不变，native /compact有记录；同native session正常退出并重新打开，实际请求完整保留目标/amend/暂停；明确继续建新边界，K3新成员登记，在Root/member活动时正常退出，两任务confirmed paused、owner jobs settled、OMP/MCP/runtime退出，pane删除；Esc保持第一宿主会话存活以恢复上下文，不称整个宿主原子关闭 |
| C08 TS/Ruby | passed于已测范围：schema派生结构与语义门回归；真实独立OMP返回经TS→Ruby被runtime接收，身份/版本/coverage裁决保留。不是所有理论分支认证 |

全部运行遵守Herdr→已安装orbit omp→真实用户要求；开发pane回报与确定性runtime不是上述路径替代。主线初始提示各一次；生命周期修订/讨论/compact/Esc属Controller干预，单独记录。失败、人工干预和未跑保留。

## 实现、核查与检查

C02 K3主写/GLM独立核查，Root整合；C08 GLM主写/Grok独立核查，Root修Unicode coverage空白。C04/C05 Root窄适配，K3独立核查；C06 Grok初版反复研究后Root保留并接管修正，K3独立核查。固定开发OMP均保留原进程，/new重载当前材料成功。

完整npm test第一次失败：测试消费者删除atomic inbox .tmp导致rename ENOENT；修为仅读.json后整仓exit0。Root最新追加具体接口/环境缺口后重新运行对应测试/独立复核，operation修复后的完整npm test也exit0，冻结验收不缩减。pack dry-run、skill validator、diff check已通过；最终源码改动后更新有效验证范围。新增测试围绕目标请求、具体参数/环境失败、Unicode协议与停止观察，未追覆盖率。

## 宿主与容量限制

C05当前SDK只有单session永久beginDispose及可等待dispose，registry release先detach且内部清理可吞异常；无团队原子关闭准入、失去全部session引用后的可靠退出信号。接入hasAdmittedSubmission防pre-stream忙态遗漏，晚到roster补丁保留，不能把事后名单检查或idle当可靠全宿主关闭。缺证仍stop_unconfirmed；本轮必要实际停止失败则Goal不能complete。

C02 context本地append记录不是server receipt或模型遵守证据；SDK hook超时/异常有上游边界。完整原目标不截断，但也不证明完整请求容量；64KiB仅程序检查投影，system/tools/MCP/history/目标/读取/输出预留不因此获得总容量保证。C03发送前所有权/版本门不是接收处原子expected-turn。C07 append cutoff非fsync/断电持久化，C09status/errorId非完整恢复控制器。

## 资源与收口

开发固定Root、pH/pJ/pK及所属MCP、Herdr服务保持；自建测试pane、进程、安装、目录逐项登记。全部新建测试pane及所属OMP/MCP/独立检查者进程均已退出并关闭；支持临时卸载exit0；本轮临时根、指针、SDK研究目录和归属明确的宿主临时目录已清，17个固定PID/4pane和日常安装摘要复核不变，Goal已实际complete。必要运行/失败/调用/原生session/固定快照与资源原件将归档到本页证据索引。

用量按角色、精确provider/model、原回执input/output/cache/totalTokens记录；reasoning仅报告字段存在时的output子集，不再相加。Root Goal计数不等于供应商token，SDK费用估计不等于现金或套餐扣减；未知保持未知，没有配对收益基线，不宣称节省。


当前必要证据已保存至[evidence索引目录](evidence/codex-lessons-20261010/)，最终每个场景包含构建/原要求、task原件、过滤的原生调用/回执（不保存凭据与私有thinking）、检查固定快照与退出记录。目录内运行中快照不会冒充最终结果。程序文件/schema与8906受测安装逐文件匹配；安装SDK对package/lock的支持变换及后来合同operation说明补清在tested-installed-source-files-final.json明列。

开发模型原生回执：pH K3 input323650/output79751/cacheRead18322176/total18725577（151条）；pJ Cursor grok-4.7-500k-fast input128611/output254609/cacheRead6272384/total6655604（7条，1条取消零usage保持未知）；pK GLM5.3Flash input487920/output121526/cacheRead29282432/total29891878（207条）。单位token，cacheWrite均为SDK报告0；K3 reasoning未报告，GLM107条报告69991、Grok3条报告30824，仅作为output子集。SDK contextTokens不是消费总量；Root开发Goal计数、现金/套餐扣减未知另记。产品Root/member/checker/Jev逐调用原字段和未知状态已最终归档，不能将开发与产品角色混为一笔。

V4 Root调用xd://report_issue把错误层级误报为宿主finish bug，原工具回执为Noted, thanks；这不是实际SDK缺陷证据。源码核实该宿主QA入口可能在既有同意条件下写本地库并异步push，本轮未验证投递结果，不把Root误报说成已修复宿主或已成功报送。Root Controller没有发送报告或修改QA同意设置。

Root新会话原件元数据：session `01a123d6-9986-7d12-b447-f6ebcffb40e9`（03:23:49.034Z，forked_from_id=null），Codex0.162.1、openai/gpt-6.1-sol。只保存元数据与客户端token_count，不归档Root私有思考。05:39:13.562Z检查点累计input47174721/cache-input46019968/output249481/reasoning-output124175/total47424202，单位token；缓存是input子集、reasoning是output子集，不能再次相加。它与Goal计数和OMP/Jev回执分开，末次资源统计还会增长，现金/套餐仍unknown。

末次身份边界：原生登记早于首模型调用；登记时SDK实际model尚不可见的binding_pending如实保留，pre-request实际model_identity及durable工作单元绑定核对后才放行模型工作。第二成员state.work_unit_id为空，不填造；真实归属由work-units的member_id/dispatch tool_call_id、成员初始上下文与范围事件交叉核实。两个未派发declare记录没有执行者，不当漏停成员；declare+评估分步也不冒称原子提交。当前支持这些有界事实，不能证明任意模型都能自行恢复（v5反例保留）。

最终原件独立复核：固定GLM pK直接读Root/成员原生调用、单位记录、检查固定快照/身份、停止/PID原件，六问在有界范围通过，报告为positive-v7-independent-result.md。修正本报告的叙述：Root实际npm127只有05:41:58一次（在复验成员派发前），此后05:43:57做CLI抽查；复验成员没有修改源码，所以不把它扩写成另一次Root npm重跑。原SUT verification文字宽于回执的事实留存，不直接修改被测状态。成员2便捷关联字段缺失的影响是只读members的消费者不能直接取得单位关系；实际durable绑定完整，后续小同步可单独处理，此处不扩大本轮协议或伪填数据。

C05可行上游方案是宿主提供团队准入epoch关闭、逐成员可等待清理结果及脱离session引用仍可查询的终结状态；集成须明确永久终结与可恢复暂停的差别。当前局部busy/retained session/owner jobs/晚到名单观察不能模拟这些原子接口；本轮不维护Fork、不扩大权限，缺证仍stop_unconfirmed。

产品用量最终按原call_id去重共433条（含失败/partial/unknown），详见product-resource-final.json。Jev实际版本77次报告input_tokens621136/output_tokens4732、另3失败实际model/usage unknown；OMP Root/member/checker各精确路线分列原字段，不从Jev输入输出推造不存在的total、不和Codex Goal计数混算。现金与配额、真实费用节省均unknown。

资源收尾原件：cleanup-inventory.json/cleanup-final.json/postcleanup-preservation.json。11个本轮自建pane关闭（生命周期pane包含正常退出后重开同session的两段进程），受测Root/MCP/独立checker及owner后台均退出；临时支持卸载、外部SDK目录及整个本轮临时根删除，固定13进程+4pane shell保留。初次清理清单因含固定开发pane观察而被身份保护拒绝，未进行删除/信号；最终按记录的测试pane过滤，未按通用进程名处理。没有归属不明资源被删除，未改日常安装/源码版本、提交推送发布。

最终Goal原件goal-final-result.json：complete，Goal计数1538326、9977秒（2小时46分17秒），无tokenBudget。它与供应商回执/费用分开。Root客户端最后可得检查点2026-10-10T06:07:13.485Z，openai/gpt-6.1-sol input52676796（含cached_input51445632）/output301269（含reasoning158379）/total52978065 token；不是最终答复之后的账单。开发三OMP reported total55273059（含cacheRead53876992）token，角色/实际型号分列，产品另433条原调用账本，不把不同层重复求和，不宣称节省。
