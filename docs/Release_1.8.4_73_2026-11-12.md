# v1.8.4／build73：学习排期与三端发行

[v1.8.4](https://github.com/yarnway/dontforget/releases/tag/v1.8.4)已发布并设latest，源码`c9bff3be1dcf21ee800f1a4c513b3f9fc8877abb`／schema17；Android ARM64 APK、通用APK、AAB，Windows Setup／Portable及Linux x64，共六包、17附件。旧v1.8.3标签和附件保持。[发行读回](benchmarks/github-release-v1.8.4-2026-11-12.json)。

## 源码与自动化

学习计划页默认收起未来7天已排词量，显示新词、复习词、每日上限及超量日期。跨计划去重并使用最新历史，今日扣除已学习词量；暂停／继续刷新。概览只读，不改排期／进度／通知，不模拟未来反馈。无新依赖或数据库迁移。

前一源码47f8930的CI43013016535 Linux质量成功，Windows两项旧测试短等待失败，构建跳过；本轮改为有界等待提交与路由关闭，增加偏好重新读取和AI结果SQLite读回，清理测试通知定时器。修正期间本机还发现直接在runAsync等待假时钟写队列会阻塞，已改为同时推进真实I/O与组件时钟；仅停止该次自有测试进程树，未结束用户App。失败及最终本机相关78通过／分析0见[修复证据](benchmarks/workload-native-and-ci-repair-2026-11-12.json)。

最终源码首次Linux构建因Ubuntu源DNS解析失败而依赖安装12分钟超时；保留日志摘要后仅重试失败任务，未修改源码、未放宽门禁。[重试记录](benchmarks/linux-ci-retry-2026-11-12.json)。

最终源码[固定SDK CI](https://github.com/yarnway/dontforget/actions/runs/43055806919)七项成功：Linux：Flutter2411通过／2跳过，Python170运行／4跳过；Windows：Flutter2393通过／20跳过，Python170运行／6跳过。[CI证据](benchmarks/github-ci-workload-2026-11-12.json)。CI固定Flutter3.44.9；本机3.47.2结果独立记录。Windows／Linux原生启动通过，Windows另有隔离安装／同包升级／卸载；Apple仅CI候选，设备和签名另验。

## 原生验收

- Pixel临时独立身份以3条合成词条实际展开、暂停／继续，已排词量3→1→3；展开前后提醒全字段不变，日期和对照计划保持，强停后新PID冷重开读回一致。临时身份已卸载，用户正式／QA未因此重装或清除。该夹具版本为1.8.3+72／源码47f8930，本轮+73应用lib树同为`959c0c3bb9e6cc3853a2cf2f04cc1fcda02b82f3`，不能将夹具安装记作普通+73包；普通包升级另列。通知为记录替身，不记系统送达。
- Windows最终CI包：当时最新数据独立备份，旧1.8.3.72普通App实际运行，安装器正常关闭后覆盖为1.8.4.73，禁止强关。37文件与便携包相同，4提醒／0媒体／1设置全字段、凭据文件和DPAPI实际值保持，CLI及普通App重开再次读回一致。[本机记录](benchmarks/windows-local-upgrade-73-2026-11-12.json)。GUI／Toast／真实麦克风未补验，更新后的computer-use仍在窗口发现前报工作目录URI错误。
- 正式Android最新备份后，以公开CI ARM64+72为起点升级最终CI ARM64+73；普通冷重开及私有同签名读回2／0／1保持、安全存储为空映射。+73公开通用／ARM64直接双向覆盖后再次核对保持，最终普通ARM64安装字节与公开附件摘要一致。
- QA单独最新备份+72→最终源码+73，本机SDK独立debug身份，55／9／1、9原声摘要及1安全条目值保持，普通冷重开通过。不是固定发行签名包。+73均未卸载新装，不移用历史+68新装结果。[双Android记录](benchmarks/android-upgrade-73-2026-11-12.json)。

## 包与发布

通用APK76489468字节、ARM64 APK26425812字节（减少65.45%）；两APK固定证书、版本／最低SDK、真实ELF及插件集均核对，AAB实际保留三ABI。此处为下载文件大小，不等于系统完整安装占用。

[发布工作流](https://github.com/yarnway/dontforget/actions/runs/43065249164)成功。三份来源ZIP完整SHA／CRC核对，15个来源文件与17项发布附件大小／摘要及回执交叉核对；另下载发布器生成的provenance、总摘要和回执ZIP，两APK／AAB再次验签。未重复下载公开大包或release-ready包装ZIP。标签、正文、latest及旧版标签／附件保持均独立读回。

## 剩余

46 USB长期／跨主机；47真实IME、休眠／重启通知、录音中断及Windows GUI／托盘／Toast／麦克风；48系统选择器和桌面GUI带附件恢复、凭据故障／磁盘满／断电、保留／显示名／原声压缩；49动态反馈预测、跨计划调整、档案、更多练习排程、图片分享及LAN编辑／删除／附件冲突；50 Apple设备／签名公证、Windows Authenticode及商店。
