# Android／Windows／Linux v1.7.2发行记录（2026-11-06）

## 已发布范围与源码

[GitHub v1.7.2](https://github.com/yarnway/dontforget/releases/tag/v1.7.2)已发布并读回latest，build61／schema17，标签固定源码`8514c8625aa1ae04efb63bf425f3fe99a7717bff`。本次为Windows紧凑输入维护版：默认单行，点击输入，内容超过两行或长粘贴才展开；缩短、清空或成功发送收起，长文本内部滚动，保留组合输入与草稿。Android／Linux保持原输入布局。五份安装包及三平台清单／摘要、桌面报告、来源文件共16附件，Apple不纳入本次发行；旧v1.7.1标签及全部16附件摘要再次核对保持。v1.7.0与历史草稿未操作。

## 验证分层

- 源码与本地自动化：输入／录音／发送专项79通过，新组件回归8项；Windows Flutter全量2296通过／20跳过、分析0，发行工具14项通过及新版正文标题校验通过。本机Flutter3.47.2与固定CI SDK3.44.9分别记录。
- 固定源码[CI 42153031005](https://github.com/yarnway/dontforget/actions/runs/42153031005)双平台质量与五平台构建7项成功，tag专用检查按主线条件跳过；Linux Flutter2314通过／2跳过，Windows2296通过／20跳过；Python各161运行（Linux4跳过／Windows6跳过）。五份artifact源码身份及摘要字段已核对。[CI机器记录](benchmarks/github-ci-v1.7.2-2026-11-06.json)。
- 包与云端原生冒烟：[发布工作流 42156389816](https://github.com/yarnway/dontforget/actions/runs/42156389816)prepare／publish均成功；精确源码、三个来源ZIP摘要／CRC、五包清单／摘要、Android APK／AAB固定证书、Windows隔离安装／升级／卸载及桌面启动报告均通过。本地另建Windows Setup／Portable，38份payload逐项与编译输出核对、CRC／SHA-256与PE1.7.2.61通过；本地另含native_assets.json，SDK与云端基线不同，两包分别核对；发行采用云端包。
- 发布后独立下载准备归档与收据、核对源码与ZIP完整摘要／CRC、16文件及五包摘要，重新验证APK／AAB签名；API再次读回标签、完整正文、附件大小／SHA-256及latest。固定Android证书`3db49656984fb848a73b1e8d056846b97e2a7caf47c9a9ae74f475cdbb79e9f1`。[发布机器记录](benchmarks/github-release-v1.7.2-2026-11-06.json)。
- 真实设备：本轮未覆盖安装+61，未执行+61手机或Windows原生真人验收。输入框三张实际Flutter控件渲染图已检查，是合成事项预览，不是Windows原生截图。前一+60已安装与数据保持的结果保留原版本归属。Windows中文输入法、多屏DPI、托盘／Toast／物理快捷键仍待验；当前缺Computer Use所需node_repl，不以自建UI自动化替代。Linux仅记Ubuntu24.04隔离构建与启动范围。

## 五份发行包摘要

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| DontForget_Android_v1.7.2.aab | 72814084 | `d342c78bc189477d19660ed87a02924adfcdf9cb7e4a203e23e7bb157422d668` |
| DontForget_Android_v1.7.2.apk | 75915984 | `957e1894e642118acb646f0703692be254f955e336e8125279d2d7f239e2acf5` |
| DontForget_Linux_x64_v1.7.2.tar.gz | 14329791 | `758be2204df9205e2ef9ca9947d9aa75e329f2e4490c350f9be863c4f6a21f89` |
| DontForget_Setup_v1.7.2.exe | 14621947 | `907f865402ff260944ddd20d2722de716297cde514598053e60a847473e0d77c` |
| DontForget_Windows_Portable_v1.7.2.zip | 17825907 | `e5ccef2eac25b351329f1d3209eb4af7d376f112ea674c1e0a0ed608351ac8cb` |

## 剩余阶段

- 46：保全替换已收口，USB跨端口／主机与长期休眠唤醒观察继续。
- 47：Windows原生输入法、窗口／多屏／托盘／Toast／快捷键；Android输入法其他机型、通知延后／休眠重启及录音通话／焦点中断。腾讯云真实中英／混合识别按用户决定暂缓，未配置／调用。
- 48：带附件真实跨设备恢复、手机容量保存、系统凭据锁定与重新授权、磁盘满／断电、旧备份及原件保留管理。
- 49：图片／文件分享、LAN编辑／删除／附件和冲突及同事项接续，学习计划批量管理、练习和排程尾项。
- 50：本轮Android／Windows／Linux发布已完成；Apple设备与签名公证、Windows正式签名及商店分发另行推进。
