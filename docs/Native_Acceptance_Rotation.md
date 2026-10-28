# 原生验收共享桌面限时轮换协议

更新日期：2026-10-28（Asia/Shanghai）。协议已获得参与任务确认并执行首轮；实时归还状态见规范 JSON。写入状态文件本身不授予桌面、设备或客户端访问权限。

## 参与任务与历史归还快照

| 任务 | Chat ID | 新轮换请求状态 |
| --- | --- | --- |
| 增加提醒通知快捷操作 | `01a18064-4ca8-7643-9100-2df4460110be` | `EXPLICITLY_RETURNED`（13:26:30） |
| 评估 DontForget 的 UX/UI 优化点 | `01a17c24-05d0-7273-ac6c-a2e578ad2c8b` | `ACK_NEXT_20_MINUTES`，实际接收另登记 |
| 优化项目架构与产品体验 | `01a15c7c-8a67-7562-9db6-e540460d05c1` | `EXPLICITLY_RETURNED`（12:05:50） |

所有工作区统一使用同一个规范绝对路径：`/Users/james/gitresources/opensources/dontforget/build/native_acceptance/shared-desktop-rotation.json`。不得按各自 worktree 的相对路径创建第二份状态。实时交接状态保存在该文件；该文件位于本机验收目录，不作为成功验收结果。初始提案当时使用“通知 → UX → 架构”，没有绝对开始时间或已确认的下一任务；本轮实际协调顺序与交接另见下方。每一轮仅由受影响的当前持有方与下一接收方确认；未确认的未来任务不阻止已获明确交接的当前轮次。

通知任务早期因客户端拒绝控制而于11:42:31归还，这是历史记录。12:05本轮跨任务消息已成功送达并取得ACK：架构先安全归还，UX再因等待人手锁定手机将Mac交给通知任务。通知任务实际取得12:14:32、预计释放12:34:32，控制准确623c525候选成功；因Mac随后锁屏，于**12:26:27提前明确归还**。第一轮归还时规范状态revision9；该轮锁屏状态为历史，第二轮见下方。每次下一方仍需明确接收，不能按截止时间自动转移。

实际回执：`build/native_acceptance/trust-actions-native-time-623c525-materials/round1-ui-handback.json`。第一轮当时1130最小化/运行中，Quit被锁屏阻止，六条合成记录与通知保留；该待清理状态已在第二轮闭合。旧1110含未知归属记录，继续保护。

物理iPhone的旧UX租约已于11:44:44明确归还，回执为`/Users/james/.codex/worktrees/p0-record-reminder/dontforget/build/native_acceptance/p1-ui-native-20261028-102820/native-handoff-return.json`，不再沿用“未归还”的旧推断。架构后续QA40清理与人手使用导致连接不可用；UX已承接p1current28保护和待清理项。通知任务本轮从未使用phone或Mirroring，也不将Mac的交接等同于phone使用权。`com.yarnway.dontforget.acceptance.iphone17`仍是独立受保护身份。

## 一把共享 UI lease，独立保护物理手机

Mac 共享桌面、键盘/指针、通知中心以及 iPhone Mirroring 使用同一把 UI lease。任一时刻只允许一个已确认 owner 执行会影响这些表面的操作。后台构建、静态检查、独立文件读取等不使用共享 UI 的工作可继续，但不得在无 UI lease 时抢前台、发送键盘输入、点击通知或接管镜像。

物理 iPhone 的既有独占交接独立有效。操作手机或镜像必须同时满足：共享 UI lease 归本任务、phone owner 明确授权/归还给本任务、客户端权限允许。获得其中一项不能代替其他条件。不得越过锁屏、因截止时间过去而抢占手机，或终止其他任务的进程、通知、测试及设备会话。

## 每轮默认 20 分钟

1. **提出请求。** 写清任务 ID、计划时长（默认 20 分钟）、精确 bundle ID、验收目标、是否需要物理 phone，以及希望交给的下一任务。bundle 或目标未明确的请求保持 `NEEDS_ACK`，不能开始计时。
2. **确认接手条件。** 先读取最新 JSON、现有独立 phone 交接及当前 owner 的明确归还。当前持有方明确归还，下一任务确认自己的时间与目标；不额外要求所有未来任务一致同意。工具能力授权与客户端权限必须另行满足。当前 owner 未知时先确认，不通过查看屏幕猜测 ownership。
3. **实际取得后登记。** 只有真实完成交接并具备 UI 控制权限后，才设 `ACTIVE`，填写实际 `acquired_at`、由该时刻计算的 `expected_release_at`、`owner_task_id`、精确 bundle、目标及已经确认的 `next_task_id`。时间使用带 `+08:00` 的 ISO 8601。接收到一句归还但客户端拒绝控制时，不登记虚构的 acquired 时间。
4. **到点收尾。** 默认预计释放时间为实际接手后 20 分钟。到点只提示当前 owner 收尾，owner 进入 `CLOSING`；不会自动清除 owner、偷锁或授予下一任务。若提醒/automation 未成功创建，必须如实登记，不能声称计时提醒已生效。
5. **需要延期。** 在截止前说明未完成项、所需分钟数和新的预计释放时间，并取得下一任务确认；不得单方面滚动延长。确认未到时保留当前 ownership、暂停新场景并收尾，不能伪造已批准延期。若已超时，优先向下一任务说明阻塞和归还安排。
6. **明确归还。** 当前 owner 记录实际 `returned_at`、应用/设备状态、未保存编辑、自己创建通知的清理或保留情况、需保护的原始通知/数据及证据路径，并明确说“共享桌面已归还”。未完成的业务验收可以记为 partial，不以占用时间到期代替验收或清理。
7. **下一任务接手。** 下一方先读取归还记录，确认精确目标和剩余独立 phone 条件，再明确确认接收并记录新的实际时间。前一方明确归还和下一方明确接收之间，owner 保持待确认，不能将提案自动升级为成功预约。

结束本轮后可再次排队；只读状态或等待回复不占用 UI。原始/日常应用的数据、通知、运行状态和 rollback 资产始终不属于当前验收轮次的清理范围。

## 状态与时间字段

- 请求可处于 `PROPOSED`、`NEEDS_ACK`、`WAITING_CLIENT_PERMISSION` 或 `READY_AWAITING_EXPLICIT_HANDOFF`；这些状态均不授予 UI。
- 真实接手后为 `ACTIVE`，接近/超过预计时间后为 `CLOSING`，明确归还后为 `EXPLICITLY_RETURNED`。权限受阻且未控制 UI 时可记录 `EXPLICITLY_RETURNED_WITHOUT_UI_CONTROL`。
- owner 未确认时使用 `OWNER_UNCONFIRMED` 与 `owner_task_id: null`；预计或提案时间不能填入 `acquired_at`。
- `expected_release_at` 是收尾目标，不是自动过期的租约。`explicit_return_required` 始终为 true。
- 所有新轮次在未被该轮受影响方确认时保留 `reservation_confirmed: false`；不知道的 bundle、目标、时间或下一任务使用 null，不补猜测值。

## 原子状态写入与独立文件锁

元数据统一使用独立锁 `/Users/james/gitresources/opensources/dontforget/build/native_acceptance/shared-desktop-rotation.lock`，仅保护 JSON 的读改写；不得复用数据库、notification journal 或其他任务的业务锁。**这个文件锁不代表 UI ownership。** 锁文件可以长期存在；判断 ownership 以 JSON 和明确交接证据为准，判断写锁是否占用用内核 advisory lock，不以文件存在或 mtime 决定抢占。

首次初始化如已发现同名协议、状态或锁，先只读核对，不覆盖、不删除。更新已有状态需参与者遵守以下顺序：

1. 拒绝 symlink/非普通文件；打开既有独立 lock 文件并尝试独占 `flock`。占用则等待协调，不删锁、不偷锁、不升级权限绕过。
2. 持锁重新读取 JSON，校验 schema、当前 `revision`、owner 和交接条件；若与预期 revision 不符，重新核对并放弃旧写入。
3. 在同目录写唯一临时文件，限制权限为 `0600`，flush/fsync 后以 rename 原子替换 JSON，并同步目录；更新 `revision`、`updated_at` 及简短 history。
4. 读取校验新 JSON 后释放元数据写锁。释放写锁不会归还 UI；UI 的明确归还必须另行登记。

初始尝试跨任务消息和automation曾被工具拒绝，未发送/未创建；该历史失败已保留。12:05后消息工具成功，参与者ACK与实际交接均已写入规范状态。旧有截止提醒未创建，新增安静跟进另见末尾，不宣称自动接管已生效；本轮由实际时间和明确归还收尾。第一轮Mac锁屏已由用户手动解除；当前剩余为通知中心选窗工具限制，不再误报为应用控制权限拒绝或Mac未解锁。

## 每轮最小交接记录

每轮记录任务 ID/标题、实际开始与预计释放时间、精确 bundle/设备、验收目标、下一任务及其确认、实际归还时间、自己创建的通知/数据收尾结果、未保存编辑、需保护资产与证据路径。构建、系统提交、实际送达、动作回调、queue 消费及清理分别登记，不将轮换顺利或 UI 可操作当成产品验收通过。


第一、二轮当时仅使用修复后候选：`/Users/james/gitresources/opensources/dontforget/build/native_acceptance/trust-actions-20261028-1130-timing/dont_forget.app`，源码`623c525`，主程序`dontforget_trust_actions_1130`。其自检、三语未来重排、独立注入队列重启及本身份清理已有证据；第三轮发现用户配置后停止将其作为纯测试库，后续改用1430，见末尾。真实OS动作菜单/回调与退出后原生响应仍开放。后续仍须重新确认UI交接，不能根据曾授权或预计时间取得控制权。

历史上建立的每15分钟锁屏跟进（automation `dontforget`）已删除：手动解锁已完成，当前固定选窗限制无法通过周期重试解决。删除跟进不代表全部原生验收通过，也不授予任何任务UI使用权。


## 第二轮归还状态（13:26:30）

用户已确认Mac手动解锁、通知中心展开；UX另外收到phone已锁定/USB连接确认。消息交叉时通知任务已持规范锁写入revision13并实际接手，UX确认未开始UI操作、同意等待该段结束；其独立phone后台元数据/Documents只读准备获准，不启动/终止app、不写phone、不操作共享UI。

通知任务实际接收13:13:57，预计释放13:33:57，**13:26:30提前明确归还**给UX候接，回执`build/native_acceptance/trust-actions-native-time-623c525-materials/round2-ui-handback.json`。1130经产品正式恢复空基线，DB0/0/1、schema16、integrityok、native pending/retained0/0、queueempty、journal0、repair/cancel0，自身Quit后isRunning=false；六行回退材料保留，旧1110及日常/phone数据未改。归还后不再操作UI，UX仍须登记其新20分钟的实际接收；架构任务随后与UX协调，不因13:33:57到期抢占。

注入队列6动作/3过期/2重复、跨重启旧动作重放和恢复代次轮换后旧队列丢弃已通过。实际OS按钮/三语菜单/前后台回调/退出后原生时间转交仍受Cua只选择“月”widget的限制，不能把注入测试当成这些结果。当前任务仍partial，后续需可选择真实通知卡的控制入口或人工原生动作配合。实时owner与revision以规范JSON为准。


## 第三轮与下一纯测试身份

架构13:58:43归还后，通知任务13:59:57接收至原定14:19:57。下位UX对“首个OS菜单已定位”的条件延期未激活；实际14:24:27归还，超出原计划的部分仅安全收尾。回执`build/native_acceptance/trust-actions-native-time-623c525-materials/round3-native-20261028-1400/ui-handback.json`记录应用Quit、native0/0、原通知样式恢复、两条自建记录软删。1130发现非基线用户设置，整行保留，不整库恢复、不再继续seed；含配置本地副本保持私有。原生动作来源未建立，也不以缺少日志否定OS回调。

第三轮归还后的准备快照：新1430独立包与20项纯工具自测当时仅准备完成，未启动。当时下一短探测需当前owner明确归还与root实际接收，先验独立UserNotificationCenter入口/持续系统卡，不能用过去的14:19或14:29推断拥有窗口。phone ownership仍独立。每5分钟安静跟进已重新启用并改为新1430；保护旧1110和含用户配置的1130，禁止按旧空基线自动重置。实时owner、顺序与实际截止仍以规范JSON为准。

## 第四轮短探测与明确归还（14:57:33）

UX14:53:34明确归还后，架构确认通知任务5分钟候接。新1430实际Cua控制成功，root登记14:56:35接收、预计15:01:35归还；14:57:33因`com.apple.UserNotificationCenter`被控制工具以安全原因明确拒绝，提前归还架构候接（canonical当时revision30）。回执`build/native_acceptance/trust-actions-20261028-1430-materials/round4-probe/ui-handback.json`。没有绕过拒绝或继续占用；phone仍UX所有，不随Mac桌面归还。

1430仅正常bootstrap和点击本身份权限请求，结果未观察到；未seed、未排程、未改通知样式。已正常Quit、DB0/0/1、schema16、integrityok、既有owner/pending锁空闲、pending文件不存在。设置页初始native0/0，后续刷新未完成，不能声称读到新的最终系统队列。旧1130用户配置与两条可恢复删除数据、旧1110及日常/其他任务状态均保护。下一次真实动作必须有新的可执行控制条件与明确交接。15:02跟进只读确认仍无该条件后已删除：ownership轮询不能解除控制安全拒绝，任务仍partial；不会自动重试被拒入口，也不要求用户点击已清理旧卡。

## 第五轮人工系统动作与清理归还（15:51:09）

用户明确愿意实际手动点击受限系统按钮，形成新的可执行条件。架构明确交回空闲Mac-only20分钟，root实际15:24:04接收、原定15:44:04；下一任务明确ACK延长至15:49:04。15:51:09明确归还，超出延期截止125.035秒仅做已开始的正式恢复、权限/样式恢复、最终读回和Quit，无新增场景。回执`build/native_acceptance/trust-actions-20261028-1430-materials/round5-manual-native/ui-handback.json`，canonical当时revision35；phone同期由UX另行归还架构候接，root从未操作，不混入Mac交接。

七条1430通知均有用户实际点击、精确native ID的OS response和业务副本证据；zh/en/ja菜单抽样人工确认，两次真正退出后启动新PID。两条英文窗口焦点运行路径与三条日文后台路径分开记录；日文skip虽然case名有fg，实际后台，不按名称补猜。未调用受拒UserNotificationCenter，也未绕过限制。具体边界见专属验收记录。

先保全七行完整rollback，再通过现有产品RecoveryCoordinator恢复本轮pure空基线。最终DB0/0/1/schema16/integrityok/hashb2，系统实际读回pending/retained0/0，pending为空；原permissionoff/临时样式恢复，最终Quit且Cua读回false。1130含用户配置、旧1110未知数据、daily及其他任务状态均保护。归还后本任务仅只读副本、日志和文档，不再使用UI；下一架构任务须按其真实接收登记新时段，不按15:49或15:51时间自动接管。
