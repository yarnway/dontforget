# v1.8.22／build93 最终发行与验收

[v1.8.22](https://github.com/yarnway/dontforget/releases/tag/v1.8.22) 已发布并设为 `latest`，四平台七包、20 附件独立读回通过。固定发布源码 `8ecad7c9526856c5f9ba4c307984607d4636d688`（schema 17，严格保持 SQLite 回滚日志头 `[1, 1]` 与既有凭据存储格式）。源码、自动化、安装包与真实设备验收严格分层记录：**本版从稳定性、美观性、易用性、运行时性能与安装包体积五个维度系统迭代——修复 12 项跨端边界隐患，统一明暗双主题与 WCAG AA（>= 4.5:1）象限配色并全面升级卡片／底栏／搜索／阅读／编辑／仪表盘／设置交互，引入三语框架本地化代理与 Android 语言资源裁剪使四平台 7 包在 `v1.8.21` 基础上再减 `3.27 MiB`（`-2.18%`，较 `v1.8.20` 累计缩减 `83.93 MiB`／`-36.42%`，其中 Android ARM64 APK 首次进入 10 MiB 以内至 `9.84 MiB`、iOS 未签名 IPA 降至 `9.75 MiB`）；Windows 本机一次性通过公开 CI 安装包「跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.21.92`→`1.8.22.93`，213 ms 优雅释放互斥锁、`[InstallDelete]` 清除 `packages\record_web`、27/27 载荷逐字节一致、零强杀）」、「可见运行态覆盖升级」与「自托盘隐藏态覆盖升级」三项验收；Pixel 8 Pro 正式版 `com.yarnway.dontforget` 已完成 `1.8.21 (92)`→`1.8.22 (93)` 同签名保全升级（实装 `10,321,255 B` SHA‑256 一致、冷重开零异常、`3/1/1` 备份往返逐字节一致、实机截图核验新首页计数徽章与 `AI 服务 · 仅本地模式` 徽章清晰完整、关于页显示 `1.8.22 (93)`，更新检查首次网络失败后单次只读重试确认 `已是最新发布版 / 公开版本 1.8.22 (93)`）；iPhone 93 与 Windows 活动桌面交互式 GUI／托盘菜单／桌面中文输入法仍未验。**

## 源码与自动化

- **稳定性与边界加固**：
  - Windows 原生与通知：`windows/runner/flutter_window.h`／`flutter_window.cpp`／`lib/services/windows_protocol_service.dart` 为 `WM_FONTCHANGE` 增加引擎空指针保护、对 `WM_COPYDATA` 载荷施加有界长度读取，并在 Dart `initialize` 握手前缓冲冷启动早期协议与升级退出信号；`lib/services/windows_toast.dart` 完整转义 PowerShell 5.1 Unicode 弯单引号（`U+2018`–`U+201B`）并改用带并发流排空与 10 秒超时收口的 `Process.start`。
  - Android 分享桥：`android/app/src/main/kotlin/com/yarnway/dontforget/SharedTextBridge.kt`／`MainActivity.kt` 为日志操作补齐 `@Synchronized` 并发保护、纪元切换时清理孤立 `handoffRoot/<id>` 目录，并将最大 32 MiB 的 `ContentProvider` 流拷贝移至单线程后台执行器避免主线程 ANR。
  - 状态恢复与网络／录音边界：`lib/app.dart` 中 `DesktopUpgradeExit.prepare()` 任一步骤失败时原子回滚已暂停子系统；修复 `WorkspaceDrafts.putAll` 未结清旧防抖等待者可能导致的挂起；`HomeController` 加固录音取消清理与恢复重试；`LLMService` 新增 `chatCompletionsUrl()` 规范化尾部斜杠并增加 30 秒 `sendTimeout`，`MultiAgentService` 统一使用 `requestModelName`；修复局域网同步回调关闭设置页后漏刷 `mediaRecordsProvider`、`input_bottom_bar.dart` 长按取消保护、`task_card.dart` 世代捕获时机及 `home_screen.dart` 播放报错状态竞态。
- **美观性、易用性与全链路交互升级**：
  - 统一主题令牌与 WCAG AA 象限配色：`lib/ui/theme/app_theme.dart` 优化浅色表面层次（`#F1F5F4` 底面＋纯白卡片）并新增明暗双主题均 >= 4.5:1 对比度的 `AppTheme.quadrantColor` 与 `AppTheme.quadrantIcon`，全面对齐 `task_board.dart`、`task_card.dart`、`task_reader_screen.dart`、`task_detail_screen.dart`、`dashboard_screen.dart` 与 `knowledge_graph_view.dart`。
  - 工作区与详情／仪表盘／设置打磨：桌面宽卡（>= 360px）悬停显示置顶／延后／编辑快捷图标，逾期任务支持一键延后与自定义时间选择；底栏时间胶囊支持点击编辑与一键清除；工作区页签显示实时计数并完善「全部」空态与「添加第一条事项」引导；首页新增 `N`/`Ctrl+N` 快速记录与 `1`–`4` 视图快捷键，命令面板新增按键帽样式，搜索栏升级胶囊样式且筛选芯片展示实时计数；阅读页支持 `Escape` 返回、实时倒计时与清单进度条并消除词汇笔记重复解析；编辑页统一 `Material` 分节卡片、补齐 48dp 触控热区与未保存圆点提示；仪表盘升级三色语义 KPI、等宽数字、占比百分比与平滑进度条；偏好设置新增 AI／同步状态徽章（严格保持 LAN 服务懒加载）；设置页新增 API 密钥显隐切换；统一 `InlineFeedback` 语义色与首帧语义可读入场动画。
- **性能提升与包体进一步瘦身**：
  - 三语框架本地化与平台裁剪：新增 `lib/l10n/framework_localizations.dart`（仅保留 `en`/`zh`/`ja`）替代全量 `Global*Localizations` 以在四平台 AOT 树摇 116 套未用语言表与 122 套日期符号；`android/app/build.gradle.kts` 增加 `resourceConfigurations += listOf("en", "zh", "zh-rCN", "zh-rTW", "ja")`（剔除 69 套无用系统语言资源）并排除 `kotlin/*.kotlin_builtins`；Windows／Linux 移除 Web 专用 `packages/record_web` 并在 Inno Setup `[InstallDelete]` 清理旧版残留。
  - 热路径提速：冷启动预读持久化语言避免重复通知渠道初始化，桌面语言切换降至 `O(1)`、移动端收窄至 `O(K)` 活跃窗口；静态提升高频正则并缓存双向链接分词；删除／清空事项内存直更免全表重载、批量元数据与例程保存降至 `O(N+M)`；`KnowledgeGraphView` 与 `VoiceCaptureFeedback` 引入 `RepaintBoundary`、精确 `shouldRepaint` 与 `TextPainter` 缓存；进一步收窄页面与组件 `Riverpod` `select(...)` 订阅范围。
- **自动化回归**：本机固定 Flutter `3.44.9` 下 `python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` 0 问题，全仓 `flutter test` **2,713 项通过／20 项文档化 Windows 跳过／0 失败**（含新增 `test/stability_and_polish_v1_8_22_test.dart` 8 项回归），Python 脚本测试 **192 通过／6 项 POSIX 跳过／0 失败**（含全仓无障碍门禁 `test_ui_accessibility_lint.py` 与扩展后的 `test_bundle_size_optimizations.py`）；固定提交主线 [CI 44987637794](https://github.com/yarnway/dontforget/actions/runs/44987637794) **7/7** 全部通过（Linux／Windows 质量测试、五平台构建及 Windows Server 2022 安装／升级／卸载与桌面启动冒烟）。

## 安装包与四平台体积对比

四平台七包、20 个公开附件均由 [发布工作流 44989612452](https://github.com/yarnway/dontforget/actions/runs/44989612452) 校验并发布，随后经独立 API 读回确认标签指向 `8ecad7c9526856c5f9ba4c307984607d4636d688`、`latest` 指向 `v1.8.22`、旧版 `v1.8.21`（`7cc4e8e1e848a2b8c7d1e3cf11da9b28202cbd0b`、20 附件）保持未改，详见 [github-release-v1.8.22-2026-11-22.json](benchmarks/github-release-v1.8.22-2026-11-22.json)：

| 发行产物 | `v1.8.21` (build92) | `v1.8.22` (build93) | 较 `v1.8.21` | 较 `v1.8.20` 累计 | `v1.8.22` SHA‑256（前 16 位） |
| --- | ---: | ---: | ---: | ---: | --- |
| `DontForget_Android_arm64_v1.8.22.apk` | `10,664,355 B` | **`10,321,255 B`** (`9.84 MiB`) | `-343,100 B` (`-3.22%`) | **`-62.09%`** | `4f3a18a411b36ac5` |
| `DontForget_Android_v1.8.22.apk` | `29,773,890 B` | **`29,009,290 B`** | `-764,600 B` (`-2.57%`) | **`-63.24%`** | `34e3db5b48e6c2c9` |
| `DontForget_Android_v1.8.22.aab` | `63,827,509 B` | **`62,430,868 B`** | `-1,396,641 B` (`-2.19%`) | **`-17.32%`** | `6de0f4d61bc17fd1` |
| `DontForget_Setup_v1.8.22.exe` | `13,410,865 B` | **`13,251,976 B`** | `-158,889 B` (`-1.18%`) | **`-12.08%`** | `eb486df739574f94` |
| `DontForget_Windows_Portable_v1.8.22.zip` | `15,967,858 B` | **`15,719,636 B`** | `-248,222 B` (`-1.55%`) | **`-14.45%`** | `71ec0fbcded6a376` |
| `DontForget_Linux_x64_v1.8.22.tar.gz` | `12,951,085 B` | **`12,688,990 B`** | `-262,095 B` (`-2.02%`) | **`-14.44%`** | `6a82ba8d02bd4988` |
| `DontForget_iOS_unsigned_v1.8.22.ipa` | `10,470,373 B` | **`10,219,816 B`** (`9.75 MiB`) | `-250,557 B` (`-2.39%`) | **`-12.87%`** | `ad8ed003b64965ed` |
| **四平台 7 包合计** | **`157,065,935 B`** | **`153,641,831 B`** (`146.52 MiB`) | **`-3,424,104 B`** (`-3.27 MiB` / `-2.18%`) | **`-83.93 MiB`** (`-36.42%`) | — |

- Windows x64 安装版与便携包未做 Authenticode 签名；Android 三包均经固定发行证书 `3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1` 校验通过；iOS 未签名 IPA（主包与 `PlugIns/ReminderActivity.appex` `1.8.22+93` 经发布门禁校验通过）需 AltStore 个人重签（免费账号每 7 天续期，非 App Store／TestFlight）。

## Windows 本机官方 CI 三轮运行中覆盖升级验收（全程零强杀）

- **验证 1：跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.21.92`→官方 CI `1.8.22.93`，PASS）**：详见 [windows-upgrade-93-ci-tray-hidden-running-2026-11-22.json](benchmarks/windows-upgrade-93-ci-tray-hidden-running-2026-11-22.json)。启动本机已装 `v1.8.21.92` 并以 `ShowWindow(SW_HIDE)` 隐藏至托盘态（确认 `Local\DontForget.GracefulUpgradeExit` 已注册），先备份最新数据与 SQLite 在线库后直接运行公开 CI `DontForget_Setup_v1.8.22.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`：Inno Setup 日志实录信号发出后仅 **213 ms** 释放单实例互斥锁、RestartManager 检出 0 占用应用并自然退出（退出码 `0`，全程零强杀）；安装器 `[InstallDelete]` 将旧版残留的 `packages\record_web` 目录 **100% 清除**；实装 **27/27** 个载荷文件与公开 CI 便携包逐字节一致、PE `1.8.22.93`、`MaterialIcons-Regular.otf` 为 `30,580 B`、`HKCU\Software\Classes\AppUserModelId\DontForget` 有效；CLI `--help`（`rc=0`，`DontForget CLI v1.8.22`）／`--add "   "`（`rc=2`）／`--list`（`rc=0`）全通；SQLite schema 17 `integrity_check=ok`、回滚日志头 `[1, 1]` 升级前后及重开全程不变、三表（`Reminders=7 / MediaRecords=0 / Settings=1`）全字段与 DPAPI 凭据（`1` 项）一致；`v1.8.22.93` 普通重开（`PID 37232`）稳定运行并注册优雅退出事件。
- **验证 2：可见运行态官方 CI 覆盖升级（`1.8.22.93`→`1.8.22.93`，PASS）**：详见 [windows-upgrade-93-ci-visible-running-2026-11-22.json](benchmarks/windows-upgrade-93-ci-visible-running-2026-11-22.json)。对运行中 `PID 37232` 备份并禁止强关覆盖，耗时 `1.79s` 退出码 `0`、27/27 载荷一致、业务三表与 DPAPI 凭据及普通重开（`PID 16836`）全部一致。
- **验证 3：自托盘隐藏态（`SW_HIDE`）官方 CI 覆盖升级（`1.8.22.93`→`1.8.22.93`，PASS）**：详见 [windows-upgrade-93-ci-self-tray-hidden-2026-11-22.json](benchmarks/windows-upgrade-93-ci-self-tray-hidden-2026-11-22.json)。对 `PID 16836` 隐藏主窗后禁止强关覆盖，耗时 `1.76s` 退出码 `0`、27/27 载荷一致、普通重开（`PID 36200`）通过；测后通过 `Local\DontForget.GracefulUpgradeExit` 在 `269.8 ms` 内优雅关闭测试进程（`REMAINING_WIN_PROCS=0`）。

## Android（Pixel 8 Pro）正式包保全升级与新版 UI／瘦身运行时验收

- **正式包同身份保全升级与新版运行时全通过**（[android-upgrade-93-2026-11-22.json](benchmarks/android-upgrade-93-2026-11-22.json)）：
  - 升级前确认正式版 `com.yarnway.dontforget` 为 `1.8.21 (92)`，核验公开 CI ARM64 APK（`10,321,255 B` / `9.84 MiB`，SHA‑256 `4f3a18a4...`）为固定发行证书 `3db49656...`；应用内「数据与安全 → 导出完整备份」生成升级前最新明文 `DFBK2` 备份（schema 17，`Reminders=3 / MediaRecords=1 / Settings=1`，`reminders_media_sha256: d033065a...`）。
  - 同签名覆盖公开 CI `DontForget_Android_arm64_v1.8.22.apk` 后，实机已装 APK SHA‑256（`4f3a18a4...`）与公开 Release 一致，同机三个隔离 QA 包保持未改动。
  - 实机核验 `/data/app/.../lib/arm64` 仅含 `["libapp.so", "libdartjni.so", "libflutter.so"]`（`libsqlite3.so` 持续剔除）；Android 16 冷重开（`PID 29578`）全程零 `UnsatisfiedLinkError`／零 `LocaleDataException`／零 Flutter 异常；再次应用内导出 `DFBK2` 备份验证 `3/1/1` 与 `reminders_media_sha256`（`d033065a...`）逐字节一致并清空临时导出记录；实机横屏暗色截图目视确认新版首页页签计数徽章（`全部 1`）、树摇图标及设置页 `AI 服务 · 仅本地模式` 状态胶囊渲染清晰无溢出；关于页显示 **`当前版本 1.8.22 (93)`**，手动点击「检查更新」首次因网络波动提示连接失败并保留记录，一次只读重试成功返回 **`已是最新发布版`**（`公开版本 1.8.22 (93)`）；测后保持 `WeType` 与 `font_scale=1.0` 不变并返回桌面。

## 发布后实机专项补验（2026-11-22）

- **Pixel 8 Pro `v1.8.22 (93)` 新特性、三语日期时间选择器与后台分享桥全链路验真（PASS）**：详见 [android-v1.8.22-feature-verify-2026-11-22.json](benchmarks/android-v1.8.22-feature-verify-2026-11-22.json)。在 Android 16 竖屏（`1008×2244`）正式版 `com.yarnway.dontforget` 上不改写用户数据实测：`TaskReaderScreen`→`TaskEditScreen` 打开真实中文 Material `DatePicker`（`选择日期`/`2026年11月`/`一..日`）与 `TimePicker`（`选择时间`），直接验证三语 `AppMaterialLocalizationsDelegate` 与自定义 `DateSymbols` 零 `LocaleDataException`；截图与无障碍树同步核验 `TaskSearchPanel` 筛选芯片计数（`全部 · 1`）、命令面板按键帽（`↑↓`/`Enter`/`Esc`）、`DashboardScreen` 三色 KPI 与象限百分比占比、`PreferencesScreen` `AI 服务 · 仅本地模式` 徽章、`SettingsScreen` API 密钥显隐切换（`显示密钥`↔`隐藏密钥`）与开启局域网服务端后 `设备与同步 · 共享中` 动态徽章（测后关闭）；发送实时 `ACTION_SEND` 文本验证 `SharedTextBridge.kt` 后台执行器无 ANR 投递至分享草稿，并经 UI 删除清理恢复「暂无分享草稿」与首页 `全部 1` 原状（全程 0 `logcat` 异常，`WeType` 与 `font_scale=1.0` 不变）。
- **Windows 11 `v1.8.22+93` 弯单引号 Toast 与冷启动早期升级退出缓冲实测（PASS）**：详见 [windows-v1.8.22-runtime-verify-2026-11-22.json](benchmarks/windows-v1.8.22-runtime-verify-2026-11-22.json)。① 实机 PowerShell 5.1 使用同时包含 ASCII `'`、四类 Unicode 弯单引号（`U+2018`–`U+201B`）、反引号与 `$env:TEMP` 的标题／正文及 `dontforget://` 动作按钮实测：保持用户 `DontForget` AUMID（`Enabled=0`）未改时准确输出 `Windows toast blocked: DisabledForApplication`（退出码 `2`，无语法报错）；临时注册 AUMID（`finally` 清除）实投至 Windows 11 通知中心（`History.Count=1`→`0`）退出码 `0`。② 实装 `dont_forget.exe`（`1.8.22+93`）启动并在 `OnCreate()` 注册 `Local\DontForget.GracefulUpgradeExit` 瞬间（`307.33 ms`）立即触发信号，验证 `pending_upgrade_exit_` 冷启动缓冲并在 Flutter `initialize` 后 `557.0 ms` 内优雅退出（退出码 `0`、`REMAINING_WIN_PROCS=0`），SQLite 回滚日志头 `[1, 1]`、三表（`7/0/1`）全行摘要与 `flutter_secure_storage.dat`（`742 B`）SHA‑256 逐字节不变。

## 未验范围与后续主线

- **Windows 活动桌面 `WinSta0\Default` 交互式 GUI／托盘菜单／桌面中文输入法与点开 Toast 唤醒**：当前代理运行于非活动隔离桌面 `WinSta0\exebox`（Windows DWM 不合成 ANGLE 客户端帧），继续如实保留为未验。
- **iPhone 真机（build93）**：本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证（最近独立读回仍为 build81）。
- **正式版云端 ASR 真实声学播音**与**实机 `LocalAppData\DontForget` 原地删除**：保持如实留存，详见 [Next_Steps_2026-11-02.md](Next_Steps_2026-11-02.md)。
