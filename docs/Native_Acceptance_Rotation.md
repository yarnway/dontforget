# 原生验收共享桌面限时轮换协议

更新日期：2026-10-28（Asia/Shanghai）。本协议当前为待确认提案；写入状态文件不代表任何任务已经同意预约，也不授予桌面、设备或客户端访问权限。

## 参与任务与当前状态

| 任务 | Chat ID | 新轮换请求状态 |
| --- | --- | --- |
| 增加提醒通知快捷操作 | `01a18064-4ca8-7643-9100-2df4460110be` | `WAITING_CLIENT_PERMISSION` |
| 评估 DontForget 的 UX/UI 优化点 | `01a17c24-05d0-7273-ac6c-a2e578ad2c8b` | `NEEDS_ACK` |
| 优化项目架构与产品体验 | `01a15c7c-8a67-7562-9db6-e540460d05c1` | `NEEDS_ACK` |

所有工作区统一使用同一个规范绝对路径：`/Users/james/gitresources/opensources/dontforget/build/native_acceptance/shared-desktop-rotation.json`。不得按各自 worktree 的相对路径创建第二份状态。实时交接状态保存在该文件；该文件位于本机验收目录，不作为成功验收结果。初始顺序“通知 → UX → 架构”仅为提案，未登记绝对开始时间或已确认的下一任务。每一轮仅由受影响的当前持有方与下一接收方确认；未确认的未来任务不阻止已获明确交接的当前轮次。

本轮通知任务曾收到用户“共享桌面已明确归还”，但客户端仍拒绝访问目标隔离应用；该任务已于 **11:42:31 +08:00 明确退还桌面**，状态为 `EXPLICITLY_RETURNED_WITHOUT_UI_CONTROL`，没有取得或继续占用 UI。证据为 `build/native_acceptance/trust-actions-20261028-1130-materials/desktop-handoff.json`。当前桌面 owner 未确认，不应据此推断空闲或由通知任务持有。

物理 iPhone 另有 UX 任务在 **10:33（分钟精度）** 接收的 `EXCLUSIVE_RECEIVED` 交接，要求明确归还。`study-stage39-materials/phone-handoff-extension.json` 另记载 11:01:39 延长至 11:45、`requiresExplicitHandback=true`；未见明确归还。当前验收 phone bundle 为 `com.yarnway.dontforget.acceptance.p1current28`，另一个 `com.yarnway.dontforget.acceptance.iphone17` 是需保护的其他身份。因此到达预计时间后仍保护 UX 的物理 phone ownership。不得将该交接混同为通知任务可以使用 phone，也不得将独立 phone owner 推断为当前共享桌面 owner。

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

本次初始状态已记录：跨任务发送轮换提案及创建 automation 均被工具以 `MCP tool call requires approval, but approval policy is never` 拒绝，未发送、未创建。该失败不等同于其他任务拒绝方案，更不等同于获得了他们的 ACK。工具恢复或用户提供明确交接证据前，保持上述 pending 状态。

## 每轮最小交接记录

每轮记录任务 ID/标题、实际开始与预计释放时间、精确 bundle/设备、验收目标、下一任务及其确认、实际归还时间、自己创建的通知/数据收尾结果、未保存编辑、需保护资产与证据路径。构建、系统提交、实际送达、动作回调、queue 消费及清理分别登记，不将轮换顺利或 UI 可操作当成产品验收通过。


本任务下一轮仅使用修复后候选：`/Users/james/gitresources/opensources/dontforget/build/native_acceptance/trust-actions-20261028-1130-timing/dont_forget.app`，源码 `623c525`，主程序 `dontforget_trust_actions_1130`。它已构建并验证签名，但未启动；权限等待状态不授予 UI。
