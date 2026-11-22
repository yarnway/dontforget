# DontForget v1.8.22 · Android / Windows / Linux / iOS

面向**稳定性加固、视觉美观升级、交互易用性打磨、运行时性能优化与包体持续瘦身**的全面迭代版本。在严格保持 SQLite schema17、回滚日志（`[1, 1]`）与既有用户数据／凭据格式不变的前提下，系统修复 12 项边界稳定性隐患，全面统一明暗双主题与 WCAG AA 象限配色、升级卡片／输入栏／搜索／阅读／编辑／仪表盘／设置全链路视觉与键盘体验，并通过三语框架本地化代理与语言资源裁剪实现全平台 AOT 与安装包进一步瘦身（Android ARM64 APK 首次进入 **10 MiB 以内**）。build93／schema17。

## 主要更新

### 稳定性与边界鲁棒性加固
- **Windows 原生窗口与通知容错（`windows/runner/flutter_window.h`、`flutter_window.cpp`、`lib/services/windows_protocol_service.dart`、`lib/services/windows_toast.dart`）**：为 `WM_FONTCHANGE` 增加引擎空指针保护，对 `WM_COPYDATA` 载荷施加有界长度读取并在 Dart 完成 `initialize` 握手前缓冲冷启动早期协议与升级退出信号；`WindowsToast` 完整转义 PowerShell 5.1 Unicode 弯单引号（`U+2018`–`U+201B`）并改用带并发流消费与 10 秒超时强收口的 `Process.start`，避免异常系统通知宿主挂起恢复或优雅升级流程。
- **Android 分享桥与并发安全（`android/app/src/main/kotlin/com/yarnway/dontforget/SharedTextBridge.kt`、`MainActivity.kt`）**：为分享日志操作补充 `@Synchronized` 并发保护，在纪元切换丢弃过期记录时自动清理孤立 `handoffRoot/<id>` 目录；将最大 32 MiB 的 `ContentProvider` 流拷贝移至单线程后台执行器并切回主线程派发，消除主线程 ANR 风险。
- **状态恢复、异步录音与网络边界（`lib/app.dart`、`workspace_drafts_provider.dart`、`home_controller.dart`、`tencent_realtime_recognizer.dart`、`live_pcm_recording.dart`、`llm_service.dart`、`multi_agent_service.dart`、`study_plan_service.dart`、`settings_screen.dart`、`home_screen.dart`、`input_bottom_bar.dart`、`task_card.dart`）**：`DesktopUpgradeExit.prepare()` 任一步骤失败时原子回滚已暂停子系统；修复 `WorkspaceDrafts.putAll` 未结清旧防抖等待者可能导致的永久挂起；加固录音取消／清理路径与语音识别结束态清理；新增 `LLMService.chatCompletionsUrl()` 规范化尾部斜杠并增加 30 秒 `sendTimeout`，`MultiAgentService` 统一使用 `requestModelName`；修复局域网同步回调在关闭设置页后漏刷 `mediaRecordsProvider` 及播放报错状态竞态问题。

### 美观性、易用性与交互体验升级
- **统一视觉令牌与 WCAG AA 象限色彩（`lib/ui/theme/app_theme.dart`、`task_board.dart`、`task_card.dart`、`task_reader_screen.dart`、`task_detail_screen.dart`、`dashboard_screen.dart`、`knowledge_graph_view.dart`）**：优化浅色主题页面与卡片层次对比（`#F1F5F4` 底面＋纯白卡片＋柔和阴影）；新增明暗双主题均满足 WCAG AA（>= 4.5:1）的 `AppTheme.quadrantColor` 与 `AppTheme.quadrantIcon`，统一看板、卡片、阅读／编辑页、仪表盘与知识图谱的象限视觉语言。
- **核心工作区效率升级（`task_card.dart`、`input_bottom_bar.dart`、`task_workspace_overview.dart`、`command_palette_dialog.dart`、`task_search_panel.dart`、`home_screen.dart`）**：桌面宽卡（>= 360px）悬停显示置顶／延后／编辑快捷图标，逾期未完成事项支持一键延后，延后弹窗新增图标、目标时间预览与自定义日期时间选择；底栏时间识别胶囊支持点击直选或一键清除并优化聚焦光晕；工作区页签展示实时数量、修复「全部」空态并补齐「添加第一条事项」引导按钮；首页新增 `N`/`Ctrl+N` 快速记录与 `1`–`4` 视图快捷键，命令面板新增按键帽样式与空态引导，顶部搜索栏升级胶囊样式，筛选芯片展示实时匹配计数。
- **阅读／编辑／仪表盘／设置页精修（`task_reader_screen.dart`、`task_detail_screen.dart`、`task_metadata_editor.dart`、`dashboard_screen.dart`、`preferences_screen.dart`、`settings_screen.dart`、`inline_feedback.dart`、`reminder_notice_panel.dart`、`missed_reminders_bar.dart`）**：阅读页支持 `Escape` 返回、象限／置顶胶囊、实时倒计时与清单进度条并消除词汇笔记重复解析；编辑页统一分节卡片、修复 48dp 触控热区、增加未保存红点提示；仪表盘采用语义三色 KPI、等宽数字、占比百分比、减动效安全平滑进度条及正文卡片；偏好设置新增 AI／同步状态徽章（严格保持 LAN 服务懒加载）；设置页新增 API 密钥显隐切换并统一语义按钮与提示色调；`InlineFeedback` 全面应用语义色与平滑入场（首帧语义可见）。

### 运行时性能与安装包进一步瘦身
- **三语框架本地化与平台资源瘦身（`lib/l10n/framework_localizations.dart`、`lib/app.dart`、`lib/services/data_export_service.dart`、`android/app/build.gradle.kts`、`scripts/prune_windows_bundle.py`、`scripts/build_linux.sh`、`windows_installer/installer.iss`）**：使用仅包含 `en`/`zh`/`ja` 的精简 `AppMaterialLocalizationsDelegate` / `AppCupertinoLocalizationsDelegate` / `AppWidgetsLocalizationsDelegate` 替代全量 `Global*Localizations`，在四平台 AOT 中树摇 116 套未用语言表与 122 套日期符号；Android 启用 `resourceConfigurations` 仅保留 `en`/`zh`/`zh-rCN`/`zh-rTW`/`ja`（剔除 69 套无用系统语言资源）并剔除 `kotlin_builtins`；Windows／Linux 移除 Web 专用 `packages/record_web` 资产并在 Inno Setup `[InstallDelete]` 中自动清理旧版残留。
- **冷启动、算法与渲染热路径提速（`database_helper.dart`、`notification_service.dart`、`quick_reminder_parser.dart`、`bidirectional_link_service.dart`、`providers.dart`、`task_management.dart`、`lan_sync_service.dart`、`desktop_window_service.dart`、`knowledge_graph_view.dart`、`voice_capture_feedback.dart` 等）**：冷启动预读持久化语言避免重复注册通知渠道，桌面端语言切换降至 `O(1)`，移动端收窄至 `O(K)` 活跃窗口；静态提升全部高频正则表达式并缓存双向链接分词；删除／清空事项内存直更免全表重载、批量元数据与例程保存降至 `O(N+M)`；`KnowledgeGraphView` 与 `VoiceCaptureFeedback` 引入 `RepaintBoundary`、精确 `shouldRepaint` 与 `TextPainter` 缓存；进一步收窄页面与组件 `Riverpod` `select(...)` 订阅范围。

## 下载与安装

- Windows x64：`DontForget_Setup_v1.8.22.exe` 安装版或 `DontForget_Windows_Portable_v1.8.22.zip` 便携包，未做 Authenticode 签名。
- Linux x64：`DontForget_Linux_x64_v1.8.22.tar.gz`，Ubuntu 24.04 基线。
- Android：固定发行证书签名的通用 APK（`DontForget_Android_v1.8.22.apk`）、ARM64 APK（`DontForget_Android_arm64_v1.8.22.apk`）及 AAB（`DontForget_Android_v1.8.22.aab`）。
- iOS：`DontForget_iOS_unsigned_v1.8.22.ipa` 为未签名 IPA，需要通过 AltStore 个人重签；免费账号通常每 7天 续期。安装方式见[说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)，不属于 App Store 或 TestFlight 分发。

## 验收范围与限制

源码、自动化测试、安装包与真实设备验收严格分层记录，详见[后续阶段与验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)：
- **自动化**：固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、全仓 `flutter test`（2,713 项通过／20 项文档化 Windows 跳过／0 失败，含 `test/stability_and_polish_v1_8_22_test.dart` 新增 8 项回归）、Python 脚本测试（192 通过／6 跳过，含全仓无障碍静态门禁 `test_ui_accessibility_lint.py` 与更新后的 `test_bundle_size_optimizations.py`）全部通过，并经主线四平台 CI 校验。
- **本地包体与运行核验**：已完成本地 Windows `DontForget_Setup_v1.8.22.exe`（`13,255,851 B`，较 `v1.8.21` 再减 `155,014 B`）／便携包（`15,719,922 B`，较 `v1.8.21` 再减 `247,936 B`）及 Android ARM64 APK（`10,391,655 B` / `9.9 MiB`，较 `v1.8.21` 再减 `272,700 B`）的编译与结构校验；公开发布后将对 CI 官方 Windows 安装包（含托盘隐藏态运行中升级与 `[InstallDelete]` 清理 `record_web` 实测）及已连接的真实移动设备执行正式升级验收并归档回执。
- **未验／限制范围**：Windows 活动桌面 `WinSta0\Default` 交互式 GUI／桌面中文输入法／托盘右键菜单、iPhone 真机安装与运行（本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证）、正式版云端 ASR 真实声学播音（未配置云端密钥）及实机 `LocalAppData\DontForget` 原地删除仍明确留存，不记为全部原生矩阵通过。
