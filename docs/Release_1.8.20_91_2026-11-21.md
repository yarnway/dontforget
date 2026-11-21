# v1.8.20／build91 发行与阶段性验收记录

[v1.8.20](https://github.com/yarnway/dontforget/releases/tag/v1.8.20) 已发布并设为 `latest`，四平台七包、20 附件独立读回通过。固定发布源码 `b820337968b9fa7279928aa87eab5234f387dfba`（schema 17）。源码、自动化、安装包与真实设备验收严格分层记录：**本版已完成四平台 CI（7/7）、发布工作流（2/2）与 20 附件独立读回，以及 Windows 本地／CI 官方安装器运行中初验失败留证（用户桌面运行中旧版 `v1.8.19.90` `PID 28900` 跨桌面退出码 `5`，数据与凭据完好无损）和 CI 官方便携包 CLI 校验；Windows 退出后覆盖安装＋托盘隐藏态官方安装器实机运行中优雅升级续验待用户退出 `PID 28900`，Pixel 8 Pro 正式版 `1.8.19 (90)`→`1.8.20 (91)` 保全升级与真实 TalkBack 复验待解锁 Android 16 定期安全 PIN 锁屏后补齐**；iPhone 91 与 Windows 活动桌面交互式 GUI／托盘菜单／桌面中文输入法仍未验。

## 源码与自动化

本版聚焦三类由 `v1.8.19` 真机／本机实测直接暴露的原生可靠性与无障碍收口，不更改数据库 schema 17、依赖锁文件或既有凭据存储格式：

- **Windows 托盘隐藏态优雅升级通道**：`windows/runner/flutter_window.h`、`flutter_window.cpp` 与 `windows_installer/installer.iss` 为 GUI 实例注册同用户会话级事件 `Local\DontForget.GracefulUpgradeExit`，安装器在 `PrepareToInstall`（遵循 `/NOCLOSEAPPLICATIONS` 且严禁强杀）先向运行中实例发送优雅退出信号并最长等待 8 秒自然释放，超时回退标准 Restart Manager。
- **Windows 11 Toast 禁用态准确报错与 AUMID 元数据注册**：`lib/services/windows_toast.dart` 兼容 PowerShell 5.1 WinRT 桥开启态 `$null` 与禁用态非空枚举，系统关闭通知时准确输出诊断 stderr 并退出码 `2`；`windows_installer/installer.iss` 新增 `HKCU\Software\Classes\AppUserModelId\DontForget`（`DisplayName` 与 `IconUri` 指向品牌图标，卸载自动清理）。
- **实机 TalkBack 反馈清零与永久性静态门禁**：`lib/ui/widgets/inline_feedback.dart` 改用不依赖 `Overlay` 祖先的 `MergeSemantics` + `Semantics(label: closeButtonTooltip)` 修复外层横幅误标与内层按钮无标签问题；`lib/ui/widgets/voice_capture_feedback.dart` 将 TalkBack 录音浮层 `取消` 升级为不透明深色底（`#2B2B2B`＋纯白文字，> 14:1 WCAG AAA）；补齐 `ai_profiles_screen.dart` 与剩余 4 处图片语义声明并新增永久性静态契约门禁 `scripts/tests/test_ui_accessibility_lint.py`。
- **自动化回归**：本机固定 Flutter `3.44.9` 下 `python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` 0 问题，`python scripts/report_windows_skipped_tests.py` 通过（14 项文档化 Windows 跳过），Python 脚本测试 **189 通过／6 项 POSIX 跳过／0 失败**；固定提交主线 [CI 44887222048](https://github.com/yarnway/dontforget/actions/runs/44887222048) **7/7** 全部通过（Linux `Analyze and test`、Windows `Windows analyze and test`、Windows／Linux／Android／macOS／iOS 五平台构建与 Windows Server 2022 安装／升级／卸载冒烟）。

## 安装包与分发

四平台七包、20 个公开附件均由 [发布工作流 44889388558](https://github.com/yarnway/dontforget/actions/runs/44889388558) 校验并发布，随后经独立 API 读回确认标签指向 `b820337968b9fa7279928aa87eab5234f387dfba`、`latest` 指向 `v1.8.20`、旧版 `v1.8.19`（`6eedd2a1717fb794a902fe22c2d585a1ecf0fdd7`、20 附件）保持未改，详见 [github-release-v1.8.20-2026-11-21.json](benchmarks/github-release-v1.8.20-2026-11-21.json)：

- **Windows x64（未做 Authenticode 签名）**：
  - `DontForget_Setup_v1.8.20.exe`（`15,073,293 B`，SHA‑256 `6419ed53a54e4d170a3c20256ff0d19bf8ca7a9609fc1af56d989841ea6c20b2`）
  - `DontForget_Windows_Portable_v1.8.20.zip`（`18,374,363 B`，SHA‑256 `744456df3f7c2c0c574ea29e544eabb8a83b8955ec52aaa5dfb23a118fafac96`）
- **Linux x64（Ubuntu 24.04 基线）**：
  - `DontForget_Linux_x64_v1.8.20.tar.gz`（`14,829,968 B`，SHA‑256 `2d81c0d6c55638bb32ca9cce506cef95ba5f30f179e017c94d7fd1de29a6b64a`）
- **Android（固定发行证书 `3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1` 本地 `apksigner` 与发布门禁双校验通过）**：
  - `DontForget_Android_arm64_v1.8.20.apk`（`27,222,935 B`，SHA‑256 `438398274d5cc078fdd38f4525b2898e049f6701cd547620275b5eb4daf630fd`）
  - `DontForget_Android_v1.8.20.apk`（`78,908,607 B`，SHA‑256 `07fcac68e91934aaa38b2798ddeda2ff572a5cc610849b85578677d15a596496`）
  - `DontForget_Android_v1.8.20.aab`（`75,509,599 B`，SHA‑256 `368b7b29320127d4518aae4d69601269e15e5ec812a6ccc444f9ec36b66ce53c`）
- **iOS（未签名，需 AltStore 个人重签，免费账号每 7 天续期，非 App Store／TestFlight）**：
  - `DontForget_iOS_unsigned_v1.8.20.ipa`（`11,729,041 B`，SHA‑256 `6e17e62c8288272e17aa9107c8477e2a2fd5dce000aa56384cc0e1406270822b`，主包与 `PlugIns/ReminderActivity.appex` `1.8.20+91` 身份／版本由发布门禁校验通过）

## Windows 本机初验留证与实证（待用户退出旧版 `PID 28900` 后续验）

- **本地与 CI 官方安装器运行中初验（FAIL，退出码 `5`，原始证据完整留存）**：用户交互桌面当前运行的实装进程 `PID 28900` 为旧版 `v1.8.19.90`（尚未包含 `v1.8.20` 的 `Local\DontForget.GracefulUpgradeExit` 通道）。本机分别使用本地构建包（[windows-upgrade-91-2026-11-21.json](benchmarks/windows-upgrade-91-2026-11-21.json)）与公开 Release 官方 CI 包（[windows-upgrade-91-ci-2026-11-21.json](benchmarks/windows-upgrade-91-ci-2026-11-21.json)）执行最新数据与 SQLite 在线备份→`/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`（禁止强关），Restart Manager 因跨桌面无可见主窗回滚并退出码 `5`；回滚后实装保持 `1.8.19.90`，SQLite 三表（`7/0/1`）哈希与 DPAPI 凭据（`1` 项）完整保持，未强杀用户进程。
- **CI 官方便携包与本机专项实证（PASS）**：公开 Release `DontForget_Windows_Portable_v1.8.20.zip`（`744456df...`）实测 PE 版本 `1.8.20.91`，内置 CLI `--help` 管道返回码 `0`（输出 `DontForget CLI v1.8.20`）、`--add "   "` 返回码 `2`、实机持锁态 `--list` 返回码 `75`（`Local data is in use`）；前序同源主线已完成隔离沙箱 `SW_HIDE` 托盘隐藏态 76ms 优雅退出内核实证，以及 Windows 11 真实 Toast 禁用态报错（`exit 2`）与临时注册 AUMID 真实 WinRT 通知中心投递（`History.Count=1`）并清理实证（[windows-toast-and-host-verify-2026-11-21.json](benchmarks/windows-toast-and-host-verify-2026-11-21.json)）。
- **待续验**：用户从桌面／托盘正常退出旧版 `v1.8.19.90`（`PID 28900`）一次后，立即执行官方 CI `DontForget_Setup_v1.8.20.exe`：① 退出后覆盖安装（`1.8.19.90`→`1.8.20.91`）并核验 `HKCU\Software\Classes\AppUserModelId\DontForget` 元数据；② 同桌面运行中覆盖升级（`1.8.20.91`→`1.8.20.91`）；③ **`SW_HIDE` 托盘隐藏态官方 CI 安装器运行中自动优雅关闭升级（`exit 0`，零强杀）**。

## Android（Pixel 8 Pro）正式包升级与 TalkBack 复验（待解锁 PIN 后执行）

- 已下载并独立校验公开 `DontForget_Android_arm64_v1.8.20.apk`（SHA‑256 `43839827...`，`apksigner` 固定发行证书 `3db49656...`）。
- 实机 `43201FDJG000M7` 当前触发 Android 16 定期安全锁定（`"需要锁定设备以提高安全性。已有一段时间未使用 PIN 码了。"`）。遵循不绕过锁屏与「先应用内导出最新备份再覆盖升级」规范，当前尚未安装 `1.8.20 (91)`（手机正式版仍保持 `1.8.19 (90)`）。待用户解锁后立即补齐 `1.8.19 (90)`→`1.8.20 (91)` 同签名保全升级与真实 TalkBack 复验（深色底 WCAG AAA「取消」按钮与 `InlineFeedback` 关闭按钮 `desc='关闭'`／零外层误标）。

## 未验范围与后续主线

- **Windows 活动桌面 `WinSta0\Default` 交互式 GUI／托盘菜单／桌面中文输入法与点开 Toast 唤醒**：当前代理运行于非活动隔离桌面 `WinSta0\exebox`（Windows DWM 不合成 ANGLE 客户端帧、`UIA_Nodes=2`），继续如实保留为未验。
- **iPhone 真机（build91）**：本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证（最近独立读回仍为 build81）。
- **正式版云端 ASR 真实声学播音**与**实机 `LocalAppData\DontForget` 原地删除**：保持如实留存，详见 [Next_Steps_2026-11-02.md](Next_Steps_2026-11-02.md)。
