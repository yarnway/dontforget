# DontForget v1.8.20 · Android / Windows / Linux / iOS

聚焦 Windows 托盘隐藏态优雅升级退出、Windows 11 Toast 禁用态准确检测与通知中心 AUMID 注册、以及基于实机 TalkBack 反馈的全仓无障碍语义清零与 WCAG AAA 对比度收口的稳定版本。build91／schema17。

## 主要更新

### Windows 原生升级与通知可靠性
- **托盘隐藏态优雅升级通道**：GUI 实例注册同用户会话级事件 `Local\DontForget.GracefulUpgradeExit`，Inno Setup 安装器在 `PrepareToInstall` 中（遵循 `/NOCLOSEAPPLICATIONS` 且严禁强杀）优先请求运行中实例优雅落盘退出，彻底解决窗口最小化到系统托盘（`SW_HIDE`）时 Restart Manager 归类为 `RmUnknownApp` 导致升级中断的问题。
- **Windows Toast 禁用态准确检测**：检测 `ToastNotifier.Setting`（兼容 PowerShell 5.1 WinRT 桥开启态 `$null` 与禁用态非空枚举），当系统通知被关闭时准确输出诊断错误并返回 `false`，不再静默误报送达。
- **通知中心身份与图标元数据**：安装器新增 `HKCU\Software\Classes\AppUserModelId\DontForget`（`DisplayName` 与 `IconUri` 指向品牌图标，卸载自动清理）。

### 无障碍读屏与视觉对比度清零
- **浮动提示条关闭按钮语义修复**：`InlineFeedback` 关闭图标改用不依赖 `Overlay` 的 `MergeSemantics` + 本地化 `closeButtonTooltip`，消除实机外层横幅误标为按钮且内层关闭按钮无标签的问题。
- **TalkBack 录音浮层「取消」按钮高对比度**：升级为不透明深色底（`#2B2B2B`＋纯白文字，> 14:1 WCAG AAA），在浅灰底弧上清晰易读。
- **全仓控件语义清零门禁**：补齐 `AIProfilesScreen` 原始 `Switch` 与剩余 4 处图片语义声明，新增永久性静态契约测试 `test_ui_accessibility_lint.py` 校验全仓零未加标签 `IconButton`／原始 `Switch`／`Image`。
- 不更改数据库 schema17、依赖锁文件或既有模型／语音凭据存储格式。

## 下载与安装

- Windows x64：`DontForget_Setup_v1.8.20.exe` 安装版或 `DontForget_Windows_Portable_v1.8.20.zip` 便携包，未做 Authenticode 签名。
- Linux x64：`DontForget_Linux_x64_v1.8.20.tar.gz`，Ubuntu 24.04 基线。
- Android：固定发行证书签名的通用 APK（`DontForget_Android_v1.8.20.apk`）、ARM64 APK（`DontForget_Android_arm64_v1.8.20.apk`）及 AAB（`DontForget_Android_v1.8.20.aab`）。
- iOS：`DontForget_iOS_unsigned_v1.8.20.ipa` 为未签名 IPA，需要通过 AltStore 个人重签；免费账号通常每 7天 续期。安装方式见[说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)，不属于 App Store 或 TestFlight 分发。

## 验收范围与限制

源码、自动化测试、安装包与真实设备验收严格分层记录，详见[后续阶段与验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)：
- **自动化**：固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、全仓 `flutter test`（2,701 项通过／20 项文档化 Windows 跳过／0 失败，含 `test/accessibility_guidelines_test.dart` 与 `test/windows_toast_test.dart` 新增回归）、Python 脚本测试（189 通过／6 跳过，含 `test_ui_accessibility_lint.py` 与 `test_windows_runner_cli.py`）全部通过，并经主线四平台 CI 校验。
- **Windows 本机与安装包**：已完成本地 `DontForget_Setup_v1.8.20.exe`／便携包编译与 `verify_artifacts.py` 校验、隔离沙箱 `SW_HIDE` 托盘隐藏态 76ms 优雅退出内核实证，以及真实 Windows 11 Toast 禁用态检测（退出码 `2`）与注册 AUMID 真实 WinRT 通知中心投递实证；本机升级回执与发版后 CI 官方包实机升级按 `AGENTS.md` 分层归档于台账。
- **Android 实机（Pixel 8 Pro）**：公开发布后将对公开正式版 `com.yarnway.dontforget` 执行最新保全同签名升级至 `1.8.20 (91)` 并复验真实 TalkBack 下深色高对比度「取消」按钮与浮动提示条关闭语义，结果单独归档于台账。
- **未验／限制范围**：Windows 活动桌面 `WinSta0\Default` 交互式 GUI／桌面中文输入法／托盘右键菜单、iPhone 真机安装与运行（本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证）、正式版云端 ASR 真实声学播音（未配置云端密钥）及实机 `LocalAppData\DontForget` 原地删除仍明确留存，不记为全部原生矩阵通过。
