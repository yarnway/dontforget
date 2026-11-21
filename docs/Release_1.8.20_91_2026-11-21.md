# v1.8.20／build91 最终发行与验收

[v1.8.20](https://github.com/yarnway/dontforget/releases/tag/v1.8.20) 已发布并设为 `latest`，四平台七包、20 附件独立读回通过。固定发布源码 `b820337968b9fa7279928aa87eab5234f387dfba`（schema 17）。源码、自动化、安装包与真实设备验收严格分层记录：**Windows 本机先后完整保留覆盖运行中旧版 `v1.8.19.90`（`PID 28900`，尚不含本版新增通道）正常关闭失败（退出码 `5`）原始证据，并在用户从桌面／托盘正常退出后依次通过官方 CI 安装包「退出后覆盖安装（`1.8.19.90`→`1.8.20.91`，含 `AppUserModelId\DontForget` 元数据核验）」、「同桌面可见运行中覆盖升级（`1.8.20.91`→`1.8.20.91`）」及「`SW_HIDE` 托盘隐藏态官方安装器运行中自动优雅退出升级（207 ms 释放互斥锁、RestartManager 零占用、退出码 `0`、全程零强杀）」三项续验；Pixel 8 Pro 正式版 `com.yarnway.dontforget` 已完成 `1.8.19 (90)`→`1.8.20 (91)` 同签名保全升级与真实 Android TalkBack 视觉／语义复验（深色高对比度 `取消` 按钮＋`InlineFeedback` `desc='关闭'` `48×48dp` 按钮且零外层误标）**；iPhone 91 与 Windows 活动桌面交互式 GUI／托盘菜单／桌面中文输入法仍未验。

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

## Windows 本机覆盖升级（初验失败留证与退出后三项官方 CI 续验分别记录）

- **初验：跨桌面运行中旧版正常关闭失败（FAIL，退出码 `5`，原始证据完整留存）**：用户交互桌面运行中的实装进程 `PID 28900` 为旧版 `v1.8.19.90`（尚未包含 `v1.8.20` 的 `Local\DontForget.GracefulUpgradeExit` 通道）。本机分别使用本地构建包（[windows-upgrade-91-2026-11-21.json](benchmarks/windows-upgrade-91-2026-11-21.json)）与公开 Release 官方 CI 包（[windows-upgrade-91-ci-2026-11-21.json](benchmarks/windows-upgrade-91-ci-2026-11-21.json)）执行最新数据与 SQLite 在线备份→`/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`（禁止强关），Restart Manager 因跨桌面无可见主窗回滚并退出码 `5`；回滚后实装保持 `1.8.19.90`，SQLite 三表（`7/0/1`）哈希与 DPAPI 凭据（`1` 项）完整保持，未强杀用户进程。另独立验证 CI 官方便携包 PE `1.8.20.91` 及 CLI `--help`（`rc=0`）／`--add "   "`（`rc=2`）／持锁 `--list`（`rc=75`）。
- **续验 1：用户退出后官方 CI 覆盖安装（PASS，单独记录，不替代初验失败）**：详见 [windows-upgrade-91-ci-post-exit-2026-11-21.json](benchmarks/windows-upgrade-91-ci-post-exit-2026-11-21.json)。用户从桌面／托盘退出 `PID 28900` 后，执行最新数据与 SQLite 在线备份→公开 CI `DontForget_Setup_v1.8.20.exe` 覆盖安装（`1.8.19.90`→`1.8.20.91`，退出码 `0`）→38 个载荷与 CI 官方便携包逐字节一致、PE `1.8.20.91`、CLI `--help`（`rc=0`，`DontForget CLI v1.8.20`）／`--add "   "`（`rc=2`）／`--list`（`rc=0`，10 行输出）、SQLite schema 17 `integrity_check=ok`、`Reminders=7 / MediaRecords=0 / Settings=1` 全业务字段与 DPAPI 凭据（`1` 项）及普通重开（`PID 14840`）保持一致；并实机核验注册表 `HKCU\Software\Classes\AppUserModelId\DontForget`（`DisplayName="DontForget"`、`IconUri` 指向已落盘的品牌图标 `app_icon.png`）。
- **续验 2：同桌面可见运行中官方 CI 覆盖升级（PASS，禁止强关）**：详见 [windows-upgrade-91-ci-running-followup-2026-11-21.json](benchmarks/windows-upgrade-91-ci-running-followup-2026-11-21.json)。保持运行中的 `v1.8.20.91`（`PID 14840`）完成最新备份→官方 CI 安装器执行 `/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS` 覆盖（退出码 `0`，无强关）→38 载荷一致、PE `1.8.20.91`、CLI 全通、业务三表（`7/0/1`）与 DPAPI 凭据（`1` 项）及普通重开（`PID 35424`）一致。
- **续验 3：`SW_HIDE` 托盘隐藏态官方 CI 安装器运行中自动优雅关闭升级（PASS，禁止强关，本版核心实证）**：详见 [windows-upgrade-91-ci-tray-hidden-running-2026-11-21.json](benchmarks/windows-upgrade-91-ci-tray-hidden-running-2026-11-21.json)。对实装运行中的 `v1.8.20.91`（`PID 35424`）调用 `ShowWindow(SW_HIDE)` 模拟隐藏到系统托盘（`window_visible_before_sw_hide=true` → `window_visible_after_sw_hide=false`），确认内核事件 `Local\DontForget.GracefulUpgradeExit` 已注册并完成最新备份后，直接调用公开 CI `DontForget_Setup_v1.8.20.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`：Inno Setup 日志实录 `Signaling Local\DontForget.GracefulUpgradeExit for tray-safe graceful shutdown.` 后仅 **207 ms** 收到 `DontForget released single-instance mutex gracefully.`，随后 `RestartManager found no applications using one of our files.`，总耗时 `1.89s` 退出码 `0`（全程零强杀）；38 个载荷一致、PE `1.8.20.91`、`AppUserModelId\DontForget` 有效、CLI 全通、SQLite `7/0/1` 与 DPAPI `1` 及普通重开（`PID 33716`）全部一致；测后通过 `Local\DontForget.GracefulUpgradeExit` 优雅清理测试进程（`273.8 ms`，无残留锁）。
- 另保留发版前 Windows 11 真实 Toast 禁用态检测（`exit 2`）与临时注册 AUMID 真实 WinRT 通知中心投递（`History.Count=1`）并清理实证（[windows-toast-and-host-verify-2026-11-21.json](benchmarks/windows-toast-and-host-verify-2026-11-21.json)）。本轮仍受非活动隔离桌面 `WinSta0\exebox` 限制，未验交互式桌面 GUI／托盘右键菜单／桌面中文输入法与点开 Toast 唤醒。

## Android（Pixel 8 Pro）正式包保全升级与真实 TalkBack 复验

- **正式包同身份保全升级通过**（[android-upgrade-91-2026-11-21.json](benchmarks/android-upgrade-91-2026-11-21.json)）：
  - 升级前确认正式版 `com.yarnway.dontforget` 为 `1.8.19 (90)`（SHA‑256 `69f2f6e5...`），核验公开 ARM64 包签名证书为固定发行证书 `3db49656...`；经应用内「数据与安全 → 导出完整备份」生成升级前最新明文 `DFBK2` 备份并本地校验（schema 17，`Reminders=2 / MediaRecords=0 / Settings=1`，`reminders_media_sha256: b4d0a324...`）。
  - 同签名覆盖公开 ARM64 `DontForget_Android_arm64_v1.8.20.apk` 后，读回手机已装 APK SHA‑256（`43839827...`）与公开 Release 完全一致，同机三个隔离 QA 包保持未改动。
  - 冷重开（`PID 25558`）后再次导出明文 `DFBK2` 备份复核 `2/0/1` 与 `reminders_media_sha256`（`b4d0a324...`）逐字节一致，清空临时导出记录；「设置 → 关于与更新」显示 **`当前版本 1.8.20 (91)`**，点击「检查更新」返回 **`已是最新发布版`**（`公开版本 1.8.20 (91)`）。
- **真实 Android TalkBack 视觉与语义复验通过**（[pixel-formal-91-talkback-2026-11-21.json](benchmarks/pixel-formal-91-talkback-2026-11-21.json)）：
  - 实机开启 `TalkBackService`（`accessibility_enabled=1`、`touch_exploration_enabled=1`）并临时授予录音权限，单击首页 `按住说话` 弹出无障碍录音浮层：`保存原语音`、`转文字编辑`、`取消` 三按钮均严格满足 `>= 48dp`（`48.0dp @ 360dpi`），实机截图确认深色不透明底（`#2B2B2B`＋纯白前景）的 `取消` 按钮在浅灰底弧上清晰易读。
  - 点击 `转文字编辑` 进入 `核对文字` 弹窗并触发顶部浮动提示条（`"请核对文字，或发送原语音。"`）：Accessibility 树实测零未加标签 `NAF` 控件（`naf_unlabeled_buttons=[]`），关闭图标精确暴露为 `clickable=true`、`content-desc="关闭"`、`108×108px = 48×48dp`，外层横幅误标计数为 **`0`**；全程 0 Flutter 异常。
  - 测后已完整恢复 `enabled_accessibility_services=null`、`accessibility_enabled=0`、撤销 `RECORD_AUDIO`（`granted=false`）、保持 `WeType` 与 `font_scale=1.0` 不变并返回桌面。

## 未验范围与后续主线

- **Windows 活动桌面 `WinSta0\Default` 交互式 GUI／托盘菜单／桌面中文输入法与点开 Toast 唤醒**：当前代理运行于非活动隔离桌面 `WinSta0\exebox`（Windows DWM 不合成 ANGLE 客户端帧、`UIA_Nodes=2`），继续如实保留为未验。
- **iPhone 真机（build91）**：本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证（最近独立读回仍为 build81）。
- **正式版云端 ASR 真实声学播音**与**实机 `LocalAppData\DontForget` 原地删除**：保持如实留存，详见 [Next_Steps_2026-11-02.md](Next_Steps_2026-11-02.md)。
