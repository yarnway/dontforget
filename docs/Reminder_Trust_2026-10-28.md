# 提醒可信度与任务信息一致性：本轮交付记录

日期：2026-10-28（Asia/Shanghai）。工具链：Flutter 3.44.9 / Dart 3.12.2。

## 行为与边界

- 复用现有 NotificationPayload、notification journal、DataGeneration、RuntimeRecoveryGate 及 occurrence 操作；不创建第二个 DatabaseHelper，不新增数据库迁移。工作区实际 schemaVersion 为 16，保持现值。
- 系统通知支持完成、延后及周期跳过。Android 标准模板最多三个动作，经用户确认：周期通知使用 `complete / snooze_15 / skip_occurrence`，非周期使用 `complete / snooze_15 / snooze_60`；应用内仍可延后 1 小时。iOS/macOS 周期类别保留四项。默认正文点击继续导航。
- 动作在主 isolate 写事务内复验 datasetEpoch、trigger、noticeRevision；以 occurrence identity + actionId 去重。后台 isolate 只写受限队列并向运行中的主 isolate 发信号；终止后等待正常启动、StorageBootstrap、remindersProvider.ready 与恢复 gate 就绪。原子文件队列最多 32 条/128 KiB；处理成功或失效后逐条删除，提交后的 revision 阻止崩溃重放。
- 延后从动作时刻计算，目标已过时设为处理时刻后至少 1 分钟；保留 eventTime 和周期锚点。通知取消/重排失败继续由原 journal 记录待修复。
- 语言同步重新注册类别并使用现有通知排程。初始化期间切语言、注册失败后同语言重试、恢复期间暂停语言重排均有回归覆盖。
- 通知自检按证据显示权限、系统待安排数、待修复数和当前 journal 保留的最近失败时间；读取失败显示“暂不可用”。测试通知使用保留 native id 0、5 秒目标时刻和独立测试 payload，不写业务表或 journal，不进入业务路由；重复提交先取消，结果仅称“已提交系统”。
- 任务卡展示项目、前三个标签及 `+N`、清单进度。普通任务展开勾选复用 setChecklistItem。详情编辑项目、标签及清单增删/排序/勾选，复用 editTaskDetails 和未保存拦截。旧 sub_tasks 标为微习惯只读保留；特殊任务不提供通用清单编辑器。

## 修改文件清单

本表仅包含本轮文件，不包含并发药物/规划改动及已有架构文档、图源、编辑器配置。

| 文件 | 用途 |
| --- | --- |
| `android/app/src/main/AndroidManifest.xml` | 现有原生通道/回调及兼容调用 |
| `benchmark/native_notification_failure.dart` | 现有原生通道/回调及兼容调用 |
| `docs/Changelog.md` | 用户说明与变更记录 |
| `docs/User_Guide.md` | 用户说明与变更记录 |
| `ios/Runner/AppDelegate.swift` | 现有原生通道/回调及兼容调用 |
| `lib/app.dart` | 通知动作、自检、代次及启动接入 |
| `lib/data/database_helper.dart` | 通知动作、自检、代次及启动接入 |
| `lib/l10n/app_localizations.dart` | 中英日文案与本地化入口 |
| `lib/l10n/notification_diagnostics_strings.dart` | 中英日文案与本地化入口 |
| `lib/l10n/task_consistency_strings.dart` | 中英日文案与本地化入口 |
| `lib/providers/providers.dart` | 通知动作、自检、代次及启动接入 |
| `lib/services/macos_notification_scheduler.dart` | 通知动作、自检、代次及启动接入 |
| `lib/services/notification_action_presentation.dart` | 通知动作、自检、代次及启动接入 |
| `lib/services/notification_diagnostics_service.dart` | 通知动作、自检、代次及启动接入 |
| `lib/services/notification_route_service.dart` | 通知动作、自检、代次及启动接入 |
| `lib/services/notification_service.dart` | 通知动作、自检、代次及启动接入 |
| `lib/services/pending_notification_actions.dart` | 通知动作、自检、代次及启动接入 |
| `lib/ui/screens/settings_screen.dart` | 通知动作、自检、代次及启动接入 |
| `lib/ui/screens/task_detail_screen.dart` | 任务信息展示与详情编辑 |
| `lib/ui/widgets/notification_diagnostics_panel.dart` | 通知动作、自检、代次及启动接入 |
| `lib/ui/widgets/task_card.dart` | 任务信息展示与详情编辑 |
| `lib/ui/widgets/task_metadata_editor.dart` | 任务信息展示与详情编辑 |
| `macos/Runner/MainFlutterWindow.swift` | 现有原生通道/回调及兼容调用 |
| `test/backup_preview_screen_test.dart` | 沿用 fake/temp，显式完成或注入新增读取/语言注册 |
| `test/end_to_end_test.dart` | 沿用 fake/temp，显式完成或注入新增读取/语言注册 |
| `test/notification_action_app_test.dart` | 新增动作/自检/任务回归 |
| `test/notification_action_bridge_test.dart` | 新增动作/自检/任务回归 |
| `test/notification_actions_test.dart` | 新增动作/自检/任务回归 |
| `test/notification_diagnostics_test.dart` | 新增动作/自检/任务回归 |
| `test/notification_language_reconciliation_test.dart` | 新增动作/自检/任务回归 |
| `test/pending_notification_actions_test.dart` | 新增动作/自检/任务回归 |
| `test/recovery_app_flow_test.dart` | 沿用 fake/temp，显式完成或注入新增读取/语言注册 |
| `test/settings_lifecycle_test.dart` | 沿用 fake/temp，显式完成或注入新增读取/语言注册 |
| `test/settings_reliability_test.dart` | 沿用 fake/temp，显式完成或注入新增读取/语言注册 |
| `test/task_board_keyboard_test.dart` | 沿用 fake/temp，显式完成或注入新增读取/语言注册 |
| `test/task_consistency_test.dart` | 新增动作/自检/任务回归 |
| `test/widget_test.dart` | 沿用 fake/temp，显式完成或注入新增读取/语言注册 |

本交付记录自身：`docs/Reminder_Trust_2026-10-28.md`。

## 自动化验证

- `flutter analyze --no-pub`：0 issues。
- 七个新增测试文件覆盖 65 项：动作业务/过期/重复/失败清理、队列并发与重启、平台桥接、应用 readiness/恢复/反馈、语言重注册、自检、卡片/详情与三语窄屏大字体。
- `flutter test --no-pub --reporter expanded`：1728 项全部通过（56 秒）。
- `python3 -m unittest discover -s scripts/tests -v`：126 项通过。本轮未修改脚本；额外执行已有脚本回归。首次受 sandbox 的 Swift module cache 写入限制，获得工具权限后相同命令通过。
- `git diff --check`：通过。
- Swift 两个修改入口通过 `swiftc -frontend -parse`，Android manifest 通过 XML 解析。这只证明语法解析，不代表原生编译、签名或设备验收。

## 待人工设备验收

1. macOS / iOS / Android 分别在前台、后台和终止后触发通知动作；终止态检查下次启动才更新业务数据，重复回调仅生效一次。核对 Android 周期三动作与 iOS/macOS 四动作实际可见。
2. 非周期完成；周期完成/跳过推进；15 分钟及 1 小时延后保留 eventTime/周期锚点。延迟启动后目标至少晚于处理时刻 1 分钟。
3. 编辑提醒、删除任务、恢复数据后操作旧通知，确认均被丢弃；取消/重排失败后在通知修复页重试。
4. 中英日切换后核对未来通知动作标题；初始化期间切换、系统注册失败后重试与恢复后的语言也需原生复查。已保留的旧横幅可能保持旧文字，可关闭旧横幅。
5. 自检在权限允许/拒绝、专注模式、系统调度限制下读数真实；连续发送测试仅保留一条测试请求；确认业务表及 journal 无测试记录。检查实际系统投递，但不要将“已提交系统”当作送达证据。
6. 保存并重开普通任务项目、标签、清单排序/勾选；核对微习惯只读保留、特殊任务专用语义，以及窄屏/大字体/三语布局。

## 已知限制

- 初次交付未做原生构建。后续 macOS 构建与部分自检已推进，范围与阻断见下方补充；iOS/Android 设备验收仍未完成。
- Android 周期通知按确认的三个动作展示，1 小时延后在应用内；Windows/Linux 无本应用可用的原生定时通知时，自检按钮不可用并明确提示保持运行。
- pending 超过 32 条丢弃最早条目；终止态操作需要下次正常启动消费。系统权限、专注模式与平台调度仍决定实际投递。
- 详情沿用两个现有保存命令。metadata 成功而普通字段保存失败时保留未提交草稿，可安全重试；不声称单事务保存。
- 工作中观察到并发提交将 HEAD 从 `ec31b08` 推进至 `7819c06`；该药物/日历提交已保留，不属于本轮变更。已有架构/开发文档、图源、编辑器配置与脚本未回退或纳入本轮提交。


## macOS 原生构建与隔离自检进展（2026-10-28）

状态：**PARTIAL_NATIVE_BUILD_AND_DIAGNOSTICS_UI_HANDOFF_REQUIRED**。本节不标记通知动作矩阵、三语菜单或退出后消费已通过。结构化证据见 [原生记录](benchmarks/reminder-trust-macos-2026-10-28.json)。

- 冻结源码 `6f42ccda4dd6cfe2b0def0a33027a22cd97eb2f5`，产品入口 `lib/main.dart`，启用既有被动 startup/retry trace，真实 OS transport。Flutter 3.44.9 / Dart 3.12.2、Xcode 27.1、已有项目专用 CocoaPods 1.16.2 构建 release 成功（61.8 MB，主程序 arm64/x86_64），签名验证通过。未公证，不等同于发布包验收。
- 原 ZIP SHA-256 `5f92b090cea0b85d0b9eb9eb8825d34ab073bd777529c9c89c61aa60dda7368b`；通过既有准备脚本派生全新 `com.example.dontForget.acceptance.trust-actions-20261028-1110`。Sandbox 开启，无共享容器权限，Frameworks/Resources 保持不变。
- 原生界面确认未授权自检拒绝提交；授权后显示已允许、系统安排 0、待修复 0。测试通知报告“已提交系统”，连续替换读数为 1；精确 bundle/source 日志确认 id 0 实际投递和横幅呈现，未把提交当作送达。
- 测试后、并行写入发生前，隔离库为 Settings/MediaRecords/Reminders = 1/0/0、schema 16、integrity ok。只复制通知 sidecar 后用既有解码器离线核对，业务 journal 中没有 id 0；真实测试通知点击路由尚未验证。
- 操作期间该隔离库于 11:21:23 出现 3 条非本轮创建的记录。已停止 UI 操作、私下保全完整副本，未删除或改写这些记录。它们不作为本轮合成数据或动作验收证据，不将其他会话的退出归因于本轮成功。
- 第二个新身份 `com.example.dontForget.acceptance.trust-actions-20261028-1130` 已准备，主可执行文件更名为 `dontforget_trust_actions_1130` 以避免同名进程歧义。仅改变包身份字段及文件名，原生非签名字节和 Frameworks/Resources 再验证相同；未启动，等待独占窗口使用权确认。
- 实际冻结源码的 65 项相关 fake/temp Flutter 测试通过，静态分析 0 issues。本轮没有把原有 1728 项证据当作新冻结原生包的全量结果。

待继续：取得独占 Mac 验收窗口后，用第二身份重新授权、写入纯合成数据，验证通知四动作、前台/后台与退出后冷响应、明确标注的注入队列重启消费、中英日菜单与未来请求重排，以及同一候选的 pending/retained 清理。旧身份含未知归属记录，不做整库或整通知来源清理。

另有源码边界需后续修复/验证：macOS 固定插件没有原始点击时间字段，目前 Dart 在 StorageBootstrap 后接到 cold response 才记录 occurredAt；慢冷启动可能使延后时间偏后。严格点击时间验收需在原生 delegate 最早回调处采集时间，并保持既有插件转发与队列。macOS 无插件后台 isolate，不能把冷启动成功扩张为 Android/iOS 后台队列已验收。

iOS/Android 剩余：按钮实际呈现、前台/后台 FlutterEngine 与终止态消费、去重及旧 payload/数据代次拒绝、两种延后和周期锚点、三语切换/失败重试、权限与专注/调度限制、自检 id0 无业务写入、实际送达/点击及安全清理。


协作补充：用户已要求“与其他任务协作，空闲时占用验收”。只读确认“评估 DontForget 的 UX/UI 优化点”仍有 `EXCLUSIVE_RECEIVED / explicit_return_required=true` 的交接，未见明确归还。向相关聊天发送交接请求及创建空闲跟进均被客户端拒绝：`MCP tool call requires approval, but approval policy is never`。消息未发送、跟进未创建；没有改用其他渠道或调度方式绕过，也没有按 45 分钟已过推断归还。下一步需要现持有任务明确交回共享桌面使用权，或客户端允许协调工具后发送请求。


### 计时修复与轮换交接补充

已在独立 6f42ccd 源码副本实现并按每文件 SHA-256 比对整合最小修复：`MainFlutterWindow.swift` 强持有 delegate proxy，保留原插件的响应/展示/设置转发，记录每个原始 payload/action 最早 native 回调时间；32 项 FIFO，重复取首次值，completion 防重。现有 `dontforget/notification_schedule` 通道增加时间读取，Dart 再写入原 pending 文件，不增加数据库或第二套通知系统。缺失、无效或晚于 Dart 回调的值保留兼容回退；时间仍是最早 native 观察时刻，非系统公开的原始物理点击时间。

新增 11 项 Dart 回归与原有 65 项合跑 76/76，通过 targeted analyze（0 issues）。使用真实 FlutterMacOS/UserNotifications framework 编译运行 FIFO、首次时间、输入边界和 completion 纯 Swift 测试通过；registrant stub 未创建引擎/UI/系统通知。新版完整 release 构建另行取证。

用户已明确交回共享桌面，但客户端在其再次允许后仍拒绝控制唯一验收应用（`Computer Use was not approved to use ...1130`），控制会话刷新也未成功。本任务已明确归还桌面，不继续占用。用户要求各任务限时轮换：每轮记录实际开始、预计释放、本轮目标、精确应用身份，明确归还后下一任务接手；时间到只提醒收尾，不自动抢占。共享记录为待各任务确认的提案；协调工具拒绝的消息不得记作已发送或已预约。


### 修复后冻结候选与本轮结论

- 修复提交 `623c52524c43ffc60d04b48e18464d7d7549439e` 的准确 git archive 已重新构建：全源码 `flutter analyze --no-pub` 0 issues，全量 `flutter test --no-pub --reporter expanded` **1740 项通过（61 秒）**；其中 76 项为本轮相关回归。该结果不覆盖主工作区其后并行的安全存储/附件未提交修改。
- 修复后 macOS release 再次成功（61.8 MB），ZIP SHA-256 `21f15a13d5fb965f997cb8a2d9918a0757b300238174da68f20336a0d1bb4da1`。准备好的唯一身份应用为 `build/native_acceptance/trust-actions-20261028-1130-timing/dont_forget.app`，已通过签名、资源与非签名字节校验；**未启动，未做修复后原生动作验收**。
- 共享桌面仍不由本任务占用；限时轮换提案、精确的当前状态和客户端阻断见 [轮换协议](Native_Acceptance_Rotation.md)。所有工作树使用该协议中的同一个绝对路径，禁止生成各自独立的“共享锁”。当前无已确认的下一时段或自动跟进。

macOS 后续目标仍为：真实四动作、前台/后台/退出后响应、独立标注的持久队列重启消费、日文及完整中英日菜单/未来通知重排、自检实际点击与精确 source 清理。iOS/Android 剩余项继续按本记录前述矩阵执行。


### 修复后候选：第一轮共享 Mac 验收（12:14–12:26）

本节为最新状态，前述客户端拒绝与未启动是历史记录。协调工具本轮已恢复，架构任务明确归还后，UX 因等待人手锁定手机而提前将 Mac 交给通知任务；实际接收 **12:14:32**，预计释放 **12:34:32**，实际提前归还 **12:26:27 +08:00**。规范轮换状态已更新到 revision 9，下一候接方为 UX；未把预计时间当作自动交接，也没有使用手机或镜像。

- 准确 `623c525` 唯一程序成功运行，startup trace PID 18397/20233 均记录同一 revision 与正常 readiness。1130 首次库 schema16、integrity ok、Reminders/MediaRecords/Settings=0/0/1。正常退出并确认 `isRunning=false` 后，持既有存储 owner lock 核验空基线、保留私有备份，只写入六项固定模型合成任务；Settings、epoch、journal 未用于 seed，后续通知均由产品正常启动安排。
- 新包自检：未授权时拒绝提交；只开启精确1130身份的系统通知后，面板显示允许、待修复0；两次测试提交相隔2.972973秒，pending保持1，UI仅称“已提交系统”。完整 source `B807382F-153E-47BF-A178-0E18E4DF71B9` 的 id0 在12:16:08.108734实际投递、.109540呈现横幅。测试后、seed前业务计数仍0/0/1。测试通知正文点击与新包journal排除的独立解码尚未完成。
- 设置依次保存中、英、日，原生两类 category 均重新注册。保存设置后，12:19:36注册英文、12:20:11注册日文，相同六个native ID在尚未到期时重新提交到对应语言类别；自检/任务信息界面也显示对应三语。**系统动作菜单的实际标题尚未看到**，因此只记语言注册及未来重排通过。
- 系统日志确认 id0 及六条日文业务提醒均实际投递，业务 native ID 为1413984401、1728030724、1541344988、860724930、861949424、1659290389。用例名中的fg/bg/cold只是原计划，不能据此认定运行状态或动作已通过。被动trace没有动作响应埋点，本轮无动作点击证据。
- 控制工具始终选中“月”日历widget，无法定位系统通知卡，已请求人手展开。最小化本轮窗口后工具返回noWindowsAvailable；随后准备正常退出时工具明确报告Mac锁定、自动解锁失败。**Quit未确认执行**，12:25:17既有DB owner lock仍被持有。没有越过锁屏、终止其他进程、写pending文件或冒充冷启动验收。
- 11条注入队列草案仅保存在materials（6有效、3过期、2重复），未写入运行中的应用。13项离线助手自测通过，仅证明fixture/参数/锁/模型边界，不证明真实队列消费。Mac解锁后必须取得新交接、正常退出唯一程序、复验epoch/行/revision并持现有owner锁和pending独立锁，再做重启消费及二次重放。

最新状态为 **PARTIAL_FIXED_NATIVE_DIAGNOSTICS_LANGUAGE_RECONCILE_MAC_LOCKED**。六项合成记录和已投递通知已保留，尚未完成产品UI软删除和pending/retained清理，不将其写成验收关闭；旧1110未知归属记录、日常数据和其他任务状态继续保留。原1740全量Flutter、76相关回归、analyze0和release构建证据仍对应准确623c525；本段仅新增验收记录和本机materials，没有改产品或scripts。

下一轮Mac目标：手动解锁并明确接收UI → 系统通知卡三/四动作及三语标题 → 主进程前后台动作、真正退出后响应及原生时间转交 → 单独标注的pending重启/重复/过期/迟到snooze消费 → 仅本身份六项合成任务可恢复软删、系统pending/retained与queue读回。iOS/Android仍需原生按钮数量、前后台/终止引擎、32项队列与代次/重复拒绝、延后锚点、三语重排、自检权限/失败/连续替换、真实点击与清理；自动化证据不能替代设备结果。

本聊天已建立每15分钟的安静跟进，等待手动解锁和新交接；状态不变时不重复通知，不自动接管UI。第一轮私有证据hash清单SHA-256：`67f380e856f68c5bff27018abebcb0f0dc3faff891b7e45efad03a705e58c5c3`。


### 第二轮：持久队列消费与1130清理闭环（13:13–13:26）

用户已手动解锁Mac并展开通知中心。双方交叉消息后确认：通知任务已实际取得Mac-only窗口，UX没有进行UI/phone操作并明确等待；UX仅获准独立devicectl元数据/Documents只读准备。通知任务实际接收**13:13:57**，预计释放13:33:57，实际**13:26:30提前明确归还**，其后只离线更新证据，从未操作phone/Mirroring。准确623c525签名、唯一程序hash和六条合成记录在接手时均与上一轮相符。

- **主进程正常重启消费注入队列通过。** 应用自身原生Quit后，Cua精确身份读回isRunning=false；取得既有DB owner fcntl与pending独立flock后，原子写入11条（6有效、dataset/trigger/revision各1过期、2重复）。正常产品main启动后，六行各只增加1个revision和1条history，队列清空：两条非周期完成；周期完成及跳过推进次日本地同刻，跳过保持未完成。
- **两种延后通过。** 迟到snooze15的存储目标等于处理时刻+60秒；snooze60等于动作时刻+3600秒，计算误差0微秒。两者eventTime原文和有效周期锚点保持。原本为空的持久锚点按现有语义显式保存原trigger/event，不能声称原始null字段没变。实际UNCalendar投递是秒精度，微秒断言仅针对业务目标计算。
- **跨重启重放通过。** 旧11条再次落盘，同时附加一条当前正常snooze15；正常重启后仅该新请求改变bg15至revision2/history2，目标精确为动作时刻+900秒，其他行逐字段不变，队列再次清空。仍属`INJECTED_QUEUE`，不能冒称真实OS按钮或插件background isolate测试。
- **journal独立解码通过。** 清理前持owner锁复制的sidecar在临时目录由固定源码LeasedIncrementalJournal读取，未创建DatabaseHelper/SQL连接；选中快照6项（2 cancel/submitted、4 schedule/submitted），无id0、pending/failed0，schedule trigger/revision与业务快照相符；原复制sidecar hash不变。
- **正式产品恢复清理通过。** 先保留六条处理后记录的完整数据库/sidecar回退副本，再在当前1130的备份检查页选本轮空基线，逐项核对0/0/1及SHA-256，恢复计划显示本身份6→0。现有RecoveryCoordinator完成恢复与native取消/重建；没有直接覆盖数据库清理。数据epoch从`49251748-a96a-4919-8b6d-02374664e1fa`轮换为`8190fa4c-77c9-4e6a-adab-aa7c4a3ebaf2`。旧epoch的11条再次注入，正常启动全部丢弃，库保持0/0/1；该次空基线也无匹配行，不能单独称为“仅epoch一项差异”的隔离实验。
- **最终读回闭合。** 设置与自检均显示系统pending/retained0/0、repair/review/cancel0。自身Quit后isRunning=false，持既有owner锁确认schema16/integrityok、Reminders/MediaRecords/Settings=0/0/1、queue有效空文档；最终journal选中0项且epoch正确。最终DB与原空基线SHA相同：`b2a3bda8621d51b154c63f267478ffc3f3d6aa0c182a9041116107a599ca2aa5`。六行回退DB SHA：`1f71746905405dd43866561f535d02a17a89a75751b89f91d4db48513ae49517`，已私下保留。

最新状态：**PARTIAL_NATIVE_QUEUE_AND_1130_CLEANUP_PASS_OS_ACTION_UI_GATE_OPEN**。当前1130已清理并退出，旧1110含未知归属记录仍不触碰，日常数据及其他任务的phone状态未修改。原Mac锁屏阻断已解决，剩余是电脑控制工具选窗限制：即使用户展开通知中心，Cua仍只返回“月”日历widget，snapshot仅state/screenshot，没有其他窗口区域，切换窗口超时。没有因获得授权或队列通过就把真实系统按钮、三语菜单、前后台OS回调、终止后原生时间转交、测试通知正文点击写成通过。没有发现或引入不支持的产品平台API。

剩余Mac验收需要可选择真实通知卡的控制入口或人工原生动作配合；当前不再有需要清理的1130任务/通知。锁屏等待heartbeat已删除，因为其等待条件已解除、定时重试不能解决固定选窗限制；本任务没有被记为全部完成。第一轮的锁屏/未清理状态为历史。第二轮55项私有证据hash清单SHA-256：`bda358421b632790366688a7f7cc5f59a6a0cab28407997abcfa3a334b89dd77`。本轮没有修改产品源码或scripts；固定623c525的1740项全量Flutter、76项相关回归、analyze0与release构建证据继续有效，不扩张到主工作区并行未提交代码。

iOS/Android仍待：iOS周期四动作及非周期三动作，Android周期完成/15分钟/跳过及非周期完成/15分钟/1小时；前台主isolate、后台FlutterEngine信号、终止态落盘及重启消费；事件/周期锚点、周期推进与跳过、迟到目标、重复和过期/数据恢复代次；三语真实菜单与未来重排、权限拒绝/注册和排程失败重试、id0连续替换及正文路由隔离；真实投递/点击、业务/journal读回及只清理本身份的native pending/retained。Mac注入结果不替代这些移动设备证据。


### 第三轮：真实投递、来源未确认与配置保护（13:59–14:24）

按架构13:58:43明确归还接收，实际**13:59:57**、原定截止**14:19:57**，实际**14:24:27明确归还**。下位曾有条件同意额外10分钟（仅首个OS菜单定位成功才继续）；条件未满足，未启用延期。原截止后的约4分30秒只做配置保全、可恢复清理和退出，没有新增验收场景。下一已确认方为架构5分钟，之后UX；phone未操作。

- 仅写入两条精确`QA Trust R3`合成记录，固定623模型与已有owner/pending双锁，初始库hash仍为空基线b2a3…aa5。系统确认非周期397678319于14:01:55.139712、周期353804180于14:02:55.153555投递并呈现横幅，均zh类别；此前PID68660被动窗口读回focused/visible=true。
- 用户报告找不到目标“选项”，Cua始终仅返回“月”widget。应用任务菜单曾被观察到；任务历史出现一次完成、随后重开，周期项确认通知。最初将其归为应用内操作的判断过强：调试日志只证明应用发起对应通知清理，**未建立或排除之前的OS回调**。所以仅记真实投递通过，真实按钮/菜单/回调来源保持未验证，不以业务历史代替原生动作证据。
- 尝试将本身份样式由临时改为持续，计划主程序Quit后只呈现系统卡。但准备冷启动新增行时，严格guard发现非基线用户服务设置，**在SQL写入前拒绝**；没有新增cold记录或投递持续提醒。因此“持续提醒+独立系统弹窗入口”仍只是待验方案。本身份样式已恢复临时。
- 配置已在0700目录/0600文件中私下保全，报告不导出设置值。放弃整库空基线恢复，只通过产品菜单将两条精确自建事项可恢复移入回收站；前后**Settings整行完全相同**。最终库2条软删除、可见0，系统pending/retained0/0，应用正常Quit且Cua读回false。复制sidecar由SQL-free既有LeasedIncrementalJournal独立解码：2个精确R3 ID均cancel/submitted、unfinished0、无native0；未读配置数据库，原sidecar hash不变。旧1110和日常/phone数据不改。

本轮状态为 **PARTIAL_R3_NATIVE_ATTRIBUTION_UNVERIFIED_USER_CONFIG_PROTECTED_R4_PREPARED**；未完成真实按钮、三语菜单或退出后冷响应。R3有51项私有证据，hash清单SHA-256：`418d776a0e58af2c90b2891fb8899e07dbe6a9e9763fdbe169aea45626652a10`。含用户配置的本地副本不能作为可删构建缓存或公开附件。

第三轮归还后的准备快照：为继续纯测试，另由准确623 ZIP派生当时尚未启动的新身份：`com.example.dontForget.acceptance.trust-actions-20261028-1430`，显示名`DontForget QA Native 1430`，唯一程序`dontforget_trust_actions_1430`。严格签名、主非签名字节和165项Frameworks/Resources逐项相同；新ZIP SHA-256：`53d15d9c5f101734bc7d8dce2a9ff5274fcfd864bbbf71131b042408f9b24fc1`。新容器在准备时不存在，未bootstrap、未投递或执行原生验收。独立严格1430的R4工具20项离线自测通过，不读1130配置，也不改旧helper/证据。

离线系统plist确认两个不同入口：`/System/Library/CoreServices/NotificationCenter.app`（`com.apple.notificationcenterui`）和`/System/Library/CoreServices/UserNotificationCenter.app`（`com.apple.UserNotificationCenter`）。第三轮准备时，后者是否呈现持续通知动作尚未用Cua验证，不能称选窗问题已解决。当时的下一窗口计划仅在明确交接后，用新1430的持续系统通知、主程序退出及上述独立入口先做短探测；成功再协调完整20分钟，结束恢复样式、保全回退及只清本轮资产。1130从此保持用户配置，不再当空测试基线。自动跟进已更新此边界。

iOS/Android余项不变：原生动作呈现与三语标题、前后台/终止链路、周期与延后语义、去重/过期/恢复代次、自检权限/失败/连续替换及正文路由隔离、实际投递点击和安全清理。R2注入通过与R3真实投递均不替代原生OS按钮结果。

### 第四轮：新身份启动与明确的控制安全限制（14:56–14:57）

UX于14:53:34明确归还Mac共享桌面，架构确认通知任务可接5分钟短探测。root实际Cua控制成功后登记**14:56:35接收、15:01:35预计释放**；因下面的安全拒绝，**14:57:33提前明确归还**架构候接。phone仍由UX保护，没有使用Mirroring或手机，也没有按预计时间自动接管。

1430首次正常bootstrap，设置页初始读到系统pending/retained0/0、权限未开启、待修复0、当前日志无失败。点击本身份“允许通知”后，页面仍显示未开启/正在读取，未观察到授权结果；不能推断已允许。随后调用`cua.getApp('com.apple.UserNotificationCenter')`被工具明确拒绝：`Computer Use is not allowed to use the app 'com.apple.UserNotificationCenter' for safety reasons.` 没有改用CLI、AppleScript、私有API或其他入口绕过拒绝。先前NotificationCenter仅显示“月”widget的问题尚未解决；这属于控制工具边界，不是产品通知平台API不支持的证据。

未写入R4合成任务，未提交测试或业务通知，未改变本身份通知样式，也未发生可验证的原生按钮/三语菜单/冷响应。本身份正常Quit后Cua读回`isRunning=false`；持既有owner/pending锁只读核对DB0/0/1、schema16、integrityok、DB仍精确为空基线SHA-256 `b2a3bda8621d51b154c63f267478ffc3f3d6aa0c182a9041116107a599ca2aa5`，pending文件不存在。初始native0/0是观察值，权限请求后刷新未完成，没有虚构新的最终native读回。没有新的任务或通知需要删除；日常身份、旧1110、含用户配置的1130及其他任务验收状态未改。

本轮证据位于`build/native_acceptance/trust-actions-20261028-1430-materials/round4-probe/`，manifest SHA-256 `0c382b3144d4c1942b1d5ff55db8f3e60588b86886d9ad230ba966bceceb01f0`。当前结论为 **PARTIAL_R4_CLIENT_SAFETY_BLOCK_NATIVE_ACTIONS_UNVERIFIED_OWNED_APPS_EXITED**。自动跟进仅等待新的可执行条件，不自动重试被拒入口、不重复要求用户寻找已清理的R3旧卡。若后续有人能实际操作系统卡，需先重新交接、准备全新未来时刻的1430通知，再给出准确标题和最少点击；当前没有待用户点击的R4通知。

本次仅更新验收文档，没有修改产品或scripts。固定623c525的源码/构建/自动化测试证据保持原范围；本轮`python3 -m json.tool docs/benchmarks/reminder-trust-macos-2026-10-28.json`、`git diff --check`均通过；R4纯工具20项自测通过，测试未访问真实数据库或系统通知。iOS/Android待验仍为上文的原生按钮数量和三语、前后台/终止队列、延后与周期语义、幂等/过期/代次、自检失败及连续替换、真实投递/点击和各自安全清理，均未用Mac证据替代。
