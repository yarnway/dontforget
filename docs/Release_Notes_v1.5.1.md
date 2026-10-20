# DontForget v1.5.1 验收候选

版本 `1.5.1+2`，数据库 v8；候选源码 `66bf406c15a9723a8fe190a55c7007ad4c52eb3c`。
当前为发布草稿，尚未完成完整设备验收，未公开发布。

**当前候选存在 Mac 录音阻塞，不可用于正式发布。** 真机显示录音中，但缓存目录未创建导致系统无法写入音频，停止操作未收到完成回调。候选应用已退出，未生成媒体记录。修订后的包必须重新构建、核验与复测；以下附件仍为原候选 66bf406。

## 修订内容

- 移除旧内置 API 凭据，默认密钥为空；升级只清理已知旧内置密钥，保留用户配置。
- 设置保存等待初始化并使用事务，失败保留页面；服务商来源变化时清空旧密钥。
- 数据备份读取一致事务，验证镜像完整性后替换；损坏主库不再被旧镜像静默覆盖。提供手动备份入口。
- 修复月末/闰年循环、错过周期以及可空字段清除；原始日历锚点和完整通知生命周期留待 v1.6。
- 修复 Android embedding / desugaring / 插件 SDK 兼容、Linux 托盘初始化、Windows C++ 标准及打包运行库。
- 五平台统一版本、提交身份、校验清单，构建前执行分析与测试。

## 验证结果

[GitHub Actions run 39402846594](https://github.com/yarnway/dontforget/actions/runs/39402846594) 全部质量检查和五平台构建成功：

- 49 项 Flutter 测试、10 项打包测试通过。
- 七个交付包下载后独立验证版本、提交身份与 SHA-256 通过。
- Windows / macOS / Linux 交付归档解压后进程存活 10 秒。
- Windows CI 新安装、同候选覆盖安装、卸载与合成历史文件保留通过。
- 当前 Mac 英文设置保存返回主页且持久化；空任务库手动备份的 SQLite 镜像与 JSON 可读，主库/镜像完整性检查通过。用户协助滚动设置页；备份成功提示未捕获。

上述自动化不代替真实系统通知、麦克风录音、真实 v7 数据升级或设备兼容验收。

## 下载选择与限制

| 平台 | 文件 | 限制 |
| --- | --- | --- |
| Windows x64 | Setup EXE 或 Portable ZIP | 用户主机安装及实际通知/录音待验收 |
| Android | test-signed APK / AAB | 手机安装使用 APK；测试签名，不是正式商店包 |
| macOS | unnotarized ZIP | 未公证；不能据此声称正式分发资格 |
| iOS | unsigned IPA | 未签名，不能直接安装到 iPhone |
| Linux x64 | tar.gz | 虚拟显示 CI 启动通过，实际桌面功能待验收 |

附件包括五份 manifest、五份 SHA256SUMS，以及三份桌面启动和一份 Windows 安装检查结果。manifest 中的签名与运行验收范围应与本说明一起阅读。

## 升级与验收

升级前保留原始数据库和附件副本。备份包含未加密的设置（包括 API Key）与附件路径，**不包含附件文件本体**。不要为解决 Android 签名冲突而直接卸载有数据的旧版本；不能假定旧程序可直接读取升级后的 v8 数据库。

待完成：四类用户设备的通知/录音/三语设置场景、真实 v7 脱敏样本升级、正式签名/公证，以及维护者在服务商控制台撤销历史泄露凭据。数据恢复预览、失败回退和提醒闭环属于下一阶段 v1.6。

完整记录：[发布前验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Release_Acceptance_v1.5.1.md)；操作步骤：[设备验收](https://github.com/yarnway/dontforget/blob/main/docs/Device_Acceptance_v1.5.1.md)。

## 候选文件 SHA-256

| 文件 | SHA-256 |
| --- | --- |
| DontForget_Android_test-signed_v1.5.1.apk | `1627383aa469a74fff1aae5bb5aea0cff22ef4aa4e600472feb0f1ac8b6f34e4` |
| DontForget_Android_test-signed_v1.5.1.aab | `e4e43138de62af281a59e255c41ff584c8cfb89bfc804b6d5858a938558599d8` |
| DontForget_iOS_unsigned_v1.5.1.ipa | `8afda0fb50701b91043362c7c5b6d6389b2171cc58de80bdad85559fd178b56b` |
| DontForget_Linux_x64_v1.5.1.tar.gz | `a215e07e2db5100c12d98bf53a1ddc5b73d63e9aa097bb0897430583e5971cc2` |
| DontForget_macOS_unnotarized_v1.5.1.zip | `397bfed15de579ec9e9873ceb7454a8666c3792773d2dff16127b85e8b48b10f` |
| DontForget_Setup_v1.5.1.exe | `2b532496847b17cfd583c533043ff5b8e0c5df43222e5cc497b76c82b3370018` |
| DontForget_Windows_Portable_v1.5.1.zip | `196f1acd569fd1cffd83bf8ca9a8582c2ae3a0144a57618d1c4e953d36d96cbb` |
