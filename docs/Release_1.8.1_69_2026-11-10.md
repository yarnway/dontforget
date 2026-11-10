# Android／Windows／Linux v1.8.1（build69，2026-11-10）

[v1.8.1已正式发布](https://github.com/yarnway/dontforget/releases/tag/v1.8.1)并设latest，schema17／固定源码`24b9e99a6967110774ce6706acadbf1dde6a3793`，三端五包及报告共16附件；旧v1.8.0标签与附件保持。

## 已完成

- Windows安装器确认退出先排空草稿、暂停生产者并关闭存储；普通关闭仍到托盘，录音／编辑／恢复中暂缓。配置卡片裁剪内部交互背景、增加区块间距并移除矩形叠层；模型／语音／AI保存栏与正文对齐。
- 首页提醒、错过提醒、分类与输入采用共同宽度和边距。窄屏错过提醒原按内容收缩，375视口曾只有289.4，修复后351；字体／语言换行仍可用。Windows输入仍默认紧凑，随内容展开。
- 本地+69相关31通过、分析0；[固定源码CI42812595991](https://github.com/yarnway/dontforget/actions/runs/42812595991)七项成功，Linux Flutter2383通过／2跳过、Windows2365通过／20跳过，Python两端161运行（4／6跳过）。本地SDK3.47.2与固定CI3.44.9分开，+68的完整与原生结果不移记为+69。[CI证据](benchmarks/github-ci-v1.8.1-2026-11-10.json)。
- Windows真实运行中+68→本地+69，再运行中覆盖固定CI+69：每次新备份，安装器退出0且未允许强关；本地38／CI37份payload、PE1.8.1.69、原4事项／0媒体／1设置全字段保持，凭据实际DPAPI读回一致，CLI后重开。正式发布Setup摘要与已安装CI包一致。旧+66运行中失败的历史仍保留，未重记为成功。
- 双安卓在+68分别备份、卸载、全新安装并验证弹键盘／ASCII草稿冷重开，再恢复原数据／凭据、真实+60→+68与+66→+68。随后+69分别新备份并+68→+69，正式版2／0／1、QA47的55／9／1全字段及9份原声、安全条目保持；普通QA设置实际显示安全存储可读。最终正式身份再覆盖固定CI通用+69，数据保持并冷重开，APK摘要与公开包一致。+69不冒记重新全新安装。[+68独立验收](Layout_And_Android_Reinstall_68_2026-11-10.md)。
- Pixel普通QA+69截图实际观察到错过提醒与事项卡片、底部输入区左右对齐；个人页面截图仅私有保留，不发布。Windows GUI受已有computer-use URI错误限制，未冒记可视化验收；其他平台共享源码及主题布局测试与真实设备结果分开。Linux为Ubuntu24.04隔离启动范围，本机22.04桌面未移记通过。
- [发布工作流](https://github.com/yarnway/dontforget/actions/runs/42817710183)成功，准备ZIP摘要／CRC、APK／AAB固定证书、五包及三平台报告核验；发布后标签／专用正文／16附件完整集合、大小与摘要、latest和旧v1.8.0保留独立读回。[发行证据](benchmarks/github-release-v1.8.1-2026-11-10.json)。个人凭据未随源码或包分发。

## 包

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| DontForget_Android_v1.8.1.aab | 73170355 | `7926ea73725d7b2f6d4b21d3a481a90dca52e81a07e451b3f8d074d3257dacde` |
| DontForget_Android_v1.8.1.apk | 76309244 | `33e36291c288f84f2e1c753f04ec587f0f3587279fea9cb793a52602fb34f397` |
| DontForget_Linux_x64_v1.8.1.tar.gz | 14390966 | `78d9e09eaaba11fdcbb6ac6ec51c29617bfb0bba745c9c465a4cf9fef5087c83` |
| DontForget_Setup_v1.8.1.exe | 14659513 | `2871e0b49ce73757a89347c082b9f177aee3754c9dd3e811b0288a67a503a653` |
| DontForget_Windows_Portable_v1.8.1.zip | 17882003 | `e52d7bc25c10c9170527b4d70e8fbe1f13897c10a907bcc3858f02c5eef1e974` |

Android为通用APK和AAB，独立ARM64正式附件另续；QA包为独立debug身份，其体积不代表发行包占用。Windows尚无Authenticode签名。

## 剩余阶段

46 USB长期／跨主机；47其他机型、真实IME组合与发送、通知休眠重启／录音中断及Windows原生GUI／托盘／Toast；48带附件跨设备、凭据故障／磁盘满／断电、保留管理及原声压缩；49图片文件分享、LAN编辑／删除／附件／冲突与学习排程；50 Apple设备／签名公证、独立ARM64正式附件、Windows Authenticode及商店。
