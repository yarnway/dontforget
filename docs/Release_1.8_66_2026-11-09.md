# 1.8正式发行与分层验收（build66，2026-11-09）

[v1.8.0](https://github.com/yarnway/dontforget/releases/tag/v1.8.0)已正式发布并设latest，Android／Windows／Linux三端五包及清单／报告等16附件，build66／schema17、固定源码`b873b56468e0ea17713d891a45e255c7184f3869`。旧v1.7.2标签及16附件已保留并独立读回，Apple不在本轮正式发行范围。

## 交付

精简输入、设置及模型配置的冗余文字，设置响应式排列，Windows默认单行并随长内容展开，保留三语／大字／主题、中文组合态和草稿。普通录音持久保存后回收本次临时副本，内容管理提供可清理及所选空间、筛选和最多100项选择，引用及备份保护保持。

按真人反馈修正+65的迟滞：启用腾讯实时识别后，录音就绪即边录边识别，右滑前已准备文字；40ms发送帧、语音模式200ms确认长按，短点不开麦克风，文字编辑长按保留原时机。识别中间结果不再重建整页任务列表。上滑就显示预览，右侧目标按选择显示“松手编辑／松手发送”，标签高度预留以免滑动跳位；编辑或中文组合态不被后续识别覆盖，失败不自动发送中间文字。

公开包没有个人腾讯／DeepSeek凭据，未配置服务时保持关闭。启用实时识别后从录音起上传，保存原声或取消也不能撤回已发送部分；旧Flash配置兼容。成功转文字回收临时音频，PCM原声长期保存的进一步压缩仍待完成，不把缓存回收写成总存储缩小比例。

## 验证

- 本地SDK3.47.2：最终Flutter2351通过／20跳过、Python161运行／6跳过、分析0；相关106、工作区及交互收口专项见[本轮记录](Early_Live_66_2026-11-09.md)。首次全量2344通过／20跳过／5失败，旧触摸时机和直接回调夹具已改成真实指针事件再全量复验，失败证据保留。[最终门禁](benchmarks/early-live-66-local-gates-2026-11-09.json)。
- 固定SDK3.44.9的[CI42618037287](https://github.com/yarnway/dontforget/actions/runs/42618037287)两套质量和五平台构建7项成功，主线标签专用检查按条件跳过；Linux Flutter2369通过／2跳过、Windows2351通过／20跳过；Python各161运行（4／6跳过），五份artifact来源一致。[CI证据](benchmarks/github-ci-v1.8.0-2026-11-09.json)。
- [发布工作流42622025255](https://github.com/yarnway/dontforget/actions/runs/42622025255)prepare／publish成功；来源ZIP摘要／CRC、五包和三平台清单、APK／AAB固定证书、Windows隔离安装升级卸载及Windows／Linux启动报告已核对。发布后独立读回标签、专用正文、16附件完整集合／大小／摘要、latest及旧稳定版保留。[发行证据](benchmarks/github-release-v1.8.0-2026-11-09.json)。
- Windows／Pixel真实腾讯接口中英样本首段0.91–1.14秒，模拟第2秒选择转文字时都有预览；16k单声道PCM可读，合成音、静音或环境音不记真人准确性通过。私有探针退出、临时包及loopback已清理。Windows构建初次MSBuild失败保留，重试和普通入口构建通过。
- 用户在+66前一轮普通QA包反馈“速度已明显提升”，并继续要求优化易用性；只记速度改善，编辑／松手发送未获明确确认。随后预览及目标标签收口单独经自动化验证，当前普通QA包SHA与反馈包分别记录。[原生与反馈](benchmarks/early-live-66-2026-11-09.json)。最终普通QA47覆盖升级前后三表和草稿全字段一致，升级时55事项／9媒体／1设置，共享偏好与原媒体保持；它是独立QA身份，不移作正式发行Android身份的安装验收。
- 本机Windows普通App仍在运行，未终止、未覆盖安装；原生私有入口通过CLI方式测试，不接触业务数据库，GUI／IME／托盘／Toast不记通过。Linux只覆盖Ubuntu24.04隔离启动，不移记本机22.04桌面通过。Computer Use工作目录URI错误所限的Windows UI继续待验。

+65源码7d06281的CI42595423614虽成功，真人仍反馈慢，未发布；+64及更早结果保留各自版本归属。schema17和依赖锁保持。

## 包

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| DontForget_Android_v1.8.0.aab | 73168664 | `9c49d7399ebc617f89de514c7f5cb31a17289ea40ec8a081547157d0593bd22d` |
| DontForget_Android_v1.8.0.apk | 76309244 | `822942da7bf6636bfa1ffbca302e21de7c877fcaeecf4292edfd0dfccad3631f` |
| DontForget_Linux_x64_v1.8.0.tar.gz | 14390936 | `9c87cae04b78de9b6814c62125461793b863ae930e5f84f8c2d651b084e10578` |
| DontForget_Setup_v1.8.0.exe | 14659343 | `1f989175fca231a633766949df02a424f2f05353e3c868a9e32e406e625a73b1` |
| DontForget_Windows_Portable_v1.8.0.zip | 17878873 | `8fa82caad52bee215b3dd3a64e1337772867189de8938cb0c19afc317ad788a9` |

本轮Android为通用APK和AAB，没有独立ARM64正式附件；+63体积比较不移记为本版缩小比例。Windows未做Authenticode签名。

## 剩余阶段

- 46：USB长期／跨主机观察。
- 47：最终交互真人编辑／发送、其他机型及输入法、通知延后和休眠重启、其他录音中断、Windows原生GUI／多屏／托盘／Toast／物理快捷键与当前正式安装器覆盖升级。
- 48：带附件真实跨设备恢复、系统凭据锁定／重新授权、磁盘满／断电、历史保留管理和PCM原声持久编码压缩。
- 49：图片文件分享、LAN编辑／删除／附件／冲突，学习和排程尾项。
- 50：本轮Android／Windows／Linux 1.8正式发布已完成；独立ARM64正式附件、Apple设备／签名公证、Windows正式签名和商店后续。
