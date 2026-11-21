# v1.8.21／build92 最终发行与验收

[v1.8.21](https://github.com/yarnway/dontforget/releases/tag/v1.8.21) 已发布并设为 `latest`，四平台七包、20 附件独立读回通过。固定发布源码 `7cc4e8e1e848a2b8c7d1e3cf11da9b28202cbd0b`（schema 17，严格保持 SQLite 回滚日志头 `[1, 1]` 与既有凭据存储格式）。源码、自动化、安装包与真实设备验收严格分层记录：**本版聚焦全平台安装包深度瘦身（四平台 7 包合计减少 `80.66 MiB`／`-35.00%`，其中 Android ARM64 APK 直降 **`-60.83%`** 至 `10.17 MiB`、Android 通用 APK 直降 **`-62.27%`** 至 `28.39 MiB`、Windows 安装版降 **`-11.03%`** 至 `12.79 MiB`、便携包降 **`-13.10%`** 至 `15.23 MiB`、Linux 降 **`-12.67%`** 至 `12.35 MiB`、iOS 未签名 IPA 降至 **`9.99 MiB`**）与全链路冷启动／数据库／UI 运行时性能优化；Windows 本机依次一次性通过公开 CI 安装包「跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.20.91`→`1.8.21.92`，215 ms 优雅释放互斥锁、9 项旧版多余 DLL／`cupertino_icons` 100% 清除、29/29 载荷逐字节一致、零强杀）」、「可见运行态覆盖升级」与「自托盘隐藏态覆盖升级」三项验收；Pixel 8 Pro 正式版 `com.yarnway.dontforget` 已完成 `1.8.20 (91)`→`1.8.21 (92)` 同签名保全升级（实机确认 `libsqlite3.so` 彻底剔除、`useLegacyPackaging=true` 下 Android 16 零报错冷启与备份往返一致、30 KB 树摇图标实机视觉完整、关于页 `1.8.21 (92)` 且更新检查返回「已是最新发布版」）；iPhone 92 与 Windows 活动桌面交互式 GUI／托盘菜单／桌面中文输入法仍未验。**

## 源码与自动化

- **全平台安装包体积优化**：
  - `pubspec.yaml`／`pubspec.lock`：移除未使用的 `cupertino_icons`（`-258 KiB`）与已废弃空包 `sqlite3_flutter_libs`（零其他依赖漂移）。
  - `lib/services/notification_service.dart`：移除冷启动同步加载的全量 `package:timezone/data/latest.dart`（每 ABI 节省约 `385 KiB`，三 ABI 合计 > `1.1 MiB`），改用零开销 `tz.setLocalLocation(tz.UTC)` 与 `tz.TZDateTime.from(..., tz.UTC)`。
  - `assets/app_icon.ico`：托盘专用图标精简为 ≤64px 的 7 种尺寸（`49,366 B` → `15,392 B`，全平台同步受益；可执行文件／快捷方式全尺寸 256px 图标 `windows/runner/resources/app_icon.ico` 保持不变）。
  - `scripts/package_windows.ps1`、`scripts/build_linux.sh`、`scripts/build_macos.sh`、`scripts/build_ios.sh`、`scripts/build_android_variants.py`：全平台正式构建启用 `--split-debug-info=build/symbols/<platform>`（未开启混淆以保留栈名与 `runtimeType`）；规避 Flutter 3.44.9 `tool_backend.dart` 桌面端误加引号导致图标树摇失效的缺陷，使 Windows／Linux 桌面端 `MaterialIcons-Regular.otf` 从 `1,645,184 B` 缩减至 `30,048 B`（**-98.2%**）；桌面构建前自动清理 `flutter_assets` 增量缓存。
  - `scripts/prune_windows_bundle.py`、`windows_installer/installer.iss`、`scripts/package_artifacts.py`：解析所有 `.exe`／`.dll` PE 导入表仅随包打包实际传递引用的 3 个 MSVC CRT 运行库（剔除 7 个未用 CRT DLL 约 `1.09 MB` 与 Android 专用 `dartjni.dll`）；Inno Setup 升级 `lzma2/ultra64` 固实压缩并在 `[InstallDelete]` 中自动清理旧版残留的无用 DLL 与 `cupertino_icons` 目录；便携 ZIP 与 Linux `.tar.gz` 启用 9 级压缩。
  - `android/app/build.gradle.kts`：移除 `minSdk = 24` 下冗余 `multiDexEnabled`；启用 `jniLibs.useLegacyPackaging = true` 压缩直装 APK 原生库，并剔除 Android 端永不调用的桌面 FFI 库 `libsqlite3.so` 以及 `DebugProbesKt.bin`／冗余元数据。
- **启动延迟、数据库与界面运行时性能优化**：
  - `lib/data/database_helper.dart`、`lib/services/recovery/storage_bootstrap.dart`、`lib/services/security/credential_repository.dart`、`lib/providers/workspace_drafts_provider.dart`、`lib/main.dart`：新增单次 `DataGeneration` 绑定 `BootstrapSnapshot` 交接（写入／维护／关闭即刻失效），消除冷启动 4 次重复 `Settings` 读取与 2–4 次全表扫描；桌面端并行 `windowManager.ensureInitialized()` 与存储引导；SQLite `onOpen` 增加纯会话级 `cache_size = -8000`、`temp_store = MEMORY`、`busy_timeout = 5000`（严格保持回滚日志 `[1, 1]` 与 schema 17 索引不变）；`AudioPlayer`／`AudioRecorder` 懒初始化。
  - `lib/providers/providers.dart`、`lib/providers/departure_routines.dart`、`lib/providers/task_search_provider.dart`、`lib/providers/task_statistics_provider.dart`：提醒冷启对账与无活跃通知取消增加快路径；出发例程改 `O(1)` 集合判重；新增共享派生 `workspaceRemindersProvider`；草稿键入改为 350 ms 防抖合并写盘并在组件销毁与读取前自动 `flushPending()`。
  - `lib/models/reminder.dart`、`lib/app.dart`、`lib/ui/screens/home_screen.dart`、`lib/ui/widgets/input_bottom_bar.dart`、`lib/ui/widgets/task_card.dart`、`lib/ui/widgets/task_workspace_overview.dart` 等：记忆化 `occurrenceIdentity`；按 `select(...)` 收窄根组件、输入底栏、首页与任务卡片重建范围并拆分局部 `Consumer`；合并首页 10 秒心跳扫描并缓存完成数统计与 `findChildIndexCallback`；为图标与本地图片统一设置 `cacheWidth`／`ResizeImage` 解码上限。
- **自动化回归**：本机固定 Flutter `3.44.9` 下 `python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` 0 问题，全仓 `flutter test` **2,705 项通过／20 项文档化 Windows 跳过／0 失败**（含新增 `test/performance_optimizations_test.dart`），Python 脚本测试 **192 通过／6 项 POSIX 跳过／0 失败**（含新增 `scripts/tests/test_bundle_size_optimizations.py`）；固定提交主线 [CI 44942853490](https://github.com/yarnway/dontforget/actions/runs/44942853490) **7/7** 全部通过（Linux／Windows 质量测试、五平台构建及 Windows Server 2022 安装／升级／卸载与桌面启动冒烟）。

## 安装包与四平台体积对比

四平台七包、20 个公开附件均由 [发布工作流 44945602264](https://github.com/yarnway/dontforget/actions/runs/44945602264) 校验并发布，随后经独立 API 读回确认标签指向 `7cc4e8e1e848a2b8c7d1e3cf11da9b28202cbd0b`、`latest` 指向 `v1.8.21`、旧版 `v1.8.20`（`b820337968b9fa7279928aa87eab5234f387dfba`、20 附件）保持未改，详见 [github-release-v1.8.21-2026-11-22.json](benchmarks/github-release-v1.8.21-2026-11-22.json)：

| 发行产物 | `v1.8.20` (build91) | `v1.8.21` (build92) | 缩减字节 | 缩减比例 | `v1.8.21` SHA‑256（前 16 位） |
| --- | ---: | ---: | ---: | ---: | --- |
| `DontForget_Android_arm64_v1.8.21.apk` | `27,222,935 B` | **`10,664,355 B`** | **`-16,558,580 B`** | **`-60.83%`** | `8da7e521c226456e` |
| `DontForget_Android_v1.8.21.apk` | `78,908,607 B` | **`29,773,890 B`** | **`-49,134,717 B`** | **`-62.27%`** | `dddb9b6d851b0f7c` |
| `DontForget_Android_v1.8.21.aab` | `75,509,599 B` | **`63,827,509 B`** | **`-11,682,090 B`** | **`-15.47%`** | `9c752e9946df11c3` |
| `DontForget_Setup_v1.8.21.exe` | `15,073,293 B` | **`13,410,865 B`** | **`-1,662,428 B`** | **`-11.03%`** | `4f97d67ea5c220e8` |
| `DontForget_Windows_Portable_v1.8.21.zip` | `18,374,363 B` | **`15,967,858 B`** | **`-2,406,505 B`** | **`-13.10%`** | `6f6aecb7c06028c3` |
| `DontForget_Linux_x64_v1.8.21.tar.gz` | `14,829,968 B` | **`12,951,085 B`** | **`-1,878,883 B`** | **`-12.67%`** | `457f6b90f8371264` |
| `DontForget_iOS_unsigned_v1.8.21.ipa` | `11,729,041 B` | **`10,470,373 B`** | **`-1,258,668 B`** | **`-10.73%`** | `7e8bbbd4ff74df78` |
| **四平台 7 包合计** | **`241,647,806 B`** | **`157,065,935 B`** | **`-84,581,871 B`** (`-80.66 MiB`) | **`-35.00%`** | — |

- Windows x64 安装版与便携包未做 Authenticode 签名；Android 三包均经固定发行证书 `3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1` 校验通过；iOS 未签名 IPA（主包与 `PlugIns/ReminderActivity.appex` `1.8.21+92` 经发布门禁校验通过）需 AltStore 个人重签（免费账号每 7 天续期，非 App Store／TestFlight）。

## Windows 本机官方 CI 三轮运行中覆盖升级验收（全程零强杀）

- **验证 1：跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.20.91`→官方 CI `1.8.21.92`，PASS）**：详见 [windows-upgrade-92-ci-cross-tray-hidden-2026-11-22.json](benchmarks/windows-upgrade-92-ci-cross-tray-hidden-2026-11-22.json)。启动本机已装 `v1.8.20.91` 并以 `ShowWindow(SW_HIDE)` 隐藏至托盘态（确认 `Local\DontForget.GracefulUpgradeExit` 已注册），先备份最新数据与 SQLite 在线库后直接运行公开 CI `DontForget_Setup_v1.8.21.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`：Inno Setup 日志实录信号发出后仅 **215 ms** 释放单实例互斥锁并自然退出（退出码 `0`，全程零强杀）；安装器 `[InstallDelete]` 将旧版残留的 8 个无用 CRT/`dartjni.dll` 及 `packages\cupertino_icons` 目录 **100% 清除**；实装 **29/29** 个载荷文件与公开 CI 便携包逐字节一致、PE `1.8.21.92`、`MaterialIcons-Regular.otf` 为 `30,048 B`、`HKCU\Software\Classes\AppUserModelId\DontForget` 有效；CLI `--help`（`rc=0`，`DontForget CLI v1.8.21`）／`--add "   "`（`rc=2`）／`--list`（`rc=0`，10 行输出）全通；SQLite schema 17 `integrity_check=ok`、回滚日志头 `[1, 1]` 升级前后及重开全程不变、三表（`Reminders=7 / MediaRecords=0 / Settings=1`）全字段与 DPAPI 凭据（`1` 项）一致；裁剪后 3-CRT-DLL `v1.8.21.92` 普通重开（`PID 33544`）稳定运行并注册优雅退出事件。
- **验证 2：可见运行态官方 CI 覆盖升级（`1.8.21.92`→`1.8.21.92`，PASS）**：详见 [windows-upgrade-92-ci-visible-running-2026-11-22.json](benchmarks/windows-upgrade-92-ci-visible-running-2026-11-22.json)。对运行中 `PID 33544` 备份并禁止强关覆盖，耗时 `1.88s` 退出码 `0`、29/29 载荷一致、业务三表与 DPAPI 凭据及普通重开（`PID 16808`）全部一致。
- **验证 3：自托盘隐藏态（`SW_HIDE`）官方 CI 覆盖升级（`1.8.21.92`→`1.8.21.92`，PASS）**：详见 [windows-upgrade-92-ci-self-tray-hidden-2026-11-22.json](benchmarks/windows-upgrade-92-ci-self-tray-hidden-2026-11-22.json)。对 `PID 16808` 隐藏主窗后禁止强关覆盖，耗时 `1.95s` 退出码 `0`、29/29 载荷一致、普通重开（`PID 25848`）通过；测后通过 `Local\DontForget.GracefulUpgradeExit` 在 `265.6 ms` 内优雅关闭测试进程（`REMAINING_WIN_PROCS=0`）。

## Android（Pixel 8 Pro）正式包保全升级与瘦身运行时验收

- **正式包同身份保全升级与瘦身运行时全通过**（[android-upgrade-92-2026-11-22.json](benchmarks/android-upgrade-92-2026-11-22.json)）：
  - 升级前确认正式版 `com.yarnway.dontforget` 为 `1.8.20 (91)`（SHA‑256 `43839827...`），核验公开 CI ARM64 APK（`10,664,355 B`／`-60.83%`，SHA‑256 `8da7e521...`）为固定发行证书 `3db49656...`；应用内「数据与安全 → 导出完整备份」生成升级前最新明文 `DFBK2` 备份（schema 17，`Reminders=3 / MediaRecords=1 / Settings=1`，`reminders_media_sha256: d033065a...`）。
  - 同签名覆盖公开 CI `DontForget_Android_arm64_v1.8.21.apk` 后，实机已装 APK SHA‑256（`8da7e521...`）与公开 Release 一致，同机三个隔离 QA 包保持未改动。
  - 实机核验 `/data/app/.../lib/arm64` 仅含 `["libapp.so", "libdartjni.so", "libflutter.so"]`（**`libsqlite3.so` 彻底剔除**）；Android 16 冷重开（`PID 28138`）全程零 `UnsatisfiedLinkError`／零 `libsqlite3` 错误／零 Flutter 异常；再次应用内导出 `DFBK2` 备份验证 `3/1/1` 与 `reminders_media_sha256`（`d033065a...`）逐字节一致并清空临时导出记录；实机视觉核验首页与关于页截图确认 98.2% 树摇后的 `MaterialIcons-Regular.otf` 所有图标清晰完整无缺字；关于页显示 **`当前版本 1.8.21 (92)`**，手动点击「检查更新」返回 **`已是最新发布版`**（`公开版本 1.8.21 (92)`）；测后保持 `WeType` 与 `font_scale=1.0` 不变并返回桌面。

## 未验范围与后续主线

- **Windows 活动桌面 `WinSta0\Default` 交互式 GUI／托盘菜单／桌面中文输入法与点开 Toast 唤醒**：当前代理运行于非活动隔离桌面 `WinSta0\exebox`（Windows DWM 不合成 ANGLE 客户端帧），继续如实保留为未验。
- **iPhone 真机（build92）**：本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证（最近独立读回仍为 build81）。
- **正式版云端 ASR 真实声学播音**与**实机 `LocalAppData\DontForget` 原地删除**：保持如实留存，详见 [Next_Steps_2026-11-02.md](Next_Steps_2026-11-02.md)。
