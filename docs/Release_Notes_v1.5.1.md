# DontForget v1.5.1 验收候选

版本 `1.5.1+2`，数据库 v8；候选源码 `7cdf85b766fbc9be437246803a5443b2ace32937`。
当前为未公开的发布草稿，完整设备验收尚未完成。

## 修订内容

- 移除旧内置 API 凭据，默认密钥为空；升级只清理已知旧内置密钥，保留用户配置。
- 设置保存等待初始化并使用事务，失败保留页面；服务商来源变化时清空旧密钥。
- 备份读取一致事务数据、检查镜像完整性后替换；损坏主库不再被旧镜像静默覆盖。
- 修复月末/闰年循环、错过周期及可空字段清除；原始日历锚点与完整通知生命周期留待 v1.6。
- 修复首次 Mac 录音目录不存在导致的文件创建和停止失败；没有 AI 密钥时保留关联原声任务。
- 首次有效提醒调度等待通知插件初始化，等待取消完成后再重建；不代表提醒闭环已完成。
- 修复原生平台插件与运行库兼容，五平台统一版本、提交身份及哈希检查。

## 验证结果

[GitHub Actions run 39407526781](https://github.com/yarnway/dontforget/actions/runs/39407526781) 质量检查及五平台构建成功。

- 55 项 Flutter 测试及 10 项打包回归通过，静态分析无问题。
- 七个交付包的版本、提交身份和 SHA-256 独立验证通过。
- Windows / macOS / Linux 归档解压后进程存活 10 秒；Windows CI 安装、同候选覆盖、卸载和合成历史文件保留通过。
- 当前 Mac 新包录音及停止通过：原声任务与媒体关联正确，AAC 文件完整解码通过；用户处理通知权限后确认应用内回放能听到录音。
- Mac 系统通知权限当前开启，原生通知请求添加成功；用户完成测试任务后，完成状态持久化并观察到原生取消请求。到期送达及跨重启一致性尚未验收。
- 旧候选 66bf406 上的设置、备份与三语重启部分验证单独保留在台账中，不算新包所有场景重跑。

首次通知授权等待期间，界面显示 AI... 且操作缺少反馈；用户处理权限后状态恢复。此体验问题仍保留。自动化与上述局部设备结果不能代替完整设备验收。

## 下载选择与限制

| 平台 | 文件 | 限制 |
| --- | --- | --- |
| Windows x64 | Setup EXE / Portable ZIP | 用户主机实际录音、通知及升级待验收 |
| Android | test-signed APK / AAB | 手机安装用 APK；测试签名，不是正式商店包 |
| macOS | unnotarized ZIP | 未公证；不能据此声称正式分发资格 |
| iOS | unsigned IPA | 未签名，不能直接安装到 iPhone |
| Linux x64 | tar.gz | 虚拟显示 CI 启动通过，实际桌面功能待验收 |

附件为七个包、五份 manifest、五份 SHA256SUMS、三份桌面启动和一份 Windows 安装检查，共 21 个文件。

## 剩余验收

通知前台/后台/重启/编辑/完成/删除一致性，拒绝麦克风权限及重启回放，其他设备功能，真实 v7 脱敏样本升级，正式签名/公证，以及维护者在服务商控制台撤销历史泄露凭据。

升级前保留数据库与附件副本。当前备份未加密、包含设置（包括 API Key）和附件路径，**不包含附件文件本体**。不要为绕过 Android 签名冲突直接卸载有数据的版本；不能假定旧程序可以读取升级后的 v8 数据库。

v1.6 数据恢复预览、失败回退和提醒闭环尚未开始。完整证据见[发布前验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Release_Acceptance_v1.5.1.md)。

## 候选文件 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| DontForget_Setup_v1.5.1.exe | `5ffbfffa0469d188c9424970808087ec8149be51b2bb636768f9d5eb596ba5ff` |
| DontForget_Windows_Portable_v1.5.1.zip | `23830d91e2504375e5f7558291a07fb97464bb84c15e2b8b3261266489052f4a` |
| DontForget_Android_test-signed_v1.5.1.apk | `a4de8c4fce1a3dbda929b07037135633d62e17580de4be0c1768eb89ec6f67cd` |
| DontForget_Android_test-signed_v1.5.1.aab | `e60e55a02b0b0ca19d1d31f99522daf8ddcad0d4fb21f69dc76f00cbfa8c5305` |
| DontForget_Linux_x64_v1.5.1.tar.gz | `01da8b5e6e377196c1889aee11be11e2ddd6564f0e82558551a7b18f7dbfea8a` |
| DontForget_macOS_unnotarized_v1.5.1.zip | `9bf667a1c061165653205f2a6f2ddb965ce7da9bd508bf547cbb182ab511c787` |
| DontForget_iOS_unsigned_v1.5.1.ipa | `08136eb5fd711f85e0bb450e0501b886b9dee09a53464ea5145e5f76bb502bca` |
