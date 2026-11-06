# Android／Windows／Linux v1.7.1发行记录（2026-11-06）

## 已发布范围与固定源码

[GitHub v1.7.1](https://github.com/yarnway/dontforget/releases/tag/v1.7.1)已正式发布并设为latest，build60／schema17，标签固定源码`559ab5a7540d01ae69f81a27dfd6e668238b23a5`。包含Android固定发行签名APK／AAB、Windows x64 Setup／Portable和Linux x64 tar.gz五包，连同三平台清单／摘要、原生报告和来源文件共16附件。v1.7.0及历史草稿均保留，不改写其附件或来源；另已读回确认v1.7.1为latest，旧v1.7.0标签及全部16附件摘要保持。Apple未纳入此轮发行。

阶段50本轮三平台目标已完成；阶段47／48／49剩余任务继续保留，不将本次发布写成全部原生矩阵通过。

## 源码与发布门禁

固定源码的[CI 42143635895](https://github.com/yarnway/dontforget/actions/runs/42143635895)双平台质量与五平台构建7项成功，tag检查按主线条件跳过；五份artifact源码身份已核对。Linux Flutter2306通过／2跳过，Windows2288通过／20跳过；Python各161运行（Linux4跳过／Windows6跳过）。[源码机器记录](benchmarks/github-ci-v1.7.1-2026-11-06.json)。前一功能提交c1cd304及其159项Python证据保留原归属；之后仅追加版本专用说明门禁、回归和文档，产品版本保持+60。

[手动发布工作流 42146680831](https://github.com/yarnway/dontforget/actions/runs/42146680831)的prepare／publish均成功：校验精确主线源码、三个ZIP完整摘要／CRC、五包清单及摘要、APK／AAB固定证书、Windows隔离安装／升级／卸载报告和桌面启动报告，再发布并读回。版本专用说明文件及标题必须与当前版本一致，缺失／错版会失败，不再固定引用v1.7.0正文。本轮没有使用本地发布回退流程。

发布后再次独立下载准备包和发布收据，核对artifact源码、完整SHA-256／CRC及全部16文件；重新验证APK／AAB签名，并通过API读回标签指向、正文完整内容、附件集合／大小／SHA-256。固定证书为`3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1`。[发布机器记录](benchmarks/github-release-v1.7.1-2026-11-06.json)。

## 实际安装与设备范围

Pixel先从发行+59升级本地arm64+60，随后覆盖升级本轮CI通用APK，后一次升级三表全部字段保持，schema17、2／0／1、完整性ok。本轮通用APK实际SAF选择桌面返回的加密夹具、输入公开夹具密码、预检、明确确认恢复及强停冷重开成功，两条合成事项／媒体全部字段与先前本地arm64恢复结果一致。两条事项再次通过产品软删除；原QA47保持，诊断包和外部夹具已定向移除，原微信输入法／subtype／硬件键盘显示设置恢复。样本0附件，不能记作带附件真实跨设备通过。此前+59恢复失败与+60修复过程见[容量及跨设备记录](Encrypted_Total_And_Cross_Device_2026-11-06.md)。

Windows最终Setup已在本机真实升级到1.7.1+60。升级前无App进程，7份Roaming／4份备用库／1份凭据引用文件先做受限ACL备份和摘要核对；安装退出0，37份payload与最终Portable逐项一致，卸载器存在，业务文件摘要保持。新版原生CLI退出0、schema17／完整性ok，原3提醒／0媒体／1设置全部字段保持。未读取腾讯云凭据或改动Signing目录；这不是窗口／托盘／Toast视觉验收。

Linux完成Ubuntu24.04隔离构建／原生进程启动及清理检查；本机Ubuntu22.04未做实际桌面运行，不承诺所有发行版兼容。Windows同样保留CI隔离安装／启动与真实本机数据结果的独立范围。

## 五个安装包摘要

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| DontForget_Android_v1.7.1.aab | 72799780 | `03891c783ba158dac80204712d3e9876e73f841d95e71c40cb537c5747eb7c8f` |
| DontForget_Android_v1.7.1.apk | 75899600 | `ac8abe0598dcbc238127167b8874f662cb89f1e686b154e86c6e842d79c7c46e` |
| DontForget_Linux_x64_v1.7.1.tar.gz | 14326373 | `1165d1b2dcc3298f7914ef591795e7c498a89ce7e4cb43118afaf591fb9bed83` |
| DontForget_Setup_v1.7.1.exe | 14614217 | `10be58c59f6a18b7d0240fbf0789cab3f0f0d17c6e102996bfbd335845400f4f` |
| DontForget_Windows_Portable_v1.7.1.zip | 17818979 | `b369dc033b87f735d1da02fe08ff8259c3660d05e2c9a700faf345a12d9b9b3b` |

## 剩余阶段

- 46旧安装操作问题按用户保全后替换决定收口，来源未知仍作历史事实；USB长期休眠／换线观察继续，不宣称硬件永久解决。
- 47腾讯云中英／混合真实识别按用户决定暂缓；继续微信输入法真人／其他机型兼容、通知延后二次送达和休眠重启、其他录音中断、Windows原生窗口／物理快捷键／托盘／Toast。Computer Use先前URI初始化失败，更新后node_repl入口缺失，未以其他Windows UI自动化替代。
- 48完整2GiB加密宿主容量已通过独立b981592 CI；仍需带附件真实设备往返、手机完整容量保存、凭据锁定／重新授权、磁盘满／断电、保留策略及日历／定位等长期管理尾项。
- 49本轮Windows全局快捷录入源码、自动化、原生注册与包已交付；图片／附件分享、LAN编辑／删除／附件和持久冲突展示、学习批量调整及专注／排程工作流仍待完成。
- 50本轮Android／Windows／Linux发布已完成；Apple设备验收及签名公证、Windows Authenticode和商店分发另行推进。
