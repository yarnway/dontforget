# v1.8.9／build78：备份导出与学习预测

[v1.8.9](https://github.com/yarnway/dontforget/releases/tag/v1.8.9)已发布并设latest，源码`0e14c783cb5370a2154c51a97b8f9e1e43014243`、lib树`ecd624edf439ce06c60c6fa80ef63d60f35a1c23`／schema17，无新依赖。Android ARM64 APK／通用APK／AAB、Windows安装版／便携版、Linux x64共六包、17附件，旧v1.8.8标签与资产保持。[发行读回](benchmarks/github-release-v1.8.9-2026-11-14.json)。

## 源码与自动化

备份可选名称／自动命名，跨平台名称和组合态先校验；最近导出简洁展示、完整位置按需查看，旧记录兼容。文件已导出而记录写入失败时单独提示，保留文件与旧记录、不重复导出；卡片等宽、裁剪与间距统一。[行为边界](Backup_Export_78_2026-11-13.md)。

七天学习概览保留已排期视图与默认收起，增加按认识／模糊／不认识估算的预计安排，显示后续复习与待排；遵循每日／新词额度和自定义间隔，仅内存模拟。[预测边界](Learning_Forecast_2026-11-13.md)。

本机Windows原生Flutter3.47.2相关11文件127项通过，分析0；逐日真实SQLite预测对照、备份文件写入／加密恢复、组合态、元数据失败与三语／明暗／大字布局分别覆盖。固定Flutter3.44.9 [CI](https://github.com/yarnway/dontforget/actions/runs/43452984590)七项成功：Windows analyze and test：Flutter2553通过／20跳过，Python170运行／6跳过；Analyze and test：Flutter2571通过／2跳过，Python170运行／4跳过。Windows／Linux原生启动及Windows隔离安装通过，Apple仅构建候选。[CI证据](benchmarks/github-ci-backup-78-2026-11-14.json)。

## 私有合成设备验收

- Pixel备份身份6事项／1原件／1设置，实际页面触控、真实SQLite、实际流式备份及文件inspect；名称注入后由原生按钮触发导出。无效名称不导出；正常导出记录逻辑名称；取消保留旧记录及既有文件；SQL触发器拒绝写入时第二份文件仍可读、旧记录保持且无重复复制，缓存释放。明暗与新PID重开读回完成，临时身份卸载、输入法设置保持。仅强制应用自有目录分支，未调用SAF／FileSaver；文本为合成控制器注入，不记真实IME触控或本轮手机加密导出通过。[设备证据](benchmarks/backup-export-native-78-2026-11-13.json)。
- Pixel预测身份6／1／1：三种反馈各七天新词／复习／待排读回、统计右对齐、明暗／收起、切回已排期及新PID重开通过；业务全字段、原件、设置与通知意图保持，身份卸载。[设备证据](benchmarks/learning-forecast-native-78-2026-11-13.json)。
- 当前源码Windows独立合成SQLite／1 MiB原件：普通／加密分别真实NTFS错误5，缓存和共用目录导出失败不改变业务、原件、源备份或既有导出；恢复SDDL后重试字节／inspect一致，临时目录清理。显式1项通过；不是原生保存对话框、真实磁盘满或真实凭据故障。[范围](benchmarks/windows-backup-acl-78-2026-11-13.json)。

## 普通应用升级

Windows核对已安装公开+77的全部payload并重新备份最新数据，运行中77→78正常关闭覆盖、未强关，37个payload与CI字节一致。5事项／0媒体／1设置全字段、DPAPI实际值与普通重开保持。computer-use窗口发现前仍因工作目录URI报错，GUI未记通过。[升级证据](benchmarks/windows-local-upgrade-78-2026-11-14.json)。

双Android分别保全最新数据与实际原安装包后，正式公开ARM64+77→固定CI+78、通用／ARM64双向互换与冷重开，2／0／1及0安全条目保持；QA本机debug77→78，56／9／1、9原声与1安全条目实际值保持。两者最终普通入口，正式安装字节等于CI ARM64。QA普通包另从设置进入实际备份页，名称输入／导入导出入口及默认加密可读；未编辑或操作导出，返回后业务全字段、原声及实际凭据读回保持。本轮未卸载新装，历史新装验收保留原版本归属。[升级证据](benchmarks/android-upgrade-78-2026-11-14.json)。

## 发行文件

通用APK76768696字节、ARM64 APK26492048字节，缩小65.49%；身份／版本／最低SDK24、固定证书与两APK插件集及三ABI AAB核对。Pixel同版应用大小通用78.22 MB→ARM64 27.89 MB，未清用户数据或缓存。

[发布工作流](https://github.com/yarnway/dontforget/actions/runs/43458984243)成功。三份来源ZIP完整SHA／CRC、15来源文件及17公开附件摘要核对，provenance／总摘要／回执ZIP另下载；两APK和AAB证书重新验证，正文／标签／latest和旧版读回。大包复用完整验证的来源ZIP，未二次下载所有公开大包或release-ready包装ZIP。Windows未做Authenticode签名，Linux运行基线Ubuntu24.04。

## 剩余阶段

46 USB长期、休眠与跨主机；47 固定发行包／其他机型IME、微信输入法空白根因、真人中英文识别与延迟、录音中断和系统通知、完整TalkBack与Windows GUI／托盘／Toast／麦克风；48 带附件系统选择器／GUI恢复、真实凭据／磁盘满／断电故障、备份保留／外部引用登记与原声压缩；49 受保护词条重置／身份迁移、个性化预测、更多排程、图片分享／LAN冲突与普通发行包新功能完整触控；50 Apple设备／签名公证、Windows Authenticode与商店。
