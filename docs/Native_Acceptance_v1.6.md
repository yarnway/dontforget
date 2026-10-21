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
| 到期观察 | 旧任务 16:09:26 +08:00 到期后无旧 ID 送达记录；应用退出后，新请求于 16:10:26.135 被系统 Delivering，16:10:26.136 Presenting as banner。从 16:08:30 开始、覆盖旧任务到期后和新任务展示时点的有界日志只出现新 ID。横幅已过期，未取得界面截图；证据为系统送达与展示日志，不代表用户已读。 |

原生 API 接受请求不等于系统送达或用户已读。启动续检后 provider 正常加载仍会对同一个任务做一次同 ID 的取消/重排；没有观察到重复待发 ID，进一步减少重复调用留给调度协调切片。

验收发现 UTC 备份时间直接显示为 UTC（本地 16:10 显示 08:10）。[阶段 3A 源码切片](Iteration_v1.6.md) 已统一卡片、详情、日期/时间选择器、循环和复习提示的本地呈现，保留存储 instant；该显示问题不改变本次原生通知实际到期时间。修复后的新候选仍待原生复测。

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
2. 阶段 3A 已完成当前提醒确认/延后持久化及对应迁移、备份与恢复格式源码回归；新候选原生复测仍待执行，调度结果持久化与剩余来源统一留在 3C。
3. 接入可见权限状态、通知热/冷启动点击路由及调度失败重试，开展重启、循环、延后与取消的闭环验收。
4. 其他系统、休眠、时区/DST、正式签名环境及真实用户库保持独立待验；录音/播放验收继续跳过。

## 2026-10-21：schema 9 候选升级与提醒持久化验收

本次核验的是源码 `3d68c83958e9cc8664faf4cb261759218a6055c7` 的 [CI 39570026069](https://github.com/yarnway/dontforget/actions/runs/39570026069)。质量检查和 Windows、Android、Linux、macOS、iOS 候选全部成功，发布步骤按非标签构建跳过。Mac ZIP 为 23,737,558 字节，SHA-256 `0cc86bc6aa1112e5c4bb4af8e5c24207c1e60a21d6f074cfb389c9a1cba8379d`；来源清单、大小、摘要及隔离派生内容检查通过。

独立身份为 `com.example.dontForget.acceptance.schema9-r39570026069`，应用位于忽略目录 `build/native_acceptance/schema9-r39570026069/dont_forget.app`。只读进程句柄核实数据库和 owner lock 均处于该身份的沙箱。派生副本仍只改变外层身份、显示名和签名；受保护框架/资源及可执行文件非签名字节保持一致，codesign deep/strict 通过。它不代表原签名或公证包验收，不触碰真实用户库及其通知。

| 场景 | 完成情况与证据 |
| --- | --- |
| v8 → v9 原生升级 | 正常退出新隔离应用、确认进程不存在并取得其 owner lock 后，保留空白 v9 原库，再安装合成 v8 基线副本。重开应用实际执行迁移；三表逐行匹配预期，任务 1、文本记录 1、设置 1，五个新增字段为规定默认值。 |
| v9 原生恢复 | 原生文件选择器打开 `candidate-v9.sqlite`，预览任务 4、文本记录 1、设置 1，无密钥和不可访问附件。确认 1→4 后显示完成；三表逐行匹配候选，独立 rollback 逐行匹配升级后基线，pending journal 已归档。 |
| 本地时间显示 | 卡片正确显示合成 UTC 时间对应的 Asia/Shanghai 时刻：16:53、16:54、16:50 和 20:00。修复覆盖本机显示，本次未切换系统时区或验证 DST。 |
| 确认后重启 | 16:54:31 对 `QA 1 ACK DUE` 点击 Got it，数据库写入确认时间；正常退出并重开后仍保留任务，但不再出现它的到期提示。只剩另一条未确认的提醒。 |
| 延后后重启 | 16:55:06.936131 延后 `QA 2 SNOOZE DAILY`，新时间 17:00:06.936131，与延后时间精确相差 300 秒；修订为 1，原循环基准仍为 16:54。原生日志记录取消旧请求并接受同 ID `570587817` 的新请求。重启后数据逐行保持，界面只显示延后后的即将到期状态。 |
| 退出后延后通知 | 再次正常退出且核实进程不存在。17:00:06.110 系统记录 Delivering 和 Presenting as banner，NotificationCenter 于 17:00:06.111 记录 displaying as banner，日志标识 `B0B3-E1A6`。该平台按整秒计划，数据库保留微秒。证据是系统送达/展示日志，不表示用户已读。 |
| 延后后的每日循环 | 重开应用显示该提醒到期。点击完成后，下一次为 10 月 22 日 16:54，修订为 2，清空本次延后状态，保留原基准；没有变成 17:00。 |
| 提前完成与月末循环 | 提前完成每日任务，将 10 月 22 日 16:50 推至 23 日 16:50。月末任务连续完成两次，从 10 月 31 日 20:00 经 11 月 30 日回到 12 月 31 日，原始月末基准保持。这些数据在后续退出重开后仍保持。 |
| 关闭验收数据和通知 | 通过应用恢复原先保存的空白 v9 备份，界面四区任务均为 0；当前三表逐行匹配原空库，完整验收任务保存在新的独立 rollback。17:04:47.174 系统记录移除所有待发及已送达通知，未重新安排未来任务；无 pending journal，应用正常退出。 |

只保留合成数据，路径为 `/private/tmp/dontforget-schema9-fixtures-r39570026069`。关键只读证据包括 `upgrade-native-readback.json`、`candidate-native-readback.json`、`ack-before-restart.json`、`snoozed-native-readback.json`、`snooze-after-restart.json`、`cycle-after-snooze.json`、`native-delayed-delivery.log`、`cleanup-readback.json` 和 `native-cleanup.log`。恢复操作目录分别为 `recovery-08165294-9089-426d-afb7-586c5f2df25b` 和清理时的 `recovery-01a902f9-98fb-49da-b027-ccb026ef8754`；保留回退材料，不自动删除。

新增可重复的 schema 9 合成样本工具：

```sh
python3 scripts/generate_reminder_acceptance_fixture.py \
  --output /private/tmp/dontforget-schema9-unique-fixtures \
  --start-at 2026-10-21T08:50:00Z --due-minutes 3
```

输出目录须全新。工具使用冻结的 v8/v9 schema，生成升级基线、预期迁移结果、v9 JSON/SQLite 候选及摘要清单；不会读写应用数据或启动程序。13 项新增脚本测试与既有测试合计 47 项通过。

本次关闭了阶段 3A 的上述 Mac 隔离验收项；权限拒绝/再次授权、版本化 payload 点击及冷启动路由属于后续 3B 源码，不从此候选继承真机通过结论。其他设备、休眠、DST、调度持久重试和真实用户数据恢复仍独立待验；录音和播放验收继续跳过。

## 2026-10-21：3B 新候选权限与点击验收

源码 `639a2b9513910a608b6ee56c546c8e9fc409f60e` 的 [CI 39575684866](https://github.com/yarnway/dontforget/actions/runs/39575684866) 全部成功：质量、五平台构建与产物校验通过，三个桌面平台启动检查和 Windows 安装升级卸载检查通过。云端 Flutter 575 项通过、1 项 macOS 临时路径别名专属测试按平台跳过，Python 47 项通过；本机 Flutter 576 项全部通过。未触发发布。

新 Mac ZIP 为 23,790,888 字节，SHA-256 `ff3ca1c53c829bb37231aa2affdbfbf9a92e37d5abc3c7a9db80e61225c5d005`。独立派生身份 `com.example.dontForget.acceptance.permissions-r39575684866`，路径 `build/native_acceptance/permissions-r39575684866/dont_forget.app`。来源、受保护内容和签名校验通过；进程 96940 的数据库和 owner lock 位于该独立容器。初始 schema 9、设置 1、其他业务记录 0；未触碰真实用户数据。

已完成的原生观察：

- 启动和设置页查询没有自动申请权限；页面显示“未开启（尚未授权或已关闭）”，手动刷新仍保持该状态。
- 点击“允许通知”后系统出现本次独立身份的授权提示。允许后页面回读“已允许”，授权按钮消失。空数据点击“重新安排提醒”显示没有需要更新的安排。
- 通过原生文件选择、确认和恢复流程导入四条合成任务，恢复完成。三张表逐行匹配候选，本地通知身份已旋转，pending journal 归档。操作目录 `recovery-19d69b47-a419-4780-a78b-379d90490007` 保留原空库回退。
- 英文设置页仍显示 Allowed，显式重排反馈 Processed 4 reminder schedules。17:29:10 系统接受四条请求，无原生错误；再次只读核对全部业务行未改变，任务没有被确认、完成或修改修订。
- 系统在 17:31:29.129 和 17:32:29.104 分别送达两条任务，并记录横幅展示，ID 为 `197498460`/`570587817`。这仅证明系统送达和展示，点击路由另行核验。

工具期间曾返回 `noWindowsAvailable`；用户将独立窗口置于前台后，上述权限与恢复操作恢复可用。通知中心读取随后出现 timeoutReached，已请用户打开通知中心以完成点击；不能将工具超时写成产品路由失败或通过。

合成输入与证据保留在 `/private/tmp/dontforget-permissions-fixtures-r39575684866`。其中 `restored-and-retried-readback.json` 保存恢复及重排后的业务状态，`initial-epoch.json`/`restored-epoch.json` 保存身份变化，`native-restore-retry.log` 和 `native-click-delivery.log` 保存本次独立身份的有界通知记录。`before-cold-click.json` 证明 17:33:57 应用进程不存在，所有任务仍未确认，可作为冷启动点击前基线。

### 3B 隔离清理与本阶段边界

20:15:57 已完成通过应用恢复初始空基线。重连原生界面后，工作台四区任务均为 0；20:25:12 的只读数据库核验确认 schema 9、integrity_check=ok，Settings 1、MediaRecords 0、Reminders 0，三张表逐行匹配 `empty-before-restore.db`，无 pending journal。本地通知身份已旋转为 `b0a38932-fc84-40e9-a493-f5888a673a64`。

清理操作 `recovery-6e57ed62-c253-451a-bd2e-b1771c3580cb` 已归档 committed 结果，保留 candidate、displaced、rollback、原始备份和完成记录；rollback 的三张表逐行匹配本次四任务 `candidate-v9.sqlite`。没有删除回退材料，也没有修改真实用户库。

`native-cleanup.log` 记录 20:15:57.761 移除该独立身份的全部待发及已送达请求；20:15:57.762 usernoted 移除 `197498460`、`570587817` 的已送达记录，NotificationCenter 同时移除两个横幅。`cleanup-readback.json` 保存上述空库和身份读回证据。窗口观察期间曾出现过期画面/点击无效，重连后以当前界面、数据库和有界系统日志交叉核验完成结果，不据此声称曾完成通知点击。

本阶段已完成权限状态、显式重排、系统送达和清理；Mac 热点击与冷启动点击仍待验收。后续 3C-1 的 594 项源码回归及统一调度改动尚未从本次旧候选继承原生通过结论；新候选须按其源码 revision 单独核验。录音与播放验收继续跳过。


## 2026-10-21：3C-1 候选包核验与隔离副本准备

源码 `886254f100945ea978e3d759a415596e33f4ec58` 对应 [CI 39601538766](https://github.com/yarnway/dontforget/actions/runs/39601538766)，质量及五个平台候选均成功，发布步骤按非标签条件跳过。云端 Flutter 593 通过、1 项 macOS 专属条件跳过，Python 47 通过；本机功能改动 594 项全量通过，随后纯文案修正的 27 项界面回归通过。

Mac 原始候选为 `DontForget_macOS_unnotarized_v1.5.2.zip`，23,798,328 字节，SHA-256 `e7ad27bae4e72b01a06797cf9c2988ddbbcdeed1726c0688f0f82d5512d287a0`。下载的外层 GitHub artifact 同样通过官方摘要 `0175a1be5d424a9d5f9896812e9275bc4069e72144004d44b5edf39de5284605` 检查；本机 `verify_artifacts.py` 再次验证内层包的大小、摘要、版本、平台和完整源码 revision。清单及 ZIP 保存在 `build/ci_artifacts/3c1-r39601538766`。

隔离派生身份为 `com.example.dontForget.acceptance.scheduling-r39601538766`，副本位于 `build/native_acceptance/scheduling-r39601538766/dont_forget.app`。准备脚本完成受保护内容比较和 codesign 校验，未启动或注册此副本。其状态为“包来源与隔离副本准备通过，原生业务验收待执行”，不继承旧 `permissions-r39575684866` 的业务通过结论。CI Mac 记录仅为解包后 10 秒原生进程启动检查，UI/通知业务验收均未执行，原包仍未公证。

后续先使用全新合成数据验收新候选的编辑/删除/撤销与动态晋级调度，以及 Mac 热点击、冷启动与旧通知隔离；跨重启取消补偿和持久重试属下一源码阶段。保留前一隔离空基线和回退材料，录音与播放验收继续跳过。

## 2026-10-21：3C-1 原生编辑与送达续验

本轮用户已允许录音和播放验收；此前各阶段的“跳过”是历史范围，不再代表当前要求。

继续使用已核验的源码 `886254f` / CI `39601538766` 隔离身份 `scheduling-r39601538766`。首次启动为空库，设置页手动请求通知权限后，系统授权并回读为 Allowed。通过应用生成空库镜像，保存为 `/private/tmp/dontforget-scheduling-fixtures-r39601538766/empty-before-restore.db`。

原生文件选择器可定位合成文件，但 Open 持续禁用，坐标点击报 `noWindowsAvailable`；本轮没有完成该入口的恢复。正常退出且核实进程不存在、取得独立容器 owner lock 后，保留空库，再离线装入无密钥的四任务合成数据。样本、安装条件与读回记录保存在 `/private/tmp/dontforget-scheduling-session-r39601538766`。这属于隔离数据准备，不计作原生恢复通过。

| 验收项 | 观察结果 |
| --- | --- |
| 编辑提醒时间 | 对 `QA 3 DAILY EARLY` 选择 Tomorrow 09:00 并保存。数据库时间变为 2026-10-22 09:00 本地时间，修订从 0 到 1；正常退出重开后看板仍显示该时间。系统日志在 22:39:58 记录取消旧请求、接受同 ID 的新请求。标题/补充文本输入未确认生效，不计通过。 |
| 删除 | `QA 4 MONTH END` 从看板消失，任务数 4→3；只读数据库核实该行已删除。原四任务样本保留。 |
| 撤销 | 截图可见 Deleted task 和 Undo，但原生可访问性树缺少整个反馈条。坐标点击仍报 `noWindowsAvailable`，没有执行撤销；该问题已由新增 Flutter 语义回归复现，进入 3C-2 修复。 |
| 热启动送达 | 22:46:48.136 系统 Delivering，22:46:48.138 NotificationCenter displaying as banner；Q3 `hasSound: false`。应用当时运行。读取通知中心超时，未完成热点击。 |
| 退出后送达 | 正常退出且确认候选进程不存在后，22:47:48.116 系统 Delivering，22:47:48.117 displaying as banner，仍为静音。未完成冷启动点击，不把送达等同于点击或已读。 |

证据文件：`offline-seed-evidence.json`、`deleted-native-readback.json`、`native-edit.log`、`native-hot-delivery.log`、`native-cold-delivery.log`。旧候选已正常退出；合成任务和回退基线继续保留，后续在新候选完成撤销、清理及稳定 ID 原生验收。录音/播放现已允许，但本节尚未执行，不宣称通过。
