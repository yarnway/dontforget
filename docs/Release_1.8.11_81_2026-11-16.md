# v1.8.11／build81：关于与更新、外部备份引用及四平台发行

[v1.8.11](https://github.com/yarnway/dontforget/releases/tag/v1.8.11)已发布并设为latest。最终源码`ae11fd6327fffb47793e4ed8a772c58352744475`、build81、schema17，Windows／Linux／Android／iOS七份安装包及20个附件已独立核对。此前build80未发布，其验收保留[原归属](Release_1.8.11_80_2026-11-16.md)。

## 源码与自动化

设置新增“关于与更新”：系统实际应用名、版本／构建、复制信息、项目主页、第三方许可，以及手动稳定版检查、平台下载和异常重试。匿名API受限时核对本项目公开来源文件；独立网络客户端不读取模型凭据或业务数据。[实现及本机65项专项](About_Updates_2026-11-16.md)。

外部备份引用登记沿用[原实现与Pixel功能证据](External_Backup_References_2026-11-15.md)。最终源码相对72a7080的lib仅变更About服务、页面、三语文案及设置入口四文件，原登记核心字节保持；不把旧完整lib树或旧Android安装验收换记成build81通过。

[固定CI43807577968](https://github.com/yarnway/dontforget/actions/runs/43807577968)七项成功：Linux Flutter2629通过／2跳过，Python180运行／4跳过；Windows Flutter2611通过／20跳过，Python180运行／6跳过。Windows隔离安装／启动、Linux启动／清理通过；macOS仅构建，不在本次公开发行包中。[CI回执](benchmarks/github-ci-release-81-2026-11-16.json)。隔离Flutter3.44.9／Dart3.12.2验证，原SDK保持。

## 安装包与真实设备

- 包：四份来源ZIP全摘要与CRC；Android两个APK及AAB的固定证书、ABI、实际版本；Windows／Linux元数据及报告；iOS主／扩展身份、版本和未签名／无描述文件均核对。[发布前原始回执](benchmarks/release-81-prepublication-2026-11-16.json)保留当时未安装／未发布状态，最终结果以本页和发行回执为准。
- Windows：先最新保全，在build80实际运行时正常覆盖到81，安装器退出0、不强关。38payload、5事项／0媒体／1设置全字段、实际DPAPI凭据值及普通重开保持。安装后系统资源实际版本1.8.11／81；[本机回执](benchmarks/windows-local-upgrade-81-2026-11-16.json)。computer-use URI故障仍保留，不把CLI／进程和资源读取记为关于页GUI已操作。
- iPhone15ProMax：独立身份`acceptance.iphone15-20261115`的[同源构建43811574464](https://github.com/yarnway/dontforget/actions/runs/43811574464)带`+81`文件名。先取build80最新Documents／Library/Preferences快照并派生一致SQLite备份，基线为3事项／1媒体／1设置，非此前2事项快照。用户AltStore个人重签覆盖后，USB独立核对81版本与相同签名身份，三表全部字段、原音频／材料标记与偏好文件字节保持，schema17／integrity ok。用户报告显示1.8.11（81）、检查更新有结果、原记录仍在；具体更新状态文字未独立采集，不冒记为某一状态。[手机回执](benchmarks/ios-upgrade-build81-2026-11-16.json)。不含Keychain或整个Library，不称完整设备备份或自动触屏。
- Android：Pixel暂不可接入，+81正式／QA的最新设备备份、实际覆盖升级及新About真机操作未执行。CI签名／ABI／包和历史功能证据分别归属，未操作原安装或恢复指针，后续接入前重新保全。
- Linux：固定CI原生启动与归档核对，实际version.json为81；本机桌面About GUI未操作。

公开IPA为普通应用身份的未签名包；手机验收使用独立身份同源包，两者分别核对，不冒称已将公开普通身份包安装到手机。免费账号AltStore通常7天续期，非App Store或TestFlight分发；用户当前验收应用与数据继续保留。

## 发布与公开更新验证

[发布工作流43818704828](https://github.com/yarnway/dontforget/actions/runs/43818704828)prepare／publish均成功，标签精确指向ae11fd6。独立核对正文、20附件集合／大小／摘要、latest与公开来源／汇总摘要；旧v1.8.10正文及17附件ID／摘要保持。[发行回执](benchmarks/github-release-v1.8.11-2026-11-16.json)。大附件使用GitHub摘要结合已完整校验的来源ZIP核对，未二次下载所有公开大文件。

首次本地读回严格拒绝两份文本摘要差异：本机Windows生成CRLF并按不区分大小写的文件路径排序，云端Linux使用LF与区分大小写的排序。保留失败及原始准备目录，另建读回期望目录，确认18个来源文件逐字节一致、来源JSON仅换行及文件列表排序差异／按文件名映射的内容完全一致，并用实际LF来源JSON并按Linux文件名排序重新计算全部19项摘要后核对公开SHA256SUMS；未改发布附件或放宽业务包摘要。

发布后使用应用实际无认证更新服务联网复查，识别公开1.8.11／81为`current`、六个下载选择并含iOS。首次网络错误保留，后续成功；该桌面服务探针不冒记手机再次点击或桌面GUI已验。

## 剩余阶段

- 46：USB自然空闲、省电、休眠／唤醒与跨主机对照。
- 47：Android+81正式／QA最新保全升级及About真机；Windows GUI／Toast／托盘／实际麦克风；iPhone通知热冷点击、动作、录音、附件、灵动岛、输入法和无障碍矩阵。
- 48：手机容量与桌面选择器、真实故障／凭据锁定、外部文件权限／保留策略／目录接管／空间统计与原声压缩。
- 49：受保护词条重置迁移、个性化预测、图片分享与LAN编辑／删除／附件冲突。
- 50：免费签名续期、下一版各端最新保全升级、macOS真机／公证、Windows Authenticode与商店。

详见[阶段台账](Next_Steps_2026-11-02.md)。本版发布完成，不代表上述原生矩阵全部完成。
