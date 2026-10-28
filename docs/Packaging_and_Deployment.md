# DontForget 打包与发布验收

当前候选版本和构建号以 `pubspec.yaml` 为准，Flutter 固定为 3.44.9。构建成功、打包成功、安装运行、系统通知和正式发布分别验收。当前执行状态见 [v1.7 发布验收总表](Release_Acceptance_v1.7.md)，历史结果见 [v1.6 阶段验收记录](Native_Acceptance_v1.6.md) 和 [v1.5.1 验收记录](Release_Acceptance_v1.5.1.md)。

## 构建与产物

在项目根目录执行；先安装相应平台 Flutter 原生编译依赖与 Python 3。下表 `<version>` 代表 `pubspec.yaml` 中的语义版本，构建号另外记录在清单中。

| 平台 | 命令 | dist 产物 | 交付边界 |
| --- | --- | --- | --- |
| Windows 10/11 x64 | `pwsh -File scripts/package_windows.ps1` | `DontForget_Setup_v<version>.exe`、`DontForget_Windows_Portable_v<version>.zip` | 需要 Visual Studio C++ 与 Inno Setup 6；未签名 |
| Android | `bash scripts/build_android.sh` 或 `pwsh -File scripts/build_android.ps1` | `DontForget_Android_test-signed_v<version>.apk` / `.aab` | 测试密钥签名；不是商店交付件 |
| Linux x64 | `bash scripts/build_linux.sh` | `DontForget_Linux_x64_v<version>.tar.gz` | 需要 GTK、GStreamer base/good 运行时插件、ALSA、Ayatana AppIndicator；录音运行时另需 pulseaudio-utils 和 ffmpeg |
| macOS 12+ | `bash scripts/build_macos.sh` | `DontForget_macOS_unnotarized_v<version>.zip` | 完整 Xcode、CocoaPods；未公证 |
| iOS 15+ | `bash scripts/build_ios.sh` | `DontForget_iOS_unsigned_v<version>.ipa` | 完整 Xcode、CocoaPods；未签名，不能直接真机安装 |

每个平台还生成 `<platform>-manifest.json` 和 `<platform>-SHA256SUMS.txt`，包含版本、构建号、提交号、签名状态、文件大小与 SHA-256。桌面 CI 另有 `<platform>-startup.json`。便携包只表示免安装解压，应用数据仍按平台应用支持目录存放，不能当作包含用户数据的可迁移备份。

iOS 的 `Podfile` 与 Runner 均要求最低 iOS 15。部分插件仍通过 CocoaPods 集成；安装后将较低的 pod/隐私资源包目标提升至 15，保留依赖自身更高的要求，避免新 Xcode 拒绝编译旧的 iOS 9/13 目标。不要删除 Podfile 后依赖 Flutter 自动生成的默认部署版本。

iOS 的 Debug／Release xcconfig 同时继承对应 Pods 配置，工作区包含 Pods 工程并保留 Podfile.lock。Swift Package Manager 与 CocoaPods 混合使用时，这些配置负责锁定通知插件的框架路径和构建文件列表。`flutter build ios --simulator --debug --no-pub` 可验证主应用与 WidgetKit 扩展的模拟器构建；模拟器产物不用于实际 iPhone 安装。

macOS 同时保留 Swift Package Manager 与 CocoaPods 集成。锁定的通知插件需要 `macos/Podfile`、对应锁文件和 Runner 的 Pods 配置；构建时应确保 CocoaPods 在 `PATH` 中可用。项目最低目标为 macOS 12，安装时将较低的 pod 目标提升至 12，并保留依赖自身更高的要求。调试构建与签名检查通过后，真实通知、应用升级和分发仍按各自验收记录执行。

脚本使用锁定依赖，任一步失败即停止。Windows 在编译安装器前检查目录；归档发现数据库、WAL/SHM、日志、JSON 备份或 `.dart_tool` 会报错，保留原文件供检查。不会为打包删除用户数据。Windows 从已安装 Visual Studio 工具链提取配套 x64 VC CRT，不再打包仓库内的旧 UCRT/API shim；Windows 10/11 使用系统 UCRT。实际运行仍需在目标设备验证。

## 校验

```bash
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
python3 -m unittest discover -s scripts/tests -v
# 单个平台（将 COMMIT 替换为构建时的完整提交号）
python3 scripts/verify_artifacts.py dist --platform macos --revision COMMIT
# 五个平台产物汇总后
python3 scripts/verify_artifacts.py release-files --revision COMMIT --tag TAG
```

Python 回归测试使用假二进制验证归档、清单与失败保护；它们不是原生编译证据。哈希证明下载件与清单一致，不证明发行方身份或应用行为。

## iPhone 真机准备与验收

USB 连接、iPhone 镜像、签名安装和产品验收是四项独立证据。镜像可以操作手机，但不能让未签名 IPA 直接运行。先执行只读检查，输出路径必须尚不存在：

```bash
python3 scripts/check_ios_device.py --help
python3 scripts/check_ios_device.py --output /tmp/dontforget-ios-preflight.json
```

检查读取 USB 设备型号/系统版本、当前 Xcode、iPhoneOS SDK、`devicectl` 和有效开发签名数量；不建立配对、不读取配对凭据、设备名称或序列号、不修改开发者模式、不签名或安装。报告以 0600 创建且拒绝覆盖既有文件或符号链接。缺少条件或读取失败时退出码为 2；退出码 0 也只表示本地可观察条件存在，状态仍为 `REQUIRES_SIGNED_INSTALL`，不证明 profile 匹配或应用可运行。

真机还需要匹配该设备、团队、bundle ID 和有效期的 provisioning profile，以及设备配对和开发者模式。具体配置遵循 [Flutter iOS 环境文档](https://docs.flutter.dev/platform-integration/ios/setup) 和 [Apple 真机运行文档](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)。仅 Command Line Tools 不足以编译 iOS；`build_ios.sh` 和 CI 保持未签名构建，不能替代签名流程。不要将开发证书私钥或 provisioning profile 提交到仓库/公开 Release。

验收使用单独 bundle ID、合成任务和无生产凭据的设置，并记录版本、构建号、源码、包摘要及签名身份类型；只在同一隔离身份内验证覆盖升级。依次验证中文/日文组词、整段替换、软键盘避让、横竖屏、未保存提示、保存重开、原生文件选择器、提醒权限/点击/取消，以及录音与播放。逐项记录实际操作和读回；组件布局、镜像连接和原生构建不能代替未执行的真机项目。结束后从产品清理合成任务及系统通知，保留必要回退材料再轮换旧测试包。

## CI 与发布

工作流：`.github/workflows/build_and_release.yml`。

1. main 推送、PR、手动运行：先分析、Flutter 测试和打包脚本测试，再运行 Windows、Android、Linux、macOS、iOS 构建矩阵。
2. 桌面产物解压后执行 10 秒进程启动检查。Windows 另在带空格的临时路径中安装、覆盖安装与卸载，校验历史文件哈希不变；不是实际旧数据库迁移测试。Linux 使用 Xvfb；仅在隔离 GitHub runner 执行。记录进程存活与退出状态，仍需人工窗口、安装、数据库升级及通知验收。
3. 校验各平台提交号、版本和哈希后上传内部验证 artifact，保留 30 天。
4. `v*` 标签额外进入 `verify_packages`，核验标签与 pubspec 一致、五平台七个文件齐备；该作业只校验，不创建或发布 Release。整个工作流仅有 `contents: read` 权限。
5. 后续迭代默认不创建 RC 标签或 Release 草稿。macOS、iOS 验收与相关回归完成后，再从对应通过的源码和产物发布正式稳定版，并读回版本、正文及附件摘要。签名和商店提交单独核验，详见[发布策略](Release_Policy.md)。

本地有未提交改动时，清单中的 HEAD 不能表示全部源文件；发布候选应来自干净、已提交的 CI checkout。勿把本地 dirty 构建当作可追溯正式产物。

Linux 的编译开发库不等于媒体运行时插件。使用 `--no-install-recommends` 时须显式安装 `gstreamer1.0-plugins-base`、`gstreamer1.0-plugins-good`；CI 另安装 `gstreamer1.0-tools` 并用 `gst-inspect-1.0` 检查 `playbin`、`audiopanorama`、`autoaudiosink`，再执行原生进程启动检查。锁定的音频插件在 `playbin` 缺失时可能在初始化直接退出。无头 CI 还显式提供 Xvfb/xauth 和 AT-SPI；这不替代实际桌面播放、录音及可访问性验收。CI 将托管运行器的 Azure Ubuntu 下载源替换为 Ubuntu 官方 HTTPS archive，保留原有发行版、组件和签名密钥；依赖安装限制为 12 分钟，网络请求有超时与重试，避免缓慢传输耗尽整个构建时限。

## Windows 安装与升级

优先运行生成的 Inno 安装器。`scripts/Install.ps1` 会校验清单与当前源码提交后打开该安装器，不再递归删除安装目录内数据库。`scripts/Uninstall.ps1` 仅委托该目录的 `unins000.exe`；没有受管卸载程序的旧安装会停止，需先备份并迁移。Inno 只移除自己安装的文件，保留未知文件与历史数据库；不额外递归删除整个安装目录。

升级前在独立测试账号备份原始数据库与附件。保留旧版安装件和数据副本。公开 v1.7.0-rc.33 使用 DB schema 14，本地主线当前使用 schema 16（源码见 `lib/data/database_helper.dart`），不能承诺直接用旧程序降级读取，回退应恢复完整的升级前副本。macOS 候选默认迁移增量通知日志，安装旧程序前须先[退出并导出最新 v1 日志](Notification_Storage_Upgrade.md)；旧程序不一定认识存储选择器门禁。不要在唯一一份真实用户数据上执行故障注入或卸载演练。

## P1 持续日期源码的本地构建（2026-10-27）

源码 `e336f05` 的 macOS arm64 Debug 已构建并通过严格签名检查；iOS 模拟器 Debug 的主应用与 ReminderActivity 扩展均为 IOSSIMULATOR／1.7.0+33。版本号沿用 +33，不表示与公开 rc.33 的源码相同。产物位于当前受管工作树的 build 目录，没有安装、启动、上传或发布。

构建固定使用 Flutter 3.44.9／Dart 3.12.2、Xcode 27.1，以及已有 CocoaPods 1.16.2 包装入口；将包装目录加入单次命令 PATH，不修改用户全局工具设置。该构建复用现有 Pods 兼容配置；Flutter 仍提示通知插件尚未支持 SPM，该提示不是构建失败。测试、产物身份和摘要见 [P1 机器证据](benchmarks/p1-rolling-window-2026-10-27.json)，本轮功能与后续原生门槛见 [P1 分阶段记录](P1_Rolling_Notification_Window.md)。
