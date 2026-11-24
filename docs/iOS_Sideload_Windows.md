# Windows通过AltStore安装iOS客户端

GitHub Release中的`DontForget_iOS_unsigned_v<版本>.ipa`由固定源码在云端Mac构建，未包含Apple签名或设备描述文件。用户使用自己的账号在本机个人重签；免费账号通常7天后需要续期，不属于App Store或TestFlight安装。

1. 按[AltStore官方Windows指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)安装AltServer及所需Apple组件，并在iPhone安装AltStore。Apple账号和验证码由本人在本机输入。
2. iPhone连接Windows，按提示信任电脑；需要时在“设置→隐私与安全性→开发者模式”开启并重启确认，在“通用→VPN与设备管理”信任自己的开发者身份。
3. 用iPhone的Safari从本版Release下载`.ipa`，在“文件→浏览→下载项”确认文件存在。**只下载到Windows的文件不会自动出现在iPhone上。** 若下载的是Actions artifact ZIP，先在“文件”中点ZIP解压，再进入生成的文件夹。
4. 保持AltServer运行、USB连接，打开手机AltStore → My Apps → 左上角＋ → 浏览，选择手机上的IPA。按本机提示完成个人重签，等待明确的成功或错误结果。
5. 打开“别忘了”。安装完成与实际运行分开核对；后续同身份升级前，先通过产品备份功能保全最新数据。保留备份原件，不用卸载重装代替升级验证。

免费账号的应用数、App ID和续期限制以[Apple官方说明](https://developer.apple.com/help/account/basics/about-your-developer-account)及AltStore实际提示为准。不要为了排错删除其他应用、撤销证书或上传Apple密码／验证码。

本次iPhone15ProMax使用独立身份`com.yarnway.dontforget.acceptance.iphone15-20261115`，与普通发行包的`com.yarnway.dontforget`分开；安装普通发行包不会自动合并独立验收应用的数据。已有数据使用产品的备份预检与明确恢复流程迁移。

## 当前发行与设备状态（2026-11-24）

公开发行 `v1.8.23+94` 的普通身份未签名 IPA 已校验，含提醒扩展。iPhone 已经通过 USB 读回独立验收版 `1.8.11+81`。AltStore 覆盖恢复后，用户在 iPhone 信任原开发者身份，为验收应用续签并确认可以打开。续签前后的事项、附件和偏好设置已逐项核对。

同验收身份的 `1.8.24+99` IPA 已完成签名覆盖。用户确认可以打开并查看关于页，USB 读回相同签名应用身份和实装版本，覆盖前后的业务字段、附件与偏好设置一致。用户实测语音编辑、两种发送与冷重开后播放。新版过渡、播放自动收起、中文输入、通知及 VoiceOver 待续验。[阶段台账](Next_Steps_2026-11-02.md#11-月-24-日--iphone-语音过渡与系统分享-build-100)

从 build 100 起，候选包含提醒和分享两个扩展。AltStore 提示是否保留应用扩展时，选择保留，以便验收系统分享和灵动岛。分享扩展需要与主应用具备相同的 App Group 权限，个人重签后还要用真实内容核对。这些扩展也占用免费账户的 App ID 名额。[AltStore App ID 说明](https://faq.altstore.io/altstore-classic/app-ids)
