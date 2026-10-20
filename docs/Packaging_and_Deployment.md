# DontForget 打包与发布验收

当前候选版本由 `pubspec.yaml` 决定（1.5.1+2），Flutter 固定为 3.44.9。构建成功、打包成功、安装运行、系统通知和正式发布分别验收。具体执行状态见 [v1.5.1 验收记录](Release_Acceptance_v1.5.1.md)。

## 构建与产物

在项目根目录执行；先安装相应平台 Flutter 原生编译依赖与 Python 3。

| 平台 | 命令 | dist 产物 | 交付边界 |
| --- | --- | --- | --- |
| Windows 10/11 x64 | `pwsh -File scripts/package_windows.ps1` | `DontForget_Setup_v1.5.1.exe`、`DontForget_Windows_Portable_v1.5.1.zip` | 需要 Visual Studio C++ 与 Inno Setup 6；未签名 |
| Android | `bash scripts/build_android.sh` 或 `pwsh -File scripts/build_android.ps1` | `DontForget_Android_test-signed_v1.5.1.apk` / `.aab` | 测试密钥签名；不是商店交付件 |
| Linux x64 | `bash scripts/build_linux.sh` | `DontForget_Linux_x64_v1.5.1.tar.gz` | 需要 GTK、GStreamer、ALSA、Ayatana AppIndicator 等原生依赖；录音运行时另需 pulseaudio-utils 和 ffmpeg |
| macOS 12+ | `bash scripts/build_macos.sh` | `DontForget_macOS_unnotarized_v1.5.1.zip` | 完整 Xcode、CocoaPods；未公证 |
| iOS 15+ | `bash scripts/build_ios.sh` | `DontForget_iOS_unsigned_v1.5.1.ipa` | 完整 Xcode、CocoaPods；未签名，不能直接真机安装 |

每个平台还生成 `<platform>-manifest.json` 和 `<platform>-SHA256SUMS.txt`，包含版本、构建号、提交号、签名状态、文件大小与 SHA-256。桌面 CI 另有 `<platform>-startup.json`。便携包只表示免安装解压，应用数据仍按平台应用支持目录存放，不能当作包含用户数据的可迁移备份。

脚本使用锁定依赖，任一步失败即停止。Windows 在编译安装器前检查目录；归档发现数据库、WAL/SHM、日志、JSON 备份或 `.dart_tool` 会报错，保留原文件供检查。不会为打包删除用户数据。仓库内可选 CRT DLL 不构成在所有 Windows 环境免运行库的证明。

## 校验

```bash
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
python3 -m unittest discover -s scripts/tests -v
# 单个平台（将 COMMIT 替换为构建时的完整提交号）
python3 scripts/verify_artifacts.py dist --platform macos --revision COMMIT
# 五个平台产物汇总后
python3 scripts/verify_artifacts.py release-files --revision COMMIT --tag v1.5.1
```

Python 回归测试使用假二进制验证归档、清单与失败保护；它们不是原生编译证据。哈希证明下载件与清单一致，不证明发行方身份或应用行为。

## CI 与发布

工作流：`.github/workflows/build_and_release.yml`。

1. main 推送、PR、手动运行：先分析、Flutter 测试和打包脚本测试，再运行 Windows、Android、Linux、macOS、iOS 构建矩阵。
2. 桌面产物执行 10 秒进程启动检查。Linux 使用 Xvfb；仅在隔离 GitHub runner 执行。记录进程存活与退出状态，仍需人工窗口、安装、数据库升级及通知验收。
3. 校验各平台提交号、版本和哈希后上传候选 artifact，保留 30 天。
4. 只有 `v*` 标签可以进入 release job；校验标签与 pubspec 一致、五平台七个文件齐备后创建 **draft prerelease**。main 和手动运行不会创建正式 Release。签名、商店提交和正式公开发布另行处理。

本地有未提交改动时，清单中的 HEAD 不能表示全部源文件；发布候选应来自干净、已提交的 CI checkout。勿把本地 dirty 构建当作可追溯正式产物。

## Windows 安装与升级

优先运行生成的 Inno 安装器。`scripts/Install.ps1` 会校验清单与当前源码提交后打开该安装器，不再递归删除安装目录内数据库。`scripts/Uninstall.ps1` 仅委托该目录的 `unins000.exe`；没有受管卸载程序的旧安装会停止，需先备份并迁移。Inno 只移除自己安装的文件，保留未知文件与历史数据库；不额外递归删除整个安装目录。

升级前在独立测试账号备份原始数据库与附件。保留旧版安装件和数据副本。候选版 DB v8 不能承诺直接用旧程序降级读取，回退应恢复完整的升级前副本。不要在唯一一份真实用户数据上执行故障注入或卸载演练。
