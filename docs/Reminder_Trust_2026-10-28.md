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

- 尚未做本轮 macOS/iOS/Android 原生构建或设备验收；后台 FlutterEngine 回调、FFI 文件锁符号、系统通知按钮和投递仍需设备验证。
- Android 周期通知按确认的三个动作展示，1 小时延后在应用内；Windows/Linux 无本应用可用的原生定时通知时，自检按钮不可用并明确提示保持运行。
- pending 超过 32 条丢弃最早条目；终止态操作需要下次正常启动消费。系统权限、专注模式与平台调度仍决定实际投递。
- 详情沿用两个现有保存命令。metadata 成功而普通字段保存失败时保留未提交草稿，可安全重试；不声称单事务保存。
- 工作中观察到并发提交将 HEAD 从 `ec31b08` 推进至 `7819c06`；该药物/日历提交已保留，不属于本轮变更。已有架构/开发文档、图源、编辑器配置与脚本未回退或纳入本轮提交。
