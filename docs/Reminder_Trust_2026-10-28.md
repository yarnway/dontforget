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
