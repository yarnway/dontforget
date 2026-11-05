# 别忘了 · DontForget

本地优先的备忘与任务工作台。随手记录文字、录音和附件，按紧急提醒、重点跟进、常规待办与备忘便签管理事项；需要智能提取时，再连接自己配置的模型服务。

[![Flutter](https://img.shields.io/badge/Flutter-3.44.9-02569B?logo=flutter)](https://flutter.dev)
[![Source](https://img.shields.io/badge/Source-v1.7_candidate-007F83)](docs/Iteration_v1.7.md)

[使用指南](docs/User_Guide.md) · [开发指南](docs/Developer_Guide.md) · [架构](docs/Architecture_Design.md) · [变更日志](docs/Changelog.md)

后续工作按[2026-11-02 阶段与任务](docs/Next_Steps_2026-11-02.md)推进：先关闭候选缺陷与安装包差异，再做原生提醒、数据保护、学习与跨设备验收。当前源码候选为 `1.7.0+56`，按住录音上滑往右转文字改接腾讯云，并精简设置入口、减少低频原生加载及偏好保存时的凭据读写；实现与分层验收见[+56记录](docs/Tencent_Recording_Speech_56_2026-11-05.md)。腾讯云真实账号和稳定发布门槛仍需验收。Windows旧目录迁移保护及分层验收见[迁移记录](docs/Legacy_Location_Storage_52_2026-11-04.md)；设备窗口偏好独立存储见[R1验收](docs/Desktop_Window_Storage_51_2026-11-04.md)；Android +50通知与录音证据保留在阶段台账。历史+48通知、录音与媒体入口见[原生验收](docs/Native_Media_Routing_48_2026-11-03.md)；Windows +47包与Pixel隔离升级见[构建升级验收](docs/Windows_Android_Build_47_2026-11-03.md)，Windows新动作与Pixel通知／USB结果见[11月3日验收](docs/Windows_Android_Validation_2026-11-03.md)。Android冻结 `+46` 深链及Pixel结果见[阶段47验收](docs/Android_Deep_Link_Acceptance_2026-11-02.md)；Windows `+45` 包保留[阶段46验收](docs/Stage46_Validation_2026-11-02.md)的独立归属。

当前工作区的“记录与提醒”优化及后续阶段见[分阶段功能清单](docs/Recording_Reminders_Phases.md)，其中开发中功能与公开候选分别记录。 本轮新增的用药计划、出门清单、附件备份和学习管理入口见[实现与验收索引](docs/Planning_Implementation.md)，尚未计入本轮安装包验收。

## v1.7：任务浏览与清晰复盘

公开候选与平台验收范围见[发布验收总表](docs/Release_Acceptance_v1.7.md)，稳定版尚未发布。当前工作区还包含[分阶段清单](docs/Recording_Reminders_Phases.md)中的未发布优化；既有版本记录见 [v1.7 迭代清单](docs/Iteration_v1.7.md)。

- **按状态找任务**：搜索页直接浏览全部、待办、今日提醒、提醒时间已过或已完成事项，无需先输入文字；提醒时间不是事件截止时间。
- **组合关键词**：同时搜索标题、摘要和子任务；空格分隔的关键词可以出现在不同字段中。
- **排序与重置**：支持提醒时间优先、最近创建优先，一次重置搜索、筛选和排序。
- **阅读更舒适**：宽屏结果限制行宽，窄屏控件换行；支持深浅主题、大字体和键盘操作。
- **明确报告来源**：统计复盘标明模型或本地结果，模型失败可重试；数据变化提示更新，复制失败会明确反馈。
- **图谱与列表**：图谱稳定布局，每页最多显示 120 项及页内关联；完整结果可搜索、翻页或按列表浏览。
- **编辑保护**：离开未保存详情时可继续编辑、放弃修改或保存并返回。
- **复习与专注**：复习显示保存结果与下次日期；专注面板明确当前会话状态、提醒范围及失败重试，支持中文、English 和日本語。
- **摘要与导出**：情境摘要跟随任务与提醒轮次更新；CSV 支持选择保存位置、三语言字段和明确的取消/失败反馈。
- **编辑与工具**：工具使用非遮挡工作区面板，底部输入独立可用；目标与学习计划草稿跨工具保留，放弃需确认。详情支持保存/退出快捷键，工具选择支持搜索、方向键及输入法保护。
- **英语学习计划**：四级、六级、考研、雅思、托福，模型准备词汇与建议时刻，预览编辑后确认创建。按批次复习反馈推进默认 1/2/4/7/15 天间隔并更新提醒；入口为“更多功能 → 词汇学习计划”。
- **外观与输入偏好**：跟随系统、明亮、暗黑独立保存；可选回车发送或仅发送按钮，Shift+Enter 换行。空输入区按住录音，上滑后向左取消、向右转为可编辑草稿，编辑后明确发送；直接松手保存语音。iOS 设备端识别及真实采集仍需对应设备验收。
- **减少重复计算**：编辑一条任务时复用其余任务的搜索文本，列表继续按需创建卡片；统计按任务版本缓存汇总，报告操作不会重复扫描任务。
- **P0 记录与提醒集成**：持久化草稿、事项截止时间、AI 提案预览确认，以及 schema 16 对两类历史 schema 14／15 的升级与备份兼容，详见 [P0 阶段记录](docs/UX_P0_Record_Reminder.md)。

恢复、提醒持久化与多模型配置沿用 v1.6 基础；真实 DST、跨供应商服务及各平台设备验收仍以 [v1.6 验收记录](docs/Iteration_v1.6.md)为准，版本号变化不代表这些验收完成。

## 日常使用

1. 直接输入事项，先保存到本机；无明确时间时保留为备忘，可从时间菜单或详情设置提醒。已配置模型时，等待卡片中的 AI 建议并预览确认。
2. 点击录音按钮或长按输入区记录语音，也可从 `+` 导入图片、文件或视频。
3. 在任务卡标记完成、打开详情，或通过操作菜单管理任务。桌面可长按拖动到其他分类。
4. 打开搜索，按状态浏览或组合关键词查找任务。`Ctrl/Cmd+F` 打开搜索，`Esc` 关闭；`Ctrl/Cmd+K` 打开更多功能。
5. 设置页可配置模型、选择语言和外观、设置发送方式，并备份已保存的数据。
6. 从“更多功能 → 词汇学习计划”选择考试、每日词量和本次天数；检查模型给出的词汇与提醒时间后确认，在“复习卡片”中反馈掌握情况。完整步骤见[词汇学习引导](docs/User_Guide.md#v17-词汇学习引导)。

提醒在应用内集中展示，延后、完成与关闭提示均不抢走输入焦点。系统通知能力与权限、平台和应用运行状态有关；已验证范围与未完成项分别记录在版本验收文档中。

## 数据与模型

任务、附件索引和配置使用本机 SQLite 保存；导入的附件另存于本机文件目录。未配置模型也可以保存文字与原声记录。

AI 解析会将相关内容直接发送至您配置的服务商。应用不提供内置 API Key；请在设置中填入自己的服务地址、模型标识与密钥，敏感凭据由操作系统底层安全存储（Windows DPAPI、macOS/iOS Keychain、Android KeyStore）托管保护，需要本机推理时可接入本地大模型。

任务、附件索引和配置保存在本机 SQLite 数据库中。备份功能支持标准便携导出及**端到端流式加密备份（AES-256-GCM + Argon2id）**，可将全量数据与多媒体附件本体一体化打包归档，并具备防重放、抗篡改与原子安全恢复能力。

v1.7 正在候选验收阶段，尚未发布稳定版；当前源码、公开候选和剩余门槛见[发布验收总表](docs/Release_Acceptance_v1.7.md)。macOS 通知日志升级与安装旧程序前的回退步骤见[日志维护说明](docs/Notification_Storage_Upgrade.md)。

## 平台与下载

从 [GitHub Releases](https://github.com/yarnway/dontforget/releases) 查看实际可用的版本。后续迭代的内部验证包保留在 GitHub Actions artifacts，不自动创建 RC 或 Release 草稿；macOS、iOS 验收完成后发布正式稳定版。源码、构建与真机结果分别记录，详见[发布策略](docs/Release_Policy.md)。

| 平台 | 工程要求 | 交付说明 |
| --- | --- | --- |
| Windows | Windows 10/11 x64 | 独立安装包（Setup.exe）与便携归档（Portable.zip）；支持开箱即用运行、WinRT Toast 原生动作与协议唤醒、托盘常驻与优雅退出、单实例守护、窗口位置记忆、错过的提醒聚合及数据平滑迁移 |
| macOS | macOS 12.0+ | 候选归档未公证 |
| Linux | GTK 3、GStreamer base/good 插件及 AppIndicator 运行时，x64 | 归档包；发行版兼容性需验证 |
| Android | Android 7.0 / API 24+ | 测试签名 APK/AAB；正式签名单独处理 |
| iOS | iOS 15.0+ | CI 产物未签名，安装需有效签名 |

## 本地开发

使用 Flutter 3.44.9 / Dart 3.12.2 和仓库 lockfile（可运行 `python scripts/check_flutter_version.py` 检查）：

```bash
python scripts/check_flutter_version.py         # 检查是否与 CI 基线 3.44.9 一致
flutter pub get --enforce-lockfile              # 3.44.9 下强校验锁文件；本地高版本使用普通 pub get
flutter analyze --no-pub
flutter test --no-pub
python scripts/report_windows_skipped_tests.py # 查看 Windows 下 POSIX 约束跳过的测试清单
python3 -m unittest discover -s scripts/tests -v
flutter run -d macos # 或 windows / linux / 已连接移动设备
```

搜索计算基准使用隔离合成数据，不读取用户数据库：

```bash
dart run scripts/benchmark_task_search.dart
```

构建脚本和签名限制见[打包与部署指南](docs/Packaging_and_Deployment.md)。
