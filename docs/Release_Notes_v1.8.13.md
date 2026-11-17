# DontForget v1.8.13 · Android / Windows / Linux / iOS

优化语音录音、滑动转文字和转写编辑的连续体验。build84／schema17。

## 更新

- 录音显示波形气泡；上滑右划时展开同一文本气泡，松手进入编辑。
- 手机编辑态采用深色背景和绿色文本区，保留“发送原语音”和“发送”，适配系统键盘、横屏和大字。
- 保留原有语音手势：左划取消、普通松手发送原声、转文字后编辑、继续右滑发送文字。
- 手动修改与中文组合输入不被迟到转写覆盖；原声发送失败可重试，文字和原声发送保持互斥。
- 修复“按住说话”标签重复及语义范围扩散，让输入按钮保持独立边界。
- 使用已启用且已配置的腾讯实时识别时，可在录音中查看文字；本机文件识别在松手后转写。识别失败仍可编辑文字或发送原声。
- 不更改语音服务配置、模型凭据、依赖或schema17。新增Windows实际NTFS目录替换保护回归，不改变现有清理逻辑。

## 下载与安装

- Windows x64：EXE安装版或便携ZIP，未做Authenticode签名。
- Linux x64：TAR.GZ，Ubuntu24.04基线。
- Android：固定发行证书签名的通用APK、ARM64 APK和AAB。
- iOS：`DontForget_iOS_unsigned_v1.8.13.ipa`为**未签名**IPA，须通过AltStore及自己的Apple账号个人重签；免费账号通常每7天续期，不属于App Store或TestFlight分发。[安装说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)。

## 验收范围

源码、自动化、最终安装包和真实设备分别记录，见[本版验收](https://github.com/yarnway/dontforget/blob/main/docs/Release_1.8.13_84_2026-11-17.md)。组件截图使用合成文本，不替代系统键盘、读屏或识别准确率验收。Windows运行中覆盖及原数据／实际凭据、双Android分别最新保全与升级的最终范围以本版记录为准。

iPhone84尚未安装或完成真机验收，最近独立读回仍为81；公开IPA仅证明构建与包身份。免人工个人重签仍受当前工具能力限制，不自动处理Apple认证。Windows GUI／Toast／托盘／麦克风、其他通知与录音中断、软件输入法及真实读屏、容量与真实故障、迁移和同步冲突继续按[阶段台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)推进。
