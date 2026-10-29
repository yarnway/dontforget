# Windows 适配与真机验收（2026-10-29）

本轮目标：优先完成 Windows 与 iOS 的适配与真机验收。**iOS 无法在 Windows 主机上构建/安装**（Flutter 仅支持在 macOS+Xcode 部署 iOS），因此本轮在 Windows 侧做完整适配与验收，iOS 交付可在 Mac 上一次执行的[真机验收 Runbook](iOS_Device_Acceptance_Runbook.md)。

## 结论

- Windows 桌面已能**构建、启动、录入、到期提醒、系统 Toast、托盘、录音、附件导入、设置页**运行，并完成一次真实到期验收。
- 构建阻塞的根因是**工具链不足**，不是源码：原机只有 VS 2019 Build Tools（MSVC 14.29，且缺 ATL），`audioplayers_windows` 需要 C++20 协程、`flutter_secure_storage_windows` 需要 `atlstr.h`。已安装 VS 2022 Build Tools + ATL 后 debug/release 均构建成功。
- 本轮修复 4 处 Windows 适配缺陷（Toast 去重与可诊断、Toast 应用身份、安装器 AUMID、桌面隐藏拍照入口），新增 10 项回归。
- **Windows 仍不是"完全对齐"平台**：退出/休眠/重启会漏提醒、Toast 无动作与点击回跳、第二实例无交接、无开机自启、桌面全量测试在 Windows 下有 66 项失败（POSIX 持久化语义 + 工具链版本漂移）。详见第 4 节。
- 稳定版仍受 macOS/iOS 原生门槛约束，本轮不发布。

## 1 环境与工具链修复

| 项 | 修复前 | 修复后 |
| --- | --- | --- |
| Visual Studio | 2019 Build Tools 16.11（MSVC 14.29，缺 ATL） | 2022 Build Tools 17.14.43（MSVC 14.44.35207 + ATL） |
| Windows SDK | 10.0.19041.0 | 同左（可用） |
| Flutter / Dart | 3.47.2 / 3.13.2（与仓库固定 3.44.9 / 3.12.2 不一致） | 未改动 |
| `flutter build windows` | 失败：`C1189`（experimental/coroutine）、`C1083`（atlstr.h） | debug 与 release 均成功 |

安装命令（已执行，静默、管理员）：

```powershell
Invoke-WebRequest 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile vs_buildtools.exe
Start-Process vs_buildtools.exe -Wait -ArgumentList '--quiet','--wait','--norestart','--nocache',
  '--add','Microsoft.VisualStudio.Workload.VCTools',
  '--add','Microsoft.VisualStudio.Component.VC.ATL','--includeRecommended'
```

注意：`flutter pub get --enforce-lockfile` 在 Flutter 3.47.2 下失败（lockfile 与 SDK 约束不一致，需 10 个包的版本调整）。本轮用普通 `flutter pub get` 完成验收，**验收产物对应本地解析版本，不是 CI 的 3.44.9 基线**；正式发布前须回到固定版本重跑。

## 2 本机实测通过项

证据目录：`build/native_acceptance/windows-2026-10-29/`（`build/` 不入库）。

| # | 项目 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | Debug 构建 | 通过（VS2022 后） | 构建日志 |
| 2 | Release 构建 | 通过 | `build/windows/x64/runner/Release/dont_forget.exe` |
| 3 | 启动与窗口 | 通过：标题 `DontForget`，1250×875，深色主题，中文文案 | `smoke-window.png` |
| 4 | 快速录入与时间解析 | 通过：粘贴文本含 `2026-10-29 09:45` 自动生成时间 chip 并保存卡片 | `after-typing.png`、`parsed-time.png`、`after-send.png` |
| 5 | 本地持久化 | 通过：`%APPDATA%\com.example\DontForget\databases\dont_forget_v3.db`；租约锁与 `notification-epoch.json` 存在 | 数据库只读查询 |
| 6 | 应用内到期 | 通过：09:45 出现“提醒时间已到 · 1”横幅与四个动作（稍后 5 分钟/更多延后/标为已完成/我知道了） | `frames/frame-10-094500.png` |
| 7 | Windows Toast | 通过：09:45:04 系统通知中心弹出 `Don't Forget` + 任务标题 | `frames/frame-12-094504.png` |
| 8 | 设置页 | 通过：外观、输入与发送、安全提示、模型、备份入口渲染正常 | `settings.png` |
| 9 | 命令面板 / 搜索 | 通过：`Ctrl+K` 打开（输入框聚焦时可靠），`Esc` 关闭；搜索面板与分组正常 | `ctrlk-from-composer.png`、`toolbar` 系列 |
| 10 | 关闭到托盘 | 通过：点 × 后窗口隐藏、进程存活 | 窗口可见性探测 |
| 11 | 麦克风录音 | 通过：点麦克风生成 `Documents\media\import-*\audio_*.m4a`（73 KB）并写入 `MediaRecords` | 文件 + 数据库 |
| 12 | 附件导入 | 通过：原生 `Select File`（#32770）选图后生成“文件任务: qa-attach.png”，附件可预览 | `picker-open.png`、`release-parsed.png` |
| 13 | 静态分析 | `flutter analyze --no-pub`：0 issues | 命令输出 |
| 14 | 相关回归 | 新增 10 项 Toast 测试通过；通知/输入相关 57 项通过 | 测试输出 |

未在本轮取得证据：安装/升级/卸载（需 Inno Setup 打包与重启环境）、真实麦克风听感、系统通知中心点击、第二实例交接、跨日与休眠。

## 3 发现并修复的 Windows 问题

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| F1 | Windows Toast 正文等于标题，同一句话显示两遍 | 通知可读性差 | 新增 `lib/services/windows_toast.dart`：正文为空或与标题相同改用单行模板 `ToastText01`；超长正文截断；转义与失败诊断集中一处。`notification_service.dart` 改为调用它 |
| F2 | Toast 使用未注册的应用身份 `"Don't Forget"`，安装器与 runner 均未登记 AUMID | 依赖 Windows 兜底归属，安装版可能不显示或来源不明 | 统一 AUMID 常量 `DontForget`；`windows/runner/main.cpp` 调用 `SetCurrentProcessExplicitAppUserModelID`；`windows_installer/installer.iss` 给开始菜单/桌面快捷方式加 `AppUserModelID` |
| F3 | Toast 失败被静默吞掉（不检查 `Process.run` 结果） | 企业策略禁用 PowerShell 时无任何线索 | `WindowsToast.show` 返回布尔并记录 exitCode/stderr；失败可见于日志 |
| F4 | 桌面端仍显示“拍照照片”入口（`image_picker` 在桌面不支持） | 点了必然失败 | `input_bottom_bar.dart` 仅在 Android/iOS 显示拍照入口 |
| F5 | `+40~+44` 的变更未写入 CHANGELOG；README 仍称“未实现应用层加密” | 文档与实现不一致 | 见第 6 节遗留（本轮未改） |

回归：`test/windows_toast_test.dart`（10 项）覆盖模板选择、转义、截断、静音、AUMID、失败上报与异常包含；`flutter analyze` 0 issues；通知/输入相关 57 项通过。

## 4 仍需处理（按用户影响排序）

1. **退出/休眠/重启漏提醒（最高）**：Windows 无系统级排程，只有进程内 Timer；启动时过期提醒被取消而不是补发（`lib/providers/providers.dart`）。需要"启动补发窗口 + 错过汇总"设计，并考虑开机自启。
2. **Toast 无动作按钮、无点击回跳**：Windows 侧只有标题/正文，点击不打开应用。要做需自定义 AppUserModelID 注册 + 激活回调（ToastNotification.Activated / 协议激活）。
3. **第二实例无交接**：双击第二个实例会停在“存储不可用”页，而不是激活已有窗口。需要在 runner 加单实例 mutex + 激活消息。
4. **无开机自启 / 无 URL 协议**：仓库里没有 autostart 与协议注册，重启后提醒不会恢复。
5. **Windows 权限与自检显示“不可用”**：权限查询与测试通知在 Windows 返回 unsupported（设计如此），但界面需要解释清楚，避免与"未授权"混淆。
6. **数据位置与身份**：附件在 `Documents\media`、数据库在 Roaming，bundle 身份仍是 `com.example`；正式版应改为 `com.yarnway.dontforget` 并评估 Roaming/OneDrive 同步风险。
7. **托盘退出 `exit(0)`**：未关闭数据库与 journal，可能留下未刷盘状态；应改为优雅关闭。
8. **录音细节**：固定 `.m4a` 扩展名但 Windows 写 ADTS AAC；时长解析只认 MP4 `moov`，250 ms 最短录音保护在 Windows 失效。
9. **桌面文案与 i18n**：托盘菜单、Toast 正文、部分提示为中文硬编码（本轮已移除 Toast 正文的中文兜底）。
10. **测试基线**：Windows 下全量 1944 通过 / 19 跳过 / 66 失败。失败集中在 POSIX 持久化语义（文件锁租约、SIGKILL 恢复、目录 fsync/权限）与 Flutter 版本漂移；CI 只在 ubuntu 跑全量。需要"平台限定 skip 清单 + Windows 专项矩阵"，否则 Windows 回归无法判定。
11. **安装器与文档不一致**：`installer.iss` 要求 Win10+，架构文档仍写 Win7/8；`windows_redist/` 与打包脚本注释冲突。
12. **未提交的第三方改动**：`lib/services/content/content_cleanup_service.dart` 在本次会话开始后出现未提交修改（路径归一化/大小写比较），非本轮产生，需确认归属后再决定提交或回退。

## 5 分阶段计划

### W 系列（Windows，可立即执行）

- **W1（已完成）**：工具链修复、debug/release 构建、启动、录入、到期提醒、Toast、托盘、录音、附件、静态分析与回归。
- **W2（下一轮，1–2 天）**：第二实例单实例化 + 托盘退出优雅关闭；启动补发逾期提醒（含"错过的提醒"汇总卡）；窗口位置/尺寸持久化。
- **W3（2–3 天）**：录音容器与时长（ADTS/MP4 双支持、250 ms 保护）；Toast 点击回跳（协议激活）；i18n 硬编码清理。
- **W4（1–2 天）**：Inno Setup 打包 + 安装/覆盖升级/卸载验收（`scripts/package_windows.ps1`、`scripts/smoke_windows_installer.ps1`）；产物摘要校验。
- **W5（2 天）**：Windows 测试基线（平台 skip 清单、CI 增加 Windows 测试作业、失败分类归档），并把 Windows 验收集成进 `docs`。
- **W6（发布前）**：生产身份 `com.yarnway.dontforget`、正式签名（若需要）、README/CHANGELOG 同步。

### I 系列（iOS，需 macOS）

- **I1**：按 [iOS 真机验收 Runbook](iOS_Device_Acceptance_Runbook.md) 在 Mac 上构建、签名、安装到 iPhone 15 Pro Max。
- **I2**：优先级顺序：安装/首启 → 通知热/冷点击 → 动作菜单与三语 → 前后台/终止态 → 重开补排去重 → 灵动岛同步 → 日文软键盘 → 真实录音 → 附件/备份 → 清理与数据保护。
- **I3**：与 macOS 门槛合并后发布稳定版（现行[发布策略](Release_Policy.md)）。

## 6 证据与复现

```powershell
flutter pub get                       # 3.44.9 下可加 --enforce-lockfile
flutter analyze --no-pub
flutter build windows --debug   --no-pub
flutter build windows --release --no-pub
build\windows\x64\runner\Release\dont_forget.exe

# 辅助脚本（仅本机验收，不入库）
python build\native_acceptance\windows-2026-10-29\win.py shot <name>
python build\native_acceptance\windows-2026-10-29\wait_due.py HH:MM:SS 45
```

数据位置：`%APPDATA%\com.example\DontForget\databases\dont_forget_v3.db`、`%USERPROFILE%\Documents\media\import-*\`、`%LOCALAPPDATA%\DontForget\logs`。
本轮验收使用全新空配置（开始时上述目录均不存在），结束时通过删除该测试配置恢复空环境；未触碰任何既有用户数据。

## 7 与 iOS 的分工

Windows 证据只证明 Windows 行为；iOS 必须由其 Runbook 单独取证。反向亦然：iOS 真机通过不构成 Windows 通过。两侧共同受约束的是源码与 schema（16），以及 `TaskDetails` 语义版本。
