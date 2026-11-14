# v1.8.10／build79：备份导入与导出记录

[v1.8.10](https://github.com/yarnway/dontforget/releases/tag/v1.8.10)已发布并设latest，源码`e47495cd3c5ab5413ab0fa9f462c25c1e88d9ffa`、lib树`5001db8137b60bb4660617f1d7cb65348cb9fae4`／schema17；无依赖或schema变化。三端六包／17附件，旧v1.8.9保留。[发行读回](benchmarks/github-release-v1.8.10-2026-11-15.json)。

## 源码与测试

完整备份自动预检、原文件名、附件恢复提示与最近20次导出记录纳入本版。恢复保留明确核对和勾选；保存位置按需查看，不自动删除备份文件。

运行时lib与9f07c05相同，原源码的本机SDK3.47.2相关55项／分析0及独立Pixel SAF普通／加密导出、历史只读／取消保全和新PID验收保留原归属，见[历史记录](Backup_Export_History_2026-11-14.md)。预检／实际恢复的原源码范围见[自动预检](Backup_Auto_Preview_2026-11-14.md)。未重复合成身份矩阵；本轮实际安装的是下述最终版本普通包。

最终固定Flutter3.44.9 [CI](https://github.com/yarnway/dontforget/actions/runs/43621656985)七项成功：Windows analyze and test：Flutter2570通过／20跳过，Python170运行／6跳过；Analyze and test：Flutter2588通过／2跳过，Python170运行／4跳过。Windows隔离安装／升级／卸载、Windows／Linux原生启动通过；Apple仅候选构建。[CI证据](benchmarks/github-ci-release-79-2026-11-15.json)。初始19bab61候选补入专属发行说明后由最终提交替代，初始辅助包未安装，未作为最终发行来源。

## 普通应用升级

Windows核对公开+78全部payload，并保全最新数据与可解密凭据后，运行中78→79正常关闭覆盖，未强关。37文件与CI字节一致，5事项／0媒体／1设置全字段、DPAPI实际值与普通重开保持。computer-use在窗口发现前仍报工作目录URI错误，未执行GUI操作或使用UIA替代。[本机证据](benchmarks/windows-local-upgrade-79-2026-11-15.json)。

双Android先分别保全最新数据与已安装+78原APK。正式ARM64 78→固定CI79，通用／ARM64双向互换及普通入口，2／0／1、0安全条目保持；QA本机debug78→79，56／9／1、原声及1安全条目实际值保持。两者均真实SQLite全字段、原件摘要及冷重开核对，最终正式安装字节等于CI ARM64；QA另只读进入实际备份页并读回数据，再恢复普通入口。新辅助包构建于最终源码；历史保护指针不覆盖。本轮未卸载新装、不删除或重编码原声。首轮临时入口安装后显露本应用系统信息页，前台守卫停止；确认页面后从第13步续验，无产品源码修改，失败日志保留。[设备证据](benchmarks/android-upgrade-79-2026-11-15.json)。

## 发行文件

Android固定签名ARM64 APK／通用APK／三ABI AAB、Windows Setup／Portable、Linux x64共六包。通用APK76768744字节，ARM64 APK26492096字节，缩小65.49%；Pixel同版应用大小78.23 MB→27.90 MB，未清用户数据或缓存。

[发布工作流](https://github.com/yarnway/dontforget/actions/runs/43624905895)成功。三份来源ZIP完整SHA／CRC、15来源文件与17公开附件摘要核对；provenance、总摘要和发布回执另下载，证书／正文／标签／latest与旧版资产再次读回。大包复用已完整核对的来源ZIP，未重新下载全部公开大包或release-ready包装ZIP。Windows未做Authenticode签名，Linux基线Ubuntu24.04。

## 剩余阶段

46 USB自然空闲／长期／休眠／换线及跨主机；47 真人语音／中英时延、固定包／其他机型IME、系统通知／录音中断／TalkBack与Windows GUI／托盘／Toast／麦克风；48 桌面选择器、手机容量、真实故障／凭据锁定、外部文件权限／人工引用／保留策略与原声压缩；49 受保护词条重置／迁移、个性化预测、图片分享与LAN冲突；50 Apple设备／签名公证、Windows Authenticode和商店。
