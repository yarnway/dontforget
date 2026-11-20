# v1.8.18／build89 最终发行与验收

[v1.8.18](https://github.com/yarnway/dontforget/releases/tag/v1.8.18) 已发布并设为 `latest`，四平台七包、20 附件独立读回通过。固定发布源码 `4855976b7b13edb26f279ba0c163f1a9095944ad`（运行时提交 `600f517466eabe59dee75f5b2c62a98562123bc1`，schema 17）。源码、自动化、安装包与真实设备验收结果严格分层记录；iPhone 89 未安装／未真机验收，Windows 原生 GUI／托盘／Toast 仍受非交互桌面会话限制未实测。

## 源码与自动化

本版整合 `v1.8.15+86`（功能可用性）、`v1.8.16+87`（易用性与美观性）、`v1.8.17+88`（稳定性与性能）及 `v1.8.18+89`（全局架构与三语一致性收敛）四轮连续迭代，以及图片／文件分享采集与局域网双向附件传输。不更改数据库 schema 17、依赖锁文件或既有凭据存储格式。

- 本机固定 Flutter `3.44.9` 下静态分析 0 问题，Windows 全量测试 **2,686 通过／20 项文档化 Windows 跳过／0 失败**，`report_windows_skipped_tests.py` 通过，Python 脚本测试 180 通过（6 项 POSIX 跳过）。
- 最终主线 [CI 44749926901](https://github.com/yarnway/dontforget/actions/runs/44749926901) 七项任务全部成功（Linux `Analyze and test`、Windows `Windows analyze and test`、Windows／Linux／Android／macOS／iOS 五平台构建与桌面安装／启动冒烟）。

## 安装包与分发

四平台七包、20 个公开附件均由 [发布工作流 44754960147](https://github.com/yarnway/dontforget/actions/runs/44754960147) 校验并发布，随后经独立 API 读回确认标签指向 `4855976b7b13edb26f279ba0c163f1a9095944ad`、`latest` 指向 `v1.8.18`、旧版 `v1.8.14`（`116d7f2`、20 附件）保持未改，详见 [github-release-v1.8.18-2026-11-20.json](benchmarks/github-release-v1.8.18-2026-11-20.json)：

- **Windows x64（未做 Authenticode 签名）**：
  - `DontForget_Setup_v1.8.18.exe`（`15,070,109 B`，SHA‑256 `0cc56abfa4e1ce86775bef50597ef8763b3c3d462cf6bb238dc2330ff68fd870`）
  - `DontForget_Windows_Portable_v1.8.18.zip`（`18,368,011 B`，SHA‑256 `3e6e448813a1d63dd75cc7fce8fdcea702b43556e552bbd5434541e166b4c1d6`）
- **Linux x64（Ubuntu 24.04 基线）**：
  - `DontForget_Linux_x64_v1.8.18.tar.gz`（`14,825,133 B`，SHA‑256 `80043e3ac84d22cfe6c85005f8c5a4d7ca7c7def50512e87e6f7235443c69d4b`）
- **Android（固定发行证书 `3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1` 校验通过）**：
  - `DontForget_Android_arm64_v1.8.18.apk`（`27,222,947 B`，SHA‑256 `8dcb28de3921e1e21ba2ed88084cfc8479a9477249dcc97c535855a40b137183`）
  - `DontForget_Android_v1.8.18.apk`（`78,908,619 B`，SHA‑256 `96c1d263d71b61607644631786f737b4bb7115e07641dc281c5f1bab9a870f76`）
  - `DontForget_Android_v1.8.18.aab`（`75,486,546 B`，SHA‑256 `d66c43b86fd89f1a7fff79326e7b85c3d8ac3446957e9a0aaaeca79112e52051`）
- **iOS（未签名，需 AltStore 个人重签，免费账号每 7 天续期，非 App Store／TestFlight）**：
  - `DontForget_iOS_unsigned_v1.8.18.ipa`（`11,724,773 B`，SHA‑256 `e7b2b8bcb94029b5f3af11e81c19cd5fbc6a65497cf778c43540622aadb800db`，主包与 Live Activity WidgetKit 扩展身份／版本由发布门禁校验通过）

## Windows 本机运行中覆盖升级

- 本地四轮迭代已完成 `1.8.14+85`→`1.8.15+86`→`1.8.16+87`→`1.8.17+88`→`1.8.18+89` 连续运行中保全覆盖升级（见 [86](benchmarks/windows-upgrade-86-2026-11-20.json)、[87](benchmarks/windows-upgrade-87-2026-11-20.json)、[88](benchmarks/windows-upgrade-88-2026-11-20.json)、[89本地](benchmarks/windows-upgrade-89-2026-11-20.json)）。
- 最终 CI 官方安装包（`Run 44749926901`）下载并校验摘要后，在本机 `dont_forget.exe` 运行中（PID `10496`）执行最新数据备份→静默正常覆盖升级（`/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`，退出码 `0`，无强关）→38 个程序载荷文件与 CI 便携包逐字节一致、PE 版本 `1.8.18.89`、CLI `--list` 正常退出、SQLite schema 17 `integrity_check=ok`、`Reminders=7 / MediaRecords=0 / Settings=1` 全业务字段与 DPAPI 凭据（1 项）解保护摘要一致、普通重开（PID `26776`）后字段与凭据保持，详见 [windows-upgrade-89-ci-2026-11-20.json](benchmarks/windows-upgrade-89-ci-2026-11-20.json)。
- 本轮受当前非交互桌面会话 UIA 根节点为空限制，未验收 Windows 原生 GUI、托盘、Toast 与真实桌面中文键盘，不以 CLI 或进程存在代替 GUI 通过。

## Android（Pixel 8 Pro）正式包升级与隔离 QA 实机验收

- **正式包同身份保全升级**（[android-upgrade-89-2026-11-20.json](benchmarks/android-upgrade-89-2026-11-20.json)）：
  - 升级前确认已装正式版 `com.yarnway.dontforget` 为 `1.8.14 (85)`（SHA‑256 `dd9f9180...`）、签名证书与 CI 正式包完全一致（`3db49656...`）；经应用内「数据与安全 → 导出完整备份」生成升级前最新 `DFBK2` 备份并拉回本地校验（`Reminders=2, MediaRecords=0, Settings=1`）。
  - 同签名覆盖安装正式 CI `DontForget_Android_arm64_v1.8.18.apk` 后，读回手机已装 APK SHA‑256（`8dcb28de...`）与公开 Release 附件完全一致。
  - 冷重开（PID `21593`）确认品牌图标显示、再次导出只读备份核对 `Reminders=2 / MediaRecords=0 / Settings=1` 及记录逻辑摘要（`b4d0a324...`）完全一致；「设置 → 关于与更新」显示 **`当前版本 1.8.18 (89)`**，点击「检查更新」返回 **`已是最新发布版`**（`公开版本 1.8.18 (89)`）。同机其他 QA 身份、默认输入法与桌面状态均保持未受影响。
- **隔离 QA 深度真机矩阵**（[pixel-89-acceptance-2026-11-20.json](benchmarks/pixel-89-acceptance-2026-11-20.json)）：
  - 覆盖真实微信输入法（`WeType`）首页与分享编辑页拼音组合保护及单次保存、大字号（`1.3x`）多事项密度零溢出、提前 10 分钟提醒后台送达（`21:34:00`）＋通知栏「15分钟后」延后＋15 分钟准时二次送达（`21:49:08`）、真实附件内容管理清理（活跃图片受保护、过期孤立原件清理），以及与 Windows 隔离对端在同一真实 Wi‑Fi 子网（`192.168.50.0/24`，零 USB 转发）双向附件同步与跨设备回收站移入／恢复收敛。

## 未验范围与后续主线

- iPhone 真机 89 未安装／未验收（本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证；最近独立读回仍为 build81）。
- Windows 原生 GUI／托盘／Toast、build84 历史语音重复根因与读屏、Windows 历史 LocalAppData 目录人工接管、系统分享面板手选文档及正式包下的语音／通知深度矩阵均列在 [Next_Steps_2026-11-02.md](Next_Steps_2026-11-02.md)，不标为全部通过。
