# 后续阶段与任务（2026-11-02）

## 当前范围（2026-11-17调整）

按用户要求精简主线，只保留直接影响“别忘了”录入、提醒、数据保全与四平台交付的工作。阶段编号保留以便追踪；**阶段46退出当前任务列表**，不改记为全部通过。

当前发行版为[v1.8.22／build93](https://github.com/yarnway/dontforget/releases/tag/v1.8.22)，Windows／Linux／Android／iOS四平台。源码、自动化、安装包与真机结果分别记录；[发行与设备范围](Release_1.8.22_93_2026-11-22.md)。完整旧台账已移至[历史记录](Next_Steps_History_2026-11-02_2026-11-17.md)，旧“剩余”清单不再自动进入主线。

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
| 中文输入与草稿 | 11月21日已在 Pixel 8 Pro **正式版 `com.yarnway.dontforget`（`v1.8.18 (89)`）**使用真实默认中文输入法（微信输入法 `WeType`）完整实机验收全三类入口：① 首页拼音组合态（`ce shi`→`测试 89`）、往返设置页草稿保留与回车单次保存；② 分享草稿编辑页组合态（`wen dang`）禁用「保存为备忘」→候选确认（`文档`）后启用→单次保存；③ 语音核对编辑页（`LiveVoiceTextDialog`）组合态（`yu yin`）禁用「发送」→候选确认（`语音`）后启用→单次保存文本事项（此前 11月20日隔离 QA 包亦已全项通过） | 补 Windows 交互式桌面真实中文输入法及 iPhone 真机中文输入法验收 |
| 语音输入三态 | 84已有 Pixel 真实腾讯预览、编辑及用户发送证据；11月18日 85 QA 诊断包单次播放未复现重复；11月20日完成 `LivePcmRecording`／`TencentRealtimeRecognizer`／`LiveVoiceTextDialog`／`HomeController` 源码审计（无重复追加路径）；11月21日已在 Pixel 8 Pro 正式版 `v1.8.18 (89)` 实机验收真实麦克风按住左滑取消、录中按 Home 键中断与上滑右转语音核对编辑页 `WeType` 组合态单次发送；同日升级至公开正式版 **`v1.8.19 (90)`** 后开启**真实 Android TalkBack**（`TalkBackService`，`touch_exploration_enabled=1`）实机通过单击语音输入条拉起无障碍录音浮层三按钮（`保存原语音`／`转文字编辑`／`取消`，均 `48.0dp @ 360dpi`）与点击 `取消` 干净收口（0 残留录音会话、0 Flutter 异常，测后恢复 TalkBack 关闭与录音权限撤销） | Android 正式包传统按住手势与 TalkBack 读屏语音闭环均已收口；仅留配置云端 ASR 密钥后的真实声学播音全链路转写与 iOS VoiceOver 读屏验收 |
| Android最终归档 | 11月22日 Pixel 正式版 `com.yarnway.dontforget` 经应用内导出升级前最新 `DFBK2` 备份（`3/1/1`、`d033065a...`）后同签名覆盖公开 CI ARM64 **`v1.8.22 (93)`**（`10,321,255 B` / `9.84 MiB`／较 `v1.8.21` 再减 `-3.22%`、较 `v1.8.20` 累计 **`-62.09%`**，SHA‑256 `4f3a18a4...` 与固定发行证书 `3db49656...` 一致，同机三 QA 包未改）；实机确认 `/data/app/.../lib/arm64` 仅保留 `libapp.so`／`libdartjni.so`／`libflutter.so`（`libsqlite3.so` 持续剔除）、Android 16 冷重开（`PID 29578`）零异常且再次导出 `DFBK2` 复核 `3/1/1` 与 `reminders_media_sha256`（`d033065a...`）逐字节一致、实机截图核验新版首页计数徽章（`全部 1`）与设置页 `AI 服务 · 仅本地模式` 徽章清晰完整、关于页显示 `1.8.22 (93)` 且更新检查经一次只读重试返回 `已是最新发布版 / 公开版本 1.8.22 (93)`（前版 `v1.8.20 (91)` 真实 TalkBack 读屏与高对比度复验亦已闭环） | Android `v1.8.22 (93)` 正式包升级、三语精简运行时与新版视觉均已收口；仅留正式版云端 ASR 真实播音专项 |
| Android提醒 | 11月21日已在 Pixel 8 Pro **正式版 `com.yarnway.dontforget`（`v1.8.18 (89)`）**完整闭环实机验收：提前10分钟后台准时送达（`10:28:01`）→展开系统通知点击 **`15分钟后`**（`10:28:07`）→15分钟后后台准时二次送达（`10:43`）→点击通知正文直达 `事项详情`（`测试 89`）；测后已撤销临时通知权限至原始状态 | Android 正式包当前版本核心提醒闭环已收口；后续版本回归沿用同样实机门禁 |
| 普通事项提前提醒 | 快速录入与自动整理默认提前10分钟，可选5／10／15分钟。11月18–20日 Pixel 隔离包已验三档后台送达与改期旧时点零通知；11月21日 **正式版 `com.yarnway.dontforget`（`v1.8.18 (89)`）**实机通过任务编辑器设定事项时间（`10:38`）并选「提前 10 分钟」→`10:28:01` 后台首投→`15分钟后` 延后→`10:43` 后台二次送达→点击正文打开 `事项详情`；同日在 Windows 11 本机实测发现 `DontForget` 系统通知开关当前为关闭（`DisabledForApplication`），已修复 `WindowsToast.script()` 对禁用态的真实报错检测并在安装器补齐 `AppUserModelId\DontForget` 元数据注册（已随 **`v1.8.20+91`** 至 **`v1.8.22+93`** 实装并通过注册表实机核验，`v1.8.22+93` 另补齐弯单引号转义与 10 秒超时收口），同时用临时注册 AUMID 实证真实 WinRT `ToastText02`（含 `dontforget://` 协议与「完成／15分钟后」按钮）投递至 Windows 通知中心（`History.Count=1`）并干净清理 | Android 正式包与 Windows WinRT Toast 协议模板投递／AUMID 元数据注册已验证；待在活动桌面 `WinSta0\Default` 开启 `DontForget` 通知开关后补验点击通知唤醒详情及 iPhone 真机通知 |
| Windows原生入口 | 85至93（`v1.8.14+85`→`v1.8.22+93`）均已完成本机覆盖升级验收。**`v1.8.22+93`** 一次性通过公开 CI 安装包（`13,251,976 B`／较 `v1.8.20` 累计 `-12.08%`，便携包 `-14.45%`）三轮运行中覆盖升级：① **跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.21.92`→`1.8.22.93`，Inno 日志实录 213 ms 优雅释放互斥锁、RestartManager 0 占用、退出码 `0`、全程零强杀，`[InstallDelete]` 100% 清除 `packages\record_web` 残留，27/27 载荷与官方便携包逐字节一致、`MaterialIcons-Regular.otf` 为 `30,580 B`、`AppUserModelId\DontForget` 有效、CLI `--help`/`--add`/`--list` 全通、SQLite 回滚日志头 `[1, 1]` 与 `7/0/1` 及 DPAPI `1` 及普通重开 `PID 37232` 一致）**；② 可见运行态覆盖（`1.8.22.93`→`1.8.22.93`，`1.79s` 退出码 `0`）；③ 自托盘隐藏态覆盖（`1.8.22.93`→`1.8.22.93`，`1.76s` 退出码 `0`，测后 269.8 ms 优雅清理 `REMAINING_WIN_PROCS=0`）。此前已确认非活动隔离桌面 `WinSta0\exebox` 下 Windows DWM 不合成 Flutter ANGLE 客户端帧（`UIA_Nodes=2`） | `v1.8.22+93` Windows 瘦身安装／跨版本托盘隐藏态优雅升级／残留清理／AUMID／CLI／数据与凭据已全部收口；交互式活动桌面 `WinSta0\Default` GUI／托盘右键菜单／桌面中文输入法与点开 Toast 唤醒仍待活动桌面会话实测 |
| iPhone客户端 | 手机最近独立读回为81。同源同验收身份85未签名 IPA 已构建并读回；**`v1.8.22+93`** 未签名 IPA（`10,219,816 B`／`9.75 MiB`／较 `v1.8.20` 累计 `-12.87%`，SHA‑256 `ad8ed003...`）与 `PlugIns/ReminderActivity.appex` 已发布并独立读回；本机仍无 iPhone USB 连接且为 Windows（`MACOS_BUILD_HOST_REQUIRED`／无 Xcode／`devicectl`） | 接入后取最新备份，按既有 AltStore 身份签名覆盖 `v1.8.22 (93)`，核对版本、记录、中文输入、通知、录音与 VoiceOver |
| 界面与文案 | 首页和启动／托盘资源已改用统一品牌图标，手机分类列表去掉重复栏头；11月21日已在 Pixel 8 Pro 正式版完成大字号（`font_scale=1.3`，随后恢复 `1.0`）密度零溢出验收；`v1.8.20 (91)` 已在源码与永久性静态门禁 `test_ui_accessibility_lint.py` 清零全仓 `lib/ui/` 控件语义并经真实 TalkBack 复验；**`v1.8.22 (93)`** 全面升级明暗双主题与 WCAG AA 象限配色、宽卡悬停操作、工作区页签计数与空态引导、底栏时间胶囊、阅读／编辑／仪表盘／设置全链路视觉与键盘体验，并在 Pixel 8 Pro 横屏暗色实机截图复验通过 | Android 正式包视觉、交互与读屏微调已收口；后续继续保持四平台正式包图标与静态无障碍门禁回归 |

## 阶段 48：数据保护与长期管理

**目标：正常备份恢复、升级和清理不丢记录、原件或凭据。**

- 已有普通／加密备份、附件往返、预检／确认／取消、错误密码、导出历史、外部引用保护与目录替换检查；新版本按相关变更选择回归，不重做整套容量实验。
- 84后端已完成[6个真实空间不足场景](Windows_Backup_Disk_Full_2026-11-17.md)和[20个Windows实际进程中断场景](Windows_Recovery_Process_2026-11-17.md)。这些是已完成的限定范围，不再列为待办，也不推广为断电／GUI或所有平台通过。
- 导出历史保留最近20条位置元数据。清除位置记录支持取消、成功与失败反馈，并保护确认期间新增记录和未来格式数据。Pixel 独立包与正式版 `com.yarnway.dontforget`（`v1.8.18+89`，11月20日实机：`导出记录 (2)`→清除取消保留→确认清除成功反馈→最近导出卡片消失→冷重开历史为空，0 异常）均已完成实机验收。
- 内容管理显示已扫描材料的总大小，同一目录内的文件按清单计一次。仍可分别查看筛选结果与选中可释放空间。旧开发目录已接入现有的租约、SQLite 独占、校验和提交保护。11月20日 Pixel 隔离 QA 包已完成有真实附件与 48h 过期孤立原件（`4.11 KiB`）的清理闭环；11月21日已在 Pixel **正式版 `com.yarnway.dontforget`（`v1.8.18 (89)`）**实机验收：① 活跃附件保护（扫描共 `8.29 KiB`、`0 B` 可清理，`df_f89_doc.pdf`、`df_f89_img.png` 与 Windows 同步而来的 `win_formal89.txt` 均标示「仍被引用，保留」；非调试正式版沙箱受 24h 宽限期保护，不伪造系统时间强制删除）；② 完整 `DFBK2` 备份与两步确认恢复（`导入并预检备份`→`结构检查通过`→`核对恢复内容`→勾选确认后启用`替换并恢复`→冷重开后导出复核 `2/0/1` 与 `reminders_media_sha256` 逐字节一致）。原件清理继续保护回收站、归档、草稿、外部备份及历史恢复引用。
- 本机 Windows 11月21日实测：`DatabaseLocationMigrator.retainedSource` 对实机运行目录 `Roaming\com.yarnway.dontforget\DontForget\databases` 只读解析命中 `LocalAppData\DontForget\databases`；基于真实旧库（schema 16，3 条历史 QA 事项，SHA‑256 `56fdfedc...`）与 `notification-epoch.json` 的隔离全真副本已通过 `v1.8.18+89` 真实 `resolveAndMigrate`→schema 16→17 升级→`StorageBootstrap`→`RetainedMediaReferences.read`（`uncertain=false`，源字节 SHA‑256 保持一致）；实机 `LocalAppData\DontForget` 因含 `Signing/` 证书及 `credential-references/` 凭据引用保持只读不动（如确需原地删除旧库文件须由用户单独明确指令）。
- 凭据保持、恢复失败保全及每版最新备份属于基本质量要求；真实安全存储锁定穷举归入按需专项。

## 阶段 49：学习与跨设备完整工作流

**目标：完善现有采集与跨设备继续处理能力。**

| 任务 | 当前状态 | 下一步 |
| --- | --- | --- |
| 分享采集 | 11月21日已在 Pixel 8 Pro **正式版 `com.yarnway.dontforget`（`v1.8.18 (89)`）**完整实机验收：① **真实 Android 系统分享面板（`分享`→点选 `别忘了`→`仅此一次`）**投递 PDF 文档（`df_f89_doc.pdf`，`329 B`）至正式版 `MainActivity`→分享草稿编辑页 `WeType` 组合态禁存／确认启用→保存为备忘；② `ACTION_SEND`（`image/png`，`69 B`）图片分享保存；③ 任务编辑器经 Android 原生 `documentsui` 选中 `df_f89_note.txt`（`131 B`）附加并在应用内预览页核对异步体积显示（`131 B`）、UTF‑8 中文正文及「复制文本／保存副本」按钮（0 异常） | Android 正式包分享采集全链路已收口；iOS 分享扩展待接入 iPhone 补验 |
| 局域网同步 | Windows 已实测默认端口冲突后换端口。11月21日已在 Pixel 8 Pro **正式版 `com.yarnway.dontforget`（`192.168.50.158`，`v1.8.18 (89)`）**与 Windows `v1.8.18+89` 隔离对端（`192.168.50.4:14697`，物理网卡优选，**零 USB 转发**）完成同一真实 Wi‑Fi 子网（`192.168.50.0/24`）4 次直连双向同步实机闭环：Windows 端实收正式版 PDF（`329 B`）与 PNG（`69 B`）原件 SHA‑256 逐字节一致，正式版实收 Windows 事项与附件 `win_formal89.txt`（`106 B`）并受内容管理保护；完成跨设备回收站移入差异采用（`移入本机回收站`）、恢复差异采用（`在本机恢复事项`）与第 4 次同步 0 差异收敛；此前亦已验证正式版服务端 `192.168.50.158:42888` 错误配对码 HTTP `401` 拒绝 | Android 正式版 ↔ Windows 真实 Wi‑Fi 同步已收口；待 Windows GUI 交互会话可用与接入 iPhone 后补全三端 GUI 实机互联 |
| 学习与排程 | 计划管理、词条档案、批量改期、七天预测等已有实现和验收 | 维护已有功能；身份迁移、更多练习与预测扩展移入可选需求池 |

## 阶段 50：正式发布（build93 四平台已发布且本机 Windows／Pixel 实机验收全部收口）

**目标：稳定后交付Windows／Linux／Android／iOS新版Release。**

1. 固定源码、版本、SDK与锁文件，完成必要回归和质量检查；不把CI内部候选写成已安装或已发布。
2. 核对四平台发行包版本、来源、摘要及平台签名／未签名状态；不移动旧标签或覆盖旧附件。
3. 每个Windows新版本：最新数据备份→旧／新包与实际版本核对→本机运行中正常覆盖→安装后文件、全字段、实际凭据与普通重开验证。关闭失败保留证据，不强关或冒记通过。
4. 可用手机分别最新保全、同身份升级及关键功能验收；设备不可用的范围明确列出。iPhone当前采用个人签名路径，安装与签名续期分别记录。
5. 本版93四平台七包、20附件已发布并独立读回（[Release_1.8.22_93_2026-11-22.md](Release_1.8.22_93_2026-11-22.md)），全平台分发包在 `v1.8.21` 基础上再减 **`3.27 MiB`／`-2.18%`**（较 `v1.8.20` 累计缩减 **`83.93 MiB`／`-36.42%`**，Android ARM64 APK 降至 `9.84 MiB`、iOS 未签名 IPA 降至 `9.75 MiB`）；Windows 本机一次性通过公开 CI 跨版本 `SW_HIDE` 托盘隐藏态运行中升级（213 ms 优雅关闭、`[InstallDelete]` 清除 `packages\record_web`、27/27 载荷一致、零强杀）、可见运行态与自托盘隐藏态升级；Pixel 8 Pro 正式版已完成 `1.8.21 (92)`→`1.8.22 (93)` 同签名保全升级、新版 UI 视觉核验与 `已是最新发布版` 更新检查；后续版本按[发布策略](Release_Policy.md)发布并独立读回。macOS客户端、公证、商业签名及商店上架属于可选分发扩展，不附加为当前四平台发布的必做阶段。

## 本轮执行记录

### 11月22日 v1.8.22／build93 稳定性、美观性、易用性、性能与包体综合迭代正式发布及 Windows／Pixel 实机验收全闭环

- **源码**　固定发布提交 `8ecad7c9526856c5f9ba4c307984607d4636d688`（版本号升至 `1.8.22+93`，严格保持 schema 17、SQLite 回滚日志头 `[1, 1]` 与凭据存储格式不变）：
  - **稳定性加固**：Windows 原生 `WM_FONTCHANGE` 空引擎保护、`WM_COPYDATA` 有界读取与冷启动握手前协议／升级信号缓冲、`WindowsToast` PowerShell 5.1 弯单引号转义与 10 秒超时收口；Android `SharedTextBridge` 并发同步、过期目录清理与后台流拷贝防 ANR；`DesktopUpgradeExit.prepare()` 原子回滚、`WorkspaceDrafts.putAll` 结清旧防抖等待者、`HomeController` 录音取消／恢复重试加固、`LLMService.chatCompletionsUrl()` 规范化与 30 秒 `sendTimeout`、`MultiAgentService` 模型名对齐、局域网同步回调 `mediaRecordsProvider` 刷新及媒体播放报错竞态修复。
  - **美观性与易用性升级**：优化浅色表面层次与明暗双主题 WCAG AA `AppTheme.quadrantColor`/`quadrantIcon`；桌面宽卡悬停快捷操作、逾期一键延后与自定义时间、输入栏可交互时间胶囊、工作区页签计数与「全部」空态引导、`N`/`Ctrl+N` 与 `1`–`4` 快捷键、命令面板按键帽、胶囊搜索栏与筛选计数；阅读页 `Escape` 返回／倒计时／清单进度条、编辑页统一 `Material` 分节卡片／48dp 触控热区／未保存圆点、仪表盘三色 KPI 与等宽数字及占比百分比、偏好设置 AI／同步状态徽章（保持 LAN 懒加载）、设置页 API 密钥显隐切换及 `InlineFeedback` 语义色与首帧可读入场动画。
  - **性能与包体再瘦身**：新增三语框架本地化代理 `lib/l10n/framework_localizations.dart` 树摇 116 套未用语言表与 122 套日期符号；Android 启用 `resourceConfigurations` 剔除 69 套无用系统语言资源并排除 `kotlin_builtins`；Windows／Linux 移除 `packages/record_web` 并在 `[InstallDelete]` 清理旧版残留；冷启动预读语言避免重复通知渠道初始化、高频正则静态提升与双向链接分词缓存、内存直更删除／清空事项、`O(N+M)` 批量元数据与例程保存、`KnowledgeGraphView`/`VoiceCaptureFeedback` `RepaintBoundary` 与 `TextPainter` 缓存及 `Riverpod` `select(...)` 收窄。
- **自动化**　本机固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、全仓 `flutter test` **2,713 通过／20 文档化 Windows 跳过／0 失败**（含新增 `test/stability_and_polish_v1_8_22_test.dart` 8 项回归）、Python 脚本测试 **192 通过／6 跳过／0 失败**（含 `test_ui_accessibility_lint.py` 与扩展后的 `test_bundle_size_optimizations.py`）；主线四平台 [CI 44987637794](https://github.com/yarnway/dontforget/actions/runs/44987637794) **7/7** 全绿。
- **安装包与发布**　经 [发布工作流 44989612452](https://github.com/yarnway/dontforget/actions/runs/44989612452) 正式发布 [v1.8.22](https://github.com/yarnway/dontforget/releases/tag/v1.8.22) 并设为 `latest`；独立 API 读回确认标签指向 `8ecad7c9526856c5f9ba4c307984607d4636d688`、全部 20 附件完整且下载 SHA‑256 校验通过、旧版 `v1.8.21`（`7cc4e8e`、20 附件）保持未改；四平台 7 包合计 `153,641,831 B`（`146.52 MiB`，较 `v1.8.21` 再减 `-3.27 MiB`／`-2.18%`，较 `v1.8.20` 累计缩减 `-83.93 MiB`／`-36.42%`）：ARM64 APK `10,321,255 B`（`9.84 MiB`）、通用 APK `29,009,290 B`、AAB `62,430,868 B`、Windows Setup `13,251,976 B`、便携包 `15,719,636 B`、Linux `12,688,990 B`、iOS 未签名 IPA `10,219,816 B`（`9.75 MiB`），详见 [github-release-v1.8.22-2026-11-22.json](benchmarks/github-release-v1.8.22-2026-11-22.json)。
- **Windows 本机官方 CI 三轮运行中升级验收（全 PASS，全程零强杀）**：
  - **跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.21.92`→`1.8.22.93`）**：详见 [windows-upgrade-93-ci-tray-hidden-running-2026-11-22.json](benchmarks/windows-upgrade-93-ci-tray-hidden-running-2026-11-22.json)。最新数据备份后禁止强关覆盖，`Local\DontForget.GracefulUpgradeExit` 在 **213 ms** 内优雅关闭托盘隐藏态 `v1.8.21.92`（RestartManager 0 占用，退出码 `0`）；`[InstallDelete]` 100% 清除 `packages\record_web` 残留；实装 27/27 载荷与官方便携包逐字节一致、PE `1.8.22.93`、`MaterialIcons-Regular.otf` 为 `30,580 B`、`AppUserModelId\DontForget` 有效、CLI `--help`/`--add`/`--list` 全通、SQLite 回滚日志头 `[1, 1]` 与三表（`7/0/1`）及 DPAPI 凭据（`1` 项）全量一致，普通重开（`PID 37232`）稳定运行。
  - **可见运行态与自托盘隐藏态升级（`1.8.22.93`→`1.8.22.93`）**：详见 [windows-upgrade-93-ci-visible-running-2026-11-22.json](benchmarks/windows-upgrade-93-ci-visible-running-2026-11-22.json) 与 [windows-upgrade-93-ci-self-tray-hidden-2026-11-22.json](benchmarks/windows-upgrade-93-ci-self-tray-hidden-2026-11-22.json)，耗时分别 `1.79s` 与 `1.76s`、均退出码 `0`、27/27 载荷与业务／凭据及普通重开通过，测后 269.8 ms 优雅清理测试进程（`REMAINING_WIN_PROCS=0`）。
- **Pixel 8 Pro 正式版官方 CI 升级与新版 UI／瘦身运行时验收（PASS）**：详见 [android-upgrade-93-2026-11-22.json](benchmarks/android-upgrade-93-2026-11-22.json)。升级前应用内导出明文 `DFBK2` 备份（`3/1/1`、`d033065a...`）→同签名覆盖公开 CI ARM64 `v1.8.22 (93)`（`10,321,255 B`，实装 SHA‑256 `4f3a18a4...` 与固定证书 `3db49656...` 一致，同机三 QA 包未改）→实机核验 `/data/app/.../lib/arm64` 不含 `libsqlite3.so`→Android 16 冷重开（`PID 29578`）零异常且再次导出 `DFBK2` 复核 `3/1/1` 与逻辑摘要逐字节一致→实机横屏暗色截图目视确认新版页签计数徽章（`全部 1`）与 `AI 服务 · 仅本地模式` 徽章渲染完整→关于页显示 **`1.8.22 (93)`**，更新检查首次网络波动失败后单次只读重试返回 **`已是最新发布版 / 公开版本 1.8.22 (93)`**，恢复原始输入法与桌面基线。

### 11月22日 v1.8.21／build92 性能与全平台安装包瘦身迭代正式发布、四平台 7 包独立读回与本机 Windows／Pixel 实机验收全闭环

- **源码**　固定发布提交 `7cc4e8e1e848a2b8c7d1e3cf11da9b28202cbd0b`（版本号升至 `1.8.21+92`，严格保持 schema 17、SQLite 回滚日志头 `[1, 1]` 与凭据存储格式不变）：
  - **安装包瘦身**：移除 `cupertino_icons` 与 `sqlite3_flutter_libs`；移除冷启动全量 `package:timezone/data/latest.dart`（改用 `tz.UTC` 零开销初始化）；精简托盘专用 `assets/app_icon.ico` 至 ≤64px；五平台构建启用 `--split-debug-info=build/symbols/<platform>`，规避 Flutter 3.44.9 桌面端 `tool_backend.dart` 图标树摇引号缺陷使 `MaterialIcons-Regular.otf` 缩减 98.2%（`1.65 MB` → `30 KB`）并清理增量 `flutter_assets`；新增 `scripts/prune_windows_bundle.py` 基于 PE 导入表裁剪 7 个未用 CRT DLL 与 `dartjni.dll`，Inno Setup 升级 `lzma2/ultra64` 固实压缩并新增 `[InstallDelete]` 清理旧版残留，便携 ZIP／Linux `.tar.gz` 启用 9 级压缩；Android 启用 `jniLibs.useLegacyPackaging = true` 并剔除桌面 FFI 库 `libsqlite3.so` 与 `DebugProbesKt.bin`／冗余元数据。
  - **运行时性能**：引导阶段提供单次 `DataGeneration` 绑定 `BootstrapSnapshot` 消除冷启动 4 次重复 `Settings` 读取与 2–4 次全表扫描；桌面端并行 `windowManager.ensureInitialized()` 与存储引导；SQLite `onOpen` 增设纯会话级 `cache_size = -8000`／`temp_store = MEMORY`／`busy_timeout = 5000`；`AudioPlayer`／`AudioRecorder` 懒初始化；提醒对账／取消增加快路径、出发例程 `O(1)` 判重、共享 `workspaceRemindersProvider`、草稿 350 ms 防抖合并写盘与 `flushPending()`；记忆化 `Reminder.occurrenceIdentity`、精细收窄根组件／底栏／首页／卡片 `select(...)` 重建范围、合并 10 秒心跳扫描并缓存完成数与 `findChildIndexCallback`、为图标与本地图片增加 `cacheWidth`／`ResizeImage` 解码上限。
- **自动化**　本机固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、全仓 `flutter test` **2,705 通过／20 文档化 Windows 跳过／0 失败**（含 `test/performance_optimizations_test.dart`）、Python 脚本测试 **192 通过／6 跳过／0 失败**（含 `scripts/tests/test_bundle_size_optimizations.py`）；主线四平台 [CI 44942853490](https://github.com/yarnway/dontforget/actions/runs/44942853490) **7/7** 首次全绿（含 Linux／Windows 全量测试、五平台打包及 Windows 安装器／桌面启动冒烟）。
- **安装包与发布**　经 [发布工作流 44945602264](https://github.com/yarnway/dontforget/actions/runs/44945602264) 正式发布 [v1.8.21](https://github.com/yarnway/dontforget/releases/tag/v1.8.21) 并设为 `latest`；独立 API 读回确认标签指向 `7cc4e8e1e848a2b8c7d1e3cf11da9b28202cbd0b`、全部 20 附件完整且下载 SHA‑256 校验通过、旧版 `v1.8.20`（`b820337`、20 附件）保持未改，四平台 7 包合计减少 **`84,581,871 B`（`-80.66 MiB`／`-35.00%`）**：ARM64 APK `-60.83%`（`10,664,355 B`）、通用 APK `-62.27%`（`29,773,890 B`）、AAB `-15.47%`（`63,827,509 B`）、Windows Setup `-11.03%`（`13,410,865 B`）、Windows 便携包 `-13.10%`（`15,967,858 B`）、Linux `-12.67%`（`12,951,085 B`）、iOS 未签名 IPA `-10.73%`（`10,470,373 B`），详见 [github-release-v1.8.21-2026-11-22.json](benchmarks/github-release-v1.8.21-2026-11-22.json)。
- **Windows 本机官方 CI 三轮运行中升级验收（全 PASS，全程零强杀）**：
  - **跨版本 `SW_HIDE` 托盘隐藏态运行中升级（`1.8.20.91`→`1.8.21.92`）**：详见 [windows-upgrade-92-ci-cross-tray-hidden-2026-11-22.json](benchmarks/windows-upgrade-92-ci-cross-tray-hidden-2026-11-22.json)。最新数据备份后禁止强关覆盖，`Local\DontForget.GracefulUpgradeExit` 在 **215 ms** 内优雅关闭托盘隐藏态 `v1.8.20.91`（退出码 `0`）；`[InstallDelete]` 100% 清除 9 项旧版多余 DLL／`cupertino_icons` 残留；实装 29/29 载荷与官方便携包逐字节一致、PE `1.8.21.92`、`MaterialIcons-Regular.otf` 为 `30,048 B`、`AppUserModelId\DontForget` 有效、CLI `--help`/`--add`/`--list` 全通、SQLite 回滚日志头 `[1, 1]` 与三表（`7/0/1`）及 DPAPI 凭据（`1` 项）全量一致，裁剪后 3-CRT-DLL `v1.8.21.92` 普通重开（`PID 33544`）稳定运行。
  - **可见运行态与自托盘隐藏态升级（`1.8.21.92`→`1.8.21.92`）**：详见 [windows-upgrade-92-ci-visible-running-2026-11-22.json](benchmarks/windows-upgrade-92-ci-visible-running-2026-11-22.json) 与 [windows-upgrade-92-ci-self-tray-hidden-2026-11-22.json](benchmarks/windows-upgrade-92-ci-self-tray-hidden-2026-11-22.json)，均退出码 `0`、29/29 载荷与业务／凭据及普通重开通过，测后 265.6 ms 优雅清理测试进程（`REMAINING_WIN_PROCS=0`）。
- **Pixel 8 Pro 正式版官方 CI 升级与瘦身运行时验收（PASS）**：详见 [android-upgrade-92-2026-11-22.json](benchmarks/android-upgrade-92-2026-11-22.json)。升级前应用内导出明文 `DFBK2` 备份（`3/1/1`、`d033065a...`）→同签名覆盖公开 CI ARM64 `v1.8.21 (92)`（`10,664,355 B`，实装 SHA‑256 `8da7e521...` 与固定证书 `3db49656...` 一致，同机三 QA 包未改）→实机核验 `/data/app/.../lib/arm64` 不含 `libsqlite3.so`→Android 16 冷重开（`PID 28138`）零异常且再次导出 `DFBK2` 复核 `3/1/1` 与逻辑摘要逐字节一致→实机截图确认 30 KB 树摇图标渲染完整→关于页显示 **`1.8.21 (92)`** 且检查更新返回 **`已是最新发布版`**，恢复原始输入法与桌面基线。

### 11月21日 v1.8.20／build91 Windows 官方 CI 三模式覆盖升级（含 `SW_HIDE` 托盘隐藏态 207 ms 自动优雅关闭实证）与 Pixel 8 Pro 正式版升级＋TalkBack 复验全部收口

- **源码**　无产品源码变更（全程验证已公开发布的 `v1.8.20` 官方 CI 产物，固定来源 `b820337968b9fa7279928aa87eab5234f387dfba`，未改动任何发布标签或公开附件）。
- **自动化**　沿用固定提交已 7/7 通过的主线四平台 [CI 44887222048](https://github.com/yarnway/dontforget/actions/runs/44887222048) 与发布工作流 [44889388558](https://github.com/yarnway/dontforget/actions/runs/44889388558)。
- **安装包**　全程使用已独立读回并校验 SHA‑256 的公开 Release 附件：`DontForget_Setup_v1.8.20.exe`（`6419ed53...`）、`DontForget_Windows_Portable_v1.8.20.zip`（`744456df...`）与 `DontForget_Android_arm64_v1.8.20.apk`（`43839827...`，固定发行证书 `3db49656...`）。
- **Windows 本机续验（与初验退出码 `5` 失败回执严格分列）**：
  - **续验 1（用户退出后官方 CI 覆盖安装，PASS）**：详见 [windows-upgrade-91-ci-post-exit-2026-11-21.json](benchmarks/windows-upgrade-91-ci-post-exit-2026-11-21.json)。用户退出旧版 `v1.8.19.90`（`PID 28900`）后，完成最新数据与 SQLite 在线备份→覆盖安装（`1.8.19.90`→`1.8.20.91`，退出码 `0`）→38 载荷与官方便携包逐字节一致、PE `1.8.20.91`、CLI `--help`（`rc=0`，`DontForget CLI v1.8.20`）／`--add "   "`（`rc=2`）／`--list`（`rc=0`，10 行输出）、SQLite schema 17 `7/0/1` 全字段与 DPAPI 凭据（`1` 项）及普通重开（`PID 14840`）一致；并实机核验注册表 `HKCU\Software\Classes\AppUserModelId\DontForget`（`DisplayName="DontForget"`、`IconUri` 指向实装 `app_icon.png`）。
  - **续验 2（同桌面可见运行中官方 CI 覆盖升级，PASS，禁止强关）**：详见 [windows-upgrade-91-ci-running-followup-2026-11-21.json](benchmarks/windows-upgrade-91-ci-running-followup-2026-11-21.json)。对运行中 `v1.8.20.91`（`PID 14840`）完成最新备份→`/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS` 正常关闭覆盖（退出码 `0`）→38 载荷、PE `1.8.20.91`、CLI、SQLite `7/0/1`、DPAPI `1` 及普通重开（`PID 35424`）全部通过。
  - **续验 3（`SW_HIDE` 托盘隐藏态官方 CI 安装器运行中自动优雅退出升级，PASS，禁止强关）**：详见 [windows-upgrade-91-ci-tray-hidden-running-2026-11-21.json](benchmarks/windows-upgrade-91-ci-tray-hidden-running-2026-11-21.json)。对运行中 `PID 35424` 调用 `ShowWindow(SW_HIDE)` 隐藏主窗（`window_visible_after_sw_hide=false`）并确认 `Local\DontForget.GracefulUpgradeExit` 已注册后，执行最新备份→直接运行公开 CI `DontForget_Setup_v1.8.20.exe`（`/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`）：Inno Setup 日志实录信号投递后仅 **207 ms** 即收到 `DontForget released single-instance mutex gracefully.`、RestartManager 检测零占用、总耗时 `1.89s` 退出码 `0`（全程零强杀）；38 载荷、PE `1.8.20.91`、`AppUserModelId\DontForget`、CLI、`7/0/1`、DPAPI `1` 及普通重开（`PID 33716`）全部一致；测后通过优雅退出事件在 `273.8 ms` 内干净释放测试进程（无残留锁）。
- **Pixel 8 Pro 正式版续验（PASS）**：
  - **同签名保全升级（`1.8.19 (90)`→`1.8.20 (91)`）**：详见 [android-upgrade-91-2026-11-21.json](benchmarks/android-upgrade-91-2026-11-21.json)。升级前应用内导出明文 `DFBK2` 备份（`2/0/1`、`b4d0a324...`）→同签名覆盖公开 ARM64 `v1.8.20 (91)`（实装 APK SHA‑256 `43839827...` 与公开附件一致，同机三 QA 包未动）→冷重开（`PID 25558`）复核 `2/0/1` 与逻辑摘要逐字节一致并清空临时导出记录；关于页显示 **`1.8.20 (91)`**，检查更新返回 **`已是最新发布版`**。
  - **真实 Android TalkBack 视觉与语义复验**：详见 [pixel-formal-91-talkback-2026-11-21.json](benchmarks/pixel-formal-91-talkback-2026-11-21.json)。实机开启 `TalkBackService` 单击 `按住说话` 打开无障碍录音浮层，三按钮均严格 `>= 48dp` 且截图确认不透明深色底（`#2B2B2B`＋纯白文字）`取消` 按钮清晰醒目；点击 `转文字编辑` 触发顶部 `InlineFeedback`（`"请核对文字，或发送原语音。"`），Accessibility 树确认 0 未加标签 `NAF` 控件、关闭图标精确暴露为 `clickable=true` / `content-desc="关闭"` / `108×108px = 48×48dp`、外层横幅误标计数为 **`0`**、0 Flutter 异常；测后完整恢复 `enabled_accessibility_services=null`、`accessibility_enabled=0`、撤销 `RECORD_AUDIO` 与 `WeType`/`font_scale=1.0` 基线。

### 11月21日 v1.8.20／build91 四平台正式发布、20 附件独立读回与 Windows 初验留证（待 Windows 退出旧版 `PID 28900` 与 Pixel 解锁续验）

- **源码**　固定发布提交 `b820337968b9fa7279928aa87eab5234f387dfba`（版本号升至 `1.8.20+91`、`lib/main.dart` CLI 版本对齐 `v1.8.20`、更新 `docs/Changelog.md` 与 `docs/Release_Notes_v1.8.20.md`，整合托盘优雅升级退出、Toast 禁用态报错与 AUMID 注册、`InlineFeedback` 关闭语义与 TalkBack「取消」WCAG AAA 高对比度及全仓无障碍静态门禁；不更改 schema 17、依赖锁文件或既有凭据存储格式）。
- **自动化**　本机固定 Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题、`report_windows_skipped_tests.py` 通过（14 项文档化 Windows 跳过）、Python 脚本测试 **189 通过／6 跳过／0 失败**；固定提交主线 [CI 44887222048](https://github.com/yarnway/dontforget/actions/runs/44887222048) **7/7** 全部通过（含 Linux／Windows 质量测试、五平台构建及 Windows Server 2022 安装／升级／卸载冒烟）。
- **安装包与发布**　经 [发布工作流 44889388558](https://github.com/yarnway/dontforget/actions/runs/44889388558)（`prepare`＋`publish` 全绿）正式发布 [v1.8.20](https://github.com/yarnway/dontforget/releases/tag/v1.8.20) 并设为 `latest`；独立 API 读回确认标签指向 `b820337968b9fa7279928aa87eab5234f387dfba`、全部 20 个附件完整且下载校验 SHA‑256 一致、Android ARM64 APK（`43839827...`）经本地 `apksigner` 校验固定发行证书 `3db49656...`、iOS 未签名 IPA（`6e17e62c...`）与 `PlugIns/ReminderActivity.appex` `1.8.20+91` 校验通过、旧版 `v1.8.19`（`6eedd2a`、20 附件）保持未改，详见 [github-release-v1.8.20-2026-11-21.json](benchmarks/github-release-v1.8.20-2026-11-21.json)。
- **本机／真机验收（严格分层，不冒记通过）**：
  - **Windows 官方 CI 便携包 CLI 校验（PASS）**：实测 `DontForget_Windows_Portable_v1.8.20.zip`（`744456df...`）PE 版本 `1.8.20.91`，CLI `--help` 管道返回码 `0`（输出 `DontForget CLI v1.8.20`）、`--add "   "` 返回码 `2`、实机持锁态 `--list` 返回码 `75`（`Local data is in use`）。
  - **Windows 本地与 CI 安装器运行中覆盖初验（FAIL，退出码 `5`，原始证据完整留存）**：用户桌面当前运行旧版 `v1.8.19.90`（`PID 28900`，尚不含本版 `Local\DontForget.GracefulUpgradeExit` 事件）。本地包（[windows-upgrade-91-2026-11-21.json](benchmarks/windows-upgrade-91-2026-11-21.json)）与公开 CI 安装器（[windows-upgrade-91-ci-2026-11-21.json](benchmarks/windows-upgrade-91-ci-2026-11-21.json)）均先完成最新数据与 SQLite 在线备份，严格以 `/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`（禁止强杀）尝试覆盖并因跨桌面无可见主窗回滚退出码 `5`；回滚后实装保持 `1.8.19.90`、SQLite 三表（`7/0/1`）哈希与 DPAPI 凭据（`1` 项）完整无损。待用户正常退出 `PID 28900` 后立即续验退出后安装（含 `AppUserModelId\DontForget` 核验）、同桌面运行中升级与 **`SW_HIDE` 托盘隐藏态官方安装器自动优雅关闭升级实证**。
  - **Pixel 8 Pro 正式版升级与 TalkBack 复验（待用户解锁 PIN 后执行）**：设备 `43201FDJG000M7` 当前处于 Android 16 定期安全锁定（`"需要锁定设备以提高安全性。已有一段时间未使用 PIN 码了。"`），严守不绕过锁屏与「先应用内导出最新备份再覆盖安装」约束，暂保持 `1.8.19 (90)`，待解锁后立即执行 `1.8.19 (90)`→`1.8.20 (91)` 保全升级与真实 TalkBack 复验。

### 11月21日 Windows 11 本机 Toast 禁用态检测与 AUMID 注册修复、WinRT 通知投递实证与主线 CI 7/7 通过

- **源码**　提交 `b3d016b4197d842741931e45680ac9a4f9994463`（基于已通过 [CI 44883472602](https://github.com/yarnway/dontforget/actions/runs/44883472602) 7/7 的主线 `fcba535`，未改公开 `v1.8.19` 标签或附件）：
  - **Windows Toast 禁用态准确报错（`lib/services/windows_toast.dart`）**：本机 Windows 11（Build 26300）实测发现当应用通知在系统设置中关闭（`Enabled=0` → `ToastNotifier.Setting == DisabledForApplication`）时，`$notifier.Show(...)` 仍退出码 `0` 导致静默误报成功；且实证 PowerShell 5.1 WinRT 桥在通知开启时返回 `$null`、禁用时返回非空枚举。现改为精确判断 `if ($null -ne $notifier.Setting -and $notifier.Setting -ne [Windows.UI.Notifications.NotificationSetting]::Enabled)`，输出诊断 stderr 并返回退出码 `2`，同步更新 `test/windows_toast_test.dart`。
  - **Windows 安装器补齐 `AppUserModelId\DontForget` 元数据注册（`windows_installer/installer.iss`、`scripts/tests/test_windows_runner_cli.py`）**：写入 `HKCU\Software\Classes\AppUserModelId\DontForget`（`DisplayName` 与 `IconUri` 指向应用品牌图标，卸载自动清理），改善 Windows 10/11 通知中心图标与名称显示。
- **自动化**　前序主线加固提交 `fcba535`（含 Windows 托盘优雅退出通道、浮动提示条关闭语义、TalkBack「取消」对比度与 `test_ui_accessibility_lint.py`）已通过四平台 [CI 44883472602](https://github.com/yarnway/dontforget/actions/runs/44883472602) **7/7**（含 Windows Server 2022 `smoke_windows_installer.ps1` 安装／升级／卸载冒烟）；本提交 `b3d016b` 在固定 Flutter `3.44.9` 下 `flutter analyze --no-pub` 0 问题、`test/windows_toast_test.dart` 13/13 通过、全量 Python 脚本测试 **189 通过／6 跳过／0 失败**，Inno Setup 6.7.3 编译验证通过（12.0s）。
- **本机实测（[windows-toast-and-host-verify-2026-11-21.json](benchmarks/windows-toast-and-host-verify-2026-11-21.json)）**：
  - **协议与快捷方式**：确认本机已装 `v1.8.19.90` 的 `HKCU\Software\Classes\dontforget` 协议指向实装 `dont_forget.exe "%1"`，开始菜单 `DontForget.lnk` 属性库 `System.AppUserModel.ID` 为 `DontForget`。
  - **真实 Windows 11 Toast**：① 针对本机当前被用户关闭通知的 `DontForget`（`Enabled=0`），修复后脚本准确输出 `Windows toast blocked: DisabledForApplication` 并退出码 `2`；② 使用临时注册 AUMID `DontForget.ToastVerify20261121`（测后在 `finally` 中删除）实证真实 WinRT `ToastText02`（含 `dontforget://` 协议唤醒及「完成／15分钟后」双中文动作按钮）成功投递至 Windows 11 通知中心（`History.Count=1`）并经 `History.Remove` 干净清除（`Count=0`）。
  - **隔离 QA 窗口与非活动桌面边界实证**：基于 `b3d016b` 临时隔离 worktree 编译启动 QA 二进制（未触碰用户桌面的 `PID 28900` 或 `HKCU` 协议），验证单主库锁（`SHGetKnownFolderPath`）可靠阻止并发打开实机数据库、二次启动单实例互斥正常退出；同时实证确认在当前代理非活动桌面 `WinSta0\exebox` 下，Windows DWM 不合成 Flutter ANGLE/DirectComposition 客户区帧（`PrintWindow` 可见标题栏与品牌图标，客户区未合成、`UIA_Nodes=2`），因此交互式桌面 GUI／桌面中文输入法／托盘菜单保持诚实标注待在活动桌面 `WinSta0\Default` 实测（测后已彻底清理临时 worktree）。

### 11月21日 v1.8.19／build90 Windows 官方 CI 退出后覆盖安装与同桌面运行中升级续验通过（＋主线托盘优雅退出隔离内核实证）

- **源码**　Windows `v1.8.19` 续验全程使用已发布的公开 GitHub Release 官方 CI 安装包（来源 `6eedd2a`，无产品源码变更）；隔离托盘优雅退出内核实证使用 `main` 提交 `5735db5` 的本地编译产物（未改 `v1.8.19` 标签或公开附件）。
- **自动化**　主线 `5735db5` [CI 44882579998](https://github.com/yarnway/dontforget/actions/runs/44882579998) 中 Linux `Analyze and test` 已通过，`Windows analyze and test` 与五平台构建进行中；`v1.8.19` 发行源码仍归属已 7/7 通过的 [CI 44863670223](https://github.com/yarnway/dontforget/actions/runs/44863670223)。
- **安装包**　使用已独立读回并校验 SHA‑256 的公开 Release 附件 `DontForget_Setup_v1.8.19.exe`（`395d9efe...`）与 `DontForget_Windows_Portable_v1.8.19.zip`（`3ed51804...`）。
- **本机验收（与既有跨桌面退出码 `5` 失败证据严格分列）**：
  - **续验 1（用户退出后覆盖安装，PASS）**：详见 [windows-upgrade-90-ci-post-exit-2026-11-21.json](benchmarks/windows-upgrade-90-ci-post-exit-2026-11-21.json)。确认用户已从桌面／托盘退出 `PID 19044` 后，完成最新数据与 SQLite 在线备份→静默覆盖安装（`1.8.18.89`→`1.8.19.90`，退出码 `0`）→38 个载荷与官方便携包逐字节一致、PE `1.8.19.90`、CLI `--help` 管道返回码 `0`（`DontForget CLI v1.8.19`）／`--add "   "` 返回码 `2`／`--list` 返回码 `0`（10 行输出）、SQLite schema 17 `integrity_check=ok`、`Reminders=7 / MediaRecords=0 / Settings=1` 全业务字段与 DPAPI 凭据（`1` 项）解保护摘要一致、普通重开（`PID 4412`）保持一致。
  - **续验 2（同桌面运行中覆盖升级，PASS，禁止强关）**：详见 [windows-upgrade-90-ci-running-followup-2026-11-21.json](benchmarks/windows-upgrade-90-ci-running-followup-2026-11-21.json)。在 `v1.8.19.90` 运行中（`PID 30340`）执行最新备份→官方 CI 安装器按 `/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS` 正常关闭并完成覆盖（退出码 `0`）→38 载荷一致、PE `1.8.19.90`、CLI 全项通过、业务三表（`7/0/1`）与 DPAPI 凭据（`1` 项）及普通重开（`PID 23768`）保持一致；结束确认无残留隔离进程占用实机库锁。
  - **主线托盘隐藏态优雅退出隔离内核实证（PASS）**：在独立临时 `APPDATA`/`LOCALAPPDATA` 沙箱中启动 `main` 本地编译产物（`PID 32052`），调用 `ShowWindow(SW_HIDE)` 模拟关闭到系统托盘（`window_visible_after_tray_hide=false`）后触发 `SetEvent(Local\DontForget.GracefulUpgradeExit)`，进程经 `onUpgradeExit` 在 **76 ms** 内干净退出（`exit_code=0`）并释放 `Local\DontForget.SingleInstance` 互斥锁（零强杀，未触碰用户实机目录）。

### 11月21日 主线体验与 Windows 托盘优雅升级收口（已合入 `main`，尚未发布新版本）

- **源码**　在公开 `v1.8.19+90` 之后于 `main` 完成三项来自本轮实机与本机验收反馈的定向修复（不改变 schema 17、锁文件、版本号或公开 `v1.8.19` Release 附件）：
  - **Windows 托盘隐藏态优雅升级退出通道（`windows/runner/flutter_window.h`、`windows/runner/flutter_window.cpp`、`windows_installer/installer.iss`）**：GUI 实例（`show_on_create_ == true`）在 `OnCreate` 注册同用户会话级事件 `Local\DontForget.GracefulUpgradeExit`（初始化 `ResetEvent` 防残留误触发、`RegisterWaitForSingleObject` 经 `PostMessageW` 投递 `kUpgradeExitMessage` 复用既有 `onUpgradeExit` / `DesktopUpgradeExit` 优雅收口链路，并在 `OnDestroy` 通过 `UnregisterWaitEx(..., INVALID_HANDLE_VALUE)` 干净解绑）；Inno Setup 在 `PrepareToInstall` 中遵循 `/NOCLOSEAPPLICATIONS` 约束，仅当检测到运行实例互斥锁且对方注册了优雅退出事件时发送信号并等待最多 8 秒自然释放（严禁强杀，超时仍回退标准 Restart Manager）。此修复将在后续包含该源码的新版 Windows 实装后生效，不回溯改变当前运行中的 `v1.8.18.89` 进程。
  - **浮动提示条关闭按钮读屏语义修复（`lib/ui/widgets/inline_feedback.dart`）**：移除原先导致外层容器误标为不可点击按钮 `'关闭'` 且内层 `IconButton` 标签为空的外包 `Semantics`，改用不依赖 `Overlay` 祖先的 `MergeSemantics` + `Semantics(label: closeButtonTooltip)` 与 `ValueKey('inline-feedback-close')`，确保 TalkBack／VoiceOver 精确朗读关闭按钮。
  - **TalkBack 无障碍录音浮层「取消」按钮高对比度增强（`lib/ui/widgets/voice_capture_feedback.dart`）**：将 `voice-accessible-cancel` 按钮底色由透明描边升级为不透明深色底（`Color(0xFF2B2B2B)`＋白色前景，对比度 > 14:1 WCAG AAA），解决在浅灰底弧上对比度不足的问题。
  - **全仓 `lib/ui/` 控件语义清零与永久性静态契约门禁（`ai_profiles_screen.dart`、`about_screen.dart`、`content_management_panel.dart`、`medication_plan_panel.dart`、`task_attachments_panel.dart`、`scripts/tests/test_ui_accessibility_lint.py`）**：补齐 `AIProfilesScreen` 最后一处未加标签的原始 `Switch` 语义标签、`ContentManagementPanel`/`MedicationPlanPanel` 预览图 `semanticLabel` 与 `AboutScreen`/`TaskAttachmentsPanel` 装饰／内嵌缩略图 `excludeFromSemantics`，并新增永久性 Python 静态门禁校验全仓零未加标签 `IconButton`／原始 `Switch`／`Image`。
- **自动化**　固定 Windows Flutter `3.44.9` 下 `check_flutter_version.py --strict` 通过、`flutter analyze --no-pub` 0 问题；定向运行关联 Flutter 测试（`accessibility_guidelines_test.dart`、`quiet_feedback_test.dart`、`desktop_shutdown_test.dart`、`windows_upgrade_exit_channel_test.dart`、`about_screen_test.dart`、`task_attachments_test.dart`、`content_cleanup_test.dart`）全部通过；Python 脚本测试（含新增 `test_ui_accessibility_lint.py` 及 `test_windows_runner_cli.py` 托盘优雅退出契约）**189 通过／6 跳过／0 失败**；推送触发主线四平台 CI 进行全仓回归与隔离安装器冒烟校验。
- **安装包与本地构建**　本机固定 Flutter `3.44.9` 下已通过 `scripts/package_windows.ps1 -NoPub` 完成 MSVC C++ Runner 与 Inno Setup 6.7.3 安装脚本完整编译校验，内置 CLI `--help` 管道返回码 `0`（`DontForget CLI v1.8.19`）；未创建新版本标签或新 Release，公开最新版仍为 `v1.8.19`。
- **真机／本机验收**　Windows 桌面用户进程 `PID 19044`（`v1.8.18.89`）仍处于运行态未强杀，本机 `v1.8.19+90` 退出后安装与同桌面运行中升级继续待用户退出后执行；上述三项新修复待主线 CI 通过及后续发版时并入真机回归，当前不记为已实机发布验收。

### 11月21日 v1.8.19／build90 四平台正式发布、Pixel 正式版保全升级与真实 TalkBack 实机验收（含 Windows CI 安装包运行中退出码 5 留证）

- **源码**　固定发布提交 `6eedd2a1717fb794a902fe22c2d585a1ecf0fdd7`（代码提交 `7e28ef0953b030fd482fdf3c36208b93dfb49da9`，schema 17）。
- **自动化**　主线 [CI 44863670223](https://github.com/yarnway/dontforget/actions/runs/44863670223) 七项任务全部通过（Linux `Analyze and test`、Windows `Windows analyze and test` 及 Windows／Linux／Android／macOS／iOS 五平台构建与桌面安装／启动冒烟）；本机固定 Flutter `3.44.9` 全量测试 `2,699 通过 / 20 跳过 / 0 失败`、Python 测试 `184 通过 / 6 跳过`。
- **安装包与发布**　经 [发布工作流 44869031743](https://github.com/yarnway/dontforget/actions/runs/44869031743) 发布 [v1.8.19](https://github.com/yarnway/dontforget/releases/tag/v1.8.19) 并设为 `latest`，独立读回校验全部 20 个公开附件、Android 三包固定发行证书（`3db49656...`）、iOS 未签名 IPA 与 WidgetKit 扩展及旧版 `v1.8.18`（`4855976`、20 附件）保持未改，详见 [github-release-v1.8.19-2026-11-21.json](benchmarks/github-release-v1.8.19-2026-11-21.json)。
- **真机／本机验收**：
  - **Pixel 8 Pro 正式版同签名保全升级（PASS）**：详见 [android-upgrade-90-2026-11-21.json](benchmarks/android-upgrade-90-2026-11-21.json)。升级前应用内导出最新明文 `DFBK2` 备份（schema 17、`2/0/1`、`reminders_media_sha256: b4d0a324...`）→同签名覆盖公开 ARM64 `v1.8.19 (90)`（实装 APK SHA‑256 `69f2f6e5...` 与公开附件一致，同机 QA 包未动）→冷重开（`PID 20449`）后复核导出 `2/0/1` 与逻辑摘要逐字节一致并清空临时导出记录；关于页显示 **`1.8.19 (90)`**，检查更新返回 **`已是最新发布版`**。
  - **Pixel 8 Pro 正式版真实 Android TalkBack 读屏验收（PASS）**：详见 [pixel-formal-90-talkback-2026-11-21.json](benchmarks/pixel-formal-90-talkback-2026-11-21.json)。核验「数据与安全」（加密态两处密码显隐按钮均为 `显示密码`、`108×108px = 48×48dp`，`naf_count=0`）与「设备与同步」（局域网同步 `Switch` 为 `局域网同步`、`135×108px = 60×48dp`，`naf_count=0`）；开启真实 `TalkBackService`（`accessibility_enabled=1`、`touch_exploration_enabled=1`）并临时授予录音权限，单击首页 `按住说话` 成功弹出无障碍录制浮层且三按钮 **`保存原语音`／`转文字编辑`／`取消`** 均满足 `48.0dp`（`108px @ 360dpi`），点击 `取消` 正常收口（`RecordingActivityMonitor` 无残留、0 Flutter 异常），测后完整恢复 `enabled_accessibility_services=null`、`accessibility_enabled=0`、撤销 `RECORD_AUDIO` 与 `WeType`/`font_scale=1.0` 基线。
  - **Windows CI 官方包运行中覆盖升级（FAIL，退出码 `5`，留证待续验）**：详见 [windows-upgrade-90-ci-2026-11-21.json](benchmarks/windows-upgrade-90-ci-2026-11-21.json)。CI 官方便携包 PE `1.8.19.90` 与 CLI `--help` 管道（`rc=0`、`DontForget CLI v1.8.19`）／`--add "   "`（`rc=2`）独立校验通过；使用 CI 官方 `DontForget_Setup_v1.8.19.exe`（SHA‑256 `395d9efe...`）按 `/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS` 尝试覆盖运行中的用户桌面 `PID 19044`（`v1.8.18.89`）仍因跨桌面 `RmUnknownApp` 正常关闭失败并回滚（退出码 `5`），实装版本保持 `1.8.18.89`、业务三表（`7/0/1`）与 DPAPI 凭据（`1` 项）完好，遵循 `AGENTS.md` 不强杀进程且不冒记通过，待用户退出 `PID 19044` 后分别续验退出后安装与同桌面运行中升级。

### 11月21日 v1.8.19／build90 无障碍读屏收口、Windows CLI／Runner 修复、UTF‑16 安全截断与本机运行中升级初验留证

- **源码**　固定提交 `7e28ef0953b030fd482fdf3c36208b93dfb49da9`（版本升至 `1.8.19+90`，不更改 schema 17、依赖锁文件或既有凭据存储格式）：
  - **阶段 47 无障碍读屏（TalkBack / VoiceOver）与 WCAG AA**：基于 `flutter_a11y_agent` 全量审计及 Pixel 8 Pro 正式版 XML 实查，修复移动语音按住条读屏阻塞（`MediaQuery.accessibleNavigationOf(context)` 下支持单次点击／双点激活启动录音，解除浮层 `AbsorbPointer` 并提供 >= 48dp 高对比度 `保存原语音`／`转文字编辑`／`取消` 按钮，完全保留原有按住滑动手势）；补齐加密备份／恢复全部 3 处密码显隐按钮动态三语 `tooltip`、局域网同步 `Switch` 语义标签、分享编辑器返回按钮 `tooltip` 与输入框标签、首页图片预览 48dp 关闭按钮与 `semanticLabel`、只读清单完成状态语义及附件卡片 `enabled`/`semanticLabel`；扩大任务详情清除时间按钮、情境触发 `ChoiceChip`、设置页外链 `ActionChip`、语音编辑页与提醒通知条触控热区至 >= 48dp；解除语音编辑页高字号隐藏错误提示并补齐 `liveRegion`、`Semantics(header: true)`、`CheckedPopupMenuItem`、局域网冲突弹窗 2.0x 缩放防溢出与 WCAG AA 对比度修复；新增 `test/accessibility_guidelines_test.dart`。
  - **Windows CLI／Runner 与 UTF‑16 代理对安全截断**：修复 `windows/runner/main.cpp` `ConfigureStandardStreams()` 保留重定向管道／文件流且仅在纯父控制台无重定向时调用 `FlutterDesktopResyncOutputStreams()`（解决 `0xC0000409` 崩溃与管道捕获为空），`IsCliInvocation()` 改用 `CommandLineToArgvW` 精确参数比对，`FlutterWindow` CLI 禁用启动闪窗，`lib/main.dart` CLI 版本对齐 `v1.8.19`、退出前冲刷流且 `--add` 空参返回码 `2`；抽离共享 `lib/services/text_bounds.dart`（`truncateRunes`/`truncateUtf16Safe`）消除 `LLMService`、`MultiAgentService`、`AppUpdateService`、`LanSyncService._safeFileName`、`main.dart` 与 `WindowsToast` 的 UTF‑16 代理对切分风险；补齐中／英／日三语无障碍词条、分享收件箱提示、`StorageUnavailableScreen` 三语副标题及使用／开发／打包文档；新增 `test/text_bounds_test.dart` 与 `scripts/tests/test_windows_runner_cli.py`。
- **自动化**　固定 Windows Flutter `3.44.9` 下：`python scripts/check_flutter_version.py --strict` 通过，`flutter analyze --no-pub` 0 问题，`python scripts/report_windows_skipped_tests.py` 通过（14 项文档化 Windows 跳过），Python 脚本测试 **184 通过／6 项 POSIX 跳过**，全仓 `flutter test --no-pub --concurrency 2 --timeout 2m` **2,699 通过／20 项文档化 Windows 跳过／0 失败**。
- **安装包**　基于干净提交 `7e28ef0` 本机固定 Flutter `3.44.9` 构建 Windows x64 未签名安装包 `DontForget_Setup_v1.8.19.exe`（`15,071,091 B`，SHA‑256 `55097c2402cd4603934390e8284a3ca08e2a627a17ac13492d31dd851101e0cf`）与便携包 `DontForget_Windows_Portable_v1.8.19.zip`（`18,374,315 B`，SHA‑256 `3f05df2a8d1db2e1be0ea86e0331ce9ae416255ab9f85d3caf612e4a8a4e31a9`），通过 `scripts/verify_artifacts.py` 校验；尚未发布 `v1.8.19` GitHub Release。
- **本机／真机验收**　详见 [windows-upgrade-90-2026-11-21.json](benchmarks/windows-upgrade-90-2026-11-21.json)：
  - **Windows 运行中覆盖升级（初验正常关闭失败，保留证据）**：升级前对实机运行目录完成最新数据与 SQLite 在线备份并验证一致；实机已运行用户经 `explorer.exe`（PID `6556`）启动的 `dont_forget.exe`（PID `19044`，`v1.8.18.89`）。自当前隔离桌面（`WinSta0\exebox-...`）调用安装器 `/CLOSEAPPLICATIONS /NOFORCECLOSEAPPLICATIONS`（禁止强关），Restart Manager 命中 `DontForget` 但因跨桌面／托盘无可见主窗将其归类为 `RmUnknownApp`（`Type=0, Restartable=False`）导致无法自动关闭，安装器在 0.7s 内中止并回滚（**退出码 `5`**）。独立复核安装文件仍保持 `1.8.18.89`，业务三表（`7/0/1`）与 DPAPI 凭据（1 项）完好无损。遵循 `AGENTS.md`，未强杀用户进程，保留本次失败证据，待用户从桌面／托盘退出 `DontForget` 后继续执行退出后覆盖安装与同桌面运行中升级续验（两者分别记录，不冒记通过）。
  - **内置 Release CLI 实测**：对 `build\windows\x64\runner\Release\dont_forget.exe` 实测 `--help` 管道捕获返回码 `0` 且完整输出 `DontForget CLI v1.8.19`、`--add "   "` 返回码 `2`、在 PID `19044` 持有库锁时 `--list` 正确返回码 `75`（`Local data is in use`）。
  - **待续验**：用户退出 PID `19044` 后完成 Windows 本机 `v1.8.19+90` 覆盖安装与同桌面运行中升级、主线 CI 通过后发布四平台 `v1.8.19`、CI 官方安装包复验、Pixel 8 Pro 正式版 `com.yarnway.dontforget` 同签名升级至 `1.8.19 (90)` 及真实 Android TalkBack 实机读屏验收。

### 11月21日 正式版实机验收收口（Pixel 8 Pro 公开正式版 `com.yarnway.dontforget` `v1.8.18 (89)` 全链路＋Windows 旧库全真副本接管）

- **源码**　无产品源码变更（全程基于公开 `v1.8.18` 发布提交 `4855976`）。
- **自动化**　沿用 `v1.8.18+89` 四平台主线 [CI 44749926901](https://github.com/yarnway/dontforget/actions/runs/44749926901)（7/7 通过）与本机全量套件（2,686 通过／20 跳过／0 失败）；新增 Windows `v1.8.18+89` 实机旧库副本迁移与实机 `retainedSource` 只读验证全部通过。
- **安装包**　全程使用 Pixel 8 Pro 已实装的公开正式发布包 `com.yarnway.dontforget`（`1.8.18 (89)`，APK SHA‑256 `8dcb28de...` 与 GitHub Release 公开 ARM64 附件完全一致，发行证书 `3db49656...`）；未构建新包，未改动 `v1.8.18` 标签或 Release 附件。
- **真机／本机验收**　完整证据回执见 [pixel-formal-89-acceptance-2026-11-21.json](benchmarks/pixel-formal-89-acceptance-2026-11-21.json)：
  - **测前保全**：经正式版应用内导出测前明文 `DFBK2` 备份（`pre-formal-acc89-dontforget-2026-11-21-101638335.dfbackup`，`2/0/1`，`reminders_media_sha256: b4d0a324...`）并拉取至本机留存。
  - **阶段 47（正式版）**：① 真实 `WeType` 首页（`ce shi`→`测试 89` 单次保存）、分享草稿编辑页（`wen dang` 组合态禁存→`文档` 启用保存）与语音核对编辑页（`yu yin` 组合态禁用「发送」→`语音` 启用单次保存）全三入口实机通过；② 真实麦克风按住左滑取消、录中按 `Home` 键中断（`RecordingActivityMonitor` 无残留录音会话）；③ 系统大字号 `font_scale=1.3`（全部列表＋四象限分类页，0 溢出，随后恢复 `1.0`）；④ 任务编辑器设事项时间 `10:38` ＋「提前 10 分钟」→`10:28:01` 后台首投→展开通知点击 **`15分钟后`**（`10:28:07`）→`10:43` 后台准时二次送达→点击通知正文直达 `事项详情`（`测试 89`）。
  - **阶段 48（正式版＋Windows）**：① 正式版内容管理扫描 `8.29 KiB`（`0 B` 可清理），确认活跃附件 `df_f89_doc.pdf`、`df_f89_img.png` 与同步而来的 `win_formal89.txt` 均标示「仍被引用，保留」；② 正式版经 `导入并预检备份`→`结构检查通过`→`核对恢复内容`→勾选确认框后启用`替换并恢复`完成真实 `DFBK2` 恢复，冷重开（PID `11578`）后复核导出快照 `2/0/1` 且 `reminders_media_sha256` 与测前基线 `b4d0a324...` 逐字节一致，随后清空临时导出记录；③ Windows 本机只读核验 `DatabaseLocationMigrator.retainedSource` 解析命中 `LocalAppData\DontForget\databases`（实机旧库 SHA‑256 `56fdfedc...` 全程未改动），并基于真实 schema 16 旧库全真副本完成 `resolveAndMigrate`→schema 16→17 升级→`StorageBootstrap`→`RetainedMediaReferences.read` 全链路通过。
  - **阶段 49（正式版）**：① 通过 **Android 原生系统分享面板（`分享`→点选 `别忘了`→`仅此一次`）**成功投递 `df_f89_doc.pdf`（`329 B`）至正式版 `MainActivity` 并保存，同时验收 `image/png`（`69 B`）分享保存与原生 `documentsui` 选取 `df_f89_note.txt`（`131 B`）附加及应用内 UTF‑8 预览（顶部 `131 B` 体积徽标＋中文正文＋复制／保存副本）；② 确认零 USB 转发后，正式版（`192.168.50.158`）与 Windows `v1.8.18+89` 隔离对端（`192.168.50.4:14697`）完成 4 次真实 Wi‑Fi 直连双向同步：Windows 实收正式版 PDF／PNG 原件 SHA‑256 逐字节一致，正式版实收 Windows 事项与附件 `win_formal89.txt`，并实机验收跨设备回收站移入采用、恢复采用与第 4 次同步 0 差异收敛。
  - **测后不变式与环境边界**：全程 0 Flutter 异常；已撤销正式版临时授予的 `POST_NOTIFICATIONS` 与 `RECORD_AUDIO`（均恢复 `granted=false`），清理手机测试文件，确认 `WeType` 与 `font_scale=1.0` 不变并返回桌面。当前仍受环境／硬件条件限制未执行的项明确留存：Windows 交互式桌面 GUI／托盘／Toast／桌面中文输入法（`UIA_CHILDREN=0`）、iPhone `v1.8.18 (89)` 真机（无 iPhone USB 且无 macOS／Xcode）、正式版云端 ASR 真实声学播音转写（正式版未配置 ASR 密钥）、TalkBack／VoiceOver 读屏、以及实机 `LocalAppData\DontForget` 原地清理（含签名证书与凭据引用）。

### 11月20日 阶段 47／48／49 续验（Pixel 8 Pro `v1.8.18+89` 正式包零污染验证＋语音编辑／中断＋系统文件选择器与 PDF 分享）

- **源码**　无新增产品源码改动（基于公开 `v1.8.18` 发布提交 `4855976`）；完成语音识别管道（`LivePcmRecording`、`TencentRealtimeRecognizer`、`LiveVoiceTextDialog`、`HomeController`）全链路代码审计，确认 PCM 偏移顺序读取、按分片索引覆写与全量文本替换逻辑不存在重复追加路径。
- **自动化**　沿用 `v1.8.18+89` 已通过的主线四平台 [CI 44749926901](https://github.com/yarnway/dontforget/actions/runs/44749926901) 与本机全量套件（2,686 通过／20 跳过／0 失败），无新增产品代码变更。
- **安装包**　沿用已实装的公开正式版 `com.yarnway.dontforget`（`v1.8.18 (89)`，证书 `3db49656...`）与同源隔离 QA 包 `com.yarnway.dontforget.acceptance.sync20261118`（`v1.8.18 (89)`），未构建新安装包，未改动 `v1.8.18` 标签或 Release 附件。
- **真机验收**　详见 [pixel-89-followup-2026-11-20.json](benchmarks/pixel-89-followup-2026-11-20.json)：
  - **正式版 `com.yarnway.dontforget` 零污染验收**：① 阶段 47：首页真实 `WeType` 中文拼音输入（`ce shi`→`测试`）往返设置页草稿完整保留并清空（0 数据库写入）；② 阶段 48：数据与安全页 `导出记录 (2)` 清除流程实机验收「取消保留→再次打开确认清除→显示已清除反馈→最近导出卡片消失→冷重开后导出历史为空」，0 Flutter 异常；③ 阶段 49：开启局域网同步服务实网广播 `192.168.50.158:42888`，Windows（`192.168.50.4`）直连 Wi‑Fi 发送错误配对码被正式版正确返回 HTTP `401` 拒绝（随后关闭服务，0 数据写入）。
  - **隔离 QA 包 `sync20261118` 补齐项**：① 阶段 47 语音三态与中文组合：临时仅对 QA 授予麦克风权限（测后已撤销 `granted=false`），实机验证按住左滑取消（0 新增记录、无残留临时音频）、录中按 Home 键中断（0 新增记录、`RecordingActivityMonitor` 无残留录音会话）、上滑右转进入语音核对编辑页（`LiveVoiceTextDialog`）在 `WeType` 拼音组合态 `ce shi` 时精确禁用「发送」按钮（`enabled=false, clickable=false`）、候选确认 `测试` 后立即启用、点击「发送」仅落库单条中文文本事项 `测试`（`0` 新增音频记录）；② 阶段 49 系统文档选择器与 PDF 分享：任务编辑器调用 Android 原生 `documentsui` 选中 `df_qa_preview_89.txt`（`115 B`）附加并校验落盘 SHA‑256 一致、附件卡片展示文件名与体积且点击打开 UTF‑8 中文预览正常；另通过 `ACTION_SEND`（`application/pdf`，`content://media/external/file/862`，`329 B`）导入 `df_qa_share_89.pdf` 至分享草稿并保存为备忘，导入原件 SHA‑256 逐字节一致。测后已完整恢复 QA 安装前 `3/0/1` 数据基线、撤销录音权限、清理测试下载文件，确认默认输入法与字号 `1.0` 未变。
  - **仍留存未完成／受限项**：Windows 原生 GUI／托盘／Toast／桌面中文输入法（当前非交互桌面会话 UIA 根节点为空）、iPhone `v1.8.18 (89)` 真机升级与功能（无 iPhone USB 与 macOS／Xcode）、Windows 历史 `LocalAppData\DontForget` 目录人工接管（需用户明确授权变更旧目录）、真实声学播音转写与 TalkBack／VoiceOver 读屏、Android 系统分享面板人工点选（同机多包同名）及正式版需写入业务数据的通知／语音／双向同步全流程。

### 11月20日 v1.8.18／build89 四平台正式发布、CI 安装包运行中升级与 Pixel 正式版保全升级

- **源码**　固定发布提交 `4855976b7b13edb26f279ba0c163f1a9095944ad` 推送至 `origin/main`（包含 `v1.8.15`–`v1.8.18` 四轮代码与 `docs/Release_Notes_v1.8.18.md`）。
- **自动化**　主线 [CI 44749926901](https://github.com/yarnway/dontforget/actions/runs/44749926901) 七项任务全部通过（Ubuntu Linux `Analyze and test`、Windows 2022 `Windows analyze and test` 及五平台候选构建与安装／启动冒烟）。
- **安装包与发布**　通过 [发布工作流 44754960147](https://github.com/yarnway/dontforget/actions/runs/44754960147) 发布 [v1.8.18](https://github.com/yarnway/dontforget/releases/tag/v1.8.18) 并设为 `latest`，独立读回校验全部 20 个附件、Android 三包固定发行证书（`3db49656...`）、iOS 未签名 IPA 主包与 WidgetKit 扩展及旧版 `v1.8.14` 保持未改，见 [github-release-v1.8.18-2026-11-20.json](benchmarks/github-release-v1.8.18-2026-11-20.json)。
- **真机／本机升级**　① Windows 本机下载并校验 CI 官方安装包（SHA‑256 `0cc56abf...`）后在运行中执行最新备份→静默正常覆盖升级→38 载荷与 CI 便携包逐字节一致、PE `1.8.18.89`、DB `7/0/1` 与 DPAPI 凭据及普通重开保持，见 [windows-upgrade-89-ci-2026-11-20.json](benchmarks/windows-upgrade-89-ci-2026-11-20.json)；② Pixel 8 Pro 正式版 `com.yarnway.dontforget` 先经应用内导出最新备份，再同签名覆盖公开 ARM64 `v1.8.18 (89)`（SHA‑256 `8dcb28de...` 与公开附件一致），冷重开核对 2／0／1 记录摘要一致、品牌图标更新、关于页显示 `1.8.18 (89)`、更新检查返回「已是最新发布版」，见 [android-upgrade-89-2026-11-20.json](benchmarks/android-upgrade-89-2026-11-20.json)。未验范围（Windows GUI／托盘／Toast、iPhone 89 真机、build84 语音重复与读屏、旧 LocalAppData 人工接管、系统分享面板手选文档）保持如实留存。

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
