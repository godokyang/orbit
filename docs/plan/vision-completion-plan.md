# Orbit 当前执行计划

最后核对：2026-10-01（installed 0.7.33；1d59231e 已终态 complete＋confirmed stop；stuck/off_track 正向仍未证）。方向以[主方案](mixed-model-delivery-proposal.md)为准，每项实现／调整／删除对应[代码审计](mixed-model-delivery-code-audit.md)。精确版本、当前 diff、执行者、原始证据和现场资源统一见[当前交接](handoff.md)，不在本页复制另一份状态快照。

## 同次完整交付

用户已授权以 Goal 模式完整实现及真实验收，不设硬预算，不推送或发布。Codex 编排与审核，复用用户授权的 Herdr OMP 执行者。当前 Goal **未完成**；迁移会话不清零进度、负例或剩余要求。

`orbit omp` 是启动方式。普通业务请求的自主协作是核心要求；内部 `explicit_orbit` 分类不是用户另需执行的启动步骤。不得把明确要求交接的测试说成普通需求自主派发。

## 冻结完成条件

- [ ] W1：入口以执行授权及委派／监督任一路径判断；审计交付、续办归属、拒绝和失败恢复有据，题义与放行记录版本一致。
- [ ] W2：成员与检查者消费任务相关、无时间信号的能力事实；agentic-only、intelligence、上下文／模态、真实路由、冲突和日期未知资格明确。
- [ ] W3：池内、旧无目录、检查者、补证、状态／CLI 和文档全部退出旧时间与粗档费用选型；运行计时、缓存与停止控制保留。
- [ ] W4：明确工作单元与实际派发绑定，原始要求、范围、依赖、验证及升级条件可追溯；串行与自主派发路径不增加用户逐次确认。
- [ ] W5：真实路由价格／额度规则与可得用量按调用、任务、角色及实际身份关联；缺失保持未知，失败和判断用量不漏计，不新增硬预算门。
- [ ] W6：新判断经过代表性真实任务、失败和缺证样本校准，实际型号与问题／输入／决策版本绑定；历史分数不迁成新判断。
- [ ] W7：分层检查与当前要求覆盖闭合，实际工具范围与独立只读生效，必要升级保留此前结果与消耗；最终门及停止不退化。
- [ ] W8：冻结安装构建的真实自主派发、回收、集成、finding 纠偏、手动终检与停止完成；开发者辅助动作不冒充被测 Root 行为。
- [ ] W9：同等验收下比较交付、顶级资源、其他消耗、缺陷与介入；有范围地报告效果，不能以推荐次数或历史不同任务宣称节省。
- [ ] W10：相关检查、完整回归、打包和证据核对完成；文档同步、必要收尾及本地提交完成；不推送或发布后才更新 Goal complete。

## 当前关键状态

- **installed 0.7.31（历史）**（`cfc18a44`、digest `d8cec5dd…`、release `ee215c95`、83 pack 0 mismatch、full 278s exit 0）。**031 fresh 验收**：新职责提醒实际送达且 Root 作出真实简短核验（边界探针＋测试复跑），但 **C1 仍 FAIL（连续第六代 K3-root 漏 U+0085；prompt 存在≠质量）**；零 findings ⇒ 选型仍 UNEXERCISED；8 writes 全带 content（单样本不断言因果）。观察窗口 0.7.32＋历史提示 0.7.33 已安装；**033 controlled-fault healthy self-recovery complete＋confirmed stop**（0 process/0 historical notice；GPT #7 发现真实缺陷＝强模型检查价值）——**stuck 正向链＋off_track 全链仍缺，下一核心＝自然场景真实触发＋必要阶段介入＋同质量收益＋54 W1-W10**。
- **installed 0.7.30（历史）**（`20f3cb79`、digest `156f3faa…`、release `96a20bca`、83 pack 内容哈希核验 0 mismatch、install exit 0）。程序 integration 选型（tagged-send 接缝）**已安装、live 未测**：030-r1 在 prerequisites 满足前被 Controller Esc 中断（诊断边界：jsonl＝已解析记录非 wire；未发现 Orbit Main 工具桥删改 content；028/029 证明同模型 write 能力与 edit 自纠先例）。**030-r2 机械链完整通过一次（complete＋confirmed stop）——质量非全验收 PASS（C1 FAIL）**：9 次 no-content write（7 业务 artifact＋2 xd://orbit）未中断；核心/CLI 由 bash heredoc 落地、4 次 edit 3 成功为修正既有内容（不称 edit 初始实现证明）；零 findings ⇒ 程序选型 UNEXERCISED（tagged send 执行、选型分支正确 no-op）；外评 8/8＋6/6 matched＋C1 FAIL（连续第五代 K3-root 漏 U+0085）。**已实现（source 0.7.31，Root 已审）**：runtime 既有 manual-ready 提醒正文加入先 full-spec/risk 可执行验证再请求 manual final 的职责句，与换型成功解耦（无 finding/同型/失败职责不变）；host 仅成功来源句去重；selection 逻辑/guards/phase/trace 零变化。组合验证 full 278s exit 0、check/pack/skill 全 0（原件 `/private/tmp/orbit-integration-rider-031/`）——已提交安装（`cfc18a44`）；031 fresh 显示职责送达＋真实核验发生但 C1 未闭合，质量效果与选型触发仍待后续自然轮次。
- **installed 0.7.29（历史）**（`b863b3fd`、digest `48e45af1…`、release `da41d4ab`、83 pack 字节一致、组合验证 exit 0——原件 `final-v029`）。0.7.27 隔离 checker 自动 SDK retry 关闭（`SDK.retry.enabled=false` 为实际 checker 路径设置，真实 provider 失败保留为有界样本）；0.7.28 root-model 工具确定性通过但 **live 未触发**（028 轮 24 root calls 全 K3/root_execution、selection=0）；028 质量负例中 **#6/#12/#13 旗舰 GPT checker 亦漏 C1**——程序 integration 选型动机成立而非低型号 checker 归因；**0.7.29 full/install 正确但其旧接缝（before_agent_start 自动 consider）经 SDK 源码证明不可达**，029 partial（paused＋native confirmed stop，非完整对照轮）未 exercise。**source 0.7.30（full 已过）＝tagged send（发送终检提醒之前）＋单一同步 fresh state authority**，局部 gate/runtime exit 0；组合验证原件 `final-v030`（full exit 0、03:30:36Z→03:35:16Z 280s，check:version/pack/skill/diff-check exit 0）——**source 0.7.30 已提交安装，待真实选型证明**。现场：S last UI=1311 套餐未开放 GLM5.3FlashX；R stopped 且 Tool not available（无原始回执，不泛称 provider 工具坏）；Q 可用。
- **安装 0.7.26（历史）**（commit `b7401a2`、dirty false、digest `2314ec03…`、installed_at `19:59:55Z`、单次 exit 0；83 pack 对 release 字节全一致；installed loader accepted:6）。本版仅两处最小修复：Go subscription 映射 verified_by 短标签（修前 loader 5→6，四键未动）＋host.mjs work-unit 类型 help 文案（只描述，不改校验）；限定理由移存 mapping-audit。组合验证：full 前台 wrapper 权威 exit 0＋check:version/pack/validator/diff-check exit 0；178＋83 对 tested-pre（升版后冻结）逐文件一致，两段 freeze 边界如实（metadata-corrections 已记 pass_markers 227→127 等勘误）。**回归通过≠新真实验收或收益证明；.25 的 pair4 试验身份不写成 .26 跑的；新 Go 映射不是费用/专属 route 质量证明**。上一版 0.7.25（pair4 试验构建）为历史。
- **原生指令冲突已确认（源码规则分支与 shape／config 探针证据，非 wire 证据）**：OMP 18.3.4 对 `revision >= 6` 给 `delegation-bias restrained`，`system-prompt.ts` 据此渲染 inline-first（「NEVER delegate one slice」「2+ independent slices」），与主方案 §5.2 的串行接力冲突，并已按同层政策修复（见下）；**这是源码规则分支与 shape／config 探针证据**（`/private/tmp/omp-delegation-bias-investigation.json`），实际请求体未落盘，既不能据此推定旧两轮 `members=0` 的因果，也不宣称服务器收到或模型遵循。
- 最小真实 Jev API HTTP 200。随后 installed21 明确交接任务 `26935a3e` 的实际成员实现、Root 固定测试、独立终检和停止确认已闭合。隔离单候选池、明确交接，**普通自主派发与资源收益仍未验收**。
- 启动接缝修复已在 installed 0.7.23 生效并有普通请求实测：任务 `01f4925b-84e2-4560-9a26-20cf1bb5294b`（fixture `/private/tmp/orbit-ordinary-phone-1XOIXp`，seed `f59f7d0b…`，请求原文不提 Orbit，真实全池）入口 `uncertain → start`（jev-1.13.0）、首个载荷带 bootstrap、首次编辑前单元 `none`、Root 自行实施、检查 3 次（1 次 Go 429 失败／2、3 由 k3 完成、findings 0）、外部 copy 固定 9 例 exit 0、`complete`＋`confirmed stop`。**成员=0：只证明入口与自行实施路径，不证明自主委派。**
- 未知／不可比成本下最大质量概率优先的推强模型风险已按决策消除并随 installed 0.7.23 生效：过门后无可比资源证据时保留稳定池序（不称便宜／可靠），decision-3 放行已重签。普通任务 `01f4925b` **有匹配放行与真实付费判断**（2 次 `jev_checker_selection` `answered`，`judgment_model jev-1.13.0`），但**无候选过 0.6 门**（唯一有分候选 0.55），故当时降级池序；**pair3 本次 selection 已触发该正向排序并直接核对**（state `member_selections[wu-56f0622023bf4fa6]`：released `orbit-quality-decision-3`、门 0.65；index1 K3 0.66 与 index4 Zen 0.70 过门，`first` 仍 K3／backup Zen，`cost_comparison: unknown`、basis `released_task_fit`）；**phone／pair2 未触发**；真实 hint 采纳在 phone/pair2/pair3 各自该轮未证；pair4 已证采纳→派发→交付机械链（见 pair4 行），资源收益仍未证。最小链资源后验（36 调用全 reported、billing／account unknown）只汇总账本、不证明收益
- **pair2 mixed 臂该轮已完成**（`w1Y:p26`，installed 0.7.23；任务 `d623e8b1` `created_at 14:35:19Z`、终态 `complete`＋`stop_confirmation.confirmed`，终态链 `finalization_notice`→`completed_via_finalized_stop`→`stopped`；原生 `/exit` 已执行，pid 27206／27262／27322 实测消失，pane 回 shell）。入口 delegation 0.83 支持 start、bootstrap `via: provider_payload` 已记录；但 `members=0`、无工作单元/派发，**不构成自主派发证明，也不作收益结论**（账本 judgment 10／root 19／checker k3 6／checker Go 1 unknown）。baseline 臂未启动、资源对照未做；Q 外部副本验证已完成（固定 8 tests 8/8、冻结 6 probes 6/6，各一次 exit 0，评估记录 14:59:13Z），**不改 `members=0` 负例**。
- **pair3 mixed 臂已终态（complete＋confirmed stop，非成功成员交付）**：任务 `b91fe4de` 终态与进程退出详见 handoff；实际链＝自主声明→首 selection 服务失败（Net::OpenTimeout）→无 hint 首派 429 真实失败→same-unit 重派被 bound 挡（Seam A/B 两断点，已随 0.7.25 修复实施）→decision-3 真实触发（首次 15:46:30Z K3 .66/Zen .67；state.latest 为 15:49:51Z 时点 judgment K3 .66/Zen .70）但 v2 hint 无采纳——hint 后无实际派发；v1/v2 阻断另由源码确定（Seam A/B 断点与修复保留）→Root 自行实现→checks（#1 Go 失败保留/#2 K3 complete）→外部 8+6 各一次 exit 0。资源 57 调用、root 32＋checker K3 3 有 account 关联、20 Jev＋2 Go 未知分列（不泛称全部 account 未知）。
- **pair4 两臂终态（试验于 0.7.25）**：mixed 全链真实——同代 v2 hint（sig 1eea74bb…）→native K3 派发→注册先于模型工作→bound dispatch 含 hint_signature/message_id→followed/basis=orbit_hint→member completed/accepted_at→Root 集成（8/0×2＋smoke）→manual final（只读、coverage 5/0）→complete＋confirmed stop 17:02:54Z＋原生 exit；**B 未触发不冒称**。baseline plain 13 回执 final 17:23:54Z＋外评 8/6 exit 0＋原生 exit。对照：旗舰 612078 vs 260831 totalTokens（+134.665%，分类数字见 paired-comparison+correction）；**负结论不重标：质量无可检出差异、该任务未证明节省**；account 41 known/16 unknown、cash/扣减未知分列。
- 0.7.20 配对 mixed members=0、Top 总量约 +30%，负例保留；不因源代码已修或新最小链成功改判。

## 下一动作

1. 新 Root 核对交接、live diff／installed identity／Herdr；保留成功、失败及未完成证据。minchain21 当前 PID 已不存在，本轮未执行 kill（进程表不证明退出原因），无空闲自有测试进程需收尾。
2. 0.7.30 已提交安装（`20f3cb79`）；030 首轮 fresh 为 Controller 中断 partial（原件见交接），下一轮放行已证自纠窗口后重试真实 live 验证（程序选型需自然 resolved finding＋reminder 边界，不人为制造）。SDK 18.3.4 不升级。历史 0.7.26 的安装与组合验证原件保留在其目录。安装不称完整验收。
旧 0.7.30 轮已终结（历史）；当前 1d59231e 已终态 complete＋confirmed stop；卡点/跑偏正向仍未证，不重复权限样本。
4. 完整闭合质量充分后分派、旗舰必要升级、路由成本／用量、错误控制、独立纠正、手动终检和实际停止；普通监督价值任务与其他主方案必要分支不丢弃。
5. 核心通过后作冻结同质量 Top／混合对照，统计全部角色和实际未知量，按主方案 §11.3 调整负收益路径；逐项闭合 W1—W10 后才 complete。

更早版本与运行的事实按[本次验收](../reference/mixed-model-real-acceptance-20260929.md)、交接中的原始目录及 Git 查阅。历史失败不改标，未校准正向推荐不放行，未知成本不伪装为零，不新增时间选型、硬预算或全型号可靠性证明要求。
