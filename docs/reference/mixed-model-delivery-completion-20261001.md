# 混合模型交付完成记录（2026-10-01）

本文件是原 54 项审计（A01–F10）与 W1–W10 的**当前收口工程汇总**（产品运行语义以[任务运行合同](../../contracts/task-runtime.md)为准）。逐项判定沿 Root 的
`/private/tmp/orbit-stop-guard-037/ROOT-54-CURRENT-COMPLETION-AUDIT.json`（2026-10-01T13:01Z，基于源 `451bff2`）；
不重写 0.7.10 初审标签（原表保留于[代码审计](../plan/mixed-model-delivery-code-audit.md)与 Git 历史）。
构建身份：源码/安装 **0.7.37 / commit `4cc957e374300b9598f4e02bce5c3920f9bc97dc` / digest `9662512a…` /
release `29fba720cde2c6cd01c5e019`**，full 197.31956s exit 0，83 pack 逐字 SHA 与安装一致。

## 54 项逐项判定（沿 Root 审计 JSON `rows[]` 生成，原文要求见主方案对应条款；本记录是工程收口汇总，不取代[任务运行合同](../../contracts/task-runtime.md)的产品语义权威）

| ID | 实际 source | 有效证据与边界（沿 Root 审计） | 状态 |
| --- | --- | --- | --- |
| A01 | `lib/orbit/omp_entry.rb`; `plugins/omp-host.mjs` entry/start paths | Session接入与任务激活分离；pair4/033/37/W9均为实际installed普通请求；不以Jev校准替代完整SUT负例。 最后原件补验：entry-negative-wvKE，Root独立复核单user/native read-edit-bash、准确拼写diff、无task/hint/evidence/member/check，实际native exit；Root-NEGATIVE-REVIEW.json。 | verified（有限范围） |
| A02 | `lib/orbit/prestart.rb#classify`; host message dedupe/binding; entry ledger | 规则优先、原生ID去重、受控启动前置门保留；W9两臂单业务user，37单user，无Controller重复业务要求。 | verified（有限范围） |
| A03 | `prestart.rb#intent_text`/`discussion_lead?` | 引用过滤保留完整原文语义input；分类测试/full已覆盖，未把所有自然引用形状称普遍正确。 | verified（有限范围） |
| A04 | `prestart.rb` three entry questions and `EntryCalibration.passes?` | execution AND(delegation OR supervision)，八例有限校准真实服务含fail/holdout，ordinary监督37/W9＋交接pair4。 | verified（有限范围） |
| A05 | `prestart.rb` unattributed continuation → `root_decides`; CLI native message selection | 无绑定续办不从Git猜要求；原生来源选择及takeover8e411be9原件复用，非所有续办语句认证。 | verified（有限范围） |
| A06 | runtime `collect_amendments`/turn attribution; sent internal message exclusion | 活动新问题/显式修订/程序消息归属分离，原缺陷修复不重标历史。 | verified（有限范围） |
| A07 | task takeover records, CLI start/takeover-scope | 真实takeover原始来源、接管点和snapshot绑定；旧冻结构建complete confirmed为历史证据。 | verified（有限范围） |
| A08 | `task_view.rb`, host status, resource ledger projections | task_view/host/state分别呈现接入、激活、hint、真实派发/check与可得角色资源，推荐不算执行。 | verified（有限范围） |
| B01 | `task_runtime.rb#member_candidates`; session catalog and native task guards | 用户池∩session目录，真实native登记：pair4选择同unit并注册先于work，成员accepted并纳入stop。 | verified（有限范围） |
| B02 | `member_model_selector.rb`; shared capability facts/overview | 相关catalog+精确facts→typed适配；pair4正hint到真正成员，旧负样本保留。 | verified（有限范围） |
| B03 | independent candidate preparation/holds; capability projections | 逐候选缺证/不可用独立处理；未强求逐型号本地成功证书。 | verified（有限范围） |
| B04 | `jev_advisor.rb`; `ModelQualityPolicy.project_selection_state` | 先验是判断input，不与Noul概率加权，来源及未知资格显式。 | verified（有限范围） |
| B05 | `checker_model_selector.rb#identity_for`; host catalog routes/limits; isolated reviewer actual receipts | 实际provider/model/route/context与可得account单独记录；W9 actualnative与ledger匹配，不推断未知reasoning/upstream。 | verified（有限范围） |
| B06 | `lib/orbit/data/openrouter-model-map.json`; endpoint-based billing route; mapping audit | 实际文件lib/orbit/data/openrouter-model-map.json六条精确route映射，4个模型identity；26已修Go标签并6/6 loader证据。 | verified（有限范围） |
| B07 | `openrouter_model_overview.rb#lookup(indices:)` | lookup(indices:)无coding通用准入；agentic/intelligence各保留relevant_indices，不补缺coding。 | verified（有限范围） |
| B08 | overview facts + capability `execution_eligibility` | catalog maxima与execution_eligibility实际route限制分离；身份及supported parameters可传。 | verified（有限范围） |
| B09 | overview-v3 fetch/store/project and benchmark variants | overview-v3抓取/清洗/benchmark variants/intelligence投影，有限动态覆盖审计复用，不固定实时值。 | verified（有限范围） |
| B10 | overview fetch/measurement fields; capability date qualification | 抓取TTL不是测量日期；date要求未知hold，放行profile明确，actualmeasurement未知保留。 | verified（有限范围） |
| B11 | `model_capability_facts.rb#candidate_facts`/`evidence_relations` | 同时展示catalog与精确证据，potential conflict hold/root review，不按source名字判真伪。 | verified（有限范围） |
| B12 | work-unit dispatch/result/verification history; selector unit view/signature | unit dispatch/actualresult/verification反馈入当前selector签名，旧版本失效，非永久品牌排名。 | verified（有限范围） |
| B13 | optional OpenRouter setup/overview refresh/cache | 可选key-free状态/0600私有事实/有界刷新与禁用无出站保留，未重建配置系统。 | verified（有限范围） |
| C01 | quality policy + member selector | 当前quality-policy无旧time/parallel_gain门，可信可比cost才排序；未知cost正向候选稳定池序。 | verified（有限范围） |
| C02 | checker selector/selection | checker现行无time/coarse fee/family preference排序；families仅facts/signature，纠正旧Root index错误。 | verified（有限范围） |
| C03 | current connection/catalog and member selector | 生产逐候选session目录，无整组no-catalog旧fallback调用；empty与nil不混同。 | verified（有限范围） |
| C04 | policy projection/metric denylist/capability facts | projection/cache denylist去时间/本地样本/粗价；deadline/cooldown/stop诊断保留。 | verified（有限范围） |
| C05 | entry and selection calibration documents | 8 entry与17标签/14 selection真实调用有限放行，绑定jev-1.13.0及问题/输入/决策，失败未知、holdout分列。 | verified（有限范围） |
| C06 | policy versions and consumer signatures | entry3/input2/decision2与selection decision3/memberv2/checkerv7签名升级；旧分数不迁移。 | verified（有限范围） |
| C07 | contract/ADR/usage/status/current consumer tests | 现行消费者已接线/full；当前计划/合同状态残留未交付和W9未完成句需同步，历史正文不改判。 | pending（最终文档/本地交付） |
| D01 | task record original instruction/basis/amendments/digests | 原始instruction/basis/amendment/source/input_digest持久，summary不成为新用户要求。 | verified（有限范围） |
| D02 | `work_unit.rb`; actual native dispatch binding | work-units2 objective/requirements/context/decisions/scope/acceptance/deps/escalation与actual dispatch绑定；pair4同unit hint/receipt成立。 | verified（有限范围） |
| D03 | handoff task-fit questions; conditional host policy; pair4 | 串行交接无需并行/用户逐次安排；pair4 native K3先交付后Root集成、验证、manual final、stop真实。 | verified（有限范围） |
| D04 | member registration/expected model/drift guards | 注册及before-provider实际型号核对，drift拒收/hint失效/尝试停止；27以后本段代码未改变。 | verified（有限范围） |
| D05 | `work-unit-scope.mjs`; actual tool entry and macOS sandbox | actual tool入口work-unit-scope执行path/edit/命令sandbox限制，网络/private拒绝，full测试当前过；无跨平台通用权限承诺。 | verified（有限范围） |
| D06 | unit view + current task original inputs/decisions/findings/context/history | unit/current-context生成可追溯事实/决定/finding/省略提示；原文可读，无另造知识图谱。 | verified（有限范围） |
| D07 | source-backed requirements/findings, stale handling, executable tool limits | 四类控制分别有来源核验/要求绑定/tool限制/版本持久。35 off_track触发→真实process；37非stale process→合法阻断停；033 actual artifact finding→纠正→修复→resolved停。非stale process finding→纠正→恢复组合仍未实测，不冒称passed。 | verified（有限范围） |
| D08 | Root `root-model`, shared SDK selection/phase sink, program stage seam | 根阶段选模/程序控制器/宿主切换是原§1.3/11.3实现选择；必要强模型判断033自动fallback GPT发现真实缺陷已证。Root工具/程序switch已更正tagged pre-send，有确定性/full、SDK接口证；自然switch分支未实测，不把配置变化冒称自动选型。 | verified（有限范围） |
| D09 | retained dispatch attempts/failure classification/history; Root stage selection | 真实structured quota/service/invalid_result/缺输入区分；35 task排除避免每产物重复失败，36换型保通道live37；33复杂缺陷GPT检查介入纠正。原生failed-unit自动释放仅确定性、无虚标live。 | verified（有限范围） |
| D10 | public OMP task/hub/model/control surfaces | public task/hub/setModel/job/reap SDK接缝可用；继续OMP是基于已核对接口/有效真实链的实现决定，无宿主重写义务。 | verified（有限范围） |
| E01 | isolated reviewer/confined tools/frozen snapshot receipts | 独立OMP readonly read/grep/glob固定snapshot前后SHA和实际model核对：pair4/033/37/W9；进程仍有模型网络，不声称无网络。 | verified（有限范围） |
| E02 | event observations/check signatures/in-flight guards | change/signature observation去重，in-flight仅poll，manual优先；36 process fallback成功/过期回常规timer，无无限检查链。 | verified（有限范围） |
| E03 | scoped local Root verification receipts + relevant semantic review + final coverage | Root可执行验证→相关独立语义→按需强检查→manual整体覆盖，33真实发现/修复及W9外部统一评价；不存在全领域收益证明。 | verified（有限范围） |
| E04 | coverage schema/current-version requirement statuses/completion gate | requirement-coverage2 ID/evidence/input/root/artifact当前绑定，process不授完成，缺项不能靠无finding补；W9 manual当前delivery7项及外部20断言。 | verified（有限范围） |
| E05 | snapshot stale reasons and current resolution/finalization binding | rebind35f925ba旧check明确workspace/input/artifact stale＋新root有效check历史保留；host-stale process只给历史提示，不冒当前纠正。 | verified（有限范围） |
| E06 | runtime completion/stop gate, native member readiness/jobs, exit evidence | Root完成意图+有效manual通知+members settled+真实idle/tools0/asyncsettled，pair4和W9 complete confirmed；37blocked needs_user confirmed；35 stop_unconfirmed失败不改判。37 own-marker精确移除gate已过，但原pending-marker特定现场未实机复现。 | verified（有限范围） |
| F01 | route resource fact/store schema, exact applicability/source/date, category rules | 可信route_resource_facts/store分来源/route/plan/原unit/生效date，未知effective不可price/rank；不冒用OpenRouter价，无新价格调查。 | verified（有限范围） |
| F02 | quality policy scoped cost comparison | 程序quality gate后仅可信可比resource estimate排序，unknown保留稳定候选序，不按厂商粗成本排行。 | verified（有限范围） |
| F03 | route cost inputs and receipt mean verification | 实际接受同类unit receipt构成均值/forecast与settlement分开；交叉单价缺构成不能断成本，declared-workload不授自动排行。 | verified（有限范围） |
| F04 | native message/call receipt sinks; task/work-unit/role/phase ledger | resource_call_ledger与native sinks Root/member/checker/Jev逐call/任务/unit/phase/actual identity；W9 Root/native 27一一范围相同只cross-reference，45uniquecalls。 | verified（有限范围） |
| F05 | accounting before selection returns, call-ID dedupe | 判断在pending/decline/不可用返回前记账、call-ID去重；selection多标签共享call不能重复算，W9全9Jev实际input/output。 | verified（有限范围） |
| F06 | checker error receipt persistence/native call source | failed checker/parse不合格保存可得usage和身份或explicitunknown，SDK automatic retry已隔离关闭；Go failed1各category null不是0。 | verified（有限范围） |
| F07 | ledger category groups/gaps; session summary/resource projection; task evidence export | summary/export按真实identity/role/phase/source/unit分组及reported/missing；未知跨model总数nil是诚实，非按conversation时间窗推账。 | verified（有限范围） |
| F08 | no monetary hard-budget gate; ordinary runtime controls | 用户明确排除硬预算；无需新预算门，deadline/停止实际运行保持。 | verified（有限范围） |
| F09 | paired frozen quality probes, baseline/native receipts, per-role ledger | Root本轮已独立写ROOT-W9-RESULT-REVIEW：同一冻结prompt/spec/6tests/20oracle，两臂同外评；K3 execution配置+existing checker pool mixed旗舰observed0 vs plainGPT7，其他用量更高，cash/quota unknown，单task效果；旧pair4旗舰+134.665%负例保留，调整后用普通监督路径有限比较，不推广派成员必省。 | verified（有限范围） |
| F10 | full regression/pack freeze/install raw exits/installed identity; current docs | 代码4cc957e/installed0.7.37/digest9662512a，full197.31956s exit0/83pack冻结与install匹配，regress37与W9 real；最终docs/local checkpoint/必要doc-only install/cleanup待Root复核。 | pending（最终文档/本地交付） |

关键证据分列：

| 证据 | 内容 | 边界 |
| --- | --- | --- |
| pair4（0.7.25 冻结构建） | 自主成员**真实完整链**：v2 hint→native K3 派发→注册先于模型工作→bound dispatch→member completed/accepted_at→Root 集成→manual 终检→complete＋confirmed stop；旗舰臂 +134.665% 负例保持不改判 | 单任务样本；账户 41 known/16 unknown，cash/扣减未知分列 |
| 033（0.7.33） | **强 checker 自动 fallback 真实发现→纠正→resolved→停**：#1 Go 额度失败→fallback→#7 GPT 发现 k3 漏检的 ISO 缺陷→correction_sent→Root 修复＋回归→#9 resolved_ids→complete＋confirmed stop | controlled-fault healthy 自恢复，非卡点 positive |
| 35（0.7.35，task `22b36fa0`） | off_track .88→process #1；#2–#6 fallback 丢 kind **失败不改判**（成因→36 修复）；#7 host-stale→historical notice confirmed；Controller 收尾 stop_unconfirmed→37 修复同版 SDK 源码解释 | 特定搁浅 marker 场景未实机复现（gate 证据） |
| 37/regress37（0.7.36/37） | **过程 fallback 保通道**＋**非 stale 合法阻断 confirmed stop**：#1 Go process 额度失败→#2 K3 process/model_fallback 非 stale→needs_user（uchg 合法授权阻断）→stop confirmed true | Root 自身 Ask 停止路径 live；members 0 不改标 pair4 |
| W9（0.7.37 冻结配对） | 同质量双臂 **6/6＋20/20 全过**、保护 scope 双过：旗舰 observed calls **0 vs 7**（baseline GPT-6-Sol total 79,296/reasoning 390）；mixed 其他角色开销更高（root K3 total 470,394 等）；缺字段按 unknown/null 分列 | 单小任务；配置为冻结条件非自动选择宣称；`ROOT-W9-RESULT-REVIEW.json` |
| 单文件负例（0.7.37，`orbit-entry-negative-wvKE`） | **真实普通 entry 不启动**：付费 entry-3 execution 0.96 但两条价值路径 0.39/0.12<0.65→root_decides；无 task/hint/evidence/member/check；唯一拼写 byte 变化＋Root 真实验证回执；native exit | `ROOT-NEGATIVE-REVIEW.json`；launch PID 未留档已明示，退出依据 actual session_exit＋shell 现状 |

**2 项 `pending_final_docs_delivery`**：C07（本文档与其消费方状态同步）、F10（最终文档 checkpoint＋本地交付核验）——本票即其闭合动作；W10 相应保留至 Root 核验本 diff 并授权既有本地交付流程后完成。

## W1–W10

- **W1–W6**：有限 source/校准范围 verified（W1 含上述 installed 单文件负例实机原件；各未知按原样保留，不冒称全供应商/全域）。
- **W7–W8**：真实复合证据 pair4/033/35/37（各自运行身份分列）；**未测限制**＝非 stale process finding→correction→恢复组合、Root stage switch live（源码＋确定性过、自然分支未触发）。
- **W9**：原冻结配对已完成（两臂同验收全过＋资源分类汇总，见上表）。
- **W10**：本收口＋静态检查后待 Root 授权最终本地 commit/安装核验；不推送/发布。

## 明确未测限制（非 passed、非完工门）

Root-stage switch live 触发；非 stale process finding→correction_sent→恢复组合；37 自有 queued marker 的精确旧现场复现（gate 证据）；failed-unit 自动释放分支。以上为自然分支未出现，不构成“必须全部自然触发才完成”的门，也不得写成 passed。既有平台限制保留：park/dispose 完成无公开信号、devin hooks 实际不可用。**未知 cash/扣减不是新增缺口**（F01–F03/F09 边界原文有效）。

## 索引

原始要求：主方案 §1–§12；原 54 表与 0.7.10 初审：代码审计＋Git；逐项判定 JSON：Root 审计文件；各 run 原件目录：`/private/tmp/orbit-*`（handoff 指向）。
