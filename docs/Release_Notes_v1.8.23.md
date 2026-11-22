# DontForget v1.8.23 · Android / Windows / Linux / iOS

面向**核心功能链路稳定性、运行时性能、交互易用性、视觉美观性与模块化重构**的深度迭代版本。在严格保持 SQLite schema17、回滚日志（`[1, 1]`）、依赖锁文件与既有数据／凭据格式不变的前提下，系统修复通知维护竞态、数据库锁租约泄漏、AI 异常载荷污染、局域网慢连接泄漏、备份双倍加解密开销、搜索计数不一致、逾期误归类、桌面卡片悬停抖动与偏好保存锁死等核心痛点，并拆分重构设置页与公共交互组件。build94／schema17。

## 主要更新

### 核心稳定性与数据安全加固
- **通知、存储与后台并发安全（`notification_service.dart`、`database_helper.dart`、`providers.dart`、`task_management.dart`、`content_cleanup_service.dart`、`home_controller.dart`）**：
  - 修复维护暂停（`pauseForMaintenance`）切换期间原生通知窗口对账空值崩溃与心跳双触发竞态，并合并移动端窗口恢复／专注策略对账。
  - 修复 `DatabaseHelper` 异常路径泄漏 `StorageDirectoryLease` 目录租约，并在无新增写入时跳过关闭阶段重复镜像备份与空批提交。
  - 释放 `ContentCleanupService.inspect()` 磁盘遍历期间对 SQLite `EXCLUSIVE` 写事务的长占，消除清理与归档阶段的 `O(N²)` 扫描；序列化媒体记录写入队列，`ContextProfileNotifier.setProfile` 异常原子回滚，任务生命周期变更在事务内直接捕获更新后行。
  - 修复 `HomeController` 录音启动与取消均抛出异常时的永久锁死状态；修复 `PreferencesScreen._save()` 未在 `finally` 复位 `_saving` 的界面锁死问题。
- **AI 提取与局域网同步鲁棒性（`llm_service.dart`、`lan_sync_service.dart`、`context_trigger_service.dart`）**：
  - `LLMService` 强制校验并收束模型返回的 `quadrant_level`（`1..4`）与 `reminder_lead_minutes`（`0..43200`），防止异常输出污染便携备份；畸形响应统一转为 `FormatException` 纳入路由回退而非抛出未捕获类型错误；重试等待响应 `CancelToken`。
  - `LanSyncService` 直接对请求流施加超时保护防止慢连接泄漏并在超时后主动关闭套接字；入站合并校验象限范围并按已知媒体 `skipIds` 跳过冗余落盘；Wi-Fi 情境触发新增 45 秒冷却、单并发合并、`runInShell: false` 与活动规则预判。

### 核心性能与离线解析升级
- **流式加密备份单遍提速（`streaming_backup_service.dart`、`portable_backup_service.dart`、`portable_backup_panel.dart`）**：
  - 改用单常驻 `_AesGcmWorker` Isolate、`TransferableTypedData` 与零拷贝视图替代每 1 MiB 块新建 Isolate，恢复流程改为单遍解密（省去 2× 60 万次 PBKDF2 与双倍全量 AES-GCM 解密），输错密码支持原地提示重试无需重选文件。
- **离线自然语言时间解析增强（`quick_reminder_parser.dart`）**：
  - 新增 500 字符解析长度上限防护，支持中文「零X分」（如「明天下午三点零五分」）、复合相对时长（「1小时30分钟后」）、多段相对扫描（「开会30分钟，10分钟后提醒」）、「明晚／今早」与独立 `3pm`／`3:30 pm` 表达。
- **主界面与卡片渲染热路径优化（`home_screen.dart`、`task_workspace_overview.dart`、`task_search_panel.dart`、`task_card.dart`、`content_management_panel.dart`）**：
  - 停止在每次 `HomeScreen.build` 清空通知快照缓存并收窄 `homeControllerProvider` 监听与天气读取；搜索面板缓存投影并保留 `ScrollController` 实例避免键入重建整棵列表树；`TaskCard` 将媒体图标订阅隔离至局部 `Consumer` 并复用帧级 `referenceNow`；内容管理拆分归档订阅消除跨页签联动重绘。

### 易用性、美观性与模块化重构
- **工作区、搜索、命令面板与卡片打磨（`app_theme.dart`、`task_search_index.dart`、`task_workspace_overview.dart`、`task_board.dart`、`quadrant_view.dart`、`task_card.dart`、`command_palette_dialog.dart`、`reminder_notice_panel.dart`、`missed_reminders_bar.dart`）**：
  - 浅色主题 Q2 象限色微调至 `#9E4706`，确保在白色及 12% 淡色胶囊底面上均达 WCAG AA（`>= 5.2:1`）；补齐主题 `focusedBorder`、`bottomSheetTheme`、`tooltipTheme` 与等宽数字令牌。
  - 修复主界面切换回「今天／未来／全部／分类」不同步的问题；修复搜索筛选芯片与实际结果计数偏差；修复仅设提醒时间的逾期事项误归入「今日安排」；「未来」视图按「明天／本周／更晚」分组并隐藏空「已完成 · 0」开关。
  - 桌面宽卡悬停快捷操作改为右上角浮层消除标题换行抖动；单次完成新增「撤销」操作条；修复通知条跳过文案并补充 `HH:mm` 时刻；命令面板支持 `/study` 等快捷键与多词检索并优先前缀匹配；看板紧凑模式免去冗余拖拽包装并在桌面拖放悬停时展示明确投放提示。
- **阅读／编辑页与设置中心重构（`task_reader_screen.dart`、`task_detail_screen.dart`、`task_metadata_editor.dart`、`task_details_dialog.dart`、`settings_screen.dart`、`preferences_screen.dart`、`content_management_panel.dart`）**：
  - 阅读页新增 `Ctrl/Cmd+E` 快速编辑、逾期胶囊与事项截止倒计时；编辑页修复清单回车换行无法提交、无框输入框双边框与多处低对比度文字，新增标题内联必填提示与双向关联弹窗搜索过滤，修复 `TaskEditDialog` 缺失年度重复项。
  - 将 `settings_screen.dart` 拆分为 `console_url_launcher.dart`、`local_engine_probe_section.dart`（AI 与同步页双入口）与 `lan_sync_section.dart`（接入导航繁忙锁、IP／PIN 提示与更精准错误文案）；抽取 `task_snooze_picker.dart` 与 `task_category_picker_dialog.dart`；完善偏好页返回时实时刷新「共享中」徽章、错误重试按钮与内容管理未扫描引导态。

## 下载与安装

- Windows x64：`DontForget_Setup_v1.8.23.exe` 安装版或 `DontForget_Windows_Portable_v1.8.23.zip` 便携包，未做 Authenticode 签名。
- Linux x64：`DontForget_Linux_x64_v1.8.23.tar.gz`，Ubuntu 24.04 基线。
- Android：固定发行证书签名的通用 APK（`DontForget_Android_v1.8.23.apk`）、ARM64 APK（`DontForget_Android_arm64_v1.8.23.apk`）及 AAB（`DontForget_Android_v1.8.23.aab`）。
- iOS：`DontForget_iOS_unsigned_v1.8.23.ipa` 为未签名 IPA，需要通过 AltStore 个人重签；免费账号通常每 7 天续期。安装方式见[说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)，不属于 App Store 或 TestFlight 分发。

## 验收范围与限制

源码、自动化测试、安装包与真实设备验收严格分层记录，详见[后续阶段与验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)：
- **自动化**：固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、全仓 `flutter test`（2,726 项通过／20 项文档化 Windows 跳过／0 失败，含 `test/v1_8_23_core_improvements_test.dart` 新增 13 项回归）与 Python 脚本测试（192 通过／6 跳过，含全仓无障碍静态门禁与包体契约校验）全部通过，并经主线四平台 CI 7/7 校验。
- **真实设备升级验收**：公开发布后将在本机 Windows 11 执行官方 CI 安装包 3 模式运行中升级验收（托盘隐藏态 `SW_HIDE` 运行中升级、可见窗口运行中升级、自升级），并在已解锁连接的 Pixel 8 Pro 上执行官方 CI ARM64 安装包覆盖升级验收与回执归档。
- **未验／限制范围**：Windows 活动桌面 `WinSta0\Default` 交互式 GUI／桌面中文输入法／托盘右键菜单、iPhone 真机安装与运行（本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证）、正式版云端 ASR 真实声学播音（未配置云端密钥）及实机 `LocalAppData\DontForget` 原地删除仍明确留存，不记为全部原生矩阵通过。
