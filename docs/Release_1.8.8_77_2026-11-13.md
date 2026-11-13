# v1.8.8／build77：动态语音编辑与原声发送

[v1.8.8](https://github.com/yarnway/dontforget/releases/tag/v1.8.8)已发布并设latest，源码`ef6d6a0b03b52e9c52635664ac29f0c8695b2296`／schema17，无新依赖。Android ARM64 APK／通用APK／AAB、Windows Setup／Portable和Linux x64共六包、17附件，旧v1.8.7保持。[发行证据](benchmarks/github-release-v1.8.8-2026-11-13.json)。

## 功能和自动化

语音转写框随文字增减高度，长文框内滚动；底部“发送原语音／发送”，关闭保留草稿。显式发送当前文字无需等待最终识别；中文组合态不发送，Enter保持换行。原声使用同次录音，保留录音前已有草稿；保存失败可按同一媒体身份重试，识别读完文件后才清理缓存。迟到识别不覆盖编辑或重复发送。长按遮罩独立挂载，实际语义树保留状态／转写／选择并屏蔽背景；手势同帧反馈，松手／卸载／导航清理。[交互范围](Voice_Editor_77_2026-11-13.md)。

档案清理按词条预览并明确确认，单次最多200行，仅清理无引用的过往标准保留记录；保护当前事项词条／进度、今日额度、关联、附件与非标准引用。候选、快照、日期和恢复代次再次校验，失败整批回滚。[档案范围](Word_Archive_Cleanup_2026-11-13.md)。

本机SDK3.47.2最终相关228项通过、分析0，真实PCM WAV／SQLite验证原声字节、延迟识别、保存失败同身份重试、短音频和恢复拒绝。固定Flutter3.44.9 [CI](https://github.com/yarnway/dontforget/actions/runs/43380792503)七项成功：Analyze and test：Flutter2542通过／2跳过，Python170运行／4跳过；Windows analyze and test：Flutter2524通过／20跳过，Python170运行／6跳过。Windows／Linux原生启动与Windows隔离安装通过；Apple仅构建候选。

## 实机与升级

- Pixel最终源码独立合成语音身份完成长按原生节点／背景屏蔽、编辑／发送边界、手动修改、取消、新PID草稿，以及短／长文原生高度和下方双按钮；模拟原声发送一次且无文字提交。首轮批量硬件输入停在中文IME候选态，未形成长文，改用合成ASR结果验证增长，失败证据保留。1事项／1原件与输入法设置保持，身份卸载。本轮未使用真实麦克风／云端，不记软件IME触控、真人中英文延迟或完整TalkBack通过。[语音证据](benchmarks/voice-editor-native-77-2026-11-13.json)。
- 最终源码独立档案身份7事项／1原件／1设置，预览与取消保持全字段；确认只清理所列2行，非标准标记的当前批次、进度／今日额度、媒体／设置／原件保持，无额外原生意图，新PID一致，身份卸载。初始来源取消为通知记录替身。[档案证据](benchmarks/word-archive-cleanup-native-77-2026-11-13.json)。
- Windows核对旧v1.8.7公开payload并重新备份最新数据后，普通应用实际运行中76→77正常覆盖，未强关。37个文件、5事项／0媒体／1设置、DPAPI实际值与普通重开保持。computer-use仍在窗口发现前报工作目录URI错误，GUI未记通过。[证据](benchmarks/windows-local-upgrade-77-2026-11-13.json)。
- 双Android分别新备份：正式公开ARM64+76→CI+77及两APK双向互换、冷重开，2／0／1及0安全条目保持；QA独立debug76→77，56／9／1与1安全条目、已备份原声逐字节保持。最终普通入口，正式安装字节等于CI ARM64；首次ARM64启动检查遇ADB服务断连，保留失败并从该步骤续验完成；未因重试清数据或重装。本轮未卸载新装，不挪用旧结果。[证据](benchmarks/android-upgrade-77-2026-11-13.json)。

## 文件与剩余阶段

通用APK 76735928字节、ARM64 APK 26492048字节，缩小65.48%；Pixel同版应用大小通用78.15 MB→ARM64 27.86 MB，未清用户数据或缓存。最低SDK24、固定证书与三ABI AAB核对。

[发布工作流](https://github.com/yarnway/dontforget/actions/runs/43422030107)成功；三来源ZIP完整SHA／CRC、15来源文件和17公开附件摘要核对，发布provenance／checksums／回执ZIP下载验证，标签／正文／latest与旧版资产读回。大包复用完整验证的来源ZIP，未二次下载全部公开大包或release-ready包装ZIP。Windows未做Authenticode签名，Linux基线Ubuntu24.04。

46 USB长期、休眠与跨主机；47 固定包／其他机型IME、微信输入法空白根因、真人中英文录音／云端时延、录音中断与系统通知、完整TalkBack操作、Windows GUI／托盘／Toast／麦克风；48 带附件系统选择器／GUI恢复、真实凭据／磁盘满／断电故障、备份保留／显示名／原声压缩；49 受保护词条重置／身份迁移、动态预测、更多排程、图片分享／LAN冲突及普通发行包新功能完整触控；50 Apple设备／签名公证、Windows Authenticode与商店。
