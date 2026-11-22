# DontForget (别忘了) - 系统与技术架构设计文档

> **版本**：v1.8.22（build93）  
> **更新时间**：2026-11-22  
> **定位**：本地优先（Local-First）· 端侧数据保全 · 多模态录入与 AI 辅助整理 · 四平台（Windows / Linux / Android / iOS）事项、提醒与复习工作台

---

## 1. 架构总览

DontForget 采用清晰的分层架构，围绕 **单进程所有权（Process Ownership）**、**代数隔离（DataGeneration）**、**运行时恢复门控（RuntimeRecoveryGate）** 与 **响应式 Riverpod 状态管理** 构建，确保跨平台日常录入、提醒调度、局域网同步、加密备份恢复与附件清理的一致性和可恢复性。

```text
┌──────────────────────────────────────────────────────────────────────┐
│                      展现层 (Presentation Layer)                     │
│  - 统一 Material 3 设计令牌 (AppTheme: light/dark, WCAG AA 象限配色) │
│  - 三语框架本地化代理 (framework_localizations: zh/en/ja 树摇裁剪)   │
│  - 主工作台 (HomeScreen, TaskWorkspaceOverview, TaskBoard, Quadrant) │
│  - 默认只读详情与显式编辑 (TaskDetailScreen / TaskEditScreen)        │
│  - 多模态、实时语音三态与 TalkBack 读屏浮层 (InputBottomBar / Share) │
│  - 看板、知识图谱、学习排程与专注工具 (Dashboard / Graph / Planning) │
│  - 设置中心与数据管理 (Preferences / Settings / Backup / Content)    │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ watch / select / O(1) index
┌──────────────────────────────────▼───────────────────────────────────┐
│                   状态与协调层 (Providers & State)                   │
│  - BootstrapSnapshot (DataGeneration 绑定冷启动单次快照，消除重扫)   │
│  - remindersProvider + workspaceRemindersProvider + O(1) 索引        │
│  - mediaRecordsProvider + mediaRecordByIdProvider (O(1) 索引)        │
│  - settingsProvider / workspaceDraftsProvider (350ms 防抖+flush)     │
│  - homeControllerProvider (录入/语音/多模态串行队列与草稿保全)       │
│  - runtimeRecoveryGateProvider (恢复前排空全部前台活动与回调)        │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ generation-fenced operations
┌──────────────────────────────────▼───────────────────────────────────┐
│                    领域与服务层 (Domain & Services)                  │
│  - AI 与语音：LLMService / MultiAgentService / TencentRealtimeASR    │
│  - 提醒与桌面：NotificationService / WindowsToast / DesktopUpgrade   │
│  - 跨设备同步：LanSyncService (物理网卡优先、并发上限、双向附件校验) │
│  - 分享采集：SharedTextBridge (后台线程拷贝防ANR) / SharedTextInbox  │
│  - 数据保护：StreamingBackupService / PortableBackupService          │
│  - 清理保护：ContentCleanupService / RetainedMediaReferences         │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ exclusive ownership & transactions
┌──────────────────────────────────▼───────────────────────────────────┐
│                     数据持久层 (Data & Storage)                      │
│  - DatabaseHelper (SQLite Schema v17, 回滚日志 [1, 1], 单进程锁租约) │
│  - 会话级 PRAGMA (cache_size=-8000 / temp_store=MEMORY / busy=5000)  │
│  - StorageBootstrap / DatabaseRecovery / DatabaseLocationMigrator    │
│  - LocalMediaStore (受管原件目录与活动标记 OwnedMaterialActivity)    │
│  - 系统安全存储 (DPAPI / Keychain / Keystore；不随备份导出明文密钥)  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. 核心架构原则与关键子系统

### 2.1 数据安全与恢复门控（Storage & Recovery）
- **启动门控（`StorageBootstrap`）与冷启动快照（`BootstrapSnapshot`）**：主界面渲染前先获取进程目录锁（`acquireOwnership`）、校验未完成恢复日志并完成安全迁移，桌面端与 `windowManager.ensureInitialized()` 并行初始化；同时捕获绑定当前 `DataGeneration` 的单次 `BootstrapSnapshot` 供 `settingsProvider`／`remindersProvider`／通知引导复用，避免冷启动重复全表扫描。异常时进入独立于 `ProviderScope` 的三语 `StorageUnavailableScreen`。
- **SQLite 回滚日志不变量（Schema v17，禁止 WAL）**：主库严格保持经典回滚日志模式（文件头字节 18–19 恒为 `[1, 1]`）与既有 schema 17 索引布局，以确保加密备份、进程中断恢复、旧版回退与离线工具零 `-wal`/`-shm` 耦合；`onOpen` 仅设置纯会话级 `cache_size = -8000`、`temp_store = MEMORY` 与 `busy_timeout = 5000`。
- **代数栅栏（`DataGeneration`）与恢复门控（`RuntimeRecoveryGate`）**：所有异步读写、通知动作、录音、同步及备份操作均绑定代数令牌；在数据库恢复或目录接管前先排空后台任务并经 `WorkspaceDrafts.flushPending()` 结清防抖写入，恢复后旧代数写入被拒绝。
- **维护租约（`DatabaseMaintenanceLease`）**：覆盖恢复、回退与只读预检期间持有独占租约，历史完整性校验动态兼容 `7..schemaVersion`（当前 v17）。
- **系统凭据隔离**：模型与语音 API 密钥统一保存于系统安全存储（Windows DPAPI / macOS & iOS Keychain / Android Keystore），新备份默认不导出密钥。

### 2.2 内容保护与备份恢复（Backup & Content Management）
- **流式/可移植加密备份（`StreamingBackupService` / `PortableBackupService`）**：支持未加密与口令加密包（`DFBK2`、AES-256-GCM + PBKDF2-HMAC-SHA256）、1 MiB 分块大附件流式读写、预检摘要核对与失败自动回退。
- **原件引用保护（`ContentCleanupService` + `RetainedMediaReferences`）**：扫描真实受控数据库目录（`acquireOwnership()`）中的 `ha_snapshot.json`、`dont_forget_v3.mirror.db`、`recovery-*`、`schema-upgrade-*` 与迁移回执，同时保护回收站、归档、分享草稿与外部登记备份引用；遇到未知或损坏材料保守阻断清理。

### 2.3 跨设备局域网同步、分享采集与原生桌面入口
- **局域网双向同步（`LanSyncService`）**：
  - 自动优先选择物理局域网 IPv4（`192.168.x` > `10.x` > `172.16–31.x`），避开 WSL/Hyper-V/Docker/VPN 虚拟网卡。
  - PIN 常量时间比对、错误计数锁定（429）、64 MiB 请求体未读拒收（`detachSocket` 立即返回 413 并断开连接）、入站并发上限（8 路，超限 503）与单次预加载合并（消除 N+1 SQL 查询）；采用对端变更后自动刷新 `mediaRecordsProvider`。
  - 支持任务附件原件双向传输（32 MiB 单附件限制、SHA‑256 摘要核对、暂存落盘并在事务回滚时清理）。
  - 冲突对比对话框（`LanSyncConflictsDialog`）支持差异字段摘要、本机/对端对比视图以及确认后采用对端文案或回收站状态。
- **分享采集（`SharedTextBridge.kt` + `SharedTextInbox`）**：Android 原生 `SharedTextBridge` 使用 `@Synchronized` 并发保护与后台单线程 `shareExecutor` 执行附件流拷贝（避免主线程 I/O 引发 ANR）并自动清理过期暂存目录；所有分享附件严格限定于应用私有 `shared_handoff/<share-id>/` 目录，独立持久化不覆盖首页输入草稿。
- **Windows 原生运行时与托盘优雅升级**：
  - `windows/runner/flutter_window.cpp` 注册同用户会话级事件 `Local\DontForget.GracefulUpgradeExit`，供 Inno Setup 在运行中或托盘隐藏态（`SW_HIDE`）请求 `DesktopUpgradeExit` 优雅收口（严禁强杀），并缓冲引擎握手前到达的升级信号与 `dontforget://` `WM_COPYDATA` 协议消息；`WM_FONTCHANGE` 具备空引擎保护、`WM_COPYDATA` 采用有界读取。
  - `WindowsToast` 检测通知禁用态（`DisabledForApplication` 退出码 `2`），对 PowerShell 5.1 四类 Unicode 弯单引号（`U+2018`–`U+201B`）及反引号/`$` 完整转义，并设置 10 秒子进程超时保护；安装器注册 `HKCU\Software\Classes\AppUserModelId\DontForget` 元数据。

### 2.4 展现层、无障碍与性能（UI/UX & Performance）
- **设计系统（`AppTheme`）**：统一 Material 3 明暗主题令牌与 WCAG AA 象限色／图标（`AppTheme.quadrantColor` / `quadrantIcon`），支持 200% 系统字体缩放与窄屏响应式布局。
- **无障碍与读屏门禁**：全仓 `lib/ui/` 图标按钮、读屏标签与对比度由永久性静态测试 `scripts/tests/test_ui_accessibility_lint.py` 守卫；TalkBack／VoiceOver 模式下自动提供单击直达三按钮无障碍录音浮层（48dp 触控热区与深色高对比度取消按钮），`InlineFeedback` 采用 `MergeSemantics` 与首帧可读入场动画。
- **只读与显式编辑边界**：常规事项点击进入只读 `TaskDetailScreen`（支持 `Escape` 返回、倒计时、清单进度条、一键复制正文与清单、查看/预览附件），仅点击「修改」进入统一 `Material` 分节卡片结构的 `TaskEditScreen`，杜绝误触写库。
- **性能热路径与包体优化**：
  - `remindersByIdProvider`、`mediaRecordByIdProvider` 与共享 `workspaceRemindersProvider` 提供 `O(1)` 索引查找，配合精细 `Riverpod` `select(...)`、删除／清空内存直更、`O(N+M)` 批量元数据保存、记忆化 `Reminder.occurrenceIdentity` 与 `RepaintBoundary`/`TextPainter` 缓存显著降低帧重建与扫描成本。
  - `AudioPlayer`／`AudioRecorder` 懒初始化，图片与图标按 `cacheWidth`／`ResizeImage` 限幅解码，冷启动使用 `tz.UTC` 零开销时区初始化并预读语言避免重复通知渠道注册。
  - `HomeScreen` 合并 10 秒心跳扫描并按需门控 Wi‑Fi 触发器探测与动态优先级跃迁扫描，空闲状态零冗余系统进程开销。
- **三语国际化与框架本地化树摇**：业务文案拆分于 `lib/l10n/*_strings.dart`（`zh` / `en` / `ja`，统一回退英文，由 `test/l10n_integrity_test.dart` 守卫键集合与占位符）；新增 `lib/l10n/framework_localizations.dart` 仅打包三语 Material／Cupertino 代理与日期符号，剔除 116 套未用语言表与 122 套日期符号。

---

## 3. 跨平台与交付工程

- **支持平台**：Windows x64（Inno Setup `lzma2/ultra64` 安装器 + 便携 ZIP）、Linux x64（`.tar.gz`）、Android（ARM64 / 通用 APK / 三 ABI AAB）、iOS（未签名 IPA，含 WidgetKit 扩展，供个人重签）。
- **固定工具链与包体守卫**：严格对齐 CI 基线 Flutter `3.44.9`（Dart `3.12.2`），通过 `scripts/check_flutter_version.py --strict`、`scripts/prune_windows_bundle.py`（基于 PE 导入表裁剪未用 CRT DLL 与冗余资产）、`scripts/verify_artifacts.py` 与 `scripts/tests/test_bundle_size_optimizations.py` 校验版本、产物摘要与包体回归。
- **Windows 运行中升级验收**：每个新版本均在运行中（含 `SW_HIDE` 托盘隐藏态与可见运行态）实例上执行最新数据备份→静默正常关闭升级（禁止强关）→`[InstallDelete]` 残留清理与载荷逐字节校验→SQLite `[1, 1]` 完整性与全字段哈希核对→DPAPI 凭据解保护核对→普通重开验证，并归档 JSON 回执至 `docs/benchmarks/`。
