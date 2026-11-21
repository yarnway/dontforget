# v1.8.19／build90 最终发行与验收

[v1.8.19](https://github.com/yarnway/dontforget/releases/tag/v1.8.19) 已发布并设为 `latest`，四平台七包、20 附件独立读回通过。固定发布源码 `6eedd2a1717fb794a902fe22c2d585a1ecf0fdd7`（代码提交 `7e28ef0953b030fd482fdf3c36208b93dfb49da9`，schema 17）。源码、自动化、安装包与真实设备验收严格分层记录：**Windows 本机运行中覆盖升级因用户桌面运行中进程 `PID 19044` 跨桌面正常关闭失败（退出码 `5`）已完整保留失败证据且未强杀，尚待用户退出后续验**；iPhone 90 未安装／未真机验收；Windows 原生 GUI／托盘／Toast 仍受非交互桌面会话限制未实测。

## 源码与自动化

本版聚焦无障碍读屏（Android TalkBack／iOS VoiceOver）与 WCAG AA 合规、Windows CLI／Runner 管道与无闪窗修复及全链路 UTF‑16 代理对安全截断，不更改数据库 schema 17、依赖锁文件或既有凭据存储格式。

- 本机固定 Flutter `3.44.9` 下：`python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` 0 问题，`python scripts/report_windows_skipped_tests.py` 通过（14 项文档化 Windows 跳过），Python 脚本测试 **184 通过／6 项 POSIX 跳过／0 失败**（含新增 `scripts/tests/test_windows_runner_cli.py`），全仓 `flutter test --no-pub --concurrency 2 --timeout 2m` **2,699 通过／20 项文档化 Windows 跳过／0 失败**（含新增 `test/accessibility_guidelines_test.dart` 与 `test/text_bounds_test.dart`）。
- 最终主线 [CI 44863670223](https://github.com/yarnway/dontforget/actions/runs/44863670223) 七项任务全部成功（Linux `Analyze and test`、Windows `Windows analyze and test`、Windows／Linux／Android／macOS／iOS 五平台构建与桌面安装／启动冒烟）。

## 安装包与分发

四平台七包、20 个公开附件均由 [发布工作流 44869031743](https://github.com/yarnway/dontforget/actions/runs/44869031743) 校验并发布，随后经独立 API 读回确认标签指向 `6eedd2a1717fb794a902fe22c2d585a1ecf0fdd7`、`latest` 指向 `v1.8.19`、旧版 `v1.8.18`（`4855976`、20 附件）保持未改，详见 [github-release-v1.8.19-2026-11-21.json](benchmarks/github-release-v1.8.19-2026-11-21.json)：

- **Windows x64（未做 Authenticode 签名）**：
  - `DontForget_Setup_v1.8.19.exe`（`15,072,678 B`，SHA‑256 `395d9efe841cfa7e712a9bab9267578f9739563c33b2b6a9f72d8fc97da6d2b6`）
  - `DontForget_Windows_Portable_v1.8.19.zip`（`18,374,031 B`，SHA‑256 `3ed518041babb00463de92656035e0d3294e3e75b005cd0ff48863ad7b38ecc5`）
- **Linux x64（Ubuntu 24.04 基线）**：
  - `DontForget_Linux_x64_v1.8.19.tar.gz`（`14,828,862 B`，SHA‑256 `c21697125641a092566f386962184c1ec9ef2dd1dda2db2be8103f57dd7094d5`）
- **Android（固定发行证书 `3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1` 校验通过）**：
  - `DontForget_Android_arm64_v1.8.19.apk`（`27,222,935 B`，SHA‑256 `69f2f6e55be5feb514266665eb9f1e9f13ce9f28110317e8c9f0827b515cf07e`）
  - `DontForget_Android_v1.8.19.apk`（`78,908,607 B`，SHA‑256 `75c895fb278d95c0d80cc338250704f9d4a68d7f5a0327419e3f043461f21d93`）
  - `DontForget_Android_v1.8.19.aab`（`75,508,044 B`，SHA‑256 `2e40e05222561b97b58b8f3519343457ed7a4ec04b519107c2bf1c1eb2898cb3`）
- **iOS（未签名，需 AltStore 个人重签，免费账号每 7 天续期，非 App Store／TestFlight）**：
  - `DontForget_iOS_unsigned_v1.8.19.ipa`（`11,728,281 B`，SHA‑256 `2aaf162937cf3f3b9ffc13c220f1da8e9737a76ba29e2bc61d01e6382531f6de`，主包与 Live Activity WidgetKit 扩展身份／版本由发布门禁校验通过）

## Windows 本机覆盖升级状态（失败留证，待用户退出后续验）

- **本地包与 CI 官方包两次运行中尝试均正常关闭失败（退出码 `5`）**：用户经 `explorer.exe`（`PID 6556`）在其交互桌面启动的 `dont_forget.exe`（`PID 19044`，`v1.8.18.89`）全程处于运行态。自当前隔离桌面（`WinSta0\exebox-...`）调用安装器 `/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`（禁止强关），Restart Manager 将跨桌面／托盘无可见主窗的 `PID 19044` 归类为 `RmUnknownApp`（`Type=0, Restartable=False`）并在 0.7s 内中止回滚。
- 两次尝试前均已完成最新数据与 SQLite 在线备份，回滚后复核实装程序仍保持 `1.8.18.89`、SQLite schema 17 `Reminders=7 / MediaRecords=0 / Settings=1` 全业务字段与 DPAPI 凭据（`1` 项）完好无损；详见本地包回执 [windows-upgrade-90-2026-11-21.json](benchmarks/windows-upgrade-90-2026-11-21.json) 与 CI 官方包回执 [windows-upgrade-90-ci-2026-11-21.json](benchmarks/windows-upgrade-90-ci-2026-11-21.json)。
- **CLI 与 PE 独立校验通过**：CI 官方便携包 `dont_forget.exe` PE 版本为 `1.8.19.90`，管道捕获 `--help` 返回码 `0`（输出 `DontForget CLI v1.8.19`），`--add "   "` 返回码 `2`；本地 Release 二进制另实测 `PID 19044` 持有库锁时 `--list` 正确返回码 `75`。
- 遵循 `AGENTS.md`，未强杀用户进程，不将 Windows `v1.8.19+90` 覆盖升级记为通过；待用户从桌面／托盘退出 `PID 19044` 后，分别补齐**退出后安装**与**同桌面运行中升级**续验。

## Android（Pixel 8 Pro）正式包升级与真实 TalkBack 读屏实机验收

- **正式包同身份保全升级通过**（[android-upgrade-90-2026-11-21.json](benchmarks/android-upgrade-90-2026-11-21.json)）：
  - 升级前确认正式版 `com.yarnway.dontforget` 为 `1.8.18 (89)`（SHA‑256 `8dcb28de...`），核验公开 ARM64 包签名证书为固定发行证书 `3db49656...`；经应用内「数据与安全 → 导出完整备份」生成升级前最新明文 `DFBK2` 备份并本地校验（schema 17，`Reminders=2 / MediaRecords=0 / Settings=1`，`reminders_media_sha256: b4d0a324...`）。
  - 同签名覆盖公开 ARM64 `DontForget_Android_arm64_v1.8.19.apk` 后，读回手机已装 APK SHA‑256（`69f2f6e5...`）与公开 Release 完全一致，同机三个隔离 QA 包保持未改动。
  - 冷重开（`PID 20449`）后再次导出明文 `DFBK2` 备份复核 `2/0/1` 与 `reminders_media_sha256`（`b4d0a324...`）逐字节一致，清空临时导出记录；「设置 → 关于与更新」显示 **`当前版本 1.8.19 (90)`**，点击「检查更新」返回 **`已是最新发布版`**（`公开版本 1.8.19 (90)`）。
- **真实 Android TalkBack 读屏实机验收通过**（[pixel-formal-90-talkback-2026-11-21.json](benchmarks/pixel-formal-90-talkback-2026-11-21.json)）：
  - **数据与安全（加密展开态）**：Accessibility 树零未加标签 `NAF` 按钮／开关（`naf_count=0`），两处密码显隐按钮均暴露 `显示密码`（`108×108px = 48×48dp`）。
  - **设备与同步**：Accessibility 树零未加标签 `NAF` 开关（`naf_count=0`），局域网同步 `Switch` 暴露 `局域网同步`（`135×108px = 60×48dp`）。
  - **真实 TalkBack 语音录制闭环**：实机启用 `com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService`（`accessibility_enabled=1`、`touch_exploration_enabled=1`）并临时授予录音权限，单击语音输入区 `按住说话` 成功打开无障碍录制浮层，实测三按钮 **`保存原语音`**（`307×108px`）、**`转文字编辑`**（`307×108px`）、**`取消`**（`212×108px`）均严格满足 `>= 48dp`（`48.0dp @ 360dpi`）；点击 `取消` 正常关闭浮层、`RecordingActivityMonitor` 无残留录音会话、0 Flutter 异常（此外在调试中亦顺带实证点击 `转文字编辑` 可直达 `核对文字` 弹窗）。
  - 测后已完整恢复 `enabled_accessibility_services=null`、`accessibility_enabled=0`、撤销 `RECORD_AUDIO`（`granted=false`）、保持 `WeType` 与 `font_scale=1.0` 不变并返回桌面。同时记录两处非阻塞微调项留待后续迭代：无障碍录音浮层 `取消` 描边按钮在浅灰底弧上可改深色底提升对比度，顶部浮动提示条关闭图标可补齐 `tooltip`。

## 未验范围与后续主线

- **Windows 本机覆盖升级（`v1.8.19+90`）**：待用户退出桌面运行中的 `PID 19044` 后分别执行退出后安装与同桌面运行中升级续验，不冒记通过。
- **Windows 原生 GUI／托盘／Toast／桌面中文输入法**：非交互隔离桌面会话 `UIA_CHILDREN=0`，仍受环境限制未实测。
- **iPhone 真机（build90）**：本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证（最近独立读回仍为 build81）。
- **正式版云端 ASR 真实声学播音**与**实机 `LocalAppData\DontForget` 原地删除**：保持如实留存，详见 [Next_Steps_2026-11-02.md](Next_Steps_2026-11-02.md)。
