# Windows通过AltStore安装iOS客户端

GitHub Release中的`DontForget_iOS_unsigned_v<版本>.ipa`由固定源码在云端Mac构建，未包含Apple签名或设备描述文件。用户使用自己的账号在本机个人重签；免费账号通常7天后需要续期，不属于App Store或TestFlight安装。

1. 按[AltStore官方Windows指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)安装AltServer及所需Apple组件，并在iPhone安装AltStore。Apple账号和验证码由本人在本机输入。
2. iPhone连接Windows，按提示信任电脑；需要时在“设置→隐私与安全性→开发者模式”开启并重启确认，在“通用→VPN与设备管理”信任自己的开发者身份。
3. 用iPhone的Safari从本版Release下载`.ipa`，在“文件→浏览→下载项”确认文件存在。**只下载到Windows的文件不会自动出现在iPhone上。** 若下载的是Actions artifact ZIP，先在“文件”中点ZIP解压，再进入生成的文件夹。
4. 保持AltServer运行、USB连接，打开手机AltStore → My Apps → 左上角＋ → 浏览，选择手机上的IPA。按本机提示完成个人重签，等待明确的成功或错误结果。
5. 打开“别忘了”。安装完成与实际运行分开核对；后续同身份升级前，先通过产品备份功能保全最新数据。保留备份原件，不用卸载重装代替升级验证。

免费账号的应用数、App ID和续期限制以[Apple官方说明](https://developer.apple.com/help/account/basics/about-your-developer-account)及AltStore实际提示为准。不要为了排错删除其他应用、撤销证书或上传Apple密码／验证码。

本次iPhone15ProMax使用独立身份`com.yarnway.dontforget.acceptance.iphone15-20261115`，与普通发行包的`com.yarnway.dontforget`分开；安装普通发行包不会自动合并独立验收应用的数据。已有数据使用产品的备份预检与明确恢复流程迁移。

## 当前发行与设备状态（2026-11-22）

v1.8.23／build94 已发布普通身份未签名 IPA（`DontForget_iOS_unsigned_v1.8.23.ipa`，`10,242,177 B` / `9.77 MiB`，较 `v1.8.20` 累计缩减 `-12.68%`，SHA‑256 `7f735c69...`，内含 `PlugIns/ReminderActivity.appex` 并已独立读回校验），但本机当前无 iPhone USB 连接且为 Windows 环境，尚未在 iPhone 实机安装或验收。手机最近独立读回仍为 `1.8.11／81`，原应用与数据保留。自动签名安装尚无可用路径，构建／发布不等于手机已升级；下次接入 iPhone 覆盖前重新取最新备份，再按既有 AltStore 身份重签覆盖并核对版本、数据、中文输入、通知、录音与 VoiceOver。[分层记录](Release_1.8.23_94_2026-11-22.md)。
