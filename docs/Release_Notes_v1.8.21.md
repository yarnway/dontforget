# DontForget v1.8.21 · Android / Windows / Linux / iOS

聚焦**跨平台安装包大幅瘦身**与**全链路启动／数据库／UI 运行时性能优化**的迭代版本。在不改变数据库 schema17、回滚日志完整性约束及任何用户凭据／数据格式的前提下，Android ARM64 安装包直降超 60%，Windows 安装版与便携包分别缩减约 11% 与 13%，冷启动冗余查询、高频键入写盘与无谓界面重建全面收口。build92／schema17。

## 主要更新

### 安装包与分发体积优化
- **清理冗余依赖与大体积内置表（`pubspec.yaml`、`lib/services/notification_service.dart`、`assets/app_icon.ico`）**：移除未使用的 `cupertino_icons`（节省约 258 KiB 原始字体）与已废弃的空包 `sqlite3_flutter_libs`；移除冷启动同步初始化且未使用的 `package:timezone/data/latest.dart` 全量时区数据库（每 ABI 节省约 385 KiB 编译体积，三 ABI 合计 > 1.1 MiB），改用 `tz.UTC` 零开销初始化；精简托盘专用 `assets/app_icon.ico` 仅保留 ≤64px 尺寸（保留可执行文件／快捷方式全尺寸 256px 图标不变）。
- **全平台符号分离与图标字库树摇（`scripts/package_windows.ps1`、`scripts/build_linux.sh`、`scripts/build_macos.sh`、`scripts/build_ios.sh`、`scripts/build_android_variants.py`）**：全平台正式构建统一启用 `--split-debug-info=build/symbols/<platform>`（未开启混淆以保留诊断栈与 `runtimeType`）；规避 Flutter 3.44.9 桌面端 `tool_backend.dart` 误加引号导致图标树摇静默失效的问题，使 Windows／Linux 桌面端 `MaterialIcons-Regular.otf` 从 1.65 MB 缩减至 30 KB（**-98.2%**）；构建前自动清理 `flutter_assets` 残留缓存。
- **Windows 精准 CRT 裁剪、高压缩比打包与升级残留清理（`scripts/prune_windows_bundle.py`、`windows_installer/installer.iss`、`scripts/package_artifacts.py`）**：静态解析所有可执行文件与 DLL 的 PE 导入表，仅打包实际传递引用的 3 个 MSVC CRT 运行库（移除 7 个未被引用的 CRT DLL 约 1.09 MB 及仅用于 Android 的 `dartjni.dll`）；Inno Setup 启用 `lzma2/ultra64` 固实压缩（便携 ZIP 与 Linux `.tar.gz` 启用 9 级压缩），并在 `[InstallDelete]` 中自动清理旧版升级残留的无用 DLL 与 `cupertino_icons` 资源。
- **Android 原生库压缩与无效原生库剔除（`android/app/build.gradle.kts`）**：移除 `minSdk = 24` 下冗余的 `multiDexEnabled`；启用 `jniLibs.useLegacyPackaging = true` 压缩直装 APK 中的 `.so` 库，并剔除 Android 端永不调用（Android 全程使用系统 `sqflite`）的桌面 FFI 库 `libsqlite3.so` 以及 `DebugProbesKt.bin`／冗余元数据，本地实测 ARM64 Release APK 从 `27.22 MB` 降至 `10.67 MB`（**-60.8%**）。

### 启动延迟、数据库与界面运行时性能优化
- **冷启动单次快照交接与并行初始化（`lib/services/recovery/storage_bootstrap.dart`、`lib/data/database_helper.dart`、`lib/main.dart`、`lib/services/security/credential_repository.dart`、`lib/providers/workspace_drafts_provider.dart`）**：引导阶段预读单次 `DataGeneration` 绑定的 `BootstrapSnapshot`（写入／维护／关闭即刻失效），消除冷启动 4 次重复 `Settings` 读取与 2–4 次全表扫描；桌面端并行执行 `windowManager.ensureInitialized()` 与 `StorageBootstrap.prepare()`；`AudioPlayer` 与 `AudioRecorder` 改为首次实际播放／录音时懒初始化；SQLite `onOpen` 增加纯会话级性能 PRAGMA（`cache_size = -8000`、`temp_store = MEMORY`、`busy_timeout = 5000`），严格保持既有回滚日志模式（`[1, 1]`）与 schema17 索引契约不变。
- **数据层热路径与写盘合并（`lib/providers/providers.dart`、`lib/providers/departure_routines.dart`、`lib/providers/workspace_drafts_provider.dart`）**：提醒加载前增加 `state.any(...)` 快捷路径跳过无意义的出发／普通事项对账，并在当前纪元 `NotificationJournal` 无活跃系统通知时跳过冗余 `cancelReminderStrict`；出发例程写入改为 `O(1)` 集合判重；新增共享派生 `workspaceRemindersProvider` 供首页、搜索与统计复用；草稿编辑改为 350 ms 防抖合并落盘并在组件销毁与读取前自动冲刷（`flushPending`）。
- **渲染重建收敛与图像解码内存上限（`lib/app.dart`、`lib/models/reminder.dart`、`lib/ui/screens/home_screen.dart`、`lib/ui/widgets/input_bottom_bar.dart`、`lib/ui/widgets/task_card.dart`、`lib/ui/widgets/task_workspace_overview.dart` 等）**：记忆化 `Reminder.occurrenceIdentity`；按 `select(...)` 精细收窄根组件、底栏输入框、首页与卡片监听范围并将桌面语音预览／处理中状态／沉浸模式拆入局部 `Consumer`；合并首页 10 秒心跳扫描并缓存完成数统计与 `findChildIndexCallback`；为应用图标、附件与本地图片解码统一设置 `cacheWidth` / `ResizeImage` 上限。

## 下载与安装

- Windows x64：`DontForget_Setup_v1.8.21.exe` 安装版或 `DontForget_Windows_Portable_v1.8.21.zip` 便携包，未做 Authenticode 签名。
- Linux x64：`DontForget_Linux_x64_v1.8.21.tar.gz`，Ubuntu 24.04 基线。
- Android：固定发行证书签名的通用 APK（`DontForget_Android_v1.8.21.apk`）、ARM64 APK（`DontForget_Android_arm64_v1.8.21.apk`）及 AAB（`DontForget_Android_v1.8.21.aab`）。
- iOS：`DontForget_iOS_unsigned_v1.8.21.ipa` 为未签名 IPA，需要通过 AltStore 个人重签；免费账号通常每 7天 续期。安装方式见[说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)，不属于 App Store 或 TestFlight 分发。

## 验收范围与限制

源码、自动化测试、安装包与真实设备验收严格分层记录，详见[后续阶段与验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)：
- **自动化**：固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、全仓 `flutter test`（2,705 项通过／20 项文档化 Windows 跳过／0 失败，含 `test/performance_optimizations_test.dart` 新增冷启动快照、SQLite 会话 PRAGMA、草稿防抖冲刷与 `occurrenceIdentity` 回归）、Python 脚本测试（192 通过／6 跳过，含 `test_bundle_size_optimizations.py` PE 导入表与瘦身契约回归）全部通过，并经主线四平台 CI 校验。
- **本地包体与运行核验**：已完成本地 Windows `DontForget_Setup_v1.8.21.exe`／便携包（较 `v1.8.20` 分别减少约 `11.0%` 与 `13.1%`）及 Android ARM64 APK（较 `v1.8.20` 减少 `60.8%`）的编译与结构校验；公开发布后将对 CI 官方 Windows 安装包（含托盘隐藏态运行中升级与裁剪后 CRT 实机运行）与 Pixel 8 Pro 正式版 `com.yarnway.dontforget`（含 `libsqlite3.so` 剔除与原生库压缩后的冷启／读写／备份实测）执行真实设备升级验收并归档回执。
- **未验／限制范围**：Windows 活动桌面 `WinSta0\Default` 交互式 GUI／桌面中文输入法／托盘右键菜单、iPhone 真机安装与运行（本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证）、正式版云端 ASR 真实声学播音（未配置云端密钥）及实机 `LocalAppData\DontForget` 原地删除仍明确留存，不记为全部原生矩阵通过。
