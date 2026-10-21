# v1.6 恢复候选的 Mac 隔离原生验收

日期：2026-10-21。录音和播放验收按用户要求继续跳过。

## 候选与隔离方式

- 源码候选：`fd74ad9b815f9d348a33f1b59625c90a8b384163`，包版本 1.5.2+3，CI `39561632757`。
- 原 Mac ZIP：23,707,529 字节，SHA-256 `8d4b39742c75935cd866a35bb8f3d58b2dda24643912d41999e02b478db67aa9`。
- 原包没有可用于 Mac 的数据目录覆盖参数。修改解压路径或 XDG/APPDATA 环境变量不能隔离 Mac 沙箱，更不能隔离原生通知身份；不以这些方式启动原身份候选做数据替换。
- 本次从该候选派生独立 bundle 身份的验收副本，保留原 ZIP，核对核心框架和资源字节，限制主可执行文件变化在代码签名范围。独立沙箱容器和通知域使合成数据验收与当前用户应用分离。
- 派生副本须单独记录 bundle 身份、重签与内容比对证据；不能将其表述为原封不动的发行包签名验收，也不能替代真实用户库、其他设备或正式签名环境的验收。

## 场景与结果

| 场景 | 结果与证据 |
| --- | --- |
| 隔离身份 | `com.example.dontForget.acceptance.r39561632757`，沙箱 `~/Library/Containers/<独立身份>/Data`；只读进程文件句柄核对数据库和锁均在该域，初始任务/输入记录为 0。 |
| 候选内容 | 派生副本只改外层 Info 的 ID/显示名及签名；Frameworks/Resources 字节不变，两个 Mach-O 架构非签名字节摘要一致，codesign deep/strict 通过。原 ZIP 保留。 |
| 通知失败保护与重启续检 | 初次从 `/private/tmp` 运行时系统无法验证通知身份。恢复已持久化 `committed` 决策，界面只允许退出，独立 rollback/source/candidate 均保留。移至非临时目录并重新注册同一身份后，系统出现授权提示，允许后重启续检完成，pending journal 归档；合成基线逐行一致。 |
| JSON 基线恢复 | `baseline.json` 的三表各 1 行；恢复后英文设置、新模型占位名及 ONLY OLD 任务正确加载，无 API 密钥。系统接受旧请求 `421141009`（日志标识 `59FC-AE9F`）。 |
| JSON 候选取消 | 确认页正确显示任务 1→2、输入 1→1、设置 1→1。取消后全部业务行与基线一致，预定操作目录 `recovery-5aa75f5f-a9bf-4a82-b870-e06d3884f5f8` 未创建。 |
| SQLite 候选恢复 | 确认后显示 Recovery complete；三表逐行匹配 `candidate.sqlite`，独立 rollback 逐行匹配旧基线，无 pending journal。工作台只显示 ONLY NEW 和 1 个已完成任务。 |
| 通知取消与重建 | 16:03:01 +08:00 系统记录 cancelAll，随后接受新请求 `481877603`（日志标识 `E881-0A29`）；未给已完成任务创建请求。 |
| 正常退出和重开 | 进程 23649 正常退出后，以 26935 重开；三表未变、pending journal 不存在，新任务/完成数量保持。系统替换同一个新请求 ID。随后退出应用进行后台到期观察。 |
| 到期观察 | 旧任务 16:09:26 +08:00 到期后无旧 ID 送达记录；应用退出后，新请求于 16:10:26.135 被系统 Delivering，16:10:26.136 Presenting as banner。16:08:30 至 16:10:45 的有界日志只出现新 ID。横幅已过期，未取得界面截图；证据为系统送达与展示日志，不代表用户已读。 |

原生 API 接受请求不等于系统送达或用户已读。启动续检后 provider 正常加载仍会对同一个任务做一次同 ID 的取消/重排；没有观察到重复待发 ID，进一步减少重复调用留给调度协调切片。

验收发现 UTC 备份时间直接显示为 UTC（本地 16:10 显示 08:10）。下一源码切片统一卡片、详情、日期/时间选择器、循环和复习提示的本地呈现，保留存储 instant；该显示问题不改变本次原生通知实际到期时间。

原始合成证据保留在本机 `/private/tmp/dontforget-native-r39561632757`；fixture 在 `/private/tmp/dontforget-native-fixtures-r39561632757`，应用副本在仓库忽略的 `build/native_acceptance/r39561632757`。不提交真实用户库、系统其他应用通知或凭据。

## 可重复的准备工具

`scripts/prepare_macos_acceptance.py` 校验候选清单/摘要/ZIP路径，派生新身份并逐字节核验受保护内容，不自动注册或运行。验收时必须使用非临时路径；macOS 将临时目录包标记为 `in-temp-dir`，本次已实际导致通知身份验证失败。工具现拒绝系统临时目录，不能用修改 HOME/XDG/APPDATA 代替沙箱隔离。

```sh
mkdir -p build/native_acceptance
python3 scripts/prepare_macos_acceptance.py \
  --manifest /absolute/path/macos-manifest.json \
  --revision fd74ad9b815f9d348a33f1b59625c90a8b384163 \
  --run-id unique-run-id \
  --output "$PWD/build/native_acceptance/unique-run-id"
python3 scripts/generate_recovery_acceptance_fixture.py \
  --output /private/tmp/dontforget-unique-fixtures \
  --start-at 2026-10-21T16:00:00+08:00 --due-minutes 12
```

`run-id` 和输出均必须全新。fixture 工具使用冻结的 v8 schema，生成旧/新静音 Q3、已完成任务、文本记录和损坏 JSON，无密钥；不打开应用数据。它用于历史 v8 候选，不代表 v9 原生验收。记录产物摘要、独立身份、实际沙箱路径后，通过原生文件选择器导入。脚本和纯单元测试不等于上述原生验收。准备/fixture/原有打包脚本合计 34 项测试通过。

## 后续阶段

1. 本次恢复、通知取消重建、重启与有界到期观察完成。在修复 UTC 日期后的新源码候选上复核显示；隔离副本不替代原签名包验收。
2. 推进提醒发生记录与确认/延后持久化、统一任务变更和调度入口；同步数据库迁移、备份检查与恢复格式。
3. 接入可见权限状态、通知热/冷启动点击路由及调度失败重试，开展重启、循环、延后与取消的闭环验收。
4. 其他系统、休眠、时区/DST、正式签名环境及真实用户库保持独立待验；录音/播放验收继续跳过。
