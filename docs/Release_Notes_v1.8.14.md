# DontForget v1.8.14 · Android / Windows / Linux / iOS

修复分享草稿的中文输入与备忘保存。build85／schema17。

## 更新

- 中文输入法候选尚未确认时，暂停保存分享备忘；确认候选后立即恢复保存。
- 处理仅组合范围变化、文字本身不变的输入法确认，防止保存按钮停留在错误状态。
- “保存为备忘”始终按原文保存；包含`/agent`或`/goal`前缀的分享内容不触发命令、AI处理或提醒。
- 普通输入的显式命令功能保留，首页草稿及已保存记录保持。
- 精简后续计划：USB硬件排查退出产品主线，深度故障实验与非核心扩展改为按需推进；保留数据保护与每版升级验收。
- 不更改数据库schema17、依赖、模型与语音凭据。

## 下载与安装

- Windows x64：EXE安装版或便携ZIP，未做Authenticode签名。
- Linux x64：TAR.GZ，Ubuntu24.04基线。
- Android：固定发行证书的通用APK、ARM64 APK及AAB。
- iOS：`DontForget_iOS_unsigned_v1.8.14.ipa`为未签名IPA，需要个人重签；安装方式见[说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)，不属于App Store或TestFlight分发。

## 验收范围

源码、自动化、安装包与真实设备分别记录，见[本版验收](https://github.com/yarnway/dontforget/blob/main/docs/Release_1.8.14_85_2026-11-17.md)。Windows每版最新保全、运行中正常覆盖、实际数据／凭据与普通重开属于必要门禁。手机实际安装版本与验收情况以记录为准；CI构建不替代系统键盘或真机验收，不自动处理Apple认证。
