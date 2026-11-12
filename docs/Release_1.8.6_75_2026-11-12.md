# v1.8.6／build75：先查看，再修改

[v1.8.6](https://github.com/yarnway/dontforget/releases/tag/v1.8.6)已发布并设latest，源码`e44e124c817e2f801ee2d35e56e759648d558292`／schema17，无新依赖。Android ARM64 APK／通用APK／AAB、Windows安装版／便携版、Linux x64，共六包、17附件；旧v1.8.5保持。[发行读回](benchmarks/github-release-v1.8.6-2026-11-12.json)。

## 行为与自动化

点击事项默认只读：标题、说明、词卡、关联和附件均可浏览；点击“修改”才进入编辑器。列表更多菜单的“修改事项”直接编辑最新保存内容，保存后回到原页面。未改内容保存不写库或重排通知；正文修改保留未保存提示、中文组合态及并发保护。按年重复、历史情境值与安全边距一并补齐，三语明暗主题／大字号宽度对齐。编辑器内附件、关联仍各自即时保存，返回提示只针对表单，不能用放弃表单撤销这些操作。

本版同时纳入学习计划批量改期：多计划预览、提前或顺延1～365天、1／7天快捷操作；共享已学词要求选齐相关计划，整次事务校验和回滚，保留掌握度、复习记录及附件。已完成／归档／回收站不改，重复批次暂不支持。[范围](Study_Date_Adjustment_2026-11-12.md)。

本机Windows SDK3.47.2最终相关178项通过、只读专项26项通过（重叠不相加）、分析0；覆盖旧代次、点击至首帧的恢复竞态、最新值、菜单直达、编辑重试和媒体等。固定Flutter3.44.9 [CI](https://github.com/yarnway/dontforget/actions/runs/43227252796)七项成功：Analyze and test：Flutter2474通过／2跳过，Python170运行／4跳过；Windows analyze and test：Flutter2456通过／20跳过，Python170运行／6跳过。Windows／Linux原生启动与Windows隔离安装流程通过；Apple仅CI候选。[源码证据](benchmarks/readonly-detail-source-75-2026-11-12.json)、[CI证据](benchmarks/github-ci-readonly-detail-75-2026-11-12.json)。历史测试断言、等待和编译失败保留，未当作成功。

## 设备与升级

- Pixel独立合成身份、源码同最终提交，本机SDK3.47.2：卡片打开只读，无键盘／表单；更多菜单直接修改最新内容；读原文／附件／关联不写库，修改草稿保存前不写库，保存只变预期字段，未改保存和放弃均无额外写入；学习计划两组／三批次取消、顺延7天再提前1天及概览4→1→2通过，三条未选对照、共享词掌握度及新PID重开保持。临时身份已卸载，原输入法设置还原。文字用ADB硬件注入，通知用记录替身，不记软件IME或系统送达通过。最终固定发行ARM64 APK额外触控验收因现有事项均在回收站而暂缓；未为测试新增或恢复用户事项。初始脚本卡片查找与分类标签假设失败保留；随后全SQL／媒体／凭据比对保持，恢复并核对最终CI APK。[正式APK范围](benchmarks/public-apk-readonly-75-2026-11-12.json)。[实机证据](benchmarks/readonly-and-study-native-75-2026-11-12.json)。
- Windows先完成首轮未发布源码6ee06f2的运行中74→75；补齐菜单和竞态后，重新备份最新数据，核对旧payload来源，再运行中75→最终75覆盖。最终37文件与发行包一致，5事项／0媒体／1设置、DPAPI实际值及普通重开保持；正常关闭，无强关。首轮和同构建号最终替换分别留证。[升级证据](benchmarks/windows-local-upgrade-75-2026-11-12.json)。最终重试computer-use仍在窗口发现前报工作目录URI错误；未采用GUI替代通道，Windows GUI仍未验。
- 正式Android分别新备份后，公开固定签名ARM64+74→最终CI+75，两APK直接双向互换和冷重开，2／0／1事项／媒体／设置及0安全条目保持，最终普通ARM64字节与发行附件相同。QA独立+74→本机debug+75，55／9／1及9原声、安全条目1实际值保持，最终普通入口冷重开。+75均未卸载新装，旧+68新装结果独立归属。[双Android升级](benchmarks/android-upgrade-75-2026-11-12.json)。

## 发行核对

通用APK76686320字节、ARM64 APK26491592字节（减少65.45%）；两APK身份、最低SDK24、固定证书及ELF插件集核对，AAB保留三ABI。Pixel同版系统应用大小通用78.06 MB→ARM64 27.82 MB，未清用户数据或缓存。

[发布工作流](https://github.com/yarnway/dontforget/actions/runs/43236141271)成功，三份来源ZIP完整SHA／CRC和15来源文件核对；17公开附件大小／摘要交叉核对，另下载发布provenance、总摘要与回执ZIP并复验证书。大包字节复用已完整核对的来源ZIP，未二次下载全部公开大包或release-ready包装ZIP。标签、正文、latest及旧版资产独立读回。首次回执ZIP下载的TLS请求失败，保留记录后仅重试只读核验，未重复发布或放宽摘要门禁。[重试记录](benchmarks/release-readback-retry-75-2026-11-12.json)。

## 剩余阶段

46 USB长期／休眠／跨主机；47 微信输入法空白根因、固定发行包／其他机型IME、系统通知及录音中断、Windows GUI／托盘／Toast／麦克风；48 带附件系统选择器／GUI恢复、真实凭据／磁盘满／断电故障、保留／显示名／原声压缩；49 普通发行包新功能完整触控矩阵、动态预测、档案、更多排程、图片分享／LAN冲突；50 Apple设备／签名公证、Windows Authenticode及商店。
