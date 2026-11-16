# DontForget v1.8.12 · Android / Windows / Linux / iOS

优化设置和关于页，精简常用提示文案，减少成功反馈对操作的遮挡。build82／schema17。

## 更新

- 设置入口增加用途说明，统一标题、图标与留白；窄屏和大字模式采用分组列表。
- 关于页前置检查更新，将版本复制收进版本行，主页与许可独立分组。
- 精简首页空态、更新、设置、分享草稿、复盘、本地模型与同步等60组文案，中英日同义；明确区分未保存、已保存及结果未核对。
- 普通成功提示4秒后收起；较长的指定时长继续保留。警告和错误至少8秒；带撤销等操作及无障碍导航模式下的提示持续保留。
- 保持默认只读详情、明确修改入口、既有语音手势和schema17；不变更模型或语音凭据。

## 下载与安装

- Windows x64：安装版EXE或便携ZIP，未做Authenticode签名。
- Linux x64：TAR.GZ，Ubuntu24.04基线。
- Android：固定发行证书签名的通用APK、ARM64 APK和AAB；不确定架构时使用通用APK。
- iOS：`DontForget_iOS_unsigned_v1.8.12.ipa`为**未签名**IPA，须用AltStore及自己的Apple账号个人重签。免费账号通常每7天续期；非App Store或TestFlight分发。[安装说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)。

## 验收范围

源码、质量门禁、安装包和真实设备分别记录，见[本版验收](https://github.com/yarnway/dontforget/blob/main/docs/Release_1.8.12_82_2026-11-16.md)。Android Pixel暂不可接入，本轮正式／QA真机保全升级未执行；签名、ABI与包校验不替代真机结果。Windows运行中保全升级与iPhone独立身份升级另列，不宣称全部平台原生矩阵完成。

Windows原生GUI截图工具仍有已记录的工作目录URI故障；组件渲染和自动化不替代原生交互／读屏。iPhone通知、录音、附件、灵动岛与个人签名续期，以及容量、真实故障、迁移和同步冲突等继续按[阶段台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)推进。
