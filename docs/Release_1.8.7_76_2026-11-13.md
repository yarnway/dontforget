# v1.8.7／build76：语音预览与词条档案

[v1.8.7](https://github.com/yarnway/dontforget/releases/tag/v1.8.7)已发布并设latest，源码`1d37ace4030933535c117a73b59883bdb51a6d8c`／schema17，无新依赖。Android ARM64 APK／通用APK／AAB、Windows安装版／便携版、Linux x64共六包、17附件；旧v1.8.6保持。[发行读回](benchmarks/github-release-v1.8.7-2026-11-13.json)。

## 交互与自动化

语音预览明确编辑／发送状态；边界附近小幅移动保持选择，返回编辑区解除发送。短句从卡片顶部展示，长转写显示最新内容；小屏、横屏和大字号保留预览空间。手机编辑面板贴近键盘、固定操作，桌面居中；保留同一编辑控件、手动修改与中文组合态，隐藏背景重复输入和预览。实时与录后识别分开提示，本版未更改服务或上传时机。[交互范围](Mobile_Voice_UX_76_2026-11-13.md)。

纳入只读词条档案：从学习计划或学习管理检索词条、释义、例句并查看已有记录；彻底删除来源仍保留旧词进度，失败整体回滚。共用七天已排词量卡片，保留历史身份。[档案范围](Word_Archive_2026-11-12.md)。

本机Windows SDK3.47.2语音相关100项通过、分析0；先前档案相关103项独立记录，两批不相加。固定Flutter3.44.9 [CI](https://github.com/yarnway/dontforget/actions/runs/43269845320)七项成功：Analyze and test：Flutter2508通过／2跳过，Python170运行／4跳过；Windows analyze and test：Flutter2490通过／20跳过，Python170运行／6跳过。Windows／Linux原生启动与Windows隔离安装通过；Apple仅构建候选。[CI证据](benchmarks/github-ci-voice-76-2026-11-13.json)。

## 真实设备与升级

- Pixel独立合成语音身份实际长按、上滑、编辑／发送边界往返、左右释放，合成最终结果前不发送、返回后仅一次模拟发送，取消无新增发送。硬件注入Z76在最终结果返回后保留，保留草稿与新PID重开通过；1事项／1原件保持。明暗主题截图复核，临时身份卸载、输入法设置保持。本轮未录音或连接云服务；软件键盘未在该夹具显示，组合态及键盘尺寸由本机自动化验证，不能替代实际IME。UIAutomator未读出长按遮罩标签，原生无障碍继续待验。[独立设备证据](benchmarks/mobile-voice-ux-native-76-2026-11-13.json)。
- Windows重新备份最新数据、核对旧v1.8.6发行payload后，普通应用运行中75→76正常覆盖，未强关。37个安装文件一致，5事项／0媒体／1设置、DPAPI实际值与普通重开保持。computer-use本轮仍在窗口发现前报工作目录URI错误，GUI未记通过。[升级证据](benchmarks/windows-local-upgrade-76-2026-11-13.json)。
- 正式Android与QA分别新备份：正式公开ARM64+75→CI+76，通用／ARM64双向互换、冷重开，2／0／1及0安全条目保持；QA本机debug75→76，56／9／1、9原声及1安全条目实际值保持。最终均普通入口，正式安装字节与CI ARM64相同；本轮未卸载新装，不挪用旧新装结果。[双Android证据](benchmarks/android-upgrade-76-2026-11-13.json)。

## 发行文件

通用APK76719440字节、ARM64 APK26491944字节，缩小65.47%；最低SDK24、身份、固定证书、插件集与三ABI AAB核对。Pixel同版应用大小通用78.12 MB→ARM64 27.84 MB，未清用户数据或缓存。

[发布工作流](https://github.com/yarnway/dontforget/actions/runs/43276010662)成功。三份来源ZIP完整SHA／CRC、15来源文件及17公开附件摘要核对；发布provenance、总摘要与回执ZIP另下载并验签，标签、正文、latest和旧版资产读回。大包复用完整验证的来源ZIP，未二次下载全部公开大包或release-ready包装ZIP。Windows未做Authenticode签名，Linux运行基线Ubuntu24.04。

## 剩余阶段

46 USB长期、休眠与跨主机；47 固定发行包／其他机型IME、微信输入法空白根因、真实中英文录音与云端延迟、录音中断和系统通知、长按预览无障碍、Windows GUI／托盘／Toast／麦克风；48 带附件系统选择器／GUI恢复、真实凭据／磁盘满／断电故障、备份保留／显示名／原声压缩；49 档案清除及身份迁移、动态预测、更多排程、图片分享／LAN冲突、普通发行包新功能完整触控；50 Apple设备／签名公证、Windows Authenticode与商店。
