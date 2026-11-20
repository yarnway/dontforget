# 后续阶段与任务（2026-11-02）

## 当前范围（2026-11-17调整）

按用户要求精简主线，只保留直接影响“别忘了”录入、提醒、数据保全与四平台交付的工作。阶段编号保留以便追踪；**阶段46退出当前任务列表**，不改记为全部通过。

当前发行版为[v1.8.14／build85](https://github.com/yarnway/dontforget/releases/tag/v1.8.14)，Windows／Linux／Android／iOS四平台。源码、自动化、安装包与真机结果分别记录；[发行与设备范围](Release_1.8.14_85_2026-11-17.md)。完整旧台账已移至[历史记录](Next_Steps_History_2026-11-02_2026-11-17.md)，旧“剩余”清单不再自动进入主线。

| 处理 | 内容 | 后续规则 |
| --- | --- | --- |
| 移除主线 | 阶段46：USB长期、换线、跨端口／跨主机及通用休眠硬件排查 | 仅在实际连接故障阻碍开发时排查，不设独立产品验收阶段 |
| 按需专项 | NTFS卷耗尽、物理断电、任意指令窗口终止、全提供器／全机型容量与锁定穷举 | 相关存储代码变更或真实故障出现时选择必要案例，不逐版本重复实验 |
| 可选扩展 | 词条身份迁移／重置、个性化预测、更多练习、专注计时、日历／天气／地理围栏 | 已有功能保持，后续按明确需求立项，不作为当前发布尾项 |
| 可选分发 | macOS客户端真机／公证、Windows商业签名、商店上架 | 保留支持与既有检查；依赖设备／账号的分发扩展不阻塞当前GitHub四平台发布 |
| 必须保留 | 新版数据备份、发行包来源与版本、Windows本机运行中覆盖升级、字段／凭据／普通重开核对 | 遵循AGENTS.md；不能因精简台账跳过，正常关闭失败须保留证据并续验 |

## 阶段 47：平台入口与原生提醒收口（下一优先级）

**目标：日常输入、语音、提醒及设置在支持平台可靠可用。**

| 任务 | 当前状态 | 下一步 |
| --- | --- | --- |
| 中文输入与草稿 | 85已发布；11月20日已在 Pixel 8 Pro `v1.8.18+89` 隔离 QA 包使用真实默认中文输入法（微信输入法 `WeType`）实机验收首页拼音组合态、候选确认、往返设置页草稿保留与回车单次保存（无重复写入），并实机验收分享草稿编辑页组合态禁用「保存为备忘」→候选确认后立即恢复启用→单次保存无提醒备忘 | 补语音编辑页真实中文输入法组合及正式包关键路径 |
| 语音输入三态 | 84已有 Pixel 真实腾讯预览、编辑及用户发送证据。11月18日，85 QA诊断包单次播放未复现重复，已取得音频字节数及分片时间 | 继续定位84历史重复来源，再补输入／中断／读屏场景 |
| Android最终归档 | Pixel接回后已最新保全并覆盖最终发行ARM64，关于页显示1.8.14(85)，更新检查返回current；正式及原QA普通重开保持 | 本版实装收口；完整语音／中文输入法／通知等原生场景按相关任务继续，不把包升级推广为全部通过 |
| Android提醒 | 83已有正文、动作、延后与15分钟二次送达实机结果；11月20日 `v1.8.18+89` Pixel 隔离 QA 包已完成提前10分钟后台送达、通知动作点击 `15分钟后` 延后与15分钟准时二次送达实机闭环 | 正式包发布后补当前正式包关键路径回归；旧版本原生结果保持原归属 |
| 普通事项提前提醒 | 快速录入与自动整理默认提前10分钟，可选5／10／15分钟。Pixel 隔离包已验收三档后台送达、通知正文打开详情、改期后旧时点无通知且新时点只投递一条；11月20日 `v1.8.18+89` 隔离 QA 包补齐任务编辑器设提前10分钟→后台准时送达（`21:34:00`）→点选 `15分钟后` 延后（`snoozed_at` 与 `notice_revision` 更新）→15分钟后准时二次送达（`21:49:08`）实机验收 | 补正式包关键路径验收 |
| Windows原生入口 | 85至89（`v1.8.14+85`→`v1.8.18+89`）均已完成本机运行中正常覆盖、全字段与实际凭据保持及普通重开；当前会话 UIA 根节点返回空（`children: 0`），GUI 自动化工具初始化仍受阻 | 交互式桌面会话工具可用后补窗口／托盘／Toast／真实中文输入，不以CLI或进程存在代替GUI通过 |
| iPhone客户端 | 手机最近独立读回为81。同源同验收身份85未签名 IPA 已构建并读回，11月20日 `check_ios_device.py` 预检仍无 iPhone 且本机为 Windows（无 Xcode／devicectl） | 接入后取最新备份，按既有 AltStore 身份签名覆盖，核对版本、记录、中文输入、通知与录音 |
| 界面与文案 | 首页和启动／托盘资源已改用统一品牌图标，手机分类列表去掉重复栏头；11月20日 `v1.8.18+89` Pixel 8 Pro 隔离 QA 包完成多事项、长标题及系统大字号（`font_scale=1.3`）在全部列表与四象限分类页的实机密度验收（0 `RenderFlex` 溢出、0 框架异常，截图已归档） | 核对后续四平台正式包图标 |

## 阶段 48：数据保护与长期管理

**目标：正常备份恢复、升级和清理不丢记录、原件或凭据。**

- 已有普通／加密备份、附件往返、预检／确认／取消、错误密码、导出历史、外部引用保护与目录替换检查；新版本按相关变更选择回归，不重做整套容量实验。
- 84后端已完成[6个真实空间不足场景](Windows_Backup_Disk_Full_2026-11-17.md)和[20个Windows实际进程中断场景](Windows_Recovery_Process_2026-11-17.md)。这些是已完成的限定范围，不再列为待办，也不推广为断电／GUI或所有平台通过。
- 导出历史保留最近20条位置元数据。清除位置记录支持取消、成功与失败反馈，并保护确认期间新增记录和未来格式数据。Pixel 独立包已验证真实导出、取消、确认、反馈、文件摘要和重开，正式包待验。
- 内容管理显示已扫描材料的总大小，同一目录内的文件按清单计一次。仍可分别查看筛选结果与选中可释放空间。旧开发目录已接入现有的租约、SQLite 独占、校验和提交保护，合成旧库迁移及源文件保留通过自动化。11月20日已在 Pixel 8 Pro `v1.8.18+89` 隔离 QA 包完成**有真实附件时的设备清理验收**：活跃分享图片（`70 B`）标记「仍被引用，保留」且清理后磁盘字节 SHA‑256 完整保留，过期未引用原件（`4.11 KiB`）在扫描总计 `4.28 KiB` 中经二次确认弹窗清理后删除、总计准确降至 `175 B`（`0 B` 可清理）。历史目录人工接管与正式包验收仍待执行。原件清理继续保护回收站、归档、草稿、外部备份及历史恢复引用。
- 本机 Windows 只读预检确认当前支持目录和旧 LocalAppData 目录均有主库（旧库 schema 16，3条历史 QA 事项）及迁移回执（2026-10-29 完成迁移）。五个已知位置中未发现待迁移／恢复标记。人工接管仍需用户确认保全后验收。
- 凭据保持、恢复失败保全及每版最新备份属于基本质量要求；真实安全存储锁定穷举归入按需专项。

## 阶段 49：学习与跨设备完整工作流

**目标：完善现有采集与跨设备继续处理能力。**

| 任务 | 当前状态 | 下一步 |
| --- | --- | --- |
| 分享采集 | 85文字／链接分享草稿、仅备忘命令边界已有实机与自动化证据；图片／附件分享接收、确认与保存备忘（含空配文与保留首页草稿）已通过自动化并在 Pixel 独立 QA 包（85 与 11月20日 `v1.8.18+89`）完成系统 `content://` 图片分享接收、收件箱缩略图预览、确认保存、原件 SHA‑256 核对与暂存清理实机验收 | 补正式包及通过系统分享面板手选文件场景复验 |
| 局域网同步 | Windows 已实测默认端口冲突后换端口。差异页支持确认后采用对方文字；11月20日已在 Pixel 8 Pro（`192.168.50.158`，`v1.8.18+89` 隔离 QA 包）与 Windows 隔离 SQLite 对端（`192.168.50.4:13395`，物理网卡优选，**零 USB 转发**）之间完成**同一真实 Wi‑Fi 子网（`192.168.50.0/24`）直连双向同步**（双向事项＋图片／文件附件落盘 SHA‑256 核对）、**跨设备回收站移入差异采用**、**跨设备回收站恢复差异采用**与最终 0 差异收敛实机验收 | 补四平台正式包验收 |
| 学习与排程 | 计划管理、词条档案、批量改期、七天预测等已有实现和验收 | 维护已有功能；身份迁移、更多练习与预测扩展移入可选需求池 |

## 阶段 50：正式发布（build85已完成）

**目标：稳定后交付Windows／Linux／Android／iOS新版Release。**

1. 固定源码、版本、SDK与锁文件，完成必要回归和质量检查；不把CI内部候选写成已安装或已发布。
2. 核对四平台发行包版本、来源、摘要及平台签名／未签名状态；不移动旧标签或覆盖旧附件。
3. 每个Windows新版本：最新数据备份→旧／新包与实际版本核对→本机运行中正常覆盖→安装后文件、全字段、实际凭据与普通重开验证。关闭失败保留证据，不强关或冒记通过。
4. 可用手机分别最新保全、同身份升级及关键功能验收；设备不可用的范围明确列出。iPhone当前采用个人签名路径，安装与签名续期分别记录。
5. 本版85四平台七包、20附件已发布并独立读回；后续版本按[发布策略](Release_Policy.md)发布并独立读回。macOS客户端、公证、商业签名及商店上架属于可选分发扩展，不附加为当前四平台发布的必做阶段。

## 本轮执行记录

### 11月20日 阶段 47／48／49 实机推进（v1.8.18／build89 全量测试＋Pixel 8 Pro＋真实 Wi‑Fi 直连）

- **源码**　无新增产品源码改动，全部验证基于干净提交 `600f517`（`v1.8.18+89`）。
- **自动化**　固定 Windows Flutter 3.44.9 下补齐修复后全仓 `flutter test --no-pub --concurrency 2 --timeout 2m` 完整回归：**2,686 项通过、20 项文档化 Windows 跳过、0 失败**。
- **安装包**　在独立 git worktree 基于 `600f517` 构建隔离 Android ARM64 调试 QA 包（`com.yarnway.dontforget.acceptance.sync20261118`，版本 `1.8.18 (89)`，APK SHA‑256 `751b3fa7fe0749a6248b7d7afb6c5875489178351075ab7df74507bc19cae0f4`，同调试签名证书 `4f851835...`）。未构建正式四平台发行包，未推送远端或发布 GitHub Release。
- **真机／本机验收**　详见 [pixel-89-acceptance-2026-11-20.json](benchmarks/pixel-89-acceptance-2026-11-20.json)：
  - **QA 包保全升级**：Pixel 8 Pro 升级前完整 `run-as` 备份（`101.6 MB` tar）→同签名覆盖 `1.8.14+85`→`1.8.18+89`→读回已装 APK 摘要一致→冷重开后 3/0/1 全字段逻辑摘要一致，关于页确认显示 `1.8.18 (89)`，正式版 `com.yarnway.dontforget` 及其他 QA 身份均未触碰。
  - **阶段 47**：① 真实默认中文输入法（微信输入法 `WeType`）首页拼音组合态（`ce shi` / 候选栏 `1 测试`）、候选确认、往返设置页草稿保留及回车单次保存（`测试内网`，仅新增 1 条），以及分享草稿编辑页组合态下「保存为备忘」禁用→候选确认后立即启用→单次保存无提醒备忘（`SHARE_IME_测试`）；② 多事项、长标题及系统大字号（`font_scale=1.3`，随后恢复 `1.0`）在全部列表与四象限分类页 0 `RenderFlex` 溢出、0 异常；③ 通过真实任务编辑器设为提前 10 分钟提醒（事项 `21:44`／提醒 `21:34`）→后台准时送达（`21:34:00`）→展开系统通知栏点击 **`15分钟后`**（DB 写入 `snoozed_at=21:34:08`、`trigger_time=21:49:08`、`notice_revision=2`）→15 分钟后后台准时二次送达（`21:49:08`）。
  - **阶段 48**：系统 `content://` 图片分享保存（`df_qa_img_89.png`，`70 B`，SHA‑256 一致且 `shared_handoff` 清空）＋置入 48 小时过期孤立原件（`4.11 KiB`）→内容管理点击「重新检查引用」显示扫描共 `4.28 KiB`、活跃图片标记「仍被引用，保留」、孤立原件可清理→经二次确认弹窗清理后孤立目录删除、扫描降至 `175 B`（`0 B` 可清理）、活跃图片磁盘 SHA‑256 保持一致。Windows 旧 LocalAppData 目录保持只读未改动。
  - **阶段 49**：移除全部 `adb reverse/forward`（零 USB 转发），在真实 Wi‑Fi 子网（`192.168.50.0/24`）下验证 Pixel 同步服务端优先展示物理 Wi‑Fi 地址 `192.168.50.158:42888`，并与 Windows 隔离 SQLite 对端（物理网卡优选 `192.168.50.4:13395`）完成双向直连同步（双方各自收到对方任务与附件且落盘 SHA‑256 一致）→Windows 对端移入回收站→Pixel 同步后在双色差异卡片中确认「移入本机回收站」（DB `deleted_at` 置位）→Windows 对端恢复→Pixel 同步后确认「在本机恢复事项」（DB `deleted_at` 清空）→第四次同步 0 差异收敛。
  - **基线恢复与边界**：验收结束后恢复 Pixel QA 包安装前 `3/0/1` 数据基线并冷重开核对摘要一致，确认输入法／字号／其他应用未受影响并返回桌面。本轮未完成项明确留存：Windows GUI／托盘／Toast（当前非交互会话 UIA 根节点为空）、iPhone 真机（无 USB 设备且无 macOS／Xcode）、build84 语音重复归因与读屏、系统分享面板手选文件、Windows 历史目录人工接管及四平台正式包发布验收。

### 11月20日 迭代 4（v1.8.18／build89，全局架构与一致性收敛）

- **源码**　清理未引用死代码 `lib/ui/widgets/ai_background_effect.dart`（758 行）；抽取共享文件体积格式化工具 `lib/ui/formatters/byte_size.dart` 替代内容管理与便携备份面板中的重复 `_size` 实现，并为 `TaskAttachmentPreview` 补齐异步文件体积展示（`attachment-preview-size`）；收口 `TaskAttachmentFiles._discard` 复用 `LocalMediaStore.discardImport`。全面加固多语言一致性：`AppLocalizations.get` 缺失键时统一回退至英文主表及合并子表（`taskAttachmentStrings`、`taskConsistencyStrings`、`notificationDiagnosticsStrings`），新增 18 组中／英／日对称词条并替换设置页、首页、详情页与 `HomeController` 中残余硬编码文案；`StorageUnavailableScreen` 升级为三语（中／英／日）并接入 `AppTheme` 明暗双主题；`main.dart` CLI 版本对齐至 `v1.8.18`、`--list` 仅输出工作区有效事项、`--add` 改为按 runes 安全截断 30 字符。修复 `TaskBoard` 与 `TaskWorkspaceOverview` 定时刷新／前后台恢复时的投影缓存失效（`_refreshRevision`）及历史滞后测试预期 `test/recording_reminders_phase1_test.dart`。同步将 `docs/Architecture_Design.md` 更新至 `v1.8.18` 架构现状并在 `docs/Changelog.md` 补录 `v1.8.15`–`v1.8.18` 变更记录。
- **自动化**　固定 Windows Flutter 3.44.9 下 `python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` 0 问题；执行全仓 `flutter test --no-pub --concurrency 2 --timeout 2m`（2684 通过／20 项文档化 Windows 跳过／2 项失败：`task_board_performance_test.dart` 与 `recording_reminders_phase1_test.dart`）；修复上述 2 项后定向复跑 6 个测试文件（`task_board_performance_test.dart`、`recording_reminders_phase1_test.dart`、新增 `test/l10n_integrity_test.dart` 及 `v1_8_15`/`v1_8_16`/`v1_8_17` 专项回归）共 53 项全部通过（修复后未再次重跑整仓全量套件）；`python scripts/report_windows_skipped_tests.py` 通过（14 项文档化 Windows 跳过声明），Python 脚本测试 180 项通过（6 项 POSIX 跳过）。
- **安装包**　基于干净提交 `600f517` 在本机固定 Flutter 3.44.9 构建 Windows x64 未签名安装包 `DontForget_Setup_v1.8.18.exe`（SHA‑256 `267c3149f71b03aea3a93af92e9f20e9e23b699f56cc4684c6af1f89803c19ef`）与便携包 `DontForget_Windows_Portable_v1.8.18.zip`（SHA‑256 `9113b5b06bfbafa2967d73888d5776a702f268c4ca5f8c338153218136c98716`），通过 `scripts/verify_artifacts.py` 校验。未构建 Linux／Android／iOS 正式包，未推送远端或发布 GitHub Release。
- **真机／本机升级**　Windows 本机在 `1.8.17+88` 运行中执行最新数据备份→正常静默覆盖升级（`/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`，禁止强关）→安装后 39 个载荷文件与便携包逐字节一致、PE 版本 `1.8.18.89`、CLI `--list` 正常退出、SQLite schema 17 `integrity_check=ok`、全业务字段（Reminders 7 / MediaRecords 0 / Settings 1）及 DPAPI 凭据（1 项）解保护摘要一致、普通重开后字段与凭据保持，详见 [windows-upgrade-89-2026-11-20.json](benchmarks/windows-upgrade-89-2026-11-20.json)。Windows GUI／托盘／Toast 与 Android／iOS 真机未在本轮实测。

### 11月20日 迭代 3（v1.8.17／build88，稳定性与性能优化）

- **源码**　修复三项高危稳定性缺陷：① `RetainedMediaReferences.read` 改为扫描真实受控数据库目录（`database.acquireOwnership()`）而非应用支持目录，确保生产环境清理可靠识别 `ha_snapshot.json`、`dont_forget_v3.mirror.db`、`recovery-*`、`schema-upgrade-*` 与迁移回执中的原件引用；② `DatabaseMaintenanceLease._checkIntegrity` 历史版本集合动态覆盖 `7..schemaVersion`，修复 v15／v16 中断恢复校验失败；③ `HomeController._stopCapture` 在 `try/catch/finally` 中始终重置 `_nativeRecording` 并在录音停止异常时释放未完成 PCM 句柄（消除 Windows 文件锁泄漏与录制死锁），显式取消实时转写（`SpeechRecognitionException('cancelled')`）不再误存音频备忘。另增强 `HomeScreen._acknowledgeAllMissed` 异常捕获、`WindowsToast.script` 先按字符码点（runes）截断再执行 PowerShell 转义（防止截断转义符或 Emoji 代理对）、桌面 `error_log.txt` 1 MiB 轮转。性能优化：新增 `O(1)` 索引提供器 `remindersByIdProvider` 与 `mediaRecordByIdProvider`（消除 `TaskCard`、`TaskAttachmentsPanel`、`TaskReaderScreen` 线性扫描）；为 `TaskBoard` 与 `TaskWorkspaceOverview` 增加按数据身份与分钟桶缓存的投影记忆化；首页 10 秒心跳按需门控 Wi‑Fi SSID 探测（无 Wi‑Fi 触发器时不拉起 `netsh`）与动态跃迁扫描；`LanSyncService._merge` 将逐行 `SELECT` 优化为单次预加载索引并限制并发入站请求上限（8 路，超限立即返回 503）。
- **自动化**　固定 Windows Flutter 3.44.9 下 `flutter analyze --no-pub` 0 问题；11 个稳定性／性能回归测试文件共 150 项通过（含新增 `test/v1_8_17_stability_performance_test.dart` 6 项及 `content_cleanup_test.dart`、`lan_sync_maintenance_test.dart`、`home_live_recording_test.dart`、`recording_compatibility_test.dart`、`windows_toast_test.dart`、`task_board_theme_test.dart`、`task_card_theme_test.dart`、`task_attachments_test.dart`、`task_reader_screen_test.dart`、`home_notice_persistence_test.dart`）。
- **安装包**　基于干净提交 `d5d3ddb` 在本机固定 Flutter 3.44.9 构建 Windows x64 未签名安装包 `DontForget_Setup_v1.8.17.exe`（SHA‑256 `f17b60cd4e2c183dd423c7689c6a3ff1de264407499ab3c96f36be4afcd3c3e7`）与便携包 `DontForget_Windows_Portable_v1.8.17.zip`（SHA‑256 `f13a70e33c4e8d2fca72b7989e8af5db8f83ab60f1cd152ca0f8c18d53275a5b`），通过 `scripts/verify_artifacts.py` 校验。未构建 Linux／Android／iOS 正式包，未发布 GitHub Release。
- **真机／本机升级**　Windows 本机在 `1.8.16+87` 运行中执行最新数据备份→正常静默覆盖升级（禁止强关）→安装后 39 个载荷文件逐字节一致、PE 版本 `1.8.17.88`、CLI `--list` 正常、SQLite schema 17 `integrity_check=ok`、全业务字段（7/0/1）及 DPAPI 凭据（1 项）一致、普通重开后字段与凭据保持，详见 [windows-upgrade-88-2026-11-20.json](benchmarks/windows-upgrade-88-2026-11-20.json)。Windows GUI／托盘／Toast 与 Android／iOS 真机未在本轮实测。

### 11月20日 迭代 2（v1.8.16／build87，易用性与美观性优化）

- **源码**　完善 `AppTheme` 统一 Material 3 设计令牌（`dialogTheme`、`popupMenuTheme`、`chipTheme`、`snackBarTheme`），消除首页清空完成确认弹窗、任务编辑弹窗、设置页探测与局域网卡片、详情页链接／媒体区块及首页情境切换图标中的硬编码色值（`#1E1E1E`、`Colors.tealAccent`、`Colors.grey.shade400/600/700` 等），全面对齐明暗双主题 WCAG AA 对比度；优化 `TaskCard` 视觉层级（竖条优先级色带、桌面悬停边框反馈、逾期／置顶边框强调、带细描边的语义标签胶囊，并严格保持主题同步底色契约）；优化 `QuadrantView` 计数胶囊与柔和空态图标容器；优化 `TaskWorkspaceOverview` 今日分组图标＋计数徽标及空态引导；升级 `LanSyncConflictsDialog` 为本机／对端双色对比卡片与折叠差异字段摘要；升级 `DashboardScreen` 统计卡片图标底托及四象限语义配色进度条；为 `SharedTextInboxScreen` 增加安全校验后的有界图片缩略图（`cacheWidth: 128`）与统一空态视觉。
- **自动化**　固定 Windows Flutter 3.44.9 下 `flutter analyze --no-pub` 0 问题；9 个相关 UX／主题／布局测试文件共 70 项通过（含新增 `test/v1_8_16_ux_theme_test.dart` 5 项及 `task_card_theme_test.dart`、`task_board_theme_test.dart`、`settings_card_paint_test.dart`、`dashboard_screen_test.dart`、`home_notice_persistence_test.dart`、`task_reader_screen_test.dart`、`shared_text_editor_test.dart`、`settings_reliability_test.dart`）。
- **安装包**　基于干净提交 `978d44f` 在本机固定 Flutter 3.44.9 构建 Windows x64 未签名安装包 `DontForget_Setup_v1.8.16.exe`（SHA‑256 `a3b588008778d4fb9e77ce11f172848a5cb6af40bd5038d79405dfcab5194fcd`）与便携包 `DontForget_Windows_Portable_v1.8.16.zip`（SHA‑256 `ea97ed007084b4aeef4cf7bc1fed0b1a39eaf9a8fa1ed2f10badf15ed5ea1991`），通过 `scripts/verify_artifacts.py` 校验。未构建 Linux／Android／iOS 正式包，未发布 GitHub Release。
- **真机／本机升级**　Windows 本机在 `1.8.15+86` 运行中执行最新数据备份→正常静默覆盖升级（禁止强关）→安装后 39 个载荷文件逐字节一致、PE 版本 `1.8.16.87`、CLI `--list` 正常、SQLite schema 17 `integrity_check=ok`、全业务字段（7/0/1）及 DPAPI 凭据（1 项）一致、普通重开后字段与凭据保持，详见 [windows-upgrade-87-2026-11-20.json](benchmarks/windows-upgrade-87-2026-11-20.json)。Windows GUI 视觉／托盘／Toast 与 Android／iOS 真机未在本轮实测。

### 11月20日 迭代 1（v1.8.15／build86，功能可用性推进）

- **源码**　收紧分享附件私有路径边界（`SharedText.parse` / `saveSharedAttachmentMemo` / 预览页统一校验 `shared_handoff/<id>/`）；局域网同步增强：物理网卡 IP 优先级排序（避开 WSL/Hyper-V/Docker/VPN 虚拟网卡）、客户端细分失败码与本地化提示（PIN 错误/锁定/超限/超时/不可达）、大包未读拒收直接 `detachSocket` 发送 413 并断开连接防止客户端挂死、本机地址与配对码一键复制、PIN 回车直连；设置页修复 `SettingsArea.sync` 边缘模型探测「应用到配置」后保存按钮可见性及移动端 `ConsoleUrlLauncher` 外部打开回退；事项卡片新增「调整分类（Q1–Q4）」与「延后提醒（+15m/+1h/今晚/明早，兼容未来与到期事项并避开计划例程限制）」；只读事项详情新增一键复制正文与清单（严格保持只读契约）；文件附件与首页文件预览升级为异步 128 KiB 有界 UTF-8 预览（含 NUL 字节检测、CJK 截断安全与复制文本）；加密备份/恢复补齐密码显隐切换；首页补齐「移动通勤」情境切换、`U`/`,` 快捷键、`PopScope` 优先关闭搜索、`url_launcher` 跨平台打开视频、音频停止播放/再点停止、待处理分享草稿提示条与命令面板入口，内容管理增加待处理分享草稿计数徽标并修正详情弹窗关闭按钮文案。
- **自动化**　固定 Windows Flutter 3.44.9 下 `python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` 0 问题；14 个相关 Flutter 测试文件共 200 项通过（含新增 `test/v1_8_15_availability_test.dart` 10 项及 `lan_sync_maintenance_test.dart` 19 项、`home_*` / `shared_text_*` / `settings_*` / `task_*` / `content_cleanup_test.dart` / `portable_backup_test.dart`），Python 脚本测试 180 项通过（6 项 POSIX 跳过）。
- **安装包**　基于干净提交 `84b90f4` 在本机固定 Flutter 3.44.9 构建 Windows x64 未签名安装包 `DontForget_Setup_v1.8.15.exe`（SHA‑256 `29fad5ae6185d030a73a53d5ecc4c228782c9f4a72576c3f8f08c4c1d502ab92`）与便携包 `DontForget_Windows_Portable_v1.8.15.zip`（SHA‑256 `bcf7420c1c3df2481712d7d688a0135431ea7360f740c176761bfb160744696f`），通过 `scripts/verify_artifacts.py` 校验。未构建 Linux／Android／iOS 正式包，未发布 GitHub Release。
- **真机／本机升级**　Windows 本机在 `1.8.14+85` 运行中执行最新数据备份→正常静默覆盖升级（`/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`，禁止强关）→安装后 39 个载荷文件与便携包逐字节一致、PE 版本 `1.8.15.86`、CLI `--list` 正常退出、SQLite schema 17 `integrity_check=ok`、全业务字段（Reminders 7 / MediaRecords 0 / Settings 1）及 DPAPI 凭据（1 项）解保护摘要一致、普通重开后字段与凭据保持，详见 [windows-upgrade-86-2026-11-20.json](benchmarks/windows-upgrade-86-2026-11-20.json)。Windows GUI 交互／托盘／Toast 与 Android／iOS 真机未在本轮实测。

### 11月20日源码审查修复、图片／附件分享与局域网附件传输

- **源码**　审查修复三处缺陷：局域网同步完成后等待事项刷新再展示冲突列表；事项编辑在旧提前偏好已失效时手动改时间同步清理残留 `reminder_lead_minutes`；实时语音发送前等待底层录音停止完成再释放录制状态以防首页提交被拦截。扩展阶段49分享采集：Android 系统分享支持接收 `image/*` 与 `application/*`（`EXTRA_STREAM` 安全暂存至应用私有 `shared_handoff/<id>/`，限制 32 MiB 与 16 条队列上限），`SharedTextInbox` 持久化附件路径与文件名并在移除时清理暂存目录，分享确认页展示附件／图片预览卡片并支持无配文或带配文经同一 SQLite 事务导入 `LocalMediaStore` 及保存备忘，全程保留首页原输入草稿。扩展阶段49局域网同步附件传输：`LanSyncService` 双向同步事项引用的 `MediaRecords` 与原件字节（含 32 MiB 上限、安全单段文件名与 SHA‑256 摘要校验），在 SQLite 事务外通过 `LocalMediaStore.importBytes` 暂存落盘并在事务提交／回滚时经 `discardImport` 清理未采用或回滚的暂存副本；对新事项与已有事项自动关联首次接收的对端附件，同时不重新绑定本机已解绑的既有媒体记录。
- **自动化**　固定 Windows Flutter 3.44.9 下全项目静态分析 `flutter analyze --no-pub` 无问题；19 个相关测试文件共 316 项通过、2 项跳过（覆盖分享收件箱、分享编辑器图片附件确认保存与草稿保留、局域网双向附件传输与事务回滚清理、事项详情提前提醒清理、通知路由、附件与内容清理）。
- **安装包**　已基于当前 `main` 源码（`dc0f1a2`）构建隔离 Android ARM64 QA 包（`com.yarnway.dontforget.acceptance.sync20261118`，版本 `1.8.14+85`，APK SHA‑256 `e9a4aa32f2bbbf50bc22679086d18e32266c94f2102223fc6ae25f0135b2aa44`），核对 `aapt` 包名版本、ARM64 ABI 与同签名证书摘要一致。未构建新正式四平台发行包，未执行 Windows 新版覆盖安装。
- **真机**　Pixel 8 Pro 安装前完整备份并同签名覆盖安装上述 QA 包，读回手机已装 APK 摘要一致，普通重开后原有 3 条事项与设置保持。实机验收：① 先在首页输入框录入草稿 `20261120`，再通过 `ACTION_SEND`（`image/png`，`content://media/external/images/media/852`）分享 68 字节 PNG 图片与配文 `DF_SHARED_IMG_20261120`，核对 `files/shared_handoff/<id>/df_share_qa_20261120.png` 暂存 SHA‑256（`431ced69...`），在分享确认页点击「保存为备忘」后核对 `MediaRecords` 与 `LocalMediaStore` 导入原件 SHA‑256 一致、仅备忘 `Reminders` 关联该附件 ID、`shared_handoff` 暂存目录已清空，返回首页后输入草稿 `20261120` 完整保留；② 启动本机 Windows 隔离 SQLite 与 `LocalMediaStore` 对端（预置关联到既有事项 `DFLAN_WINDOWS_ONLY` 的附件 `win_note_20261120.txt`），经临时 USB 转发在 Pixel「设备与同步」页录入地址与配对码并执行双向同步，核对 Windows 对端成功接收并落盘 Pixel 的图片分享备忘及 PNG 原件（SHA‑256 一致），同时 Pixel 成功接收并落盘 Windows 对端的新增文件附件 `win_note_20261120.txt`（字节完全一致）并关联至本机 `DFLAN_WINDOWS_ONLY`。验收完成后已撤销端口转发、清理测试媒体、将隔离 QA 库恢复至安装前基线并普通重开核对一致，设备返回桌面。

### 11月18日局域网同步的回收站差异处理

- **源码**　回收站差异可在确认后应用到本机独立普通事项。移入和恢复复用事项生命周期事务，写入时核对确认前快照。计划关联、重复规则和归档事项继续沿用各自入口。
- **自动化**　固定 Windows Flutter 下27个测试文件共386项通过、2项跳过，全项目静态分析通过。覆盖取消、并发改期保护、附件记录及原件字节保持、移入撤销通知、恢复安排仍在未来的提醒。
- **安装包**　Android ARM64 1.8.14（85）独立 QA 包已构建并核对签名、摘要和 Dart 源码快照。未构建新正式包。
- **真机**　Pixel 已覆盖安装该独立 QA 包。安装前备份，安装后核对已装 APK 和普通重开，业务表及受保护文件保持。与 Windows 隔离库经 USB 转发同步后，取消操作保留所有事项，后续复验留存断线证据。Pixel 本机回环随后分别确认移入和恢复，两次同步均在确认前保留本机状态。两次提交后核对回收站字段、历史、通知修订号及无关记录，最终事项已恢复、差异入口消失，设备回到桌面。

### 11月18日 Pixel 提前10／15分钟与改期实机

- 源码：沿用已通过 Windows 回归的提前提醒及局域网端口修复，未改提醒调度。
- 自动化：读取 Pixel 隔离应用固定包名的 Android 通知投递日志，两次送达窗口各一条，改期前旧时点开始的30秒窗口为零。取改期前后业务快照核对事项时间、提醒时间、修订号及无关业务字段。
- 安装包：提前提醒真机沿用已实装的1.8.14（85）隔离 QA 包；含局域网完整地址输入的 ARM64 QA 包已构建，核对安装身份、签名、摘要和 Dart 快照。无新正式包。
- 真机：用真实事项编辑器保存提前10分钟提醒，Pixel 后台按时收到并点开正确详情。随后将下一次提醒改期并设为提前15分钟，旧提醒时点经过30秒未出现通知，新时点只投递一次，正文打开正确详情。无关事项、设置、媒体保持，设备返回桌面。

### 11月18日 Windows 与 Pixel 双库同步

- 源码：使用现有局域网同步服务和差异界面，产品源码无新增改动。
- 自动化：本机 Windows 原生测试进程使用产品服务及独立 SQLite 库，读回 Pixel 发来的事项并保留 Windows 原冲突事项。两端取业务快照核对同步、取消和采用文字结果。
- 安装包：含完整地址输入的 Android ARM64 测试包按同签名隔离身份覆盖。安装前备份，独立读回已装 APK 摘要，普通重开后业务表和受保护文件保持。Windows 验收使用隔离测试进程，未安装新版本。
- 真机：Pixel 输入完整地址和配对码，经临时 USB 转发与 Windows 双向交换记录。在手机上对照标题、备注和回收站状态，取消后记录保持，确认后仅采用对方文字并写入编辑历史，回收站差异仍显示。两端各自的合成记录留存，转发已撤销，Pixel 回到桌面。同一 Wi‑Fi 子网直连预检未收到响应，实际 Wi‑Fi 仍待验。

### 11月18日 Windows 局域网端口冲突与 Pixel 提醒验收

- 源码：Windows 截图中的 10048 对应默认 TCP 端口42888已被占用。同步服务在默认端口绑定失败后改由系统分配可用端口，界面显示实际地址与端口；对端输入支持完整地址，单独输入 IP 仍使用默认端口。失败时显示本地化提示。
- 自动化：27个测试文件共384项通过、2项跳过，全项目静态分析通过。另在本机对42888复现 WinError 10048，验证产品监听路径自动选用其他端口；用独立监听进程复现10048，通过替代端口同步真实 SQLite 测试库中的一条事项，并确认原监听仍响应。
- 安装包：已构建 Windows x64 本地候选，核对版本1.8.14+85、应用代码、运行库、摘要及编译快照。未生成新版正式安装器，未执行 Windows 覆盖安装。
- 真机：Pixel 上将前一轮的提前提醒候选包覆盖到同签名独立 QA 身份。安装前备份并核对来源，安装后文件摘要、普通重开后的业务表和受保护文件均核对一致。通知权限仅通过 ADB 为该 QA 身份启用。通过真实事项编辑器设定合成事项时间，后台在保存的提前5分钟时点观察到一个活动通知，点击系统通知正文打开正确的只读详情并返回桌面。自动优先级仅调整了合成事项的两个字段，原有事项、设置和媒体保持。该 APK 构建于端口修复之前，Pixel 上的局域网配置尝试受到输入法转换影响，差异及采用流程未复验。

### 11月18日事项改期与提前提醒

- 源码：将提前分钟数随事项保存，普通事项改期时按该偏好重算提醒。已手动选择的固定提醒时间保留。历史记录没有提前偏好时，保留现有提醒时间。
- 自动化：Windows Flutter 3.44.9 的27个测试文件共381项通过、2项跳过，全项目静态分析通过。改期与固定时间两条专项均通过。编辑器重开后可读回提前偏好，改期向通知服务发起旧请求撤销和单次重排；固定时间无额外调度。
- 安装包：Android ARM64 隔离 QA 包已构建，核对1.8.14（85）、QA 身份、签名、摘要与源码快照。正式版本仍为已发布的 build85。
- 真机：Pixel 可连接且前台为其他应用，本轮仅完成只读预检。新 QA 包的覆盖安装、后台送达、改期和延后仍待实机。Windows 历史目录仅核对文件元数据，没有打开或迁移原库。

### 11月18日事项提前提醒与局域网文字处理

- 源码：普通事项录入到明确的计划时间时，默认在事项时间前10分钟安排一条提醒。10分钟的时间点已过时尝试提前5分钟，5分钟的时间点也已过时保留到点提醒。事项编辑支持5／10／15分钟，可继续手动设置提醒时间；日历时间和提醒时间独立保存。原有已保存提醒未作批量迁移。
- 源码：局域网差异页支持明确确认后在本机采用对方的标题和备注。复用事项编辑事务与通知更新，在事务内检查本机标题、备注和回收站状态，避免覆盖确认期间的新编辑。回收站差异保留在比较结果中。
- 自动化：Windows Flutter 3.44.9 的27个测试文件共380项通过、2项跳过，全项目静态分析通过。新增录入单次提交、固定时间覆盖、时限回退、事项编辑保存、局域网取消和并发保护回归。
- 安装包：Android ARM64 独立 QA 包已构建，核对1.8.14（85）、QA 安装身份、调试签名、APK 摘要及 Dart 源码快照。正式四平台包待构建。
- 真机：原 QA 包本机回环复验遇到 ADB 断线、临时监听残留和旧表单输入，已停止本轮残留监听并保留失败记录。最终设备预检通过连接，前台为非验收界面，未覆盖安装新 QA 包。5／10／15分钟后台送达、局域网差异及采用仍待实机复验。

### 11月18日局域网差异明细

- 源码：发起端保留本次同步的差异列表，只展示有变化的字段。展开后可对照两端的标题、备注和回收站状态，并打开仍可用的本机事项只读页。同步继续保留两端各自的编辑；现有完成状态合并继续生效。
- 自动化：Windows Flutter 3.44.9 的16个测试文件共217项通过、2项跳过，隔离源码的全项目静态分析无问题。双库回环覆盖冲突、完成状态合并与失败响应；窄屏组件测试覆盖差异展开、打开只读事项和重试清空。扩展回归覆盖分享草稿、旧库迁移、附件留存与备份恢复。原 Pixel 合成响应由本机 Dart 复现格式校验失败；用产品编码器补上回收站详情的格式版本后，通过解码与语义核对。
- 安装包：Android ARM64 独立 QA 包已构建，版本为1.8.14（85），调试签名和设备读回摘要均已核对。本批工作暂无新版正式四平台包。
- 真机：Pixel 独立 QA 包实装并通过系统分享保存合成备忘。Windows 测试对端绑定端口返回 `WinError 10013`。Pixel 本机回环收到 HTTP 200 后拒绝了缺少格式版本的合成数据；覆盖诊断包前后均已保全，恢复原 QA 包并普通重开后，业务字段和受保护文件保持。修正数据前设备已断开，差异界面实机和双实体联调仍待验。

### 11月18日续行

- 源码：首页显示产品图标，紧凑分类移除重复栏头，既有平台图标资源同步更新。内容管理增加扫描容量，旧开发目录改走安全迁移流程，导出历史保留未来格式和新导出记录。主动局域网同步显示有差异的事项数。
- 自动化：Windows Flutter 3.44.9 定向147项通过，全项目静态分析无问题。核对16个 iOS 图标尺寸与无透明通道、5种 Android 图标密度及10种 Windows ICO 尺寸。
- 安装包：构建并核对 Android ARM64 独立 QA 包，源码快照在桌面旧目录迁移改动之前。iPhone 单独基于公开85源码 `116d7f203987cdab9e0ded5c48883cbade451043` 构建，同一个 iPhone 既有验收身份的主包和 Live Activity 扩展均为 1.8.14（85），已读回归档及 IPA 摘要。 [iPhone 构建与附件](https://github.com/yarnway/dontforget/actions/runs/44222688321)
- 真机：Pixel 独立 QA 包首次验证导出清除时，短提示未被系统界面树捕获。结果改为页面持续显示后，保全并覆盖独立 QA 包，核对重开字段。复验通过系统文件选择器导出、取消清除、确认清除、显示结果、文件摘要保持、冷启动历史为空及无附件时扫描显示 0 B。合成验收应用和测试导出文件保留，设备回到原桌面。Windows 新版覆盖和 iPhone 安装均待验。

### 此前记录

- 11月18日源码：导出记录支持从单条或多条记录进入清除确认，确认期间新增的导出记录受到并发保护。语音产品源码保留现有按分片索引组装规则。
- 11月18日自动化：Windows Flutter 3.44.9 的导出记录、数据保护面板、实时识别和首页录音共70项通过，变更文件静态分析通过。
- 11月18日安装包：85 QA分片诊断 APK 基于发行运行时，仅在隔离 QA 身份中加记录索引、分片时间、字节数及文字长度的诊断。无新版正式包，导出记录清除尚未实装验收。
- 11月18日真机：Pixel 单次播放旧测试样本并用真实麦克风录制，单个腾讯实时会话上传350720字节，与本地 PCM 相同长度。两个稳态分片分别为索引0（1.520至3.660秒，7个字符）和索引1（3.660至5.680秒，9个字符）；最终编辑器16个字符，各样本关键词出现一次。此轮未复现重复，84历史重复仍待归因。两次同签名 QA 覆盖前均保全数据，已恢复原85 QA APK并普通重开。提醒58条、媒体10条、设置1条和27个受保护文件保持，唯一业务快照差异为验收操作保留的合成转写草稿。正式及用户语音应用沿用各自原安装身份，设备已回到原桌面。
- 已完成：精简当前台账；阶段46移除，深度故障／硬件穷举与非核心功能／分发扩展退出主线；历史证据完整归档，基本数据与升级门禁保留。
- 已完成：build85分享草稿组合态与仅备忘命令边界修复、最终回归和四平台包核对、Windows两轮运行中保全覆盖、双Android84→85保全、最终包签名与签名块外完整字节一致核对、独立分享真机保存与发行。
- 已补验：Pixel重新连接后，最新保护备份→实际覆盖最终发行ARM64→普通重开，全字段及安全项保持，手机APK摘要与公开包一致；原QA最新58／10／1字段及27个媒体／加密偏好文件保持，用户语音84身份和记录保留。关于页显示85，首次网络错误保留，一次只读重试返回current。见[接回补验](benchmarks/android-final-apk-85-reconnect-2026-11-17.json)。
- 分层状态：1.8.14+85已发布；相关151项／0跳过，最终Linux2647通过／2跳过、Windows2632／20跳过；四平台包通过，Android最终ARM64实装及关于／更新已补验。iPhone85、Windows GUI、真实中文组合输入及完整语音／读屏仍未验，旧版本原生结果保留归属。
- 下一顺序：47日常录入／语音问题与可用设备验收→48备份记录清理和旧目录管理→49图片附件分享与局域网冲突。本版阶段50已完成，后续版本沿用必要保全交付门禁；不恢复已退出主线的专项。
