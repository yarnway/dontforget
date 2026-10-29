# 交给 Gemini 的剩余任务提示词（DontForget · 2026-10-29）

> 用途：把本项目**尚未完成**的任务，拆成可以直接粘贴给 Gemini（编码代理）执行的提示词。
> 每条提示词**自包含**（含仓库上下文、硬约束、验收标准、必须运行的命令），按顺序一条一条执行；一条通过验收后再发下一条。
> 当前基线：`HEAD=ce79a5f`、版本 `1.7.0+44`、schema 16；Windows 全量测试 2022 通过 / 20 跳过、`flutter analyze` 0 issues；安装包已产出在 `dist/`。
> 最新状态与证据：`docs/Windows_Acceptance_2026-10-29.md`；iOS 步骤：`docs/iOS_Device_Acceptance_Runbook.md`。

---

## 0. 先发给 Gemini 的“通用约束”（每条任务都会重复关键几条，这里给完整版）

把它放在每条任务提示词的最前面，或单独先发一次并声明“后续所有任务都遵守”。

```
你是 DontForget 仓库（D:\gitspace\opensources\dontforget，Flutter 3.47.2 / Dart 3.13.2 本地，CI 固定 3.44.9）的编码代理。
技术栈：Flutter + Riverpod + sqflite(sqlite3 FFI)，目标平台 Windows/macOS/Linux/Android/iOS，数据库 schema 16。

硬约束（违反视为任务失败）：
1. 不得为了让测试变绿而修改或弱化已有断言；只能改产品代码，或对确实依赖 POSIX 语义的用例显式 skip 并在文档写明原因。
2. 不得提交或输出任何用户数据、数据库、凭据、设备画面；验收证据只能放 build/native_acceptance/<日期>/（build/ 已被 .gitignore）。
3. 不创建/推送 Release、标签或 RC；不执行 git push；不删除他人未提交的改动。
4. 工作区可能有其它会话的并发改动：动手前先 git status；提交时只 git add 你改动的文件，禁止 git add -A。若发现无关文件被改动，保留不动并在报告中说明。
5. 不修改版本号除非任务明确要求；不新增数据库迁移，除非任务明确要求并同步 schema 夹具与兼容测试。
6. 每个任务结束必须运行并通过：flutter analyze --no-pub、该任务相关测试；涉及 Windows 运行时的还要 flutter build windows --release --no-pub。
7. 报告必须区分“已通过（含证据路径）”与“未验证/受限”，禁止把源码测试或构建通过写成真机/设备通过。

报告格式（固定）：
## 变更摘要
- 文件 → 改了什么 → 为什么
## 验证
- 命令 → 结果（通过/失败，关键数字）
## 证据
- 路径（截图/日志/JSON）
## 未完成与风险
## 提交
- commit hash（若允许提交）
```

---

## 1. 任务总览

| 编号 | 任务 | 类型 | 依赖 | 建议顺序 |
| --- | --- | --- | --- | --- |
| P1 | 启动补发 / 汇总“错过的提醒” | 源码+UI+测试 | 无 | 1 |
| P2 | 窗口位置与尺寸持久化 | 源码+测试 | 无 | 2 |
| P3 | 录音容器与时长（ADTS/MP4、250 ms 保护） | 源码+测试 | 无 | 3 |
| P4 | Windows Toast 点击回跳（+动作按钮） | 原生+源码 | P1 可并行 | 4 |
| P5 | i18n 硬编码清理（托盘/Toast/提示） | 源码+测试 | 无 | 5 |
| P6 | CI 增加 Windows 测试作业 + 锁定版本一致性 | 工程 | 无 | 6 |
| P7 | 生产身份 `com.yarnway.dontforget`（含数据目录迁移） | 原生+兼容 | P6 | 7 |
| P8 | 文档同步（README / CHANGELOG / 架构 / 发布策略） | 文档 | P1–P7 | 8 |
| P9 | iOS 真机验收（需 macOS） | 设备 | P0 全部 | 9 |
| P10 | iOS 无 Mac 静态预检（可选，替代 P9 的降级） | 文档+检查 | 无 | 9' |

---

## 2. 逐条提示词（直接复制粘贴）

### P1 — 启动补发 / 汇总“错过的提醒”

```
【通用约束】遵守本对话开头给出的“硬约束与报告格式”。本任务只改与本任务相关的文件。

背景：Windows/Linux 桌面没有系统级通知排程，提醒只在应用运行期间由进程内 Timer 触发。
当前行为：启动后只有 15 分钟内到期的提醒会被 home_screen 的 _checkDueReminders 补发；
更早的逾期提醒既不补发也不汇总，用户重启应用后完全看不到（今天已确认的“漏提醒”问题）。
参考代码：lib/providers/providers.dart（启动分批同步、_requiresPastCancellation、_synchronizeReminder）、
lib/ui/screens/home_screen.dart（_checkDueReminders）、lib/services/notification_service.dart（fireReminderNow）。

目标：应用启动时，把“上次运行以来错过”的提醒**聚合**成一张卡/横幅，而不是逐条弹系统 Toast（避免刷屏）：
1. 定义“错过”的口径：triggerTime 已过、未被确认（noticeAcknowledgedAt 为空）、仍在可提醒状态（canNotify）、
   且距今不超过 72 小时（常量可配置）；同一 occurrence 不重复计入。
2. 启动完成、remindersProvider.ready 之后计算一次错过集合。
3. UI：在首页已有“提醒时间已到 · N”横幅区域复用/扩展一个“错过的提醒 · N”入口，点开进入现有列表并按“错过”筛选；
   提供“全部知道了”操作（写 noticeAcknowledgedAt 或等效的已查看标记），操作后入口消失且重启不再出现。
4. 不逐条调用 Windows Toast；如需系统提示，最多弹一条聚合 Toast（正文“有 N 条提醒已错过”）。
5. 中英日三语文案齐全（现有 l10n 机制），不得硬编码中文。
6. 不新增 schema 迁移；若必须新增字段，先说明并用现有 details_json/settings 方案替代。

验收标准：
- 新增单元/组件测试覆盖：空集合、1 条、多条聚合、72 小时边界、已确认不再计入、三语与 375/768/1440 宽度渲染。
- 手动验证（Windows）：创建 3 条时间分别为 10 分钟前、2 小时前、3 天前的提醒 → 重启应用 → 只出现聚合入口，计数为 2；
  点“全部知道了” → 入口消失；再次重启 → 不再出现。
- flutter analyze --no-pub 0 issues；全量 flutter test --no-pub 通过（或仅新增失败，需修复后再报）。
- 更新 docs/Windows_Acceptance_2026-10-29.md 的“仍需处理”第 1 条与 W2 计划状态，并记录证据路径。
```

### P2 — 窗口位置与尺寸持久化

```
【通用约束】同前。本任务只涉及窗口状态持久化。

背景：桌面窗口目前每次启动使用固定尺寸（windows/runner/main.cpp 1280x720；main.dart 里 window_manager 设 1000x700），
没有保存用户调整后的位置/尺寸/最大化状态，重启就丢失。
目标：
1. 持久化窗口位置、尺寸与是否最大化；上次关闭时若在托盘隐藏态，下次启动正常显示（不要启动即隐藏）。
2. 存放到现有 Settings 表（settings.settings_json 或等效字段，禁止新增 schema 迁移）；写入在窗口移动/缩放结束后防抖（≥500ms），
   退出前再写一次。
3. 恢复时做边界校验：若保存的位置在屏幕外（换显示器/分辨率变化），回退到主屏居中；尺寸不得小于最小窗口尺寸、不得大于当前屏幕可用区域。
4. 首启（无保存值）保持现有默认尺寸。
5. 中英日文案不涉及；不得影响 macOS/Linux（用 Platform.isWindows/Linux 分支或 window_manager 统一能力）。

验收标准：
- 单元测试覆盖：解析非法值回退、越界回退、最大化标记、首启默认值。
- 手动验证（Windows）：调整窗口到非默认位置/尺寸 → 完全退出（托盘退出）→ 重新启动 → 位置尺寸一致；
  最大化 → 退出 → 重启 → 最大化；把保存值改成屏幕外 → 重启回退居中。
- flutter analyze --no-pub 0 issues；相关测试 + 全量通过。
- 更新 docs 与 W2 计划状态，附证据。
```

### P3 — 录音容器与时长（ADTS/MP4、250 ms 保护）

```
【通用约束】同前。本任务只改录音相关代码与测试。

背景：录音固定用 .m4a 扩展名，但 Windows 的 record 插件写入的是 ADTS AAC（裸流），
而 lib/services/recording_duration_reader.dart 只解析 MP4 moov，导致 Windows 上时长解析失败；
home_controller 里 250ms 最短录音保护在 Windows 失效（会把过短录音当成有效音频保存/上传）。
参考：lib/services/recording_duration_reader.dart、lib/providers/home_controller.dart（录音起停、时长校验、扩展名）。

目标：
1. recording_duration_reader 支持 ADTS AAC：按 ADTS 帧头解析采样率/声道/帧数估算时长；无法解析时返回 null 而不是抛错。
2. 是否改用 .aac 扩展名：按实际容器决定扩展名（Windows 用 .aac，iOS/macOS/Android 保持 .m4a），并保证播放器（audioplayers）与备份/媒体表路径一致。
3. 250ms 最短录音保护对两种容器都生效；过短录音删除文件且不写 MediaRecords。
4. 旧数据兼容：历史 .m4a 文件仍能读取时长并播放，不得迁移或重写已有文件。
5. 不加新依赖（不引入 ffmpeg 类库）。

验收标准：
- 单元测试：构造 ADTS 帧头样例解析、截断/损坏帧返回 null、MP4 仍正常、过短录音被拒绝、扩展名与平台映射。
- 手动验证（Windows）：录 0.1 秒（应被拒绝/提示过短）、录 3 秒（保存成功、时长正确显示、可播放）；
  完成后检查 Documents\media\import-*\ 下扩展名与文件头一致。
- flutter analyze 0 issues；全量测试通过。
- 更新 docs 的“录音细节”条目。
```

### P4 — Windows Toast 点击回跳（+ 动作按钮）

```
【通用约束】同前。涉及 Windows 原生（windows/runner）与 Dart 代码。

背景：Windows Toast 目前只显示标题/正文（lib/services/windows_toast.dart 用 PowerShell 调 WinRT ToastNotificationManager），
点击不会打开/聚焦应用，也没有动作按钮。AppUserModelID 已统一为 `DontForget`（main.cpp + installer.iss）。
目标（分两步，先做 1，评估后再做 2）：
1. 点击回跳：Toast 增加 activationType="protocol" 或使用 ToastNotification.Activated 回调，
   点击时激活已运行实例（单实例 mutex 已存在，会激活窗口）；应用未运行时启动应用并打开对应事项详情。
   - 传递事项 ID：把 reminder id 放进 launch 参数或自定义协议参数（如 dontforget://task/<id>），
     Dart 侧解析后导航到详情；解析失败要安全降级到首页，不得崩溃。
   - 需要在 runner 注册协议/命令行参数解析；Windows 10/11 下不得要求管理员权限。
2. （评估项）在 Toast 上增加“完成本次 / 延后 15 分钟”动作按钮：需改用 WinRT 自定义 toast XML + 后台激活，
   与现有 pending notification actions 队列（lib/services/pending_notification_actions.dart）对接；
   若评估成本高，先输出设计文档与风险，不强行实现。

验收标准：
- 单元测试：协议/参数解析（合法、非法、旧 payload、数据代次不匹配）。
- 手动验证（Windows）：应用运行时点 Toast → 窗口前置并打开对应事项；应用退出后点 Toast → 应用启动并打开事项；
  重复点击不产生重复窗口。
- flutter analyze 0 issues；全量测试通过；不破坏既有单实例与通知去重行为。
- 记录到 docs，并说明动作按钮是否落地。
```

### P5 — i18n 硬编码清理

```
【通用约束】同前。只改文案与其调用点，不改业务逻辑。

背景：桌面端存在中文硬编码：托盘菜单（lib/app.dart）、Toast 兜底文案、部分提示；
l10n 机制在 lib/l10n/app_localizations.dart，已有中/英/日。界面偶有不一致（例如同一提示三种语言混用）。
目标：
1. 找出 lib 下用户可见的中文字符串字面量（排除注释、日志、测试夹具、AI Prompt 模板），逐一改为 l10n key；
   至少覆盖：托盘菜单与提示、通知/Toast 文案、窗口相关提示、录音过短提示、备份/恢复状态提示。
2. 三个语言文件同时补齐 key，严禁只补中文。
3. 保留向后兼容：已废弃 key 不删除（避免外部语言包报错），新 key 命名符合现有风格。
4. 不把日志（debugPrint）与内部错误消息翻译成 UI 文案（它们不是用户界面）。
5. 输出一份清单：文件 → 原中文字面量 → 新 key。

验收标准：
- 单元/组件测试：中英日切换后托盘菜单、Toast、关键提示文案正确（无法直接测托盘则测文案解析函数）。
- 手动验证（Windows）：切到 English / 日本語，检查首页、设置、托盘菜单、撤销提示、录音提示无中文残留。
- flutter analyze 0 issues；全量测试通过。
- 更新 docs 的 i18n 条目。
```

### P6 — CI 增加 Windows 测试作业 + 版本一致性

```
【通用约束】同前。只改 CI 与依赖锁定，不改产品逻辑。

背景：.github/workflows/build_and_release.yml 的全量 flutter test 只在 ubuntu-24.04 跑（第 25、38 行），
Windows 只做构建/安装/冒烟；而本机 Flutter 3.47.2 下 flutter pub get --enforce-lockfile 失败（lockfile 与 SDK 约束漂移），
本地验收与 CI 基线（3.44.9）不一致。
目标：
1. 在同一个 workflow 增加 windows-latest 的测试作业：setup Flutter 3.44.9、flutter pub get --enforce-lockfile、
   flutter test --no-pub、flutter analyze --no-pub；失败不阻塞发布构建（用 continue-on-error 或在报告中单独标注）由你决定并说明理由。
2. 本机 lockfile 漂移：给出方案二选一并实施：(a) 固定本地 Flutter 3.44.9 的说明与版本检查脚本；
   (b) 在 pubspec.lock 中锁定兼容版本的依赖（需全量测试通过）。不得直接提交未经测试的 lockfile 变更。
3. CI 里 Windows 测试若因 POSIX 用例跳过，输出跳过清单（测试名+原因），不得静默跳过。
4. 更新 docs/Packaging_and_Deployment.md 与 README 的本地开发命令（含版本要求）。

验收标准：
- 本地能复现 CI 的 Windows 测试命令（至少 flutter test --no-pub 全量通过）；新增 workflow 通过 YAML 语法校验（可用 actionlint 或 python yaml 解析）。
- 报告里给出新增 job 的 YAML 片段与理由。
- 不修改产品代码。
```

### P7 — 生产身份 `com.yarnway.dontforget`（含数据目录迁移）

```
【通用约束】同前。这是发布前身份变更，必须考虑已有用户数据。

背景：Windows 侧身份仍是 `com.example`：windows/runner/Runner.rc 的 CompanyName、安装器 AppId/目录、
数据库与媒体路径（%APPDATA%\com.example\DontForget、%USERPROFILE%\Documents\media）。iOS/macOS 的 pbxproj 也是 com.example.dontForget。
目标（Windows 优先，iOS 侧只改配置并说明需在 Mac 验证）：
1. 统一命名：应用标识/发布者使用 `com.yarnway.dontforget`（Windows 显示名 DontForget 不变）。
2. 数据目录迁移兼容：升级后旧目录（%APPDATA%\com.example\DontForget 与 Documents\media）中的数据必须可用。
   实现一次性的迁移或回退查找（先查新目录、不存在则用旧目录并继续读写，或复制后切换），
   必须原子/可重试，失败不得丢数据，并记录迁移结果日志。
3. 附件目录若必须更换位置，需同步更新 MediaRecords 路径与内容清理/备份引用逻辑；优先保持不变以减少风险。
4. iOS：仅更新 pbxproj/Info.plist/扩展的 bundle id 到 com.yarnway.dontforget，不改签名配置；在文档注明需 Mac 重新签名验证。
5. 安装器：AppId、安装目录、快捷方式、卸载项保持一致更新；升级安装不得丢配置。

验收标准：
- 迁移测试：旧目录不存在、旧目录存在且新目录不存在、两者都存在（新优先）、迁移中断后可重试、只读旧目录失败时报错不丢数据。
- 手动验证（Windows）：用旧身份跑一份测试数据 → 安装新身份包覆盖 → 启动后数据完整、附件可预览、通知仍工作；
  卸载后用户数据按既定策略保留。
- flutter analyze 0 issues；全量测试通过；flutter build windows --release 通过。
- 文档记录身份变更、迁移策略与回滚方式。
```

### P8 — 文档同步（README / CHANGELOG / 架构 / 发布策略）

```
【通用约束】同前。只改文档，不改代码。

背景：仓库文档落后于实现：
- docs/Changelog.md 只记到 1.7.0+39，+40（数据保护）、+41（统一内容）、+42（周期上下文）、+43（原生升级）、+44（录音布局）、
  以及 2026-10-29 的 Windows 适配（Toast/单实例/托盘退出/测试全绿/安装包）均未记录。
- README.md 仍写“API Key 与备份没有应用层加密”，与 +40 的“系统安全存储 + 可选 AES-256-GCM 备份”不一致（数据库本身未加密仍属实）。
- docs/Architecture_Design.md 写 Windows 7/8 支持，而 installer.iss 要求 Win10+；windows_redist 与打包脚本注释不一致。
- docs/Release_Acceptance_v1.7.md 的剩余任务表未反映 Windows 侧已完成项与 iOS 仍待验。
目标：
1. 按现有风格补 CHANGELOG 条目（每版：功能、验证数字、限制），Windows 适配单独一节，注明证据文件。
2. 更新 README：加密表述、Windows 支持范围与限制（需应用运行、无系统排程、无动作按钮）、本地开发版本要求。
3. 更新架构文档：Windows 最低版本、通知通道差异、数据目录结构。
4. 更新 Release_Acceptance_v1.7 的剩余任务表：Windows 已完成项标注证据，iOS 仍为待验；稳定版仍被 macOS/iOS 门槛阻塞。
5. 统一 installer.iss 与文档的 Win10+ 表述；说明 windows_redist 的实际用途或标注废弃。

验收标准：
- 交叉核对：文档中的每条“已完成”都能指向代码/提交/证据路径；不得写“已验证”而实际未验。
- Markdown 链接有效（相对路径存在）。
- 不改代码、不改测试。
```

### P9 — iOS 真机验收（需要 macOS + Xcode + iPhone 15 Pro Max）

```
【通用约束】同前，但注意：本任务只能在 macOS 上执行。若当前环境是 Windows，直接报告“无法执行”，不要伪造结果。

执行依据：docs/iOS_Device_Acceptance_Runbook.md（前置条件、构建命令、18 项清单、数据保护规则、已知坑）。
步骤：
1. 确认 Xcode、CocoaPods、devicectl、Flutter 3.44.9 与两份开发描述文件（Runner 与 ReminderActivity.appex）有效。
2. 从干净 commit 用 git archive 导出源码，改写验收身份 com.yarnway.dontforget.acceptance.<run-id>（主应用与扩展一致）。
3. flutter pub get --enforce-lockfile → analyze → 全量 test → python 脚本测试。
4. xcodebuild archive + exportArchive（development），package_artifacts/verify_artifacts 校验，codesign --deep --strict 验签。
5. devicectl 安装到 iPhone 15 Pro Max，按 Runbook 第 3 节 18 项逐项验收，每项记录证据（截图/系统日志/数据库读回）。
6. 数据保护：只软删除 QA 前缀的自建数据，独立读回系统待发/保留；禁止整库覆盖、卸载重装、cancelAll。
7. 产出 docs/iOS_Acceptance_<日期>.md：逐项通过/未通过、证据路径、与总表的对应关系；同步更新 Release_Acceptance_v1.7。

验收标准：
- 18 项中每一项都有“通过/未通过/未执行”明确状态与证据；不得用 macOS 结果或组件测试替代真机结论。
- 至少完成通知热/冷点击、动作菜单三语、前后台/终止态、重开补排去重、灵动岛同步、软键盘、真实录音、附件、备份、清理。
- 更新发布门槛状态；不发布稳定版（除非所有 macOS/iOS 门槛闭合且用户明确要求）。
```

### P10 — iOS 无 Mac 静态预检（P9 的降级替代）

```
【通用约束】同前。不要声称任何真机结论。

背景：当前无 macOS，无法构建/安装 iOS。可以做不依赖设备的静态与工程预检，降低后续 Mac 上的返工。
目标：
1. 校验 iOS 工程一致性：Runner 与 ReminderActivity 的 PRODUCT_BUNDLE_IDENTIFIER、版本号、Info.plist URL scheme（dontforget-live）、
   最低 iOS 版本、WidgetKit/ActivityKit 配置是否与主应用匹配；列出不一致项并修复明显笔误。
2. 校验 scripts/check_ios_device.py、build_ios.sh、package_artifacts.py、verify_artifacts.py 的参数与文档一致（可用 --help/dry-run）。
3. 校验 CI ios job 的产物与 Runbook 的安装步骤可对接（artifact 名称、版本、源码身份字段）。
4. 产出 docs/iOS_Preflight_2026-10-29.md：检查项、结论、必须先修的问题、以及“必须在 Mac 上完成”的清单。

验收标准：
- 不改动与 iOS 无关的代码；flake8/py_compile 通过（若改了 python）。
- 报告中明确“未执行真机构建与安装”。
```

---

## 3. 使用建议

1. **顺序**：P1 → P2 → P3 → P4 → P5 → P6 → P7 → P8；P9/P10 视 Mac 条件并行。
2. **一次一条**：每条提示词尾部都要求更新验收文档，做完 P1 后再发 P2，避免上下文过载。
3. **中文回复**：要求 Gemini 用中文写报告，保留命令与英文术语原文。
4. **不要让它“顺便重构”**：明确“只改与本任务相关的文件”，否则容易触发大范围回归。
5. **每轮回来核对**：收到 Gemini 报告后，重点看三件事：是否真的运行了命令（贴了输出）、是否修改了测试断言、证据路径是否存在。

## 4. 已知坑（发给 Gemini 前最好强调）

- `flutter pub get --enforce-lockfile` 在本地 Flutter 3.47.2 下会失败（lockfile 与 SDK 约束漂移），CI 用 3.44.9；不要为绕过而随意改 lockfile。
- Windows 下文件句柄占用会导致测试临时目录删除失败（errno 32），已通过异步释放 + 重试修复；新增测试注意不要持有未关闭的句柄。
- 单实例使用 `Local\DontForget.SingleInstance` 命名 mutex；新增命令行入口必须继续放行 CLI 参数（`--add/--list/--help`），否则 CLI 会被吞。
- Toast 的 AppUserModelID 已统一为 `DontForget`（main.cpp、installer.iss、Dart 常量三处必须一致）。
- 通知/提醒相关断言涉及 occurrence identity（id + triggerTime + noticeRevision），改动排程逻辑时不要破坏这些不变量。
- 任何“数据迁移”都必须可重试、失败不丢数据，并有测试覆盖；不得直接覆盖用户数据库。
