# 别忘了 · DontForget

本地优先的备忘与任务工作台。随手记录文字、录音和附件，按紧急提醒、重点跟进、常规待办与备忘便签管理事项；需要智能提取时，再连接自己配置的模型服务。

[![Flutter](https://img.shields.io/badge/Flutter-3.44.9-02569B?logo=flutter)](https://flutter.dev)
[![Source](https://img.shields.io/badge/Source-v1.7_candidate-007F83)](docs/Iteration_v1.7.md)

[使用指南](docs/User_Guide.md) · [开发指南](docs/Developer_Guide.md) · [架构](docs/Architecture_Design.md) · [变更日志](docs/Changelog.md)

## v1.7：任务浏览与清晰复盘

当前为 `1.7.0+7` 源码候选，尚未正式发布。完成与待办分别记录在 [v1.7 迭代清单](docs/Iteration_v1.7.md)。

- **按状态找任务**：搜索页直接浏览全部、待办、今日到期、逾期或已完成事项，无需先输入文字。
- **组合关键词**：同时搜索标题、摘要和子任务；空格分隔的关键词可以出现在不同字段中。
- **排序与重置**：支持到期时间优先、最近创建优先，一次重置搜索、筛选和排序。
- **阅读更舒适**：宽屏结果限制行宽，窄屏控件换行；支持深浅主题、大字体和键盘操作。
- **明确报告来源**：统计复盘标明模型或本地结果，模型失败可重试；数据变化提示更新，复制失败会明确反馈。
- **减少重复计算**：编辑一条任务时复用其余任务的搜索文本，列表继续按需创建卡片；统计按任务版本缓存汇总，报告操作不会重复扫描任务。

恢复、提醒持久化与多模型配置沿用 v1.6 基础；真实 DST、跨供应商服务及各平台设备验收仍以 [v1.6 验收记录](docs/Iteration_v1.6.md)为准，版本号变化不代表这些验收完成。

## 日常使用

1. 直接输入事项。未配置模型时，保存为本地记录，在详情中设置提醒时间。
2. 点击录音按钮或长按输入区记录语音，也可从 `+` 导入图片、文件或视频。
3. 在任务卡标记完成、打开详情，或通过操作菜单管理任务。桌面可长按拖动到其他分类。
4. 打开搜索，按状态浏览或组合关键词查找任务。`Ctrl/Cmd+F` 打开搜索，`Esc` 关闭；`Ctrl/Cmd+K` 打开更多功能。
5. 设置页可配置模型、选择中文/English/日本語，并备份已保存的数据。

提醒在应用内集中展示，延后、完成与关闭提示均不抢走输入焦点。系统通知能力与权限、平台和应用运行状态有关；已验证范围与未完成项分别记录在版本验收文档中。

## 数据与模型

任务、附件索引和配置使用本机 SQLite 保存；导入的附件另存于本机文件目录。未配置模型也可以保存文字与原声记录。

AI 解析会将相关内容直接发送至您配置的服务商。应用不提供内置 API Key；请在设置中填入自己的服务地址、模型标识与密钥，需要本机推理时使用本地模型。

数据库、API Key 与备份目前没有应用层加密。现有备份包含任务、配置和附件路径，**不包含附件文件本体**。当前源码支持恢复预览、确认后替换和失败回退，已完成范围见[原生验收记录](docs/Native_Acceptance_v1.6.md)；正式发布能力以对应版本记录为准。

当前源码候选为 `1.7.0+7`（尚未正式发布）。macOS 通知日志升级与安装旧程序前的回退步骤见[日志维护说明](docs/Notification_Storage_Upgrade.md)。

## 平台与下载

从 [GitHub Releases](https://github.com/yarnway/dontforget/releases) 查看实际可用的版本。源码版本、CI 候选包与正式发布分别记录，不将构建成功当作设备验收通过。

| 平台 | 工程要求 | 交付说明 |
| --- | --- | --- |
| Windows | Windows 10/11 x64 | 安装包与便携归档；设备功能需独立验收 |
| macOS | macOS 12.0+ | 候选归档未公证 |
| Linux | GTK 3、GStreamer base/good 插件及 AppIndicator 运行时，x64 | 归档包；发行版兼容性需验证 |
| Android | Android 7.0 / API 24+ | 测试签名 APK/AAB；正式签名单独处理 |
| iOS | iOS 15.0+ | CI 产物未签名，安装需有效签名 |

## 本地开发

使用 Flutter 3.44.9 / Dart 3.12.2 和仓库 lockfile：

```bash
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
python3 -m unittest discover -s scripts/tests -v
flutter run -d macos # 或 windows / linux / 已连接移动设备
```

搜索计算基准使用隔离合成数据，不读取用户数据库：

```bash
dart run scripts/benchmark_task_search.dart
```

构建脚本和签名限制见[打包与部署指南](docs/Packaging_and_Deployment.md)。
