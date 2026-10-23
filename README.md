# 别忘了 · DontForget

本地优先的备忘与任务工作台。随手记录文字、录音和附件，按紧急提醒、重点跟进、常规待办与备忘便签管理事项；需要智能提取时，再连接自己配置的模型服务。

[![Flutter](https://img.shields.io/badge/Flutter-3.44.9-02569B?logo=flutter)](https://flutter.dev)
[![Source](https://img.shields.io/badge/Source-v1.5.2-007F83)](docs/Iteration_v1.5.2.md)

[使用指南](docs/User_Guide.md) · [开发指南](docs/Developer_Guide.md) · [架构](docs/Architecture_Design.md) · [变更日志](docs/Changelog.md)

## v1.5.2：更稳、更易用的任务工作台

当前为源码候选，验证范围见[本轮迭代记录](docs/Iteration_v1.5.2.md)。

- **浏览更集中**：手机窄屏通过分类切换浏览完整列表；平板和桌面保留四象限，已完成和长期停留的便签可折叠。
- **减少无效工作**：任务列表按需创建卡片，搜索复用标题、摘要和子任务索引；提醒心跳局部刷新，空闲输入栏不再持续运行动画。
- **操作更明确**：任务卡提供可点击和键盘操作的菜单、48px 完成按钮、可换行标签，支持放大字体和减少动态效果。
- **写入更可靠**：任务修改、刷新和动态优先级扫描按顺序执行；多任务关联和批量优先级变化通过事务提交，失败不提前展示成功。
- **附件更安全**：同名导入文件保存在独立目录，保留原文件名，避免覆盖旧附件。

v1.6 的恢复预览、可回退恢复、持久化提醒确认及多模型自动降级仍按[后续计划](docs/Iteration_v1.6.md)推进，不计为本版已完成功能。

## 日常使用

1. 直接输入事项。未配置模型时，保存为本地记录，在详情中设置提醒时间。
2. 点击录音按钮或长按输入区记录语音，也可从 `+` 导入图片、文件或视频。
3. 在任务卡标记完成、打开详情，或通过操作菜单管理任务。桌面可长按拖动到其他分类。
4. 使用搜索查找标题、摘要和子任务。`Ctrl/Cmd+F` 打开搜索，`Esc` 关闭；`Ctrl/Cmd+K` 打开更多功能。
5. 设置页可配置模型、选择中文/English/日本語，并备份已保存的数据。

提醒在应用内集中展示，延后、完成与关闭提示均不抢走输入焦点。系统通知能力与权限、平台和应用运行状态有关；已验证范围与未完成项分别记录在版本验收文档中。

## 数据与模型

任务、附件索引和配置使用本机 SQLite 保存；导入的附件另存于本机文件目录。未配置模型也可以保存文字与原声记录。

AI 解析会将相关内容直接发送至您配置的服务商。应用不提供内置 API Key；请在设置中填入自己的服务地址、模型标识与密钥，需要本机推理时使用本地模型。

数据库、API Key 与备份目前没有应用层加密。现有备份包含任务、配置和附件路径，**不包含附件文件本体**。当前源码支持恢复预览、确认后替换和失败回退，已完成范围见[原生验收记录](docs/Native_Acceptance_v1.6.md)；正式发布能力以对应版本记录为准。

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
