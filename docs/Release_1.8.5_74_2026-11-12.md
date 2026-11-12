# v1.8.5／build74：多计划管理与三端发行

[v1.8.5](https://github.com/yarnway/dontforget/releases/tag/v1.8.5)已发布并设latest，源码`26c90e0e56636f925f6394ca569713367db00c87`／schema17。Android ARM64 APK、通用APK、AAB，Windows Setup／Portable及Linux x64，共六包、17附件。旧v1.8.4标签和附件保持。[发行读回](benchmarks/github-release-v1.8.5-2026-11-12.json)。

## 源码与自动化

学习计划支持多选、已选数量及一次暂停／继续，完成或取消后清除选择；底部操作栏适配窄屏、大字号及中英日文，圆角卡片裁剪交互背景。最多选择20计划／50批次；回收站仍逐计划确认。选择时冻结完整快照，在同一SQLite事务校验全部计划（含无操作组）；成员新增、编辑、删除、移组均拒绝整次陈旧操作，写入失败整体回滚。继续保留既定复习日期、词条进度、附件与完成／归档批次；通知失败提供修复入口。无新依赖或数据库迁移。

本机Windows SDK3.47.2相关102项通过、分析0，覆盖第二计划失败回滚、无操作组变化、过期周期日期、普通事项／存储及三语布局。[源码证据](benchmarks/cross-plan-source-2026-11-12.json)。初始测试夹具及等待错误日志保留；最终结果独立记录。

最终[固定SDK CI](https://github.com/yarnway/dontforget/actions/runs/43139314852)七项成功，Flutter3.44.9：Analyze and test：Flutter2418通过／2跳过，Python170运行／4跳过；Windows analyze and test：Flutter2400通过／20跳过，Python170运行／6跳过。[CI证据](benchmarks/github-ci-cross-plan-2026-11-12.json)。首次Android任务下载到非ZIP的NDK文件，保留失败日志摘要后只重试失败任务，源码和门禁未改。[重试记录](benchmarks/android-build-retry-74-2026-11-12.json)。Windows／Linux原生启动报告通过，Windows另有隔离安装／升级／卸载；Apple仅CI候选。

## 真实设备与安装包

- Pixel独立临时身份以4条合成数据，实际选择两计划／三批次后暂停、重新选择并继续；未选计划全字段保持，所选日期／进度保持，新PID冷重开SQLite读回一致。使用本机SDK3.47.2、源码同本轮提交，通知为记录替身，未据此认定系统送达。验收脚本首轮误从data读取顶层paused导致断言失败，保留现场后修正脚本重验；临时身份已卸载，正式／QA数据未清除。[实机记录](benchmarks/cross-plan-native-2026-11-12.json)。
- Windows最终CI包：最新数据独立备份，普通1.8.4.73运行中正常关闭覆盖至1.8.5.74，禁止强关；37个payload一致，5提醒／0媒体／1设置全字段、凭据文件及DPAPI实际值保持，CLI与普通重开后再次读回一致。[本机升级](benchmarks/windows-local-upgrade-74-2026-11-12.json)。GUI、Toast、真实麦克风仍待验，先前computer-use初始化URI阻塞未解除。
- 正式Android独立最新备份，固定签名CI ARM64+73→+74，2／0／1提醒／媒体／设置保持、安全条目0；普通冷重开、+74通用／ARM64直接双向覆盖后再次核对，最终普通ARM64安装摘要与公开附件相同。
- QA独立备份+73→本机SDKdebug+74，55／9／1提醒／媒体／设置、9原声摘要及1安全条目值保持，普通冷重开完成；QA不是固定发行签名包。+74均未卸载新装，历史+68新装记录另属。[双Android升级](benchmarks/android-upgrade-74-2026-11-12.json)。

## 发布与包体

通用APK76505852字节、ARM64 APK26425812字节（减少65.46%），两APK版本／最低SDK及固定证书一致，真实ELF与插件库核对，AAB保留三ABI。下载包大小与系统占用分开记录。Pixel同版系统应用大小：通用77.90 MB→ARM64 27.76 MB，用户数据与缓存未清除。

[发布工作流](https://github.com/yarnway/dontforget/actions/runs/43163453867)成功。三份来源ZIP完整SHA／CRC核对，15来源文件与17公开附件大小／摘要交叉核对；另下载发布provenance、总摘要与回执ZIP，重验两APK／AAB证书。大包字节复用已完整核对的来源ZIP，未重复下载全部公开大包或release-ready包装ZIP。标签、正文、latest及旧版标签／附件保持独立读回。

## 剩余阶段

46 USB长期／跨主机；47真实IME、休眠／重启通知、录音中断及Windows GUI／托盘／Toast／麦克风；48系统选择器／桌面GUI带附件恢复、凭据故障／磁盘满／断电、保留／显示名／原声压缩；49批量改期、动态反馈预测、档案、更多练习排程、图片分享及LAN编辑／删除／附件冲突；50 Apple设备／签名公证、Windows Authenticode及商店。
