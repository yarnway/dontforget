# DontForget v1.8.19 · Android / Windows / Linux / iOS

聚焦无障碍读屏（Android TalkBack / iOS VoiceOver）与 WCAG AA 合规、Windows CLI／Runner 管道与单实例修复及全链路 UTF-16 代理对安全截断的稳定版本。build90／schema17。

## 主要更新

### 无障碍读屏（TalkBack / VoiceOver）与 WCAG AA
- **无障碍语音录入闭环**：在系统启用无障碍导航（TalkBack / VoiceOver）时，移动端语音按住条支持单次点按／双点激活开始录音，并展示可聚焦交互的 >= 48dp 高对比度操作按钮（保存原语音／转文字编辑／取消），完全保留原有按住滑动手势。
- **消除未加标签控件与语义缺失**：补齐加密备份／恢复全部 3 处密码显隐切换按钮的动态三语 `tooltip`、局域网同步服务端 `Switch` 的语义标签、分享草稿编辑器返回按钮 `tooltip` 与输入框标签提示、首页图片预览 48dp 关闭按钮与图片 `semanticLabel`、只读详情清单完成状态语义，以及附件卡片 `enabled` 与图片 `semanticLabel`。
- **触控热区、高倍字号缩放与对比度**：修复任务编辑器 16dp 清除时间按钮与非语义触发器按钮（升级为 `ChoiceChip`）、设置页外链标签（升级为 `ActionChip`）、语音编辑页与通知条紧凑按钮至 >= 48dp；解除语音编辑页高字号下隐藏错误提示的限制；修复局域网冲突弹窗 2.0x 缩放溢出与空值语义；修复首页清空完成弹窗与任务详情提示的 WCAG AA 对比度；补齐 `Semantics(header: true)`、`liveRegion` 与 `CheckedPopupMenuItem`。

### Windows CLI／Runner 与稳定性加固
- **Windows CLI 管道与无闪窗修复**：`ConfigureStandardStreams()` 保留已重定向的标准流管道／文件，仅在纯父控制台附加且无重定向时重同步输出流（修复无控制台管道下 `0xC0000409` 崩溃与 PowerShell 捕获为空）；`IsCliInvocation()` 改为基于 `CommandLineToArgvW` 的精确参数比对；CLI 调用不再闪现空白窗口，退出前自动冲刷 `stdout`/`stderr`，`--add` 缺少正文直接返回退出码 `2`。
- **UTF-16 代理对安全截断**：抽取共享 `truncateRunes` / `truncateUtf16Safe`，统一保护 AI 提示、更新说明、局域网附件名（保持 `<= 180` UTF-16 码元）、CLI 与 Windows Toast 截断不拆分 Emoji 代理对。
- **多语言与文档**：补齐中／英／日三语无障碍词条、分享收件箱图片／文件提示与存储不可用页三语副标题；同步更新使用文档、开发文档与打包指南。
- 不更改数据库 schema17、依赖锁文件或既有模型／语音凭据存储格式。

## 下载与安装

- Windows x64：`DontForget_Setup_v1.8.19.exe` 安装版或 `DontForget_Windows_Portable_v1.8.19.zip` 便携包，未做 Authenticode 签名。
- Linux x64：`DontForget_Linux_x64_v1.8.19.tar.gz`，Ubuntu 24.04 基线。
- Android：固定发行证书签名的通用 APK（`DontForget_Android_v1.8.19.apk`）、ARM64 APK（`DontForget_Android_arm64_v1.8.19.apk`）及 AAB（`DontForget_Android_v1.8.19.aab`）。
- iOS：`DontForget_iOS_unsigned_v1.8.19.ipa` 为未签名 IPA，需要通过 AltStore 个人重签；免费账号通常每 7天 续期。安装方式见[说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)，不属于 App Store 或 TestFlight 分发。

## 验收范围与限制

源码、自动化测试、安装包与真实设备验收分别记录，详见[后续阶段与验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)：
- **自动化**：固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、全量 `flutter test`（**2,699 通过／20 项文档化 Windows 跳过／0 失败**，含新增 `test/accessibility_guidelines_test.dart` 与 `test/text_bounds_test.dart`）、Python 脚本测试（**184 通过／6 项 POSIX 跳过**，含新增 `test_windows_runner_cli.py`）全部通过，并经主线 CI Linux／Windows 双端质量与五平台构建校验。
- **Windows 本机与安装包**：已完成本地 Windows x64 `DontForget_Setup_v1.8.19.exe`／`DontForget_Windows_Portable_v1.8.19.zip` 构建与 `verify_artifacts.py` 校验，以及内置 CLI `--help` 管道输出、`--add` 空参返回码 `2` 与运行占用返回码 `75` 验证；本机运行中覆盖升级回执（含跨桌面／托盘正常关闭失败留证与续验）及发版后 CI 官方安装包复验均按 `AGENTS.md` 分层归档于台账。
- **Android 实机（Pixel 8 Pro）**：公开发布后将对公开正式版 `com.yarnway.dontforget` 执行最新保全同签名升级至 `1.8.19 (90)`，并实机开启真实 Android TalkBack 验收无障碍树与单击语音录入闭环，结果单独归档于台账。
- **未验／限制范围**：Windows 交互式桌面 GUI／托盘／Toast（非交互会话 UIA 返回空）、iPhone 真机安装与运行（本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证）、正式版云端 ASR 真实声学播音（未配置云端密钥）及实机 `LocalAppData\DontForget` 原地删除仍明确留存，不记为全部原生矩阵通过。
