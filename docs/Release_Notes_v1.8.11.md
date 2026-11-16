# DontForget v1.8.11 · Android / Windows / Linux / iOS

设置新增关于信息和手动更新检查，旧备份的附件引用可明确登记，首次提供供个人重签安装的iOS下载包。build81／schema17。

## 更新

- 设置新增“关于与更新”：读取实际安装版本和构建号，支持复制信息、项目主页与第三方许可。
- 手动检查GitHub公开发行版，展示新版本、说明和对应平台下载入口；网络失败可重试，匿名API限流时使用项目公开来源文件核对。
- 同版本继续比较构建号；未能核对时明确提示，不把连接失败写成“已是最新”。iOS下载附个人重签说明，Android提供通用与ARM64 APK选择。
- 内容管理支持选取旧SQLite／JSON备份，只读预检后明确登记其附件引用。源备份移走后，登记的引用继续保护原件。
- 登记详情默认只读；移除登记另行确认，不删除源备份或附件。重复文件不重复登记；达到容量上限时拒绝新增，保留旧保护。
- 未知或损坏的引用登记会保守阻止物理清理；并发修改、恢复及清理中断时重新核对保护关系。
- 保留完整备份预检、导出历史、ARM64小包和既有语音交互，数据库仍为schema17。

## 下载与安装

- Windows x64：Setup安装器或Portable。Windows未做Authenticode签名。
- Linux x64：归档，运行基线Ubuntu24.04。
- Android：固定发行证书签名的ARM64 APK、通用APK及AAB。
- iOS：`DontForget_iOS_unsigned_v1.8.11.ipa`为**未签名**包，需要用AltStore及自己的Apple账号个人重签。Windows用户可按[安装说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)操作；免费账号通常需每7天续期。此文件不代表App Store或TestFlight分发，不含开发者证书、描述文件或Apple凭据。

## 验收范围

源码、自动化、各平台候选包、本机保全升级与手机触屏操作分别记录，见[本版记录](https://github.com/yarnway/dontforget/blob/main/docs/Release_1.8.11_81_2026-11-16.md)。Android本轮按固定签名、ABI与发行包核对交付；Pixel当前未连接，+81正式／QA的真机覆盖升级未新做，历史功能验收保留原源码与版本归属。Windows运行中保全升级与iPhone独立身份结果另列，不冒称所有平台矩阵通过。

iPhone独立身份的首启、重开、中文录入、升级与数据读回不替代全部通知、录音、附件、灵动岛与签名续期矩阵。

其余真实语音／输入法、桌面GUI、容量与故障恢复等未闭合项目保留在[阶段任务表](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)。外部引用登记只保存引用快照，不会替用户搬运或加密原备份，恢复仍需重新选取并核对源文件。
