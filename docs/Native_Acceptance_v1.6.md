# v1.6 恢复候选的 Mac 隔离原生验收

起始日期：2026-10-21，后续验收按日期追加。最新授权允许录音和播放验收；各历史段落中的“跳过”仅描述当时范围。

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

证据文件：`offline-seed-evidence.json`、`deleted-native-readback.json`、`native-edit.log`、`native-hot-delivery.log`、`native-cold-delivery.log`。23:05 通过应用逐条删除剩余三条合成提醒；只读回查 Reminders=0、MediaRecords=1（合成文本）、Settings=1，完整性正常。系统日志确认两条已送达通知移除及未来请求取消，应用正常退出。编辑后的三任务库已用 SQLite backup API 保存为 `before-cleanup-consistent.db`，原始四任务样本和空基线继续保留；`cleanup-native-readback.json` 与 `native-cleanup.log` 记录收尾。录音按钮尝试未观察到授权提示、录音状态或新音频文件，不能确认录音开始，播放也未执行。后续在新候选完成撤销及稳定 ID 原生验收。


## 2026-10-21：3C-2 持久调度候选

源码 `8f2a40ebb4cbcdab63830af5fea5e03d2266f900` 已提交 main 并推送。[CI 39622115301](https://github.com/yarnway/dontforget/actions/runs/39622115301) 的质量及五平台候选全部成功，发布步骤按非标签条件跳过。云端 Flutter 610 项通过、1 项 macOS 临时路径别名测试按平台跳过；Python 47 项通过。本机同版工具链静态分析无问题，611 项 Flutter 与 47 项 Python 全部通过。本机只有 Command Line Tools、没有可用的 xcodebuild，Mac 原生构建未完成；本轮使用 CI 产物验收。

本机纯 Dart 合成测量：200 条提醒首次分配并记录计划结果约 642 ms，200 次取消记录约 545 ms，日志 33,860 字节。仅覆盖本地日志 I/O，不包含原生调度、送达或应用启动；大规模任务、启动帧耗时和跨平台性能仍待测量。

Mac ZIP 为 23,822,455 字节，SHA-256 `edcf6bcac571e7508b0ffcdc21bb5a2dc3416d435bbff7bcb9da2b3c494bd7c4`；外层 GitHub artifact 摘要 `cc7ddab7f935aeaf04b4995ed173e22a8cb70baaa13f468d31bf7da001752c12`。下载分段超时后仅续传缺失字节，完整摘要通过。`verify_artifacts.py` 核实完整源码 revision，隔离派生内容和 codesign 检查通过。原始产物保存在 `build/ci_artifacts/3c2-r39622115301`，独立身份 `com.example.dontForget.acceptance.durable-r39622115301`，副本在 `build/native_acceptance/durable-r39622115301/dont_forget.app`；仍不代表原签名或公证验收。

新容器初始 schema 9、任务/记录均为 0，通知日志为空。系统在 23:20:05 明确记录 didGrant=1，重开后的设置页回读 Allowed。正常退出、核实进程不存在并取得 owner lock 后，保存原空库，以 SQLite backup API 安装四条无密钥合成任务；属于离线样本准备，不计本轮原生恢复入口通过。

| 验收项 | 完成情况与边界 |
| --- | --- |
| 删除与可访问撤销 | 原生菜单删除 QA 4，任务数 4→3；Undo 现在能被 AX 树读取且可点击，执行后 3→4。ID `315234779` 从 schedule→cancel→schedule 保持一致。但业务行比对发现撤销自动增加关联，完整撤销正确性暂未通过，问题已修复于 `3a0d58d`，新包另行复测。 |
| 编辑与重启 | QA 3 选择 Tomorrow 09:00 并保存，时间变为 2026-10-22 09:00、notice_revision=1，ID `1329258270` 不变；退出重开后业务行逐行不变，四个 ID 均保持。标题粘贴未实际改变内容，标题输入不计通过。 |
| 热状态系统送达 | 23:26:22.129 系统 Delivering，23:26:22.131 NotificationCenter displaying as banner，ID `1967836952`，日志标识 C9D0-0AF4。 |
| 退出后系统送达 | 候选已正常退出，进程缺席读回为 23:27:22.032；23:27:22.111 系统 Delivering、23:27:22.112 展示横幅，ID `167290217`，日志标识 2660-58A9。 |
| 热/冷点击 | 两次通知中心读取及控制中心入口均 timeoutReached，未能执行点击。送达/横幅不能替代点击路由验收；没有把工具失败归因于产品路由。 |
| 跨重启补取消与失败重排 | 应用退出并持锁，保存一致数据库和日志后，离线删去 QA 4 业务行而保留 schedule 日志，并把 QA 3 记录置为 failed。重启后 QA 4 没有复活，日志改为 cancel/submitted；系统 23:28:15.422 发起取消原标识 8F98-2101。QA 3 沿用 ID `1329258270` 取消重排，23:28:15.451 系统接受请求，日志变为 schedule/submitted、attempts 增加。两条已到期实例的日志完全未变、未重放、未自动确认。此为受控故障注入，非真实原生报错或系统重启。 |
| 录音/播放 | 首次请求后 TCC 授权后来生效，退出前生成了约 47.6 秒临时录音，未完成保存；保留文件。再次打开后原生按钮明确显示 Recording，点击停止后创建原声任务及媒体索引，持久文件 119,941 字节、AAC/44.1 kHz/双声道、6.221497 秒。附件点击后插件播放调用返回成功并显示 Playing voice note。正常退出重开，任务内容及文件 SHA-256 不变，再次点击播放成功。未配置密钥，源码空密钥分支直接保留原声，不发送云端转写。此证据覆盖录音/保存/重启与播放调用，实际扬声器听感和音质仍待人工确认。 |
| 收尾 | 保存 `before-cleanup-consistent.db` 后通过应用删除三条剩余合成任务。23:29:33/45 系统与通知中心确认两条已送达通知移除，23:29:58 取消最后未来请求。只读数据库 Reminders=0、MediaRecords=1（合成文本）、Settings=1，integrity_check=ok；四个保留 ID 均为 cancel/submitted。应用正常退出，不删除回退材料。 |

样本和证据在 `/private/tmp/dontforget-durable-session-r39622115301`：`initial-scheduled.json`、`deleted.json`、`undone.json`、`edited.json`、`restarted.json`、`before-cold-click.json`、`before-gap-consistent.db`、`before-gap-journal.json`、`gap-injection.json`、`reconciled-gap.json`、`cleanup-readback.json` 与四份 `native-*.log`。真实用户容器未读写，其他运行中的隔离实例未关闭。

本阶段完成了稳定 ID、编辑后重启、系统送达、受控失败重排及取消补偿的 Mac 隔离验证。下一步为 `3a0d58d` 的新包撤销关系复测；热/冷点击、标题输入、扬声器听感、真实原生故障、权限拒绝后重试、系统重启/休眠/DST 仍各自待验。

录音续验发生在合成提醒清理之后：最终该隔离容器保留 1 条无提醒时间的原声验收任务和 2 条媒体记录（合成文本/短录音），没有新增定时通知；原声文件和首次临时录音均保留，应用再次正常退出。`saved-audio-readback.json`、`audio-before-restart.json`、`audio-after-restart.json`、`audio-session-consistent.db` 保存元数据与一致性证据，没有将录音内容提交 GitHub。

## 2026-10-21：撤销关系修复候选

`3a0d58d2d7ace4fbd527d181cf0eb27a0c85c3b3` 对应 [CI 39625619466](https://github.com/yarnway/dontforget/actions/runs/39625619466) 全部成功：质量检查、五平台构建和工作流内产物验证均通过，非标签发布跳过。云端 Flutter 613 通过、1 项 macOS 专属条件跳过，Python 47 通过；本机 Flutter 614 全量通过、静态分析无问题。

Mac ZIP 为 23,822,422 字节，SHA-256 `32de8c5ec10e9bc542a6f72e96861d7536b8f51093fa0f6c842e5080f8fd2f9a`；外层 artifact 摘要 `0f24aa215e5242c2cf493e139abd2fe79f52980c84acc3dda829f9595f9df506`。来源/大小/摘要/完整 revision 校验及隔离派生内容、codesign 校验通过。原包位于 `build/ci_artifacts/undo-r39625619466`，新身份 `com.example.dontForget.acceptance.undo-r39625619466`，副本位于 `build/native_acceptance/undo-r39625619466/dont_forget.app`。

2026-10-22 07:24–07:27 完成原生复测。首次启动工具长时间未返回，返回后重新核实源码 HEAD 未改变、新容器为空且 schema 9/日志正常。正常退出并持锁保存空基线后，离线安装新生成的四条无密钥合成任务。重开应用原生删除 QA 4，数量 4→3；点击可访问 Undo 后回到 4，四条任务的全部业务字段逐行等于删除前，所有关联仍为空，四个原生 ID 不变。该比对关闭了 `3a0d58d` 撤销关系修复的 Mac 原生验收项。

本轮新身份未申请通知权限，范围是原生 UI、业务数据和本地调度 ID 一致性；通知系统送达证据仍属于前述 `durable-r39622115301`，不混用候选身份。保留一致数据库快照后，通过应用删除四条合成任务。收尾数据库 Reminders=0、MediaRecords=1、Settings=1，integrity_check=ok，四个日志条目均 cancel/submitted；核实应用进程已退出。

证据位于 `/private/tmp/dontforget-undo-session-r39625619466`：`before-delete.json`、`deleted.json`、`undone.json`、`undo-verdict.json`、`before-cleanup-consistent.db`、`cleanup-readback.json`、`native-undo-cleanup.log`、`closed.json`。本轮涉及的源码、回归、CI 和隔离原生验收均按 revision 独立记录；热/冷点击仍因通知中心工具超时未关闭，不据此宣称 v1.6 已完成正式发布验收。

## 2026-10-22：3C-3 调度状态与前台重试候选准备

源码 `6504bc1f438a694df5ab6707db2478821764117c` 的 Mac 候选来自 [CI 39706276489](https://github.com/yarnway/dontforget/actions/runs/39706276489)。本机独立核验清单版本 1.5.2+3、平台、完整 revision、文件大小与 SHA-256；ZIP `DontForget_macOS_unnotarized_v1.5.2.zip` 为 23,843,152 字节，SHA-256 `25931d43c7d3195fb110ac08c9ca6675ea32c8495616e2d16a0b5b9951e6f816`。原包和清单保存在 `build/ci_artifacts/status-r39706276489`。本次通过 `gh run download` 下载并核验内层包，未另行保存或声称独立核验外层 artifact ZIP 摘要。

已生成全新独立身份 `com.example.dontForget.acceptance.status-r39706276489`，副本位于 `build/native_acceptance/status-r39706276489/dont_forget.app`，受保护内容逐字节核验和派生 codesign 检查通过。准备工具没有注册或启动应用，没有创建/导入业务验收数据，也未访问用户运行库。

这一步只关闭候选来源、完整性和隔离副本准备；新状态界面、前台有界重试、权限拒绝后的补处理、通知热/冷点击及迟到点击仍需该候选原生验收。此前系统送达、自动化回归或旧候选结果不替代本轮点击通过；录音/播放允许继续验收，但本轮没有新增听感证据。正式签名、公证与其他设备业务验收仍独立待办。

交付收尾：上述 CI 整体成功，质量检查与五平台候选均通过；三桌面启动检查、Windows 安装升级卸载和全部包身份校验成功。云端 Flutter 633 项通过、1 项平台跳过，Python 47 项通过；源码本机 Flutter 634 项通过。此记录未追加新的原生界面操作或系统通知点击通过结论。


## 2026-10-22：阶段 3D-2 日志优化候选与性能测量

源码 `eec2ace947a5b0ae67b6a17fd361f9d2a689a7f4`（日志优化 `6703824`，随后修正测量计时入口）已推送 main。[CI 39709820687](https://github.com/yarnway/dontforget/actions/runs/39709820687) 质量与五平台候选全部成功：云端 Flutter 641 通过、1 项平台跳过，Python 47 通过；本机 Flutter 642 通过、静态分析无问题。三桌面启动、Windows 安装升级卸载和产物身份/摘要门禁通过；非标签发布跳过。

- 产品 ZIP `DontForget_macOS_unnotarized_v1.5.2.zip`：23,845,093 字节，SHA-256 `e1b0d7aebb19a5096796993eda240a0bb5f84721e01bab8ff442d70722828b31`。本机清单与 ZIP 保存在 `build/ci_artifacts/journal-r39709820687`，独立校验版本、完整 revision、大小和摘要通过。
- 产品派生副本 `build/native_acceptance/journal-r39709820687/dont_forget.app`，身份 `com.example.dontForget.acceptance.journal-r39709820687`。隔离签名、受保护框架与资源内容核验通过；仅通过此身份运行，不访问原应用业务库。
- [profile 构建 39709822788](https://github.com/yarnway/dontforget/actions/runs/39709822788) 的独立性能 ZIP：27,780,232 字节，SHA-256 `295a59c1fb332b893b2584c43979c2d5b3f6b4e0d1294a8317127f533c0220b2`。派生身份 `com.example.dontForget.acceptance.perf-r39709822788`，全部实际读写在该容器新建目录；不执行通知、模型或录音。它是单独 profile 入口，不能代替产品 release 原生验收。性能结果与范围参见 [迭代记录](Iteration_v1.6.md)、[首次报告](benchmarks/workspace-profile-2026-10-22.json) 与 [复测报告](benchmarks/workspace-profile-repeat-2026-10-22.json)。复测有明显帧总耗时及存储耗时波动，保留原始值；性能稳定性仍待诊断。

本轮产品原生结果（时间为本机 UTC+8）：

| 验收项 | 实际证据与边界 |
| --- | --- |
| 原生恢复 | 新候选初始四区为空，保存独立空基线。通过文件选择器、结构预览、覆盖确认、勾选与恢复按钮导入本轮四条无密钥/无录音合成任务；10:30:55 恢复完成，三张业务表逐行匹配候选。首次回退目录 `recovery-409718f1-dbed-43fa-831d-91d3ef5af8fd` 保留空库。 |
| 未授权与提交状态 | 未授权时 UI 为 Not enabled，四条日志仍为 submitted，attempts=2；macOS 插件没有抛出权限错误。UI 明确 Submitted does not confirm delivery。本次不能把未授权情况称为真实失败重试。 |
| 授权与摘要刷新 | 在应用点击 Allow notifications，系统通知中心显示精确隔离身份，执行“允许”；应用自动更新 Allowed。四条未来记录显示 Upcoming 4 / Submitted 4 / Needs review 0 / Cancellations pending 0。 |
| 前台健康记录 | 10:33:20 至 10:34:21，持续 60.84 秒观察期间四条日志字节对应内容相同，尝试次数未增加。覆盖健康记录不重复安排；未产生 pending/failed 原生错误，不能称为失败自动重试通过。 |
| 系统送达 | 10:35:34.124，ID 1967836952 送达；10:35:34.131 系统展示 banner。10:36:34.106，ID 167290217 送达；10:36:34.111 展示 banner。均为本轮隔离应用，候选仍运行；这不是热/冷点击证据。 |
| 手动原生重建 | 到期后摘要 Upcoming 2 / Submitted 2；点击 Retry reminder scheduling，反馈 Processed 2 reminder schedules。两条未来任务 attempts 从 2→4，稳定 ID 1329258270 / 315234779 不变；两条已过期记录 attempts 保持 2，没有重放，也没有自动确认或修改 notice_revision。 |
| 通知点击阻塞 | 通知授权卡片可读取及操作，但到期通知中心 AX、图像和 ControlCenter 读取均报 timeoutReached。尝试 [Apple 文档](https://support.apple.com/en-us/102650) 的 Fn-N 入口时，原生工具报 keyNotFound("fn")。未成功点击通知；热点击、冷启动点击及迟到点击继续待验，不以系统送达替代。 |
| 清理与回退 | 10:38:56 经应用完整恢复空基线，四区均为 0，三张表逐行匹配原空库、integrity_check=ok，通知 epoch 已换代、日志为空。系统日志记录 removeAllDeliveredNotifications 并移除两条已送达记录；应用通知取消返回成功。四条合成任务保留在 `recovery-289e4c98-b305-4705-9c5c-4af761114b10/rollback.db`，没有直接删除业务数据或回退材料。随后正常退出，进程检查确认产品候选不再运行。 |

合成输入保存在 `/private/tmp/dontforget-journal-native-r39709820687`，前台前后与手动重建证据保存在 `build/native_acceptance/journal-r39709820687`。本轮没有新录音或云端请求；录音/播放仍允许后续验收，既有听感与标题输入待验项保持。两个本轮独立进程最终均已退出；性能程序退出后改用应用清单和进程核验，避免再次读取关闭窗口导致工具重新启动应用。

剩余任务：真实 pending/failed 条目在前台自动重试、通知热/冷/迟到点击；完整产品冷启动及通知对账、首次列表构建与备份优化、测量分段/前后台诊断；权限拒绝恢复、系统重启/休眠/时区/DST、多模型配置迁移与降级、其他平台业务真机及正式签名发布。

## 2026-10-22：阶段 3D-3 / 3C-4 候选与原生工具边界

产品源码 `5846c2b83bd23bf63173d9349d8a889f160d9a10` 包含批量备份、列表首屏优化和日志初始化前失败的会话重试修复。[CI 39715762698](https://github.com/yarnway/dontforget/actions/runs/39715762698) 质量和五平台候选全部成功；本机 650 项 Flutter、47 项 Python 通过，云端 Flutter 649 通过/1 跳过、Python 47 通过。版本仍为 1.5.2+3 / schema 9，非标签发布跳过。

- 原产品 ZIP：23,859,758 字节，SHA-256 `610ce835ed3d1970904d647ba35e690dd017e83d778b7dc72fb8e93b5a56b420`。清单与原包位于 `build/ci_artifacts/retry-r39715762698`，本机重新核验完整 revision、大小与摘要通过。
- 派生产品：`build/native_acceptance/retry-r39715762698/dont_forget.app`，独立身份 `com.example.dontForget.acceptance.retry-r39715762698`。受保护内容和派生 codesign 核验通过。实际启动到四区空工作台，进入设置，系统通知显示“未开启（尚未授权或已关闭）”；点击“允许通知”后没有取得授权通过证据。
- 原生工具对 NotificationCenter 和 ControlCenter 的读取报 `timeoutReached`。按完整路径打开新候选的工具调用耗时约 2404 秒，随后通过 bundle ID 重连才读到当前工作台；后续 Finder 调用耗时约 3361 秒后返回 `cgWindowNotFound`。这些时间属于外部工具调用，不计入应用启动、帧或存储性能。13:32 UTC+8 只读核对 Mac 的 `IOConsoleLocked=No`，不把失败归因于用户未解锁。没有要求用户再次手动操作。
- **本候选未导入四任务 fixture、未进行文件系统故障注入、未完成前台失败自动重试或通知热/冷点击。** `fault_readonly.py` 仅为本机隔离故障演练准备文件，没有执行，不产生故障验收结论。正常退出后只读核对进程不存在，schema 9、integrity_check=ok、Reminders=0、MediaRecords=0、Settings=1、通知日志 entries=0；记录在 `build/native_acceptance/retry-r39715762698/empty-readback.json`。本轮没有新增待发业务提醒或需要恢复的合成数据。

性能候选独立于产品包：

| profile 源码 / 构建 | 原生结果 |
| --- | --- |
| `0fb2143` / `39714494785` | 完整运行完成；三个规模存储、备份和九组列表均前台有效。完整通知对账使用记录器替代 OS 传输，一万条对账片段有 hidden 事件。 |
| `403da02` / `39715027992` | 包和隔离副本准备完成，未启动，未产生原生结果。 |
| `e78b3ff` / `39716514799` | 第一轮完成但前半失去前台，一万条存储/备份/列表有效；第二轮在 100 条/1440 片段隐藏后超时。原始成功与失败报告均保留，不合并或删除异常值。 |
| `41a9e54` / `39719290459` | 修复隐藏后清理并增加启动前台门禁；静态分析与 profile 构建成功，包及隔离副本核验通过，尚未完成原生运行验收。 |

最新性能 ZIP 为 27,821,226 字节，SHA-256 `d339c8f3ccf164900e96216bec80576cd11c63685a0e57b08fb66070950183b3`，源码 `41a9e54428323cfa04e0cf7f25fe09c93d19fe23`。独立副本 `build/native_acceptance/perf-clean-r39719290459/dont_forget.app`，身份 `com.example.dontForget.acceptance.perf-clean-r39719290459`。当前不存在该容器/进程的运行证据，不把 Finder 尝试视为启动成功。此前本轮已运行的基线与优化后性能进程已退出；没有操作旧 `permissions-r39575684866` 进程。

有效性能对比、四份原始报告、完整通知对账边界和下一步任务见 [阶段 3D-3 记录](Iteration_v1.6.md)。下一验收顺序为：新性能包完整前台复测与超时后重开；新产品隔离 fixture + 真实可回退故障后的前台自动重试；通知冷启动点击和热点击。通知授权/界面工具仍为本轮阻塞项，录音/播放允许但没有新增验收证据。原包、派生副本、容器与旧回退材料均保留。


## 2026-10-22：阶段 3D-4 / 3C-5 批量对账与前台失败重试

批量实现 `708586a9d167d0951d32290be368536278a54312` 的产品 CI 首次因 Linux 文件系统时序相关断言失败；`b722da66382043b5b7254f9957f116d6ff497ad6` 仅修订该测试，随后 [CI 39731158073](https://github.com/yarnway/dontforget/actions/runs/39731158073) 质量与五平台候选全部成功。云端 Flutter 657 通过 / 1 平台跳过、Python 47 通过，本机 Flutter 658 通过、静态分析无问题。非标签发布跳过，版本仍为 1.5.2+3 / schema 9。

- 产品 Mac ZIP 23,861,025 字节，SHA-256 `a6920f9007c5d53ba4f458c46f190d52d2bcb547ed2d57c4d139ec2e7f72355c`；完整 revision、大小、摘要及派生受保护内容和 codesign 均核验通过。原包位于 `build/ci_artifacts/batch-r39731158073`，副本为 `build/native_acceptance/batch-r39731158073/dont_forget.app`，新身份 `com.example.dontForget.acceptance.batch-r39731158073`。
- 独立 [profile CI 39730823023](https://github.com/yarnway/dontforget/actions/runs/39730823023) 使用 `708586a`。ZIP 27,827,626 字节、SHA-256 `fbbf60d0354b409ce06d415265094ad85deddafa61aa441bc74520bca59e37f5`；新身份 `com.example.dontForget.acceptance.perf-batch-r39730823023`。18 段全部前台完成，测量覆盖真实数据库和日志，OS 传输为记录器；原始报告和分规模数值见 [迭代记录](Iteration_v1.6.md)。完成后正常退出并确认进程缺席。
- 前一性能候选 `perf-clean-r39719290459` 本轮完成有效前台运行、主动隐藏超时、资源释放及同进程重跑。原始失败报告保留；重跑窗口高度多 1 逻辑像素，不能替代严格同尺寸配对比较。详见迭代记录，不再沿用上一节“尚未启动”状态。

产品原生验收由代理使用界面工具执行，未要求用户手动操作。首次 Flutter 按钮反馈没有更新，切入全屏后控件可用；系统授权卡片可以读取并执行“允许”。本轮数据仅包含四条合成文本任务，无 API 密钥、无录音。

| 验收项 | 证据与边界 |
| --- | --- |
| 原生恢复与权限 | 保存空基线后，通过选择器、结构预览、覆盖确认和勾选执行恢复，出现 Recovery complete；三张业务表逐行匹配 `candidate-v9.sqlite`。14:11:44 四条 schedule/submitted、attempts=2，权限 Allowed；空库回退位于 `recovery-f81a74bb-0747-4de5-8fc2-b68e8d80a5f7`。 |
| 可回退真实写入故障 | 精确隔离目录先核验 schema 9、四个合成 ID、正常日志和非链接路径，14:12:09 开始将目录 0755 临时改为 0555，最多 40 秒 finally 恢复。点击 Retry reminder scheduling 后原生 UI 显示 4/4 失败；失败期间日志字节不变，没有伪造 pending/failed 文件。14:12:49 恢复 0755，并独立核对。 |
| 前台自动补重试 | 之后未再点击 Retry，14:14:25.567–.594 四条 attempts 从 2→4，全部 schedule/submitted，四个 ID 不变，三张业务表逐行匹配原样本。14:18–14:20 再次读取仍为 4，健康计划没有重复重排。该证据验证日志写入前失败的会话内自动恢复；不等于 OS 插件报错、跨系统重启或后台运行验收。 |
| 系统送达 | 14:17:03、14:18:03 分别出现 ID 1967836952 / 167290217 的 Delivering、Presenting 与 displaying as banner 系统记录。候选当时仍运行，送达不能替代点击路由。 |
| 发现并修复的界面问题 | 自动重试成功后仍显示旧的“4 of 4 … still failed”。`ca7a3809941eb00887cc989c7d6cc10ac9c86d32` 将中英日文明确为上次手动重试结果，状态刷新/前台恢复时清除旧反馈；读取失败继续显示不可用。本机 660 项 Flutter 全量、20 项面板测试、静态分析通过。该修复不在本节原生 `b722da6` 候选中，不能把旧包实测记成修复包复测。 |

首轮输入及空基线在 `/private/tmp/dontforget-batch-native-r39731158073`；故障前后、自动重试、系统日志位于 `build/native_acceptance/batch-r39731158073`。原始用户容器和其他已运行候选未修改，全部回退副本保留。


为捕捉通知横幅，另生成 `/private/tmp/dontforget-batch-click-r39731158073` 并通过原生确认恢复，原四任务保留在 `recovery-679ebdc7-fb0d-4aa1-ae66-3166ebbf1ffa`。14:23:14 正常退出并确认原 PID 19557 缺席；14:26:26.139 系统向 ID 1967836952 送达，随即读取 NotificationCenter AX 和截图均 timeoutReached，14:26:57 候选进程仍缺席，没有执行冷点击。之后由工具显式重开候选（PID 34211），14:27:26.111 第二条系统送达时再次读取 AX+截图仍 timeoutReached，没有执行热点击。此次没有把显式启动、应用内到期横幅或系统送达写成通知点击通过。重开后的业务三表逐行未变、四个原生 ID 不变，已过期任务未被隐式确认。

14:28:37 通过原生覆盖确认恢复最初 `empty-baseline.json`，界面显示“恢复完成”并回到四区全 0；三张业务表逐行等于空基线、integrity_check=ok、通知 epoch 已换代且 entries=[]。应用取消全部 pending 请求返回成功，系统明确移除两条 delivered 通知。回退 `recovery-a5521eb9-69e5-4293-aea9-976d7469a71c/rollback.db` 与第二轮四任务样本逐行匹配，保留不删；目录权限保持 0755。正常退出后进程缺席，证据为 `cleanup-readback.json`、`system-cleanup-events.log`、`closed.json`。本轮没有新增录音、播放或模型服务请求。

当前剩余：通知热/冷/迟到点击仍受系统通知界面读取超时阻塞；权限拒绝后恢复、OS 插件真实报错、系统重启/休眠/时区/DST、完整产品启动与更大规模日志写入、恢复重建批次、多模型设置与迁移、其他平台业务及正式签名发布继续分阶段推进。录音/播放仍允许，听感未新增验收结论。


最终界面修复候选 `ca7a380` 的 Mac 包已由 [CI 39733597774](https://github.com/yarnway/dontforget/actions/runs/39733597774) 构建，本机独立校验完整 revision、ZIP 大小/摘要和派生签名。ZIP 23,862,545 字节，SHA-256 `36848d04f74da3ae1df33c068ce7a940412057943515e89cdc62fa6a7716f96e`；文件位于 `build/ci_artifacts/feedback-r39733597774`，独立身份 `com.example.dontForget.acceptance.feedback-r39733597774`。

在新空容器原生打开设置，点击“重新安排提醒”后显示“上次手动重试没有需要更新的提醒安排。”；点击“刷新状态”后旧反馈消失，摘要仍为全 0。未请求此身份的通知权限，未导入任务或发送通知；三张业务表与初始空库逐行相同，integrity_check=ok、journal entries=0，随后正常退出并确认进程缺席。证据 `build/native_acceptance/feedback-r39733597774/native-feedback-readback.json`。此原生复测验证最终包的中文历史结果和刷新行为；返回失败/异常、前台恢复刷新及读取失败显示不可用由 20 项面板回归覆盖，未把空队列称为再次真实故障演练。


最终 CI 独立回读：`39733597774` 整体 success，质量、macOS / Android / Linux / Windows / iOS 五个平台均 success，非标签发布步骤按条件跳过。云端 Flutter 659 通过 / 1 项平台跳过、Python 47 通过；本机 Flutter 660 通过、静态分析无问题。三桌面启动和 Windows 安装升级卸载属于 CI 内检查，未扩大为全部设备业务验收。代码已推送 main；本轮原生产品、最终面板候选与两个性能进程均正常退出，原包、隔离容器和回退材料保留。

## 2026-10-22：阶段 3D-5 写入优化与完整产品启动

源码 `a614f7dd1371af4bd86ac5e7c908af877e0df5ef` 的 [产品 CI 39736112657](https://github.com/yarnway/dontforget/actions/runs/39736112657) 质量和五平台均成功，云端 Flutter 662 通过 / 1 平台跳过、Python 50 通过，本机 Flutter 663 通过、静态分析无问题。版本仍为 1.5.2+3 / schema 9；未发布正式签名版本。

| 产物 | 完整性与范围 |
| --- | --- |
| 常规产品 Mac ZIP | 23,862,086 字节，SHA-256 `5b05e1623a9c95318d3f6f7c95984e7c594e90949040a16f80fc83e4c769bb6a`，位于 `build/ci_artifacts/native-r39736112657`。 |
| profile ZIP | [测量 CI 39736121636](https://github.com/yarnway/dontforget/actions/runs/39736121636)，27,830,666 字节，SHA-256 `5634b273b984e03d5756cdf3f66bedda2a835227d6feab49517ba9320ad373cc`。 |
| 产品启动测量 ZIP | 同一测量 CI 独立 release 产物，23,885,186 字节，SHA-256 `82a856b4308e7c7bf89ebe40c23c183a4ec63ca89a04c98ab25dafb5288ba69f`。真实产品入口加被动计时，不能冒充未开启计时的常规发布包。 |

三种包均重新核验完整源码 revision、大小、摘要；所有派生副本的受保护内容和 codesign 验证通过。profile 使用全新 `perf-r39736121636` 身份，18 段全部前台完成，原任务/通知副本摘要与阶段 3D-4 相同。万条首次 / 重开对账为 12.575 / 22.917 秒、1,255 / 1,254 次原子替换；累计写入 1.297 / 2.588 GB。OS 传输是记录器，完整指标与原始报告见 [迭代记录](Iteration_v1.6.md)。profile 完成后正常退出并确认进程缺席。

完整产品测量使用 `cold100-r39736121636`、`cold1000-r39736121636`、`cold10000-r39736121636` 三个独立身份。空容器初始化退出后，在 owner lock 下插入相同 2099 合成业务行，不伪造 journal、不访问用户运行库；样本逐行摘要校验通过。应用由原生工具启动，采集器在进程仍运行时校验 bundle/PID，并读取内核进程创建时间。百条 / 千条 / 万条首次 / 万条已有日志重开的完整就绪时间分别为 0.320 / 1.326 / 19.595 / 28.880 秒；全部完整报告 outcome=complete，万条重开 ID 与业务行不变。

这四次启动均 visible=true、focused=false、lifecycle=inactive：属于工具默认后台启动的新进程测量，不是全程前台、系统重启或清空磁盘缓存后的启动。首帧是 raster 完成信号，万条首帧早于任务加载；不能把 0.28 秒写成万条任务已显示。测量身份未申请通知权限，真实调度 API 返回成功不等于 OS 保留/送达全部请求。原始证据：[产品启动报告](benchmarks/product-startup-3d5-2026-10-22.json)。

所有测量候选随后通过原生文件选择、结构预览、覆盖确认和勾选恢复空基线，界面显示恢复完成；只读验证三张表逐行与空基线一致、integrity_check=ok、journal entries=[]。回退副本分别含 100 / 1,000 / 10,000 条原任务且摘要与样本一致，保留在以下 recovery 目录；候选进程均已正常退出：

- 百条：`recovery-35dbd90e-5e83-4096-bafd-862d64864130`。
- 千条：`recovery-9696c261-71ad-40fb-a295-b71bb11b3e40`。
- 万条：`recovery-65448309-8c32-4b1a-b125-68d979957666`。

本机系统 Python 3.9 解析 Dart 的 UTC Z 后缀失败，`d2e2ad0` 已修复只读采集器并新增回归，51 项 Python 通过；该修复不改变上述二进制或通知业务逻辑。

### 阶段 3C-6：权限拒绝后恢复

常规产品派生身份为 `com.example.dontForget.acceptance.native-r39736112657`。代理直接操作原生界面：系统授权卡片选择“不允许”，系统设置该身份显示 off，应用显示 Not enabled；原生确认恢复四条无密钥合成提醒后仍明确未开启。此时 OS 调度 API 已返回成功，日志四条 submitted/attempts=2，界面没有把 submitted 当成权限允许或送达。

随后仅在系统设置中开启此隔离身份，临时将其提醒样式设为持续以便点击验收；应用点击 Refresh status 后显示 Allowed。点击 Retry reminder scheduling 后显示处理 4 条安排，四条 attempts=4、schedule/submitted，原生 ID 与三张业务表均未变。证据为 `build/native_acceptance/native-r39736112657/{denied,allowed}-readback.json`。这关闭权限拒绝、系统开启、刷新和手动重排的闭环，不扩展为拒绝期间送达或自动补发过期提醒。

### 通知冷启动点击与热点击：本候选通过

本次使用持续提醒并在通知可见时重新绑定 NotificationCenter，取得精确隔离通知的 AX 内容。此前临时横幅的读取超时仍保留原记录；本轮新证据不追溯修改旧包结论。

| 验收 | 原生证据 |
| --- | --- |
| 冷启动点击 | 15:14:57 正常退出且进程缺席；15:16:44.119 系统向 ID `1967836952` 送达 `QA 1 ACK DUE`，通知 UUID `19D5E035-5C8B-485E-9A07-6015D0EEBF84`。15:16:56.754 点击后系统记录 contents response，15:16:56.758 明确 Launching … for response；随后先通过进程只读检查发现 PID 73568，再绑定已运行窗口。实际页面为 Task Details / QA 1 ACK DUE / 15:16 / Once，未手动启动代替点击。 |
| 工具结果核对 | 冷点击后继续读取已经关闭的通知窗口返回 noWindowsAvailable；该错误不等于点击未发生。没有重放点击，通过系统 response/launch、精确新进程和目标详情页三方确认动作生效。 |
| 热点击 | 15:17:44.122 系统向 ID `167290217` 送达 `QA 2 SNOOZE DAILY`，UUID `F953AE15-56E5-4082-A92B-79051FC4CF27`。15:17:49.286 点击，系统向同一 PID 73568 回调 response；页面切换到 Task Details / QA 2 SNOOZE DAILY / 15:17 / Daily。 |
| 数据与 ID | 点击后业务三表逐行与 fixture 一致，无隐式确认/完成/延后。冷启动只重排三条仍在未来的任务，attempts=6；已到期第一条保持 attempts=4。四个原生 ID 均未改变。 |
| 清理 | 原生确认恢复 `empty-baseline.json`，显示恢复完成并回到四区全 0；三表逐行匹配初始空库、integrity_check=ok、epoch 换代、journal entries=[]。完整四任务回退保留在 `recovery-37c8d53f-d356-4e24-b6c1-738f0d397bcf/rollback.db`，逐行匹配输入样本。候选正常退出且进程缺席，仅该身份的提醒样式恢复为临时，通知权限保持 Allowed。 |

可审阅证据：[权限与点击记录](benchmarks/notification-native-3c6-2026-10-22.json)、[冷启动目标页](benchmarks/notification-cold-click-3c6-2026-10-22.png)、[热点击目标页](benchmarks/notification-hot-click-3c6-2026-10-22.png)。现场原始日志和回退核验位于 `build/native_acceptance/native-r39736112657`；本轮全部 profile、启动测量与通知产品进程均已退出，历史隔离身份和用户数据未清理。

最终源码 `d2e2ad0442090b1924d990931399a64854960830` 的 [CI 39738261734](https://github.com/yarnway/dontforget/actions/runs/39738261734) 质量及五平台全部成功：Flutter 662 通过 / 1 平台跳过、Python 51 通过，静态分析无问题。`d2e2ad0` 与实测产品 `a614f7d` 仅差 Python 采集器兼容修复及其回归测试，没有应用代码差异。三桌面启动、Windows 安装升级卸载属于 CI 检查，未扩大为其他平台业务真机验收。

本阶段完成：通知日志写入优化、同数据集完整前台 profile、完整产品后台新进程启动基线、权限拒绝后恢复、Mac 通知冷启动与热点击、隔离恢复清理。剩余：完整产品前台重复测量与日志增量存储、恢复重建批次、旧 epoch/已删任务/迟到通知点击、OS 调度失败与系统重启/休眠/时区/DST、多模型迁移与降级、其他平台业务与正式签名发布。录音和播放仍允许，本轮未新增录音或听感验收。

## 2026-10-22：阶段 3D-6 完整产品前台与万条恢复

实测应用源码 `25e5abe27b72f5e5d393116f50bf131301988327`，版本仍为 1.5.2+3 / schema 9。本机完整 Flutter 665 项及 Python 51 项通过；随后仅增加跨批次回滚回归的 `e6b1addd5c921111756dc7bc5ff5135cf78a7eea` 本机完整 Flutter 666 项通过、静态分析无问题。[最终 CI 39745407814](https://github.com/yarnway/dontforget/actions/runs/39745407814) 质量与五平台全部成功，云端 Flutter 665 通过 / 1 平台跳过、Python 51 通过；与实测包没有应用代码差异。

| 产物 | 核验结果 |
| --- | --- |
| 常规产品，[CI 39742373065](https://github.com/yarnway/dontforget/actions/runs/39742373065) | 23,865,013 字节，SHA-256 `410f96e530f5b72bb09ed26344e0ccb1b570049de2fb2a579eb21ab1fde96de8`。 |
| profile，[CI 39742418043](https://github.com/yarnway/dontforget/actions/runs/39742418043) | 27,843,504 字节，SHA-256 `b1e6cfedf006ab47ed4d288b1d992cd8e3a33bd2a8716e0726ed7b70b5bbf10c`。 |
| 产品启动测量，同一测量 CI | 23,876,836 字节，SHA-256 `5932551eb3f1d7f0a9b91d5d1fef58e01ba2398d85699a9fdd840888bc9f1645`。 |

三包均核验完整 revision、字节大小和摘要；派生副本受保护内容与 codesign 通过。`basefg10000-r39736121636` 与 `optfg10000-r39742418043` 通过原生 Finder 双击得到全程前台样本，一次空日志首次、三次已有日志重开，各轮任务摘要和稳定 ID 不变。旧/新首次为 20.239/7.673 s，三次重开中位数 29.108/9.776 s。两份未满足前台规则的样本保留并排除后重跑；不是系统重启或清空缓存后的测量。

`perf-r39742418043` 的 18 个片段全部前台；真实 SQL/provider/journal，OS 传输为记录器。万条首次/重开写入从 1.297/2.588 GB 降至 0.173/0.334 GB，通知恢复重建首次基线 1.814 s，范围不含备份检查和 SQL 替换。列表、备份与完整原始记录见 [阶段 3D-6](Iteration_v1.6.md) 和 [profile](benchmarks/notification-startup-3d6-profile-2026-10-22.json)。

新产品测量候选原生恢复同一万条 JSON，三表逐行一致、epoch 换代、10,000 条日志成功且 ID 保持。随后新旧启动候选均原生恢复空基线并正常退出，通知 journal 为空，回退万条摘要一致。新候选两份回退分别是 `recovery-4978579d-1c67-42e8-bf61-596ac2a26da4` 和 `recovery-b88d2335-53d6-4d44-85b2-f17ab25c999e`；旧候选是 `recovery-601bef38-2c7f-4291-950e-7b6fdd04a56c`。profile 也已退出，数据及报告保留。[产品各轮和恢复清理记录](benchmarks/product-startup-3d6-2026-10-22.json)。

## 2026-10-22：阶段 3C-7 通知点击边界

常规产品 `25e5abe` 两个全新隔离身份由原生工具操作。系统权限均已允许，只在验收期间将该身份的提醒样式设为持续。没有修改系统时钟、真实用户数据或直接操作系统通知存储。

| 场景 | 证据与结论（UTC+8） |
| --- | --- |
| 已删除任务 | `native-r39742373065` 的 QA 2 在 16:08:28.096 实际送达，UUID `0520A527-26B8-45D8-A565-3E3D2637FF57`。16:08:55.429–16:09:35.435 仅 journal 权限 0644→0000→0644，40 秒 finally 恢复；数据库目录未锁写，journal 字节未改。UI 删除任务成功并提示取消通知失败。16:10:05.612 真正的 contents response 到达已有 PID 11041，工作台保持三条任务，没有详情路由或复活数据。后续自动重试把该 ID 写为 cancel/submitted。通知堆叠展开本身不算点击，只有记录到系统 response 的动作纳入验收。 |
| 旧数据身份 | `epoch-r39742373065` 原生恢复一条 QA OLD EPOCH。退出并确认进程缺席，在 owner lock 下调用生产 epoch store 于 16:15:09.971 换代，保存前后身份和未修改的 journal；业务数据与系统通知均未修改。旧通知 16:16:16.114 送达，UUID `DB2D4A3B-9971-456F-AA31-9F4405A6634C`。16:16:53.158 点击、16:16:53.162 系统 Launching，产生 PID 21264；当前任务留在工作台，未进入详情，三表未变。此项只证明中断状态下的旧 epoch 拒绝，不把模拟当成完整恢复执行。 |
| 迟到冷启动 | `native-r39742373065` 的 QA 1 到期 16:07:28.403，系统 16:07:28.087 送达（原生调度秒级边界），UUID `C09BB76A-C5C8-49BA-B27E-42A41928DF1A`。正常退出且进程缺席后，16:24:20.168 点击，16:24:20.173 系统 Launching，先读回 PID 27009 再绑定窗口；正确详情显示 QA 1 ACK DUE / 16:07 / Overdue / Once。迟到 16 分 51.765 秒，三表与删除后状态完全相同，无隐式确认、完成或延后。15 分钟仅是冷启动补发现到期提示的范围，已展示提示不会因此自动清除。 |
| 清理与回退 | 两身份原生恢复空基线，三表等于最初空库、integrity_check=ok、journal 空，正常退出且进程缺席。三任务/一任务回退分别保存在 `recovery-4c3506d3-681e-4807-bd35-2e89fd2557b1` / `recovery-bd487d13-5f72-4e85-9e5a-f554a9cc257c`，逐行核对通过。通知样式均恢复临时，Allowed 权限保留；故障权限已恢复。 |

[系统事件、界面状态及数据核验](benchmarks/notification-native-3c7-2026-10-22.json)，[迟到冷启动详情](benchmarks/notification-late-click-3c7-2026-10-22.png)。原始材料保留在两个 `build/native_acceptance/<identity>` 目录；没有清理历史隔离环境或用户容器。截图也暴露了详情页中文硬编码和内部 ID 文案，后续 `88ab248` 修复；本节截图和通知点击结论仍归属于实测 `25e5abe`，不混称新文案包已验收。

剩余：日志增量方案及崩溃一致性评估，固定高度的列表首帧重复测量；真实 OS 调度失败、系统重启、休眠、时区/DST；多模型持久化/迁移/设置与降级；其他平台业务、正式签名发布。录音/播放允许，本轮没有新增听感验收。

### 文案修复候选独立复核

`88ab2484add63e42f60d22b99ef5151afa40fa19` 的 Mac ZIP 为 23,865,073 字节，SHA-256 `6b8c727b2cae5c5d34c3ff62102406160aa1d83e9e1ba0bfa6d5cd0242245283`，清单、完整 revision、摘要和派生 codesign 核验通过。新身份 `copy-r39747956305` 原生恢复同一条合成英文输入，直接打开详情核对 Click to change、Linked input record、Play / preview attachment；内部 `qa-synthetic-text` 不再显示。[原生截图](benchmarks/task-detail-copy-3c7-2026-10-22.png) 与 AX 状态已保存。此项只验证新包展示，没有播放或模拟通知点击。

随后原生恢复空基线并正常退出，三表逐行匹配初始空库、journal 空、integrity_check=ok；一任务和输入记录回退保留在 `recovery-6482d94e-c722-4c20-a1e0-003e9ee54b9f`，逐行匹配 fixture。本轮所有新建原生验收进程均已退出，原包、合成数据、回退及测量报告均保留。

最终 [CI 39747956305](https://github.com/yarnway/dontforget/actions/runs/39747956305) 对应 `88ab248`，质量及五平台全部成功；云端 Flutter 665 通过 / 1 平台跳过、Python 51 通过，本机完整 Flutter 666 通过。未触发标签发布；构建和桌面启动检查不扩大为其他平台完整业务验收。


## 2026-10-22：阶段 3D-7 固定高度与崩溃恢复评估

`ae9e88d` 的性能构建 [39752935632](https://github.com/yarnway/dontforget/actions/runs/39752935632) 成功，派生 `fixed-r39752935632` 后完成三轮完整前台测量：54/54 片段有效，无错误；同一 fixture 的三个规模摘要与 3D-6 相同，全部 162 次挂载均为目标宽度 × 792、DPR 2。万条 1440 宽的三轮首帧 build p50 为 12.00/11.91/10.19 ms，合并 15 样本 p50/max 为 11.65/17.59 ms。保留首个候选被可用屏幕高度限制而拒绝的记录；修正仅压缩测量页固定状态区域，不修改产品看板。

[完整固定视口证据](benchmarks/fixed-viewport-3d7-2026-10-22.json)。组件首帧不等于产品启动；通知对账使用记录器，不等于 OS 批量送达。宽屏尾部仍超过 16.67 ms，保持待优化。

增量日志评估读取上一轮关闭的万条合成备份，只写独立临时目录。三个 JIT 进程均在重放/检查点后得到与 v1 相同状态；追加字节显著降低，但本原型写入和未压缩重放更慢，决定保留生产 v1。12 项实验/生产崩溃回归覆盖逐字节尾部截断、损坏拒绝、代际/稳定 ID 和七个子进程 SIGKILL 边界；不等于断电、真实 OS 故障或系统重启。[实验数据与限制](benchmarks/incremental-journal-3d7-2026-10-22.json)。

## 2026-10-22：阶段 3C-8 OS 回调与新候选原生验证

修复 macOS 插件没有等待 UNUserNotificationCenter add completion 的问题，失败可进入现有持久重试；取消、权限、点击委托和稳定 ID 保持一致。最终 [CI 39752932522](https://github.com/yarnway/dontforget/actions/runs/39752932522) 质量及五平台成功，本地 679 Flutter / 51 Python 通过；云端 Flutter 678 通过 / 1 平台条件跳过、Python 51 通过。Mac 候选 `ae9e88d` 派生为 `os-r39752932522`，原始 ZIP/hash/签名与派生身份验证通过。

完成情况：
1. 两条合成任务在未授权和明确拒绝权限后，真实系统回调均成功、日志 submitted；界面保持未开启状态。此平台行为不作为调度失败证据。
2. 系统设置恢复该隔离身份 Allowed；正常退出后重开，业务三表和原生 ID 保持一致。
3. 系统 17:24:50.125 送达 QA OS RESULT RECOVERY；进程退出后，17:25:14.269 点击触发系统冷启动，新 PID 76539 打开正确详情，业务三表无改动。
4. 原生恢复空基线，journal 空，回退库保留两条完整合成任务；确认进程缺席，提醒样式恢复临时。全部三张业务表逐行核验通过。

剩余任务：真实 OS add 拒绝后的持久重试、跨系统重启、睡眠、时区/DST。系统菜单读取 timeoutReached，睡眠键 keyNotFound，因此睡眠未执行；开机时间前后仍为 2026-10-13，未发生系统重启。没有修改锁屏/电源保护，也没有退出其他用户应用。不能把模拟错误或本轮应用重开记为这三项通过。多模型配置、其他平台业务、正式签名发布继续后续阶段。

[机器可读证据](benchmarks/notification-os-callback-3c8-2026-10-22.json) · [冷启动正确详情](benchmarks/notification-os-callback-3c8-2026-10-22.png)。录音和播放允许，本轮未新增录音或听感验收。

## 2026-10-22：阶段 3D-8 宽屏新候选与崩溃恢复

看板源码 `6205968338d7f278cd1749a1f55d3379f6c72657` 的 [测量构建 39757723420](https://github.com/yarnway/dontforget/actions/runs/39757723420) 成功。profile ZIP 为 27,878,189 字节，SHA-256 `0bbdcc07d7a4941a7852cc9ade9721c5a26ee024d87f1ba1d65e343b56cde084`；完整清单、源码 SHA、派生受保护内容和 codesign 校验通过，隔离身份为 `com.example.dontForget.acceptance.wide-r39757723420`。

完成情况：

1. 三轮 54/54 片段为全程前台，errors 为空；全部 162 次看板挂载为目标宽度 × 792、DPR 2。三个规模与上阶段任务及通知副本摘要相同。
2. 万条 1440 宽首帧 build 的合并 15 样本 p50/max 为 11.30/15.86 ms，375 宽为 7.18/8.36 ms；768 宽为 12.78/17.44 ms，有两次超过 16.67 ms。旧基线 768 宽最大值为 14.89 ms，不能忽略这项反向变化。先前一次中途失焦轮次全量保留并排除，再取得第三轮有效样本。
3. 只读交替 JIT 诊断显示四区数据投影 p50 从 150 µs 减至 92 µs；它不测 Flutter 帧，不足以解释上述 768 宽波动。新旧原生测量相隔约一小时，仍需同一时段交替运行。
4. 增量索引和每 24 帧检查点使用同一万条夹具，在独立临时目录完成三个进程的等价复测；分段末尾只重放 8 帧，约 34–38 ms。26 项日志实验回归通过，五个万条子进程 SIGKILL 边界核对完整状态和全部稳定 ID。没有执行断电、系统重启或真实 OS 通知，生产仍为 v1 日志。
5. 测量包正常退出，最后一次精确进程检查确认 wide、fixed 和 probe 三个本轮目标均无进程。历史隔离数据、回退副本和测量目录保留，没有清理用户容器。

[原生前台帧与排除样本](benchmarks/wide-first-frame-3d8-2026-10-22.json) · [纯投影诊断](benchmarks/board-projection-3d8-2026-10-22.json) · [索引、分段及崩溃边界](benchmarks/indexed-segmented-journal-3d8-2026-10-22.json)。这里的看板挂载不等于产品冷启动，记录器对账不等于系统通知送达。

## 2026-10-22：阶段 3C-9 OS 负例候选与权限阻塞

`5367a8b0ef18de4ee7e62182e02e7dd37fc0961a` 的 [产品 CI 39758791793](https://github.com/yarnway/dontforget/actions/runs/39758791793) 及 [测量构建 39758794353](https://github.com/yarnway/dontforget/actions/runs/39758794353) 均成功。含单任务 OS 负例入口的 profile ZIP 为 27,900,592 字节，SHA-256 `0c0e729d8c052602176b476618a9d31a149141ce0d19775371fd2013deb7ad40`；源码、文件清单及派生签名验证通过，身份为 `com.example.dontForget.acceptance.probe-r39758794353`。它是独立验收工具，未进入正式产品入口。

探针计划对一条 2099 年合成任务改变发出的空内容或过去日期，仍调用生产桥及真实 OS API；不能伪造错误。重开时读取同一独立目录的原有日志，不主动调度，便于验证 failed 持久化和同 ID 的有效请求重试。后续 `7be2d91` 源码增加完整初始化成功门禁、错误类型及清理失败记录；普通异常不得算作真实 NSError。该工具修订尚未打入已准备的 `5367a8b` 包，原生验收前需重建并核验。

| 验收项 | 本轮结果 |
| --- | --- |
| 用户授权 | 已明确允许操作旧 `fixed-r39752935632` 与新 `probe-r39758794353`。 |
| 旧版交替对照启动 | 授权后工具仍返回 `Computer Use was not approved to use 别忘了·隔离验收 fixed-r39752935632`，没有启动新的测量。 |
| 单任务 OS 探针启动 | 工具返回相同类型拒绝，目标为 `别忘了·隔离验收 probe-r39758794353`。探针未启动、未提交 OS 请求。 |
| OS 拒绝、failed 重开和同 ID 重试 | 未执行。只有未来读到 `native_schedule_failed` 与真实 OS domain/code 才可计入；API 接受负例不能记作失败。 |
| 系统重启、睡眠/唤醒 | 未执行，没有将应用退出或测试子进程 SIGKILL 记作系统验收。 |

这属于原生工具尚未取得两个 app 的操作权限，用户授权本身已有记录；本轮没有反复要求手动点击、改应用身份或使用其他自动化绕过。最后确认两个目标均无进程，候选与合成数据留存。[准备与阻塞证据](benchmarks/notification-os-probe-3c9-2026-10-22.json)。

主体源码 `3ccd1fe` 的 [CI 39783468820](https://github.com/yarnway/dontforget/actions/runs/39783468820) 质量与五平台全部成功，云端 Flutter 694 通过 / 1 平台条件跳过、Python 51 通过；本机 Flutter 695 项、Python 51 项通过。主体产品代码与原生测量 `6205968` 一致；后续验收工具的改动另列源码与检查，CI 不替代被阻塞的原生步骤。

`7be2d91` 同时修复测试子进程对 PATH Dart 的隐式依赖，改用当前 Flutter SDK 配套可执行文件；在原先失败的 PATH 环境下，静态分析和完整 695 项测试通过。最终 [CI 39802691717](https://github.com/yarnway/dontforget/actions/runs/39802691717) 工作流 completed/success，质量为 Flutter 694 通过 / 1 平台条件跳过、Python 51 通过，Android/iOS/macOS/Windows job success。Linux 构建、原生启动、包摘要核验、上传及 Complete job 步骤 success，但顶层仍返回 in_progress/null；独立 job 接口及无缓存回读一致，保留为汇总字段差异，未将其改写成 job success。该提交仅涉及验收工具、诊断脚本及测试，没有产品 `lib/` 或 macOS 代码差异。

剩余任务：同一时段旧/新交替测量和 768 宽尾部排查；真实 OS 拒绝、failed 跨进程保留及同 ID 重试；系统重启、睡眠/唤醒、时区/DST；增量日志迁移/所有权/大小边界/代际回收；多模型持久化与降级、其他平台业务及正式签名发布。录音和播放允许，本轮未新增相关实测。

## 2026-10-23：阶段 3D-9 同期交替测量与诊断候选

完成情况：

1. 早期工具权限拦截在用户补充授权后解除，继续操作原旧/新身份。A→B→A→B→A→B 各三轮默认完整 profile，108 个区段全前台，三档数据的 task/notification 哈希一致；固定高度 792、DPR 2，324 次挂载中有 270 个测量首帧，全部 build <16.667 ms。新版一次未取得前台的尝试保留，不计入统计。
2. 万条任务 768 宽 build p50/max：旧版 10.731/14.301 ms，新版 10.565/14.148 ms。未复现之前 17.443 ms 尾部，不能据各三轮认定异常已消除或归因。375/1440 的全部样本和原始报告、启动/备份/日志统计均留存于[六轮记录](benchmarks/alternating-first-frame-3d9-2026-10-23.json)。
3. 新版万条存储启动各轮 p50 60.104–60.815 ms，备份 148.171–153.376 ms，完整已有日志重开 3.247–3.333 秒，日志写入仍约 334 MB / 162 次替换。通知统计使用记录运输层，不能作为 OS 送达或完整进程冷启动。
4. `9ebcffe`/`1476353` 的自身 VM 诊断、清理完成门禁和未知状态必须重开已实现；本机 Flutter 700、Python 56 和静态分析通过。[产品 CI 39812209714](https://github.com/yarnway/dontforget/actions/runs/39812209714) 质量及五平台成功，云端 699 通过 / 1 平台跳过、Python 56 通过；[测量 CI 39812302641](https://github.com/yarnway/dontforget/actions/runs/39812302641) 两项成功。
5. 诊断包 `diag-r39812302641` 完成外层摘要/CRC/白名单、内部 manifest/hash、受保护内容及 codesign 核验。用户解锁后，两轮各五帧真实自身 VM 采集均全前台完成，状态恢复成功。两轮分别 3/5、4/5 帧出现 UI 线程新生代 GC 区间，约 2.0–3.9 ms；嵌套时间不相加，插桩额外分配尚不能与普通尾部建立因果。压缩原始报告与[首轮](benchmarks/frame-trace-summary-3d9-2026-10-23.json)/[重开后](benchmarks/frame-trace-after-restart-summary-3d9-2026-10-23.json)分析留存，不混入普通基线。

受控最小化保持超过 10 秒，实际 TimeoutException 后 report failed / restart_required=true。重复启动/切换普通模式无效，目录数未变；旧 PID 缺席后新进程完成采集。第一次最小化被工具观察提早恢复，虽然 complete 但失焦，分析器拒绝。[超时与重开门禁](benchmarks/frame-timeout-gate-3d9-2026-10-23.json)。

剩余：复现并据未插桩证据优化 768 宽尾部后默认协议复测；增量日志/索引和分段检查点仍需迁移、所有权、大小边界及代际回收。[完整机器记录](benchmarks/frame-diagnostics-3d9-2026-10-23.json)。

## 2026-10-23：阶段 3C-10 OS 请求、进程重开与权限观测

完成情况：

1. `probe-r39807412561` 来自 [CI 39807412561](https://github.com/yarnway/dontforget/actions/runs/39807412561)，源码 `2da0c33709f08f017a887d76b04fb79c84d7fb78`。ZIP 27,901,155 B，SHA-256 `339663804fdb44211ef8e110bf317125f9d1b43152da5f132c40e1218eec3c37`，摘要、manifest、受保护内容及派生签名核验通过。它是隔离 profile 工具，非正式签名产品。
2. 单条合成任务的空内容、过去日期请求均被真实 macOS 接受，报告为 `probe_accepted_by_os`。没有真实 NSError，不写成系统拒绝。
3. 退出 PID 27291、确认进程缺席后重开 PID 30041，读回同一会话的 submitted/native ID `733214976`。有效请求复用该 ID，取消后通过 API 确认 pending 为空。[原始事件](benchmarks/native-os-probe-3c10-2026-10-23.json)。这不是 failed 跨进程验收，也不是系统重启。
4. 探针未请求权限，所以当时不在系统通知列表中。`c545302` 增加显式请求按钮和独立权限/pending 读回，每次记录真实授权、alert/sound 与 pending IDs，未知值不改写为已授权。本机静态分析和 700 项 Flutter 测试通过并推送 main。[产品 CI 39889437264](https://github.com/yarnway/dontforget/actions/runs/39889437264) 质量及五平台、[测量构建 39889484900](https://github.com/yarnway/dontforget/actions/runs/39889484900) 两项均成功。
5. 新 `probe-r39889484900` 的 manifest/hash/签名核验通过。实际拒绝权限，系统开关 off、应用 notEnabled，但有效请求仍被 OS 接受，pending 为 `[733214976]`。退出 PID 4353 并确认缺席，重开 PID 5974 保留拒绝状态、submitted 日志和 pending；系统开关恢复 on 后读回 granted，同 ID 重提后仍只有一条。没有把拒绝授权写成调度 NSError。[权限闭环原始记录](benchmarks/native-permission-probe-3c10-2026-10-23.json)。

6. 电源验收先保存请求/日志/boot-session 检查点。一致读回：wake 设置需要 root，非交互管理员调用需要密码，没有创建测试 wake；`pmset sleepnow` 返回 71 / not permitted `0xe00002e2`，系统菜单读取 timeoutReached。电源日志查询成功但没有新增 Sleep/Wake/DarkWake，boot-session 未变，故未执行实际睡眠或系统重启。新探针最后取消并读回 pending 为空，本轮五个隔离进程退出，数据保留。[电源尝试记录](benchmarks/power-gates-3c10-2026-10-23.json)。

剩余：真实 `native_schedule_failed` + OS domain/code、failed 重开和同 ID 重试；正常电源操作能力可用后的系统重启、睡眠/唤醒、时区/DST；多模型持久化/迁移/设置及降级、其他平台业务和正式签名发布。录音和播放允许，本轮未新增相关实测。锁屏由用户解锁，电源/安全策略和其他用户应用保持原状。

## 2026-10-23：阶段 3D-10 GC 关联与普通模式复测

完成情况：

1. 旧包 `3f6efeb` / [CI 39900595838](https://github.com/yarnway/dontforget/actions/runs/39900595838) 与优化包 `19c6a40` / [CI 39901693129](https://github.com/yarnway/dontforget/actions/runs/39901693129) 两项构建均成功，外层/内部摘要、manifest、保护内容和派生签名核验通过。新身份 `gc-before-r39900595838`、`gc-after-r39901693129`，同一关闭万条夹具 SHA-256 `ffe48931fba0f93c79c3f0c60daaa0dc0e3dcfa26f1210d82c7ccd531203e669`，三档任务与通知行摘要逐项相同。
2. 两包各三轮 GC 观察，共各 90 帧，固定 768 × 792 / DPR 2，全程前台、组件 profiling 关闭、每轮只在全部挂载后读一次自身 VM 时间线。优化前 44 帧含同 UI 线程 GC，其中 22 帧 build >16.667 ms；46 帧无该 GC 重叠，全部低于预算。优化后分别为 35 帧中 9 帧超预算、55 帧中 0 帧。是关联证据，不是唯一因果；先旧三轮再新三轮，不与普通模式合并。[样本与压缩原始时间线](benchmarks/gc-observation-3d10-2026-10-23.json)。
3. 产品投影共用一个时刻并避免逐行 Duration 分配后，默认模式 A→B→A→B→A→B 各三轮、108 区段均前台。万条 768 宽 build p50/max 从 12.458/20.134 ms 到 9.474/12.444 ms，超预算 3/15 → 0/15；375 为 7.101/8.062 → 6.773/8.968 ms，1440 为 11.960/17.507 → 9.833/15.483 ms。全部规模优化后仍有千条的两帧超预算，GC 观察仍有 9/90，不宣称尾部消失。[六轮全部原始数据](benchmarks/gc-reduction-standard-3d10-2026-10-23.json)。
4. 一次后台工具全屏切换使实际宽度 1512 而非 375，视口门禁拒绝，失败记录保留。修正为正常窗口并 Raise 后重跑，没有剔除任何有效慢帧。存储启动、备份、记录运输层通知对账均留存，不作为完整进程冷启动或 OS 送达证据。

剩余任务：扩大跨进程及多机器采样，继续排查 GC 观察和千条规模尾部；生产通知日志写放大仍约 334 MB / 万条重开，由增量阶段单独解决。[方法与分析器](GC_Frame_Measurement.md)。

## 2026-10-23：阶段 3D-11 有界增量原型

完成情况：

1. `c8bea54` 增加 manifest/检查点/日志段/帧上限与非普通文件拒绝，超大预检保持已发布状态，容量不足要求检查点轮换。原型不由产品导入，生产仍使用 v1。
2. 34 项专项回归通过，覆盖原有崩溃/损坏/链/epoch/ID 边界与八项新大小、链接、容量测试。SIGKILL 不等于断电一致性。
3. 同一关闭夹具以三个全新 JIT 进程复测，v1/索引/每 24 帧检查点均在重放及最终检查点后等价。已有日志写入阶段中位数分别为 900.045 / 119.849 / 242.816 ms；索引与分段重放中位数为 135.610 / 39.610 ms，段尾 80 → 8 帧。分段减少重放但增加检查点成本。[全部三轮与范围](benchmarks/incremental-journal-3d11-2026-10-23.json)。
4. 本机 Flutter 713、Python 61、静态分析通过；[最终源码 CI 39902735238](https://github.com/yarnway/dontforget/actions/runs/39902735238) 五平台与质量全部成功，云端 Flutter 712 通过 / 1 条平台条件跳过、Python 61 通过。最终产品代码与已原生复测优化包一致，未发布正式 v1.6。

剩余任务：生产迁移/回退、跨进程租约、目录总量、读者安全代际回收和断电一致性。此处是日志组件实验，不是产品原生启动或 OS 调度性能验收；[边界说明](Incremental_Journal_Experiment.md)。

## 2026-10-23：阶段 3C-11 真实 OS 失败与同 ID 重试

完成情况：

1. 新隔离身份 `origin-r39889484900` 使用已核验的 `c545302` / CI 39889484900；保护内容及签名通过，相同文件内容的副本从受控临时安装路径启动。正常内容、正常模式和 2099 触发时间的请求收到真实 `native_schedule_failed`，OS details 为 `UNErrorDomain` / code 1，没有注入异常。
2. PID 68635 的 failed 日志在退出并确认缺席后，由新 PID 70756 原样读回；有效请求再次真实失败，同 native ID `733214976`、同 epoch，attempts 2 → 4，pending 始终空。
3. 再退出并确认缺席，从正常验收路径启动同身份、同文件内容的包，PID 71719 读回 failed 后有效重试成功。submitted 沿用同 ID，重复提交 pending 仍仅 `[733214976]`；取消后为空。此过程使用显式重试按钮、生产通知服务/日志/原生桥；相关源码与当前 main 一致。
4. 该身份全程 notEnabled，没有将 pending 成功算作授权或送达。受控安装来源负例不推断所有临时路径或拒权都会报错。两个性能身份和 OS 探针均正常退出，精确路径进程检查为空，回退材料保留。[完整八次事件及产物核验](benchmarks/native-os-retry-3c11-2026-10-23.json)。

剩余任务：真实 OS 错误在完整产品前台自动重试协调器中的验收；系统重启、睡眠/唤醒、时区/DST；多模型配置与其他平台业务、正式签名发布。应用进程重开没有替代系统重启。本轮录音/播放允许，未新增相关实测。

## 2026-10-23：阶段 3D-12 同夹具分配优化与 GC 补测

完成情况：

1. 先以相同二进制、相同千条/万条数据对比测量壳主题：12 轮有效、360 帧，另保留 2 次失焦。缓存主题本身未稳定改善万条尾部，后续产品对比两边都固定为 cached theme。[壳校准](benchmarks/gc-shell-3d12-2026-10-23.json)。
2. 只读子任务解析缓存和窄屏焦点节点惰性创建后，旧 `49c0cc1` / 新 `8b1961e` 默认普通模式各三轮交替，108 区段均前台、270 帧。千条/768 p50 9.699 → 8.940 ms，万条/768 11.360 → 10.094 ms，全规模超预算帧 4 → 1。三档行摘要一致，全部有效慢帧及排除原因保留。模型复用和预热会填充新缓存，不代表首次解析或完整进程冷启动。[完整六轮](benchmarks/product-allocation-3d12-2026-10-23.json)。
3. 旧版与最终 `9dca8cb` 的千条/万条 GC，各三轮、每组 90 帧，固定 768×792 / DPR 2、widget profiling 关闭、30 次挂载后只读一次自身时间线。千条慢帧 7 → 2，万条 16 → 11；无同 UI 线程 GC 重叠的帧均未超预算，但万条 max 18.651 → 19.272 ms。分组顺序和补测均明确，不推断独占因果。[分析和压缩原始数据](benchmarks/gc-product-3d12-2026-10-23.json)。
4. 最终源码又完成一轮普通完整 profile，18 个区段前台、45 个测量帧；万条/768 仍有一帧 20.113 ms。单独报告，未合并进前述三轮比较。[最终回归](benchmarks/final-profile-3d12-2026-10-23.json)。记录运输层的完整通知对账不能作为真实 OS 调度或完整产品冷启动证据。

剩余任务：跨进程/机器扩大采样，继续定位千条及万条剩余慢帧；不以 p50 改善宣称尾部消失。本轮没有新增完整产品冷启动性能测量。

## 2026-10-23：阶段 3D-13 租约、迁移回退与回收实验

完成情况：共享数据库目录租约、生产 v1 选择器门禁、保留原始 v1 的迁移、最新状态导出回退及中断恢复、前代固定与受管文件回收已实现。目录限制 256 MiB / 256 文件，链接拒绝，未知普通文件保留并计入限制。56 项日志专项回归涵盖新增 9 个 SIGKILL 边界、租约互斥/释放、外部冲突及容量；单所有者 isolate 和协作锁约束明确。

同一关闭万条夹具以三个新 JIT 进程比较，全部模式的重放、回退及再次迁移后状态、epoch、ID 等价。已有日志写入中位数从 v1 的 900.489 ms / 162,678,720 B 到带租约分段的 296.216 ms / 10,649,386 B，重放/回退/再次迁移成本分别记录。[全部结果](benchmarks/leased-journal-3d13-2026-10-23.json)。

剩余任务：生产后端接入、版本化升级/降级、多平台锁和断电持久性；生产默认仍为 v1，组件实验未充当原生产品验收，SIGKILL 未充当断电。

## 2026-10-23：阶段 3C-12 完整产品前台自动重试闭环

完成情况：

1. `9dca8cb` / [测量 CI 39918373329](https://github.com/yarnway/dontforget/actions/runs/39918373329) 的 release 产品入口加被动轨迹，源码、manifest、摘要和派生签名通过；独立身份 `foreground-r39918373329`。真实通知运输、HomeScreen 与 Provider 保持产品路径。
2. 同一合成夹具派生一条 2099 任务；字节相同的临时来源程序 PID 1495 实际收到 `native_schedule_failed / UNErrorDomain 1`。failed 与 ID `1846708357` 落盘，退出并核实缺席后，正常路径 PID 1970 于一分钟内重开，保留同一 epoch/ID/attempts=2，触发启动冷却门禁。
3. 系统权限未启用时前台协调器 attempted=0，failed 未丢失。原生工具恢复焦点并读到 resumed 后，通过系统设置开启该隔离身份通知；正常心跳 attempted=1 / failed=0，同 ID submitted、attempts=4，真实 OS pending 为 `[1846708357]`。没有点击手动重排、改时钟或改日志时间。后续心跳 attempted=0，pending 未重复。
4. 通过产品删除合成任务，cancel/submitted、attempts=5，pending 为空；任务数 0、schema 9、integrity_check=ok。空基线/合成输入/清理后三份一致 SQLite 备份及全部轨迹保留，所有隔离应用正常退出。[完整证据](benchmarks/native-foreground-retry-3c12-2026-10-23.json)。

剩余任务：系统重启、休眠唤醒、时区/DST；其他平台业务和正式签名。此处 pending 是系统接受，非送达；应用重开不是系统重启。录音/播放允许，本轮没有新增相关实测。

## 2026-10-23：验证后存储清理

完成情况：本机 Flutter 739、Python 63、静态分析通过后，核实进程缺席和无打开文件，清理 42 个旧隔离程序、过期已验摘要包、重复 ZIP/下载分片及项目缓存，目录占用减少 4.37 GiB。清理清单记录每条路径、类别和保留元数据；实际整盘可用空间变化另列，避免把 APFS 克隆占用当作独占物理回收量。

最终两个程序/原包、旧版性能对照/原包、Library 容器、同夹具、SQLite 与回退材料均保留，一个缺准备清单的旧程序也保留。没有处理用户数据、共享 SDK/依赖或无关脏文件。[清理证据](benchmarks/storage-cleanup-2026-10-23.json)。剩余：后续候选完成替代验收后再轮换当前保留资产。

最终工作流 `3a0772c` / [CI 39927785276](https://github.com/yarnway/dontforget/actions/runs/39927785276) 的质量与五平台全部通过，含 Linux/macOS/Windows 原生启动、Windows 安装升级卸载及包摘要验证。Linux 下载源修订与 GStreamer 显式运行时修复均通过；这不替代 Linux 桌面媒体或通知业务验收。相对已验 `9dca8cb`，产品和测量源码未变化，仅构建工作流修订；main 构建没有发布 release。[CI 与验证明细](benchmarks/phase-validation-2026-10-23.json)。
