# Android／Windows／Linux v1.8.2（build71，2026-11-11）

[v1.8.2已正式发布](https://github.com/yarnway/dontforget/releases/tag/v1.8.2)并设latest，schema17／固定源码`de4bda47a8759c4bff634d115d65f8bd4ec7e14a`，三端五包及报告共16附件；旧v1.8.1标签和附件保持。

## 已完成

- “全部知道了”和“我知道了”统一为“知道了”，保留原确认范围及状态持久化。26个三语文案键精简；删除重复外观保存说明、模型长篇介绍、分类范围说明和每张复习卡重复规则，保留可展开的集中规则及必要错误／删除／权限／上传信息。旧矩形叠层与宽度修复沿用1.8.1。[文案记录](UI_Copy_Polish_71_2026-11-10.md)。
- 学习计划编辑、复习和每日练习可进入整组管理，集中看批次与暂停数量，整组暂停、继续或移至回收站。事务内核对全部成员及字段，陈旧操作拒绝，写入失败整组回滚；进度、原日期和附件保持。回收站操作先确认，不永久删除；过期学习批次不补发系统通知。[实现与+70分层证据](Study_Plan_Management_70_2026-11-10.md)。
- +71本地相关155通过、分析0；设置桌面深浅主题／窄屏渲染预览1项通过并查看。最终[固定源码CI42841722705](https://github.com/yarnway/dontforget/actions/runs/42841722705)七项成功，Linux Flutter2403通过／2跳过、Windows2385通过／20跳过；Python两端161运行（4／6跳过）。[CI证据](benchmarks/github-ci-v1.8.2-2026-11-11.json)。本地SDK3.47.2与固定CI3.44.9分开，+70旧源码的完整CI不替代+71。
- Windows先新备份，应用运行中+70→本地+71，再运行中覆盖固定CI+71；两次正常关闭、安装器退出0，未允许强关，本地38／CI37份payload、PE1.8.2.71、4事项／0媒体／1设置全字段和凭据实际DPAPI读回保持，CLI及普通App重开。首次预检发现旧App未运行，尚未启动安装器；先重开旧+70，再完成真实运行中升级。正式Setup与安装验收包摘要一致。Windows原生GUI交互未记通过。
- Android正式版和QA47分别在升级前重新备份最新数据，同签名+70→+71、全字段／媒体／安全条目保持、普通入口冷重开；正式版2／0／1、QA47的55／9／1及9原声。正式身份最终覆盖固定CI通用+71，再核对全部字段及安全条目并冷重开；公开APK与此验收包摘要一致。+71未重新卸载，+68双身份卸载／新装／恢复和+69／+70升级证据保留原版本归属。
- Pixel普通QA+71页面实际截图已查看；观察范围见发行JSON。学习分组触控／实际Android SQLite冷重开是在+70独立临时合成身份完成，通知传输为记录替身，不代表系统送达；临时身份已卸载，未写入用户数据。共享源码／布局测试不替代Apple或其他机型验收。
- [发布工作流](https://github.com/yarnway/dontforget/actions/runs/42949696021)成功；源构建归档摘要／CRC、APK／AAB固定证书、五包及报告核验。发布后下载发行回执、来源清单与校验表，与14份已验源文件逐一核对，验证全部16附件的大小和摘要；标签、专用正文、latest及旧v1.8.1保留均独立读回。[发行证据](benchmarks/github-release-v1.8.2-2026-11-11.json)。个人凭据未随源码或包分发。

## 包

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| DontForget_Android_v1.8.2.aab | 73247117 | `e6bd8b6f2362332e64fe65c7d990b469edb1a19fcd6d1ba54e8f36da221bb8eb` |
| DontForget_Android_v1.8.2.apk | 76473084 | `8e09e362cfce6835adcf1a9cb7ce217994886bd2a398c8db45d68eeab4e6d7d1` |
| DontForget_Linux_x64_v1.8.2.tar.gz | 14401974 | `e10c202379a4487fded953e28f3a34f3388808b637ef70630e8e870a5b94e615` |
| DontForget_Setup_v1.8.2.exe | 14669662 | `96ecd3be12bc00bebb04f6a3ba5daab2a54f3abfc127caea4d28b2b1232492ef` |
| DontForget_Windows_Portable_v1.8.2.zip | 17894494 | `68a2fab3a58bc34d92efd0594ea6547603b51dbbab3529c7a97370f81df0d5b6` |

Android通用APK／AAB，独立ARM64正式附件另续。Windows尚无Authenticode签名。Linux为Ubuntu24.04隔离启动范围，不移记本机22.04桌面通过。

## 剩余阶段

46 USB长期／跨主机；47其他机型／真实IME发送、通知休眠重启／录音中断及Windows原生GUI／托盘／Toast；48带附件跨设备、凭据故障／磁盘满／断电、保留管理及原声压缩；49跨计划调整、负担预测、档案管理／清除与词条身份迁移、更多练习排程、图片分享及LAN编辑／删除／附件／冲突；50 Apple设备／签名公证、独立ARM64正式附件、Windows Authenticode及商店。
