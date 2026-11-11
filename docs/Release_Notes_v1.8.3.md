# DontForget v1.8.3 · Android / Windows / Linux

安卓 ARM64 安装包与发行校验改进，build72／schema17。

## 更新

- 新增独立 ARM64 APK，面向常见的64位安卓手机，减少下载体积和安装占用。通用 APK 继续支持 ARM64、ARMv7 和 x86_64，AAB 保持完整架构支持。
- ARM64 与通用 APK 使用同一应用身份和固定发行证书，可直接覆盖升级；升级前建议导出备份。两种 APK 的版本、最低系统要求、原生库架构与插件完整性分别校验。
- 构建失败时保留通用包，禁止把 ARM64 包误标为通用包；发布前分别验证两种 APK 和 AAB 的固定发行签名。
- 保留此前输入、语音、学习计划和界面改进，无新增依赖或数据库迁移。个人模型与语音凭据仅保存在本地，不随公开包分发。

## 安装与验收范围

- Android：ARM64 APK、通用 APK、AAB；Windows x64：Setup、Portable；Linux x64：归档。Linux基线Ubuntu24.04，Windows尚无Authenticode签名。
- 源码、自动化、普通安装包与真实设备验收分别记录，见[阶段台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)。
- 其他机型／IME、通知休眠与录音中断、Windows GUI、带附件的系统文件选择器与故障恢复、分享／LAN冲突和更多学习排程继续；Apple、代码签名和商店分发另续。
