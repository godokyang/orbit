# 本地检查宿主与快照归档验收（2026-10-11）

后续发布准备：用户明确授权源码升至0.8.5并提交/推送。以下受测0.8.4构建、dirty状态、digest、失败及已知限制均保留原事实，不重标为提交后0.8.5真实验收；日常安装不更新。

状态：两项修复已集成，冻结验收、独立核查、合同文档与资源收口完成；实际Goal于2026-10-11T07:43:39Z由工具确认complete。以下过程记录保留当时的失败和未完成状态，最终结果以文末为准。唯一[总 TODO / 冻结条件](../plan/local-host-snapshot-repair.md)。源码基线 25f0104／0.8.4，保留原三份修改文档与两份未跟踪研究；本轮不升版/提交/推送/发布/改日常安装，不处理 Zeen 存量或旧摘要异常。

## 实际无模型探针

Root 临时根 `/var/folders/fc/zfb6fxjn0h9dz1j1r0mpkcbw0000gn/T/orbit-host-storage-20261011-ogwxn983`，实际 compiled `/Users/yangke/.local/bin/omp` 18.8.0。用真实 `--trusted-extension`，独立进程组、隔离 agentDir、HOME 未改；不是产品 `orbit omp` 验收。

- `root-export-probe`：OS 禁网络下 api.pi 的 createAgentSession/discoverAuthStorage/ModelRegistry/AgentRegistry/SessionManager/isAuthenticated/Settings.isolated 及 pi-utils 的 getBaseConfigRoot/getModelDbPath/getProfileRootDir/resolveProfileEnv 全可解析。factory 内 process.exit(0) 被真实 HostGuard 拒绝，退出1；研究的直接退出假设撤回。
- `root-lifecycle-probe`：Controller 夹具遗漏 await discoverAuthStorage，创建失败；pending factory 无 keepalive 导致 eventloop drained。后续 signal 检查遭进程已结束的竞态，原失败保留；所属路径进程审计空。这不是产品代码失败。
- `root-lifecycle-probe-v2`：真实私有 restricted 会话创建、await dispose、最终记录写出后保持 factory pending（普通 CLI 会话不建立）；父进程 TERM，公开 postmortem.register 接到 sigterm，退出143，stderr空，归属进程为空。网络 OS 禁止。
- `root-lifecycle-probe-v3`：进一步禁止临时根之外的写入，发现 bootstrap 在 factory 前试图 mkdir ~/.omp/run/daemons/<项目hash>，EPERM退出1，无 factory receipt。不能由 factory 提前退出推断无启动副作用。
- `root-lifecycle-probe-v4`：用官方 PI_CONFIG_DIR 定向隔离 config-root（相对于原 HOME），不改 HOME；OS 禁网络且只允许本轮根写入。TERM 前私有会话已创建且未 dispose，TERM 后公开 cleanup await dispose 完成，退出143，stderr空，所属进程为空。目录包含隔离 profile 的 SQLite/terminal/custom-session 文件及隔离 config-root 的 extension cache；daemon presence 退出后已回收。未发送任何模型 prompt；receipt 中初始 `model_requests=0` 是夹具声明字段，不当作模型调用仪表计数，网络边界由 OS 实施。

由此采用公开信号生命周期候选：factory 完成/取消均由父监督进程收口，不取 guarded native exit 符号、不修改宿主；正常完成须有最终有效回执、私有会话 dispose 及父发出的完成 TERM 归属，取消与失败不能冒充正常。适配后仍需新临时安装的完整实测。

当前适配 entry（不是旧 v4 夹具）已实际跑通 probe_host、源 catalog/credential 可解析探针：zhipu-coding-plan/glm-5.3-flash、kimi-code/k3-256k、cursor/grok-4.7-fast。`adapted-permission-probe` OS 禁网络，17 个受限工具 case 全过；PNG 70 bytes，sha256 c414cd0e204de974f73753c7e28d7638e7b3691bb8b1a2bab6b25bb7fed7ce77，三次实际 read 回执一致，不声称模型渲染。PID49819，真实 wait exit143、组 ESRCH；最终 receipt sigterm/disposed。版本标注 launcher_omp_version，另记录实际 host_runtime_executable，不当作内部 SDK 独立版本测量。

初次临时安装：2026-10-11T06:24:15Z，dirty 源码25f0104、digest31ba8c98cdb6b82762a45c52b72bae1f0d1221145278c68bb493a4c8ee603cfd；实际 host factory 容量探针通过，无私有 SDK，仅 root 既有 zod 依赖。927 files，logical8,029,736／allocated10,514,432 bytes。对照未改日常 release logical916,611,544／allocated1,004,711,936；开发区原 ignored 私有树918,327,983 logical bytes 已保留。该构建随后有修正，不能作为最终真实矩阵受测构建。

独立 H 发现退出后 evidence 缺失/非法仍会把 receipts 写 collected，Root 已修为 failed/unknown、保留 workspace；版本来源明确标注并在探针核对 CLI 版本。K 独立核查继续。

## 已有测试基线

snapshot、OMP runner、CLI checker、export、install 五组 exit0，原件 baseline/tests.log；新增安装前置回归覆盖本地/远程/直接管理入口的缺失、不可执行、执行失败、旧版本与 help，确认无下载/无 release 准备。安装 fixture 的宿主能力返回是外部边界模拟，不替代真实 compiled 探针或产品验收。改写后的首次安装回归因 fixture 子进程遗漏 require open3 失败，修正夹具后出现 /var 与 /private realpath 断言差异并校正预期；最终安装全组通过，不记为产品能力探针失败。新增 host 回归也曾用不符合 coverage schema 的夹具，补齐有效 coverage 后通过；未放宽产品校验。

## 产品验收与资源

本轮产品矩阵已启动。冻结受测 v2：source25f0104 dirty／0.8.4，安装2026-10-11T06:36:29Z，content_digest c70f5b6028bf58a96ee35a0e1a1ff163a38d7860d144e90b00779c4983911ffc；release3468fbcc398178aab350d9ec。源码打包文件逐字节与该 release 对照无差异。`npm test` 全量 exit0（含34项 Bun 回归及新增7条以内高价值场景，不采用动态模型/体积固定断言）。独立 K 修正其长行截断造成的 Bun test 未接线误读；指出的版本检查 Timeout/capture 子进程泄漏已改为有界独立组 popen3/kill/join。H 复核归档、三门收尾与四处新安全接缝，未见阻断；代码核查不替代 live。

负例通过：pane w23:p1D，实际 Root PID61884／GLM5.3Flash，task85ac5da9-9211-42d7-9ad6-8ba22815df74。局部 slug 修复、项目内node三断言实际通过，execution=root、无 delegation_hint／无登记成员。检查1自动PID63615、检查2手动PID65148，真实 opencode-go/deepseek-v4.1-flash 独立进程，before/after fingerprint相同，sigterm清理／waitpid／组ESRCH／回执collected均有原件；二者 workspace_reclaim=reclaimed，归档和scope保留。2026-10-11T06:41前后 task complete、stop_confirmation.confirmed=true、runtime_pid=null；Ctrl+D后Root与MCP61924/61963及两checker PID均不存在。

负例历史 restore-check 1 从 archive 成功，export664,630 bytes／221 files／missing0；解包 workspace 的node测试独立运行exit0、不读取原对象目录。只在导出副本移除新sidecar构造旧完整目录格式，restore返回source=workspace、export662,697 bytes／217 files／missing0；原任务及Zeen完全未改。此项是离线格式兼容验证，非历史任务迁移。

真实缺失安装检查：对当前实际临时安装分别执行本地bootstrap、remote --ref main、直接manager，在PATH无OMP时全exit1＋中文缺失下一步；current、marker、wrapper字节不变，curl哨兵未触发，没有源码/依赖下载。help与卸载的最终缺OMP实际收口另行记录。

正例 pane w23:p1E／RootPID64811／K3-256k；存储演练复用空闲 p1D，fresh RootPID66437／GLM5.3Flash；均通过installed orbit omp，在独立Git夹具接收完整初始用户要求。正例推荐/交接/终检、存储重复小改动、失败/取消恢复与资源收口仍待验证。四个全新 Git 夹具已准备；固定 Root w23:p1、H/J/K w23:pH/pJ/pK 与 OMP PID12801/12883/12966、关联 MCP、主 Herdr、归属不明 w23:p16 保留。baseline 保存进程/pane/日常安装/Git dirty 与 untracked 备份。详细本轮资源登记在临时根 resources.json；最终收口时吸收必要原件。开发成员当前供应商 token/费用/额度未知，不把 UI 估算当账单。

## 后续真实校准与进展（仍在验收）

旧正例 af2990c5… 的选择是 facts_only，原生成员虽登记，但 Root 错误声明仅 bash/test 入口导致读写拒绝；Controller 原生 Esc，task paused、Root 与成员 confirmed stop，随后 Ctrl+D 确认原 Root/MCP 退出。不能计作推荐/交付通过。存储首演练 705429f4… 在途没有任何 check_started/scope，人工 Esc 后 confirmed stop；不是两轮检查通过。Cursor Grok Root 的 storage-v2 / failure 场景持续重新获取工具，没有形成有效检查，也记录中断退出。failure-v2 使用 eval/judge 而未启动 Orbit，不能作为产品检查；完整要求在新进程重试。均未修改产品源码或抹掉原件。

为推荐正例前提，2026-10-11T07:05Z 用 ego-browser 实际重读 [DeepSeek 作者发布页](https://api-docs.deepseek.com/news/news260910/) 与 [原始基准图](https://api-docs.deepseek.com/img/v4.1_260910_benchmark_table_en.png)，并核对 [OpenCode Go 的型号供应](https://opencode.ai/go)。V4.1-Flash 的 DeepSWE v1.1=74.2；仅通过当前 API 写入临时 acceptance-cache，四键为 opencode-go/deepseek-v4.1-flash/unknown/subscription_quota，有效一天。basis 明示模型级作者基准，OMP 路由/推理变体未独立跑同一基准；测量日期未知，价格/配额未知，不提交速度或 local_samples，不刷新旧 TTL、不改全局缓存。K 用原图 OCR 和当前校验器独立核实数值、身份与限制。

新正例 positive-v2 task9aea0d98…：真实 hint 652a12a3…、unit wu-4fdb7d551a77c9a1、decision4/input2 与 Jev1.13.0 及放行 profile 绑定，首选 DeepSeek recommended。原生成员 orbit-1c8de33f… 在07:10:10登记、随后 model identity 与工作开始，07:11:22 native_task 结果返回；Root 实际整合 CLI/测试/README、全量验证、accepted。初次独立检查发现 F-header-shape：三字段的带引号逗号表头经 join 错误匹配四列合同，Root 已自主按 finding 修正并加回归，正在复验。尚未计为整个正例通过。

存储项目 storage-v3：A task96dadc27…、只读 repeat task92f92422… 各完成一次真实手动检查和 confirmed stop。对象库两次均4个对象、3,520,329 logical/3,534,848 allocated bytes，重复增量0；大文件唯一内容3,520,000 bytes。H 独立观察 A 在途完整 workspace，Controller 被动采样 repeat 记录源/快照 inode 不同且 SHA-256 相同；二者 waitpid/ESRCH/collected + archive verified 后 workspace 均回收。A restore-check 从 archive 成功，export364,991 bytes/114 files/missing0。小改动第三任务正在同项目的新 Root 中运行，后续记录其真实增量及旧历史仍可恢复。

在途取消：failure-v3 初始默认选择后实际检查改用 DeepSeek，不当作 Zenmux 失败。第1检查提示补程序验证证据，Root 自主补齐后请求第2检查。Controller 观察真实 checker PID89401存活、独立workspace、in_flight、无生命周期marker、Root TUI idle，在07:14:01通过原生 Ctrl+D 退出。task paused/confirmed stop/runtime_pid空；checker session_created/disposed、sigterm、3次真实调用回执，lifecycle reaped=true/group_probe=esrch/receipts=collected，归档三门均成立后 workspace回收，Root85500/checker89401不存在。取消的check2按scope/run/回执与usage.interrupted_checks归属，不冒充正常check_finished。provider失败路径另由新的显式选模 failure-v4 验证。

最终工具检查：npm pack --dry-run exit0，压缩501,685 bytes/源码包1,894,344 bytes，无 docs、私有 node_modules 或 bun.lock；git diff --check exit0。Skill validator 首次因系统 Python 缺 PyYAML 未能运行，改用本轮所属临时venv＋PyYAML6.0.3后 exit0／Skill is valid；不改系统 Python。资源和文档收口仍进行中，Goal active。


## 最终真实矩阵（冻结 v2，2026-10-11）

必要原件保存在 [本轮证据目录](evidence/local-host-snapshot-repair-20261011/)，不依赖清理后的临时根。构建身份见 `tested-build-v2.json`、`source-build-comparison.json`、`final-frozen-source-comparison.json`：源 HEAD 25f0104b70d68c7c47b43473f1b75d928d2222db、实际 dirty 工作状态、版本0.8.4，release3468fbcc398178aab350d9ec，digest c70f5b6028bf58a96ee35a0e1a1ff163a38d7860d144e90b00779c4983911ffc；所有打包源码和受测 release 逐字节相同，最终11个关键文件冻结摘要无变化。后续只改交接/验收文档，docs 不进入产品包。没有拿旧安装优化的测试充当本轮通过。

| 冻结项 | 本轮实际结果与边界 |
| --- | --- |
| 安装入口 | 实际当前临时安装下，本地 shell、remote --ref main、直接 manager 的缺 OMP 均中文拒绝，旧 current/marker/wrapper 不变、curl 未执行；不可执行、无法正常运行、旧版本分支有已有/新增回归；实际本地18.8.0 factory能力探针通过后才切换。缺 OMP 的 help 和 uninstall 均 exit0，临时安装已正常卸载。最后验证夹具第一次漏放 /bin/sh 导致 shebang exit127，补已有 sh 后重试，不改产品。其他 OMP 版本/平台未作实际认证。 |
| 本地检查与边界 | 无模型的 compiled 导出/加载/副作用/生命周期探针先行，适配后的受限 read/grep/glob 17/17，PNG原始70 bytes/摘要三回一致；真实检查分别运行 DeepSeek、Zenmux、GLM，记录 requested/actual model 和实际源认证，独立 private registry/profile，正常 TERM/143/dispose 与取消证据具备。不声称模型视觉理解或全部供应商已认证。 |
| 必要负例 | negative 的局部修改由 Root 执行，零委派建议/成员，两次真实检查、相同快照指纹，complete + confirmed stop。 |
| 推荐协作正例 | positive-v2 task9aea0d98…：Jev与真实 hint652a12a3…/unitwu-4fdb7d551a77c9a1 同代绑定，DeepSeek 推荐首选、先持久登记再模型工作、native task/hub返回，Root 整合实际14项测试；check1 finding F-header-shape、Root按合同修正，check2 resolved、findings0/coverage通过，Root和成员 confirmed stop。导出副本不读原对象库，14项 Node 测试实际 exit0。早先 facts_only/错误工具范围及工具获取失败的校准不是通过；原件保留。 |
| 正常与失败/取消收尾 | 正常路径 waitpid、整组 ESRCH、有效回执收集后回收。process-failure task1730d605… 的真实 checker1532 在实际 provider invocation 已开始后由 Controller 对已核对归属的独立组 SIGKILL；程序 check_failed 回执为 exit signal9，usage unknown/pending、桶总数 null，不补零；归档已验证、真实 reap/ESRCH/回执collected后回收。随后程序自动换到GLM，该在途检查由原生 Ctrl+D 取消，paused/confirmed stop，未完成后备裁决。failure-v3 第二检查亦真实在途 Ctrl+D，sigterm/dispose、usage.interrupted_checks保留、三门后回收。不把这些取消称 provider 错误或正常check_finished。 |
| 去重与小改动 | storage-v3 A/repeat/C 三个真实新 Root/任务在同一 Git 项目各完成检查和 confirmed stop。A/repeat 均4对象、3,520,329 logical/3,534,848 allocated bytes，重复增量0；C 仅 notes.txt 79→102 bytes，对象库变5对象、3,520,431 logical/3,538,944 allocated bytes，即新增102逻辑bytes/4KiB分配，3,520,000-byte大文件只存一份。被动采样确认在途完整workspace与源 inode 不同、SHA相同；三次workspace均在三门完成后回收。C Root 等待时曾调用一次 status，记录这项协议纪律偏离，不拿它证明纯事件等待。 |
| 异常保留 | archive-failure task85336501… 启动前在自有项目放置对象库父目录符号链接，真实归档拒绝，外部目标始终空。两次检查仍读独立完整workspace，其他生命周期门全真而 archive=false，两份workspace均产品保留。check1指出Root未报告异常，Root补报后check2 resolved，complete/confirmed stop；该终态未触发删除。官方export missing0，并从保留workspace恢复成功；整体测试夹具清理前已把两份完整历史保存进自包含export。内容异常/未知reap/坏回执的保留分支有高价值回归，启动/停止重试恢复的保守归属有独立代码核查；未把PID缺失当reap。 |
| 历史恢复与导出 | C之后恢复A仍79 bytes、恢复C为102 bytes，大文件摘要一致，恢复inode独立；负例、A/repeat/C导出missing0，负例旧完整目录副本读取/导出兼容通过。取消check2及受控失败check1均 archive恢复成功。正例、失败/取消导出仍如实列出协作/会话材料缺口，完整历史workspace可由证据包独立读取，无需原项目对象库；不是承诺导出所有原生记录。 |

实测失败干预未改产品源码：进程故障 Controller 的 `actual_reported_calls_before_fault=1` 字段名不准确，它实际统计一条已观测 pending invocation receipt，未有模型回答完成；`controller-receipt-erratum.json` 保留更正，原干预和程序回执不改。信号9由 runner 的实际 Process::Status 生成失败字符串，未另存数值 termsig 字段。process-failure 的第二检查和取消正例的观察项仍 `in_flight`，结束事实取 interrupted_checks、生命周期/回收和停止确认；现行合同已定义下一运行的 abandoned恢复，不用该旧观察标签断言进程仍活着。没有给本轮增加日志协议改造。

失败/取消回执不等于供应商拒绝：实际单一 Zenmux 池 failure-v5 task35ca2471… 的检查真实成功，不能根据旧猜测称402。控制器故障是已声明的归属SIGKILL，受测Root要求中的“不切换模型”未阻止程序既有自动fallback；此行为和显式start覆盖问题如实列为当前限制，不称同一路由重试通过。

## 独立核查与工程验证

相关五组既有测试先跑；实现完成后全量 npm test exit0（Bun34项、Ruby现有及本轮少量回归），pack/skill/diff检查通过。新增测试聚焦安装保留/无下载、宿主完成与取消、归档去重与异常留存、独立恢复及自包含导出、运行安全门；不固定实时供应商事实/体积为单测。探针失败、夹具错误、Python缺PyYAML和独立H shell进程替换300秒超时均留原件，后者以直接Python重新核算11/11冻结源码摘要通过，未改产品。

固定H/J/K经Herdr核对真实身份与目录后作实质独立核查。H发现坏/缺回执错误标collected、K发现版本探测子进程Timeout泄漏，Root已在冻结v2之前修正并重新构建、全测、实测；J检查实际对象/源/恢复inode、失败/取消归属和异常workspace。K独立核验正例hint→登记→实际native结果→finding修正→终检→停止原件，以及宿主权限、实际用量未知和Controller更正。开发回报不当成产品运行结果。原件见 `independent-review/`，本轮不调用Codex内部subagent，不重建固定成员进程。

## 当前限制与未扩修项

- 实際宿主兼容认证限当前macOS/OMP18.8.0。最低版本18.2.8保留，但任何版本都须通过真实能力探针；未知接口不自动升级或下载私有SDK。普通OMP不加载Orbit，临时安装入口检查见 `plain-omp-installation-passivity.json`。
- 既有显式start选模未持续钉入后续选择：failure-v4 start记录Zenmux显式来源，实际reviewer却重新选择DeepSeek；runner严格使用当次请求型号。建议另行修正CLI记录/selector的显式绑定与失效规则，未获本轮额外修复授权，未改该层。
- positive-v2 export missing2：一条非本任务/不可解析/追加中协作行只计遗漏，成员native session transcript不能与成员session身份核验，未拷贝。受控失败、取消各missing1是协作子集缺口；均由manifest保留，不能声称整个任务记录毫无缺失。新历史工作区导出和恢复已通过，不扩修旧会话归属逻辑。
- Zeen存量、状态和证据未改；309份旧完整副本及181摘要不符/1缺失的成因仍未确认，不宣称修复或用其清理作验收。

## 体积、资源与收口

冻结临时release实际956 files、8,040,804 logical/10,645,504 allocated bytes（约7.67MiB/10.15MiB），不含私有SDK。保留日常release仍916,611,544 logical/1,004,711,936 allocated bytes，source5e781e44…/digest82ba262f…/0.8.4/2026-10-11T04:00:49Z身份字段与启动基线相同；没有应用本轮源码。开发区原 ignored 私有树仍保留，本轮只删除发行依赖声明和锁文件，不清用户已有目录。

产品任务ledger实际记录326调用：Jev73、Root169、执行成员23、检查者61；各原始token类别分别汇总于 `actual-resource-summary.json`，不跨 input/cache/reasoning/total类别相加。SIGKILL和中断调用用量未知，失败前校准和非Orbit Python judge亦有缺口；费用、现金/订阅实际扣减和固定开发成员用量未知，不把UI估算当账单、不新增硬预算。该数值为记录到的产品调用，不是本轮所有开发/控制器资源总成本。

资源收口记录见 `pre-directory-cleanup-audit.json`、`pane-cleanup.json`、`missing-omp-real/help-uninstall-result.json`：14个实际产品任务均已confirmed stop/runtime_pid=null，完成与人工暂停分别保留；测试Root、MCP、独立checker及自开observer/故障Controller实际退出后，仅关闭三个本轮pane。临时安装在无OMP PATH中公开uninstall exit0；原始失败归档workspace由官方export留证后才回收整个测试夹具。K的两个临时验证目录和OCR脚本已清，固定OMP12801/12883/12966和关联MCP、Root/mainHerdr、归属不明资源均保留。自开浏览器space13已finish；14个control目录、三处已确认探针presence、已登记session-agent根均不存在。其他session-agent根归属未建立，保留。

卸载后本轮临时根尚占1,804,207,807 logical/1,815,461,888 allocated bytes，包含隔离Git夹具Node副本、探针和临时校验venv，不是峰值采样；必要原件已留仓，所属临时根已删除且所属进程为空；清理事实和Goal完成回执见 `final-cleanup.json` / `goal-complete.json`。固定资源不会因该数值被清理。

最终收口：2026-10-11T07:42:22Z，本轮临时根实际不存在、归属进程审计空；9份export副本逐字节与原件相同后留仓。固定三OMP及MCP的PID集合/各shell与基线相同，日常安装4个已捕获身份字段相同。工程HEAD仍25f0104、两份原未跟踪研究摘要未变、原dirty差异原件已备份，check-result schema与ADR-009未变。所有冻结门已完成，Goal由实际工具记录收尾，不把文档勾选当工具状态。

实际Goal最终回执：complete，createdAt1791698221／updatedAt1791704619，计数1,226,664 tokens、6,397秒（106分37秒），无token预算；这是工具执行计数，非模型账单或现金成本。原件见 [goal-complete.json](evidence/local-host-snapshot-repair-20261011/goal-complete.json)。
