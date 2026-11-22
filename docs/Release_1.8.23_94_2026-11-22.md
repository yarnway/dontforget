# v1.8.23／build94 最终发行与验收

[v1.8.23](https://github.com/yarnway/dontforget/releases/tag/v1.8.23) 已发布并设为 `latest`，四平台七包、20 附件独立读回通过。固定发布源码 `8b35d753ac31602a0aacaa1ea78600c6ef6b9641`（schema 17，严格保持 SQLite 回滚日志头 `[1, 1]`、依赖锁文件 `pubspec.lock` 与既有凭据存储格式）。源码、自动化、安装包与真实设备验收严格分层记录：**本版围绕核心功能链路开展五批易用性、美观性、性能、稳定性优化与模块化重构——系统修复通知维护竞态、数据库租约泄漏、AI 载荷越界污染、局域网慢连接泄漏、流式加密备份双倍加解密开销、搜索计数偏差、逾期误归类、桌面宽卡悬停换行抖动、编辑页无框双边框／清单回车及偏好保存锁死等核心痛点，拆分重构 `settings_screen.dart` 为 `console_url_launcher.dart`、`local_engine_probe_section.dart`（AI／同步双入口）与 `lan_sync_section.dart` 并抽取 `task_snooze_picker.dart` 与 `task_category_picker_dialog.dart`；四平台 7 包合计保持 `146.86 MiB`（仅微增 `+0.23%`，较 `v1.8.20` 累计缩减 `-83.59 MiB`／`-36.27%`，ARM64 APK `9.87 MiB`、iOS 未签名 IPA `9.77 MiB`）；Windows 本机一次性通过公开 CI 安装包「跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.22.93`→`1.8.23.94`，优雅释放互斥锁、RestartManager 0 占用、退出码 `0`、27/27 载荷一致、零强杀）」、「可见运行态覆盖升级」与「自托盘隐藏态覆盖升级」三项验收；Pixel 8 Pro 正式版 `com.yarnway.dontforget` 已完成 `1.8.22 (93)`→`1.8.23 (94)` 同签名保全升级（实装 `10,347,183 B` SHA‑256 一致、`libsqlite3.so` 持续剔除、冷重开零异常、`3/1/1` 备份往返逐字节一致、实机截图逐页核验首页隐藏 `已完成 · 0`、AI 设置页新增 `本地模型／检测本地模型` 入口、内容管理页新增未扫描引导提示、关于页显示 `1.8.23 (94)`；因 Pixel 当前 Wi‑Fi 访问 GitHub API 超时，应用内更新检查如实记录为 `检查超时，请重试。`，未冒记为 `已是最新发布版`，公开 `latest` 状态已由本机独立 API 读回确认）；iPhone 94 与 Windows 活动桌面交互式 GUI／托盘菜单／桌面中文输入法仍未验。**

## 源码与自动化

- **批次 1：核心稳定性、数据安全与并发加固**：
  - 通知与存储：`lib/services/notification_service.dart` 修复 `pauseForMaintenance` 切换期间原生窗口对账空值隐患、将 `_reminderDueController.add` 提前至异步窗口对账前消除心跳双触发竞态并合并移动端窗口恢复／专注策略对账；`lib/data/database_helper.dart` 修复异常路径泄漏 `StorageDirectoryLease` 目录租约，并在无新增写入时跳过关闭阶段重复镜像备份与空批提交。
  - AI、同步与清理并发：`lib/services/llm_service.dart` 强制约束 `quadrant_level`（`1..4`）与 `reminder_lead_minutes`（`0..43200`）、畸形载荷统一收敛为 `FormatException` 纳入多路回退，重试等待响应 `CancelToken`；`lib/services/lan_sync_service.dart` 为请求流施加慢连接超时保护与套接字主动关闭，校验入站 `quadrantLevel` 并通过已知媒体 `skipIds` 跳过冗余落盘；`lib/services/content_cleanup_service.dart` 释放磁盘遍历期间的 SQLite `EXCLUSIVE` 写事务长占、消除清理／归档 `O(N²)` 循环并在 `repair()` 中持有 `OwnedMaterialActivity.hold`；`lib/providers/providers.dart` 与 `lib/services/task_management.dart` 序列化媒体记录写入队列、`ContextProfileNotifier.setProfile` 失败原子回滚、生命周期更新改为事务内直接捕获结果。
- **批次 2：流式备份单遍提速与离线时间解析升级**：
  - 备份性能与体验：`lib/services/streaming_backup_service.dart`、`portable_backup_service.dart` 与 `portable_backup_panel.dart` 改用单常驻 `_AesGcmWorker` Isolate、`TransferableTypedData` 与零拷贝视图替代每 1 MiB 块重建 Isolate，恢复流程合并为单遍解密（省去 2× 60 万次 PBKDF2 与双倍全量 AES‑GCM 解密），输错密码支持原地重试无需重选文件。
  - 录入与离线解析：`lib/utils/quick_reminder_parser.dart` 新增 `maxParseLength = 500` 防护，支持中文「零X分」（如「明天下午三点零五分」）、复合相对时长（「1小时30分钟后」）、多段相对扫描（「开会30分钟，10分钟后提醒」）、「明晚／今早」与独立 `3pm`／`3:30 pm`；`lib/providers/home_controller.dart` 修复录音启动与取消双异常导致的 `_nativeRecording` 永久锁死并加固短录音清理。
- **批次 3：首页、通知条、延后与情境触发收口**：
  - 抽取公共延后组件 `lib/ui/widgets/task_snooze_picker.dart`；`lib/services/context_trigger_service.dart` 新增 `hasPendingWifiTrigger` 活动规则预判、45 秒冷却合并与 `runInShell: false`；修复 `HomeScreen` ↔ `TaskWorkspaceOverview` `onViewChanged` 视图同步、修正跳过反馈文案、为单次完成新增「撤销」操作条、保留 `HomeScreen` 通知快照缓存并收窄 `Riverpod` `select(...)` 订阅。
- **批次 4：视觉对比度、搜索、看板、卡片、命令面板与阅读／编辑打磨**：
  - 设计令牌与对比度：`lib/ui/theme/app_theme.dart` 将浅色 Q2 象限色调整至 `#9E4706`（白色底 `6.25:1`、12% 淡胶囊底 `5.23:1`，均满足 WCAG AA）并补齐 `focusedBorder`、`bottomSheetTheme`、`tooltipTheme` 与等宽数字令牌。
  - 工作区、搜索与交互：`lib/utils/task_search_index.dart` 通过 `project()` 单遍计算确保搜索芯片计数与实际结果严格一致，`task_search_panel.dart` 缓存投影并稳定保留 `ScrollController`；`task_workspace_overview.dart` 修复仅含提醒时间的逾期事项误归入「今日安排」、「未来」视图按「明天／本周／更晚」分组并隐藏空「已完成 · 0」开关；`task_card.dart` 将桌面悬停快捷操作改为右上角浮层彻底消除标题换行抖动、将媒体图标隔离至局部 `Consumer` 并抽取 `lib/ui/widgets/task_category_picker_dialog.dart`；`task_board.dart`／`quadrant_view.dart` 复用 `AppTheme.quadrantIcon`、紧凑模式免冗余拖拽包装并增加拖放提示；`command_palette_dialog.dart` 索引 `/study` 等快捷键并支持多词与前缀优先排序及 `Home`/`End`/`PageUp`/`PageDown`；`task_reader_screen.dart` 新增 `Ctrl/Cmd+E` 快速编辑、逾期胶囊与事件倒计时；`task_detail_screen.dart` 修复无框输入双边框与低对比度文字、新增标题内联必填校验与可检索双向关联弹窗；`task_metadata_editor.dart` 修复清单回车直加；`task_details_dialog.dart` 补齐 `'yearly'` 重复项；`lib/l10n/app_localizations.dart` 同步补齐 10 个三语键。
- **批次 5：设置中心、偏好页与内容管理模块化重构**：
  - 拆分 `lib/ui/screens/settings_screen.dart` 为 `lib/services/console_url_launcher.dart`（保持兼容 re-export）、`lib/ui/widgets/settings/local_engine_probe_section.dart`（同时挂载于 **AI 设置** 与 **同步设置**）与 `lib/ui/widgets/settings/lan_sync_section.dart`（接入 `UnsavedEditorScope.busy` 锁、IP／PIN 提示、`maxLength: 6`、非阻塞冲突提醒与更精确错误文案）；加固 `settings_screen.dart`（未就绪守卫、退出清理内存 API 密钥、通知区即时就绪、加载失败重试）、`preferences_screen.dart`（`finally` 必然复位 `_saving = false`、返回实时刷新局域网 `共享中` 徽章、错误重试）与 `content_management_panel.dart`（隔离 `_ArchiveTabView` 消除跨页签联动重绘、新增未扫描引导态 `content-unscanned-hint` 与搜索清除按钮）。
- **自动化回归**：本机固定 Flutter `3.44.9` 下 `python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` **0 问题**，全仓 `flutter test --no-pub` **2,726 项通过／20 项文档化 Windows 跳过／0 失败**（含新增 `test/v1_8_23_core_improvements_test.dart` 13 项回归），Python 脚本测试 **192 通过／6 项 POSIX 跳过／0 失败**（含 `test_ui_accessibility_lint.py` 全仓无障碍静态门禁与 `test_bundle_size_optimizations.py` 包体契约守卫）；固定提交 `8b35d753ac31602a0aacaa1ea78600c6ef6b9641` 主线 [CI 45035402012](https://github.com/yarnway/dontforget/actions/runs/45035402012) **7/7** 全绿。

## 安装包与四平台体积对比

四平台七包、20 个公开附件均由 [发布工作流 45039497093](https://github.com/yarnway/dontforget/actions/runs/45039497093) 校验并发布（发布时间 `2026-11-22T15:40:27Z`），随后经独立 API 读回确认标签指向 `8b35d753ac31602a0aacaa1ea78600c6ef6b9641`、`latest` 指向 `v1.8.23`、旧版 `v1.8.22`（`8ecad7c9526856c5f9ba4c307984607d4636d688`、20 附件）保持未改，详见 [github-release-v1.8.23-2026-11-22.json](benchmarks/github-release-v1.8.23-2026-11-22.json)：

| 发行产物 | `v1.8.22` (build93) | `v1.8.23` (build94) | 较 `v1.8.22` | 较 `v1.8.20` 累计 | `v1.8.23` SHA‑256（前 16 位） |
| --- | ---: | ---: | ---: | ---: | --- |
| `DontForget_Android_arm64_v1.8.23.apk` | `10,321,255 B` | **`10,347,183 B`** (`9.87 MiB`) | `+25,928 B` (`+0.25%`) | **`-61.99%`** | `f9b58ef97549ed1b` |
| `DontForget_Android_v1.8.23.apk` | `29,009,290 B` | **`29,088,346 B`** (`27.74 MiB`) | `+79,056 B` (`+0.27%`) | **`-63.14%`** | `3d11c6d0fbf1777e` |
| `DontForget_Android_v1.8.23.aab` | `62,430,868 B` | **`62,594,930 B`** (`59.70 MiB`) | `+164,062 B` (`+0.26%`) | **`-17.10%`** | `e5aa62fc26b0936a` |
| `DontForget_Setup_v1.8.23.exe` | `13,251,976 B` | **`13,269,364 B`** (`12.65 MiB`) | `+17,388 B` (`+0.13%`) | **`-11.97%`** | `b738db1313b6fa93` |
| `DontForget_Windows_Portable_v1.8.23.zip` | `15,719,636 B` | **`15,740,163 B`** (`15.01 MiB`) | `+20,527 B` (`+0.13%`) | **`-14.34%`** | `ae0b3445bd553a80` |
| `DontForget_Linux_x64_v1.8.23.tar.gz` | `12,688,990 B` | **`12,712,995 B`** (`12.12 MiB`) | `+24,005 B` (`+0.19%`) | **`-14.27%`** | `2337daac5cf1b190` |
| `DontForget_iOS_unsigned_v1.8.23.ipa` | `10,219,816 B` | **`10,242,177 B`** (`9.77 MiB`) | `+22,361 B` (`+0.22%`) | **`-12.68%`** | `7f735c69be709dde` |
| **四平台 7 包合计** | **`153,641,831 B`** | **`153,995,158 B`** (`146.86 MiB`) | **`+353,327 B`** (`+0.34 MiB` / `+0.23%`) | **`-83.59 MiB`** (`-36.27%`) | — |

- Windows x64 安装版与便携包未做 Authenticode 签名；Android 三包均经固定发行证书 `3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1` 校验通过；iOS 未签名 IPA（主包与 `PlugIns/ReminderActivity.appex` `1.8.23+94` 经发布门禁校验通过）需 AltStore 个人重签（免费账号每 7 天续期，非 App Store／TestFlight）。

## Windows 本机官方 CI 三轮运行中覆盖升级验收（全程零强杀）

- **验证 1：跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.22.93`→官方 CI `1.8.23.94`，PASS）**：详见 [windows-upgrade-94-ci-tray-hidden-running-2026-11-22.json](benchmarks/windows-upgrade-94-ci-tray-hidden-running-2026-11-22.json)。启动本机已装 `v1.8.22.93`（`PID 36392`）并以 `ShowWindow(SW_HIDE)` 隐藏至托盘态（确认 `Local\DontForget.GracefulUpgradeExit` 已注册），先备份最新数据与 SQLite 在线库后直接运行公开 CI `DontForget_Setup_v1.8.23.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`：Inno Setup 日志实录旧实例优雅释放单实例互斥锁、RestartManager 检出 0 占用应用并自然退出（总耗时 `2.36s`，退出码 `0`，全程零强杀）；实装 **27/27** 个载荷文件与公开 CI 便携包逐字节一致、PE `1.8.23.94`、`MaterialIcons-Regular.otf` 为 `30,616 B`、无旧版冗余文件残留、`HKCU\Software\Classes\AppUserModelId\DontForget` 有效；CLI `--help`（`rc=0`，`DontForget CLI v1.8.23`）／`--add "   "`（`rc=2`）／`--list`（`rc=0`，10 行）全通；SQLite schema 17 `integrity_check=ok`、回滚日志头 `[1, 1]` 升级前后及重开全程不变、三表（`Reminders=7 / MediaRecords=0 / Settings=1`）全字段与 DPAPI 凭据（`1` 项）一致；`v1.8.23.94` 普通重开（`PID 29948`）稳定运行并注册优雅退出事件。
- **验证 2：可见运行态官方 CI 覆盖升级（`1.8.23.94`→`1.8.23.94`，PASS）**：详见 [windows-upgrade-94-ci-visible-running-2026-11-22.json](benchmarks/windows-upgrade-94-ci-visible-running-2026-11-22.json)。对运行中 `PID 29948` 备份并禁止强关覆盖，耗时 `1.74s` 退出码 `0`、27/27 载荷一致、业务三表与 DPAPI 凭据及普通重开（`PID 19244`）全部一致。
- **验证 3：自托盘隐藏态（`SW_HIDE`）官方 CI 覆盖升级（`1.8.23.94`→`1.8.23.94`，PASS）**：详见 [windows-upgrade-94-ci-self-tray-hidden-2026-11-22.json](benchmarks/windows-upgrade-94-ci-self-tray-hidden-2026-11-22.json)。对 `PID 19244` 隐藏主窗后禁止强关覆盖，耗时 `1.76s` 退出码 `0`、27/27 载荷一致、普通重开（`PID 18964`）通过；测后通过 `Local\DontForget.GracefulUpgradeExit` 在 `329.7 ms` 内优雅关闭测试进程（`REMAINING_WIN_PROCS=0`）。

## Android（Pixel 8 Pro）正式包保全升级与新版 UI 实机验收

- **正式包同身份保全升级与新版界面核验（PASS，含更新检查网络超时如实记录）**（[android-upgrade-94-2026-11-22.json](benchmarks/android-upgrade-94-2026-11-22.json)）：
  - 升级前确认正式版 `com.yarnway.dontforget` 为 `1.8.22 (93)`，核验公开 CI ARM64 APK（`10,347,183 B` / `9.87 MiB`，SHA‑256 `f9b58ef9...`）为固定发行证书 `3db49656...`；应用内「数据与安全 → 导出完整备份」生成升级前最新明文 `DFBK2` 备份（`86,104 B`，schema 17，`Reminders=3 / MediaRecords=1 / Settings=1`，`reminders_media_sha256: d033065a...`）。
  - 同签名覆盖公开 CI `DontForget_Android_arm64_v1.8.23.apk` 后，实机已装 APK SHA‑256（`f9b58ef9...`）与公开 Release 一致，同机三个隔离 QA 包保持未改动。
  - 实机核验 `/data/app/.../lib/arm64` 仅含 `["libapp.so", "libdartjni.so", "libflutter.so"]`（`libsqlite3.so` 持续剔除）；Android 16 冷重开（`PID 20377`）全程 **0 条运行时 `logcat` 异常**；再次应用内导出 `DFBK2` 备份（`86,341 B`）验证 `3/1/1` 与 `reminders_media_sha256`（`d033065a...`）逐字节一致并清空临时导出记录。
  - 实机截图目视核验多项 `v1.8.23` 新改动：首页显示 `全部 1` 且隐藏空 `已完成 · 0` 开关；`未来` 视图切换正常；**AI 设置页**实机呈现新增的 **`本地模型`／`检测本地模型`** 探测卡片（`ai_settings_has_local_probe: true`）；**内容管理页**实机呈现新增的未扫描引导文案 `点击“扫描”检查本地存储与冗余媒体。`（`content_mgmt_shows_unscanned_hint: true`）；**关于页**显示 **`当前版本 1.8.23 (94)`**（`about_shows_1_8_23_94: true`）。
  - **更新检查网络超时如实记录**：在 Pixel 8 Pro 当前 Wi‑Fi 环境下点击「检查更新」触发网络超时并准确显示 `检查超时，请重试。`（`update_check_is_current: false`），不冒记为 `已是最新发布版`；公开 GitHub Release `v1.8.23` 的 `latest` 状态与 20 附件完整性已由本机独立 API 读回核验通过（见上方发行回执）。测后保持 `WeType` 输入法与 `font_scale=1.0` 不变并返回桌面。

## 未验范围与后续主线

- **Windows 活动桌面 `WinSta0\Default` 交互式 GUI／托盘菜单／桌面中文输入法与点开 Toast 唤醒**：当前代理运行于非活动隔离桌面 `WinSta0\exebox`（Windows DWM 不合成 ANGLE 客户端帧），继续如实保留为未验。
- **iPhone 真机（build94）**：本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证（最近独立读回仍为 `1.8.11/81`）。
- **Pixel 8 Pro 应用内更新检查复测**：待手机所连网络可稳定直连 GitHub API 时只读复点一次「检查更新」确认返回 `已是最新发布版`。
- **正式版云端 ASR 真实声学播音**与**实机 `LocalAppData\DontForget` 原地删除**：保持如实留存，详见 [Next_Steps_2026-11-02.md](Next_Steps_2026-11-02.md)。
