# v1.8.3／build72 三端发行与ARM64包体验收

[v1.8.3](https://github.com/yarnway/dontforget/releases/tag/v1.8.3)已发布并设latest，源码`ee5a675a10a9a573b0568796be73e5103ac5b6da`，schema17。Android ARM64 APK／通用APK／AAB、Windows Setup／Portable、Linux x64归档，共六包、17附件。旧v1.8.2的标签和附件独立读回保持。[发行机器记录](benchmarks/github-release-v1.8.3-2026-11-11.json)。

## 源码与自动化

- 应用lib树与已发布+71一致，无新增依赖及数据库迁移；本轮改动发行工具与按本次构建启用的NDK ABI过滤。
- 自1.8.3起Android清单必须包含三包；验证ELF架构、Flutter运行库、插件库集合、两APK身份／版本／最低SDK，失败恢复通用包并清除残留小包。旧版双附件清单仍可验证。两APK及AAB分别验证固定发行证书。
- [固定SDK CI](https://github.com/yarnway/dontforget/actions/runs/42987767822)七项成功：Linux Flutter2403通过／2跳过，Python170运行／4跳过；Windows Flutter2385通过／20跳过，Python170运行／6跳过。Windows／Linux原生启动均通过；Windows另有CI隔离安装／同包升级／卸载与清理，报告分别包含在来源附件中；Apple只完成CI候选，不记设备／正式签名通过。[CI证据](benchmarks/github-ci-arm64-2026-11-11.json)。
- 首轮源码8456342的本机Windows全套170运行／6跳过通过；ABI过滤修正后相关9项单独通过，最终源码全套结果以本次固定CI为准。首轮WSL调用Flutter启动脚本切换SDK，导致SDK可用性失败；原Windows Dart保留目录复制恢复并核对二进制，随后原生回归和构建通过。WSL原失败日志保留；首轮Windows日志被成功复验覆盖，原失败计数及工具输出已记录。
- 首轮源码8456342的CI42970303510两端质量和其他平台构建成功，Android被严格ABI门禁拒绝：target-platform仍混入插件的其他ABI库。修正为本次构建的NDK过滤，关闭Flutter默认过滤覆盖；不使用可能提高versionCode的ABI split。失败证据和修正后原生4库校验见[工具记录](benchmarks/arm64-tooling-72-2026-11-11.json)，未从失败CI发布。

## 包体与安装占用

| 同源码固定SDK发行APK | 字节 |
| --- | ---: |
| 通用（三ABI） | 76473084 |
| ARM64 | 26425812 |
| 减少 | 50047272（65.44%） |

ARM64只含arm64-v8a，保留libapp、libflutter、libdartjni、libsqlite3；通用包三ABI均完整。AAB另读取实际ZIP原生库清单，保留三ABI。以上为同源码／SDK／固定签名的正式附件对照，不拿本机SDK候选替代。

| Pixel系统存储页（同为1.8.3） | 通用APK | ARM64 APK |
| --- | ---: | ---: |
| 应用大小 | 77.84 MB | 27.74 MB |
| 用户数据 | 352 kB | 352 kB |
| 缓存 | 127 kB | 127 kB |
| 总计 | 78.32 MB | 28.22 MB |

保留系统单位及四舍五入；安装占用与下载字节分别记录。未按清空数据／缓存，未重编码或删除原件。截图只本地保留。[Android记录](benchmarks/android-arm64-upgrade-72-2026-11-11.json)。

## 本机与手机验收

- **Windows**：最终固定CI Setup安装前，独立备份当时最新数据和凭据，旧+71普通App实际运行。安装器正常关闭后覆盖为PE1.8.3.72，禁止强关；37个payload文件与便携包逐字节一致。4提醒／0媒体／1设置全字段、凭据文件和DPAPI实际值保持；CLI与普通App重开后再次读回一致。[本机证据](benchmarks/windows-local-upgrade-72-2026-11-11.json)。Windows GUI／Toast未在本轮补验。
- **Android正式版**：最新备份独立保全后，以公开固定CI通用+71为起点升级固定CI ARM64+72，普通入口冷重开。通过同签名私有导出入口核对2提醒／0媒体／1设置全字段和安全存储快照（0条）；同版公开通用APK与ARM64 APK直接双向覆盖，再读回保持。最终留固定CI ARM64普通App，摘要与公开附件一致。私有恢复入口不分发。
- **QA47**：先新备份后+71→首轮源码+72，55提醒／9媒体／1设置和1安全条目保持；修正后再次新备份并同版覆盖最终源码+72，9原声摘要、全业务字段、凭据实际值和普通入口冷重开再验通过。独立debug签名／本机SDK3.47.2，不能记正式发行签名或固定SDK包。两次源码范围分别记录。
- 本轮均未卸载新装；+68两身份分别卸载／新装／恢复为历史独立结果，不移记+72新装通过。未在本轮重做真实IME、语音转写、系统通知或SAF恢复。

## 发布与读回

[手动发布工作流](https://github.com/yarnway/dontforget/actions/runs/42992950392)成功。三份来源ZIP完整SHA-256／CRC验证；发布后的provenance及总摘要另行下载，按文件名比较15条来源文件，17附件逐项核对大小／SHA、正文、标签和latest。15个来源文件的字节来自完整验证的CI来源ZIP，与GitHub上传附件摘要及发布回执交叉核对；另行下载发布器生成的provenance和总摘要。发布回执ZIP已下载核对；未重复下载公开大包或release-ready包装ZIP，后者明确为false。两APK／AAB签名再次验证。发行包清单如下。

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| `DontForget_Android_arm64_v1.8.3.apk` | 26425812 | `ee15e771373eb66857ad7fa73765d533f392fca2533b6af9ae703c439e6e1ae0` |
| `DontForget_Android_v1.8.3.aab` | 73247110 | `9f926d4dd050a0ad275edafc35bfa6998873f611c9cf37f3d41ef17962cbdb34` |
| `DontForget_Android_v1.8.3.apk` | 76473084 | `0b2dce5f8bc50f0bdcbc34ecd7a2f1044e7b6483206d5fced7452a590c17ff7d` |
| `DontForget_Linux_x64_v1.8.3.tar.gz` | 14402068 | `662c5cc2d5e3660acec231bcb7b56eccfe019c344fc37102e2117402b4c4bd9d` |
| `DontForget_Setup_v1.8.3.exe` | 14666239 | `dcace0d25c11f97494d938551e2fca634787880cb1cc22cba512d71a182d9d7f` |
| `DontForget_Windows_Portable_v1.8.3.zip` | 17894502 | `a5b8f249be172ad2fe4be717206c49245d7464a3f0cdce774ec5807d19f93ac7` |

## 剩余阶段

46：USB长期／跨主机对照；47：真实IME组合与发送、通知休眠／重启、录音中断、Windows GUI／托盘／Toast；48：带附件的系统文件选择器和桌面GUI恢复、真实凭据故障／磁盘满／断电、保留管理／显示名／原声压缩；49：跨计划调整、负担预测、更多练习排程、图片分享与LAN编辑／删除／附件冲突；50：Apple设备与签名公证、Windows Authenticode和商店分发。独立ARM64正式附件已完成，不再列为待执行。
