# DontForget (别忘了) - 系统与技术架构设计文档

> **版本**：v1.8.18（build89）  
> **更新时间**：2026-11-20  
> **定位**：本地优先（Local-First）· 端侧数据保全 · 多模态录入与 AI 辅助整理 · 四平台（Windows / Linux / Android / iOS）事项、提醒与复习工作台

---

## 1. 架构总览

DontForget 采用清晰的分层架构，围绕 **单进程所有权（Process Ownership）**、**代数隔离（DataGeneration）**、**运行时恢复门控（RuntimeRecoveryGate）** 与 **响应式 Riverpod 状态管理** 构建，确保跨平台日常录入、提醒调度、局域网同步、加密备份恢复与附件清理的一致性和可恢复性。

```text
┌──────────────────────────────────────────────────────────────────────┐
│                      展现层 (Presentation Layer)                     │
│  - 统一 Material 3 设计令牌 (AppTheme: light / dark, WCAG AA)        │
│  - 主工作台 (HomeScreen, TaskWorkspaceOverview, TaskBoard, Quadrant)  │
│  - 默认只读详情与显式编辑 (TaskDetailScreen / TaskEditScreen)         │
│  - 多模态输入与实时语音三态 (InputBottomBar, SharedTextInboxScreen)  │
│  - 看板、知识图谱、学习排程与专注工具 (Dashboard / Graph / Planning) │
│  - 设置中心与数据管理 (Settings / Backup / ContentManagement)        │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ watch / select / O(1) index
┌──────────────────────────────────▼───────────────────────────────────┐
│                   状态与协调层 (Providers & State)                   │
│  - remindersProvider + remindersByIdProvider (O(1) 索引)             │
│  - mediaRecordsProvider + mediaRecordByIdProvider (O(1) 索引)        │
│  - settingsProvider / workspaceDraftsProvider / contextProfile       │
│  - homeControllerProvider (录入/语音/多模态串行队列与草稿保全)       │
│  - runtimeRecoveryGateProvider (恢复前排空全部前台活动与回调)        │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ generation-fenced operations
┌──────────────────────────────────▼───────────────────────────────────┐
│                    领域与服务层 (Domain & Services)                  │
│  - AI 与语音：LLMService / MultiAgentService / TencentRealtimeASR    │
│  - 提醒与情境：NotificationService / WindowsToast / ContextTriggers  │
│  - 跨设备同步：LanSyncService (物理网卡优先、并发上限、双向附件校验) │
│  - 分享采集：AndroidShareService / SharedTextInbox (私有 handoff)    │
│  - 数据保护：StreamingBackupService / PortableBackupService          │
│  - 清理保护：ContentCleanupService / RetainedMediaReferences         │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ exclusive ownership & transactions
┌──────────────────────────────────▼───────────────────────────────────┐
│                     数据持久层 (Data & Storage)                      │
│  - DatabaseHelper (SQLite Schema v17, WAL, 单进程锁与维护租约)       │
│  - StorageBootstrap / DatabaseRecovery / DatabaseLocationMigrator    │
│  - LocalMediaStore (受管原件目录与活动标记 OwnedMaterialActivity)    │
│  - 系统安全存储 (DPAPI / Keychain / Keystore；不随备份导出明文密钥)  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. 核心架构原则与关键子系统

### 2.1 数据安全与恢复门控（Storage & Recovery）
- **启动门控（`StorageBootstrap`）**：主界面渲染前必须先获取进程目录锁（`acquireOwnership`）、校验未完成恢复日志并完成安全迁移，避免多实例并发写库或覆盖历史数据；异常时进入独立于 `ProviderScope` 的三语 `StorageUnavailableScreen`。
- **代数栅栏（`DataGeneration`）与恢复门控（`RuntimeRecoveryGate`）**：所有异步读写、通知动作、录音、同步及备份操作均绑定代数令牌；在数据库恢复或目录接管前先排空后台任务，恢复后旧代数写入被拒绝。
- **维护租约（`DatabaseMaintenanceLease`）**：覆盖恢复、回退与只读预检期间持有独占租约，历史完整性校验动态兼容 `7..schemaVersion`（当前 v17）。
- **系统凭据隔离**：模型与语音 API 密钥统一保存于系统安全存储（Windows DPAPI / macOS & iOS Keychain / Android Keystore），新备份默认不导出密钥。

### 2.2 内容保护与备份恢复（Backup & Content Management）
- **流式/可移植加密备份（`StreamingBackupService` / `PortableBackupService`）**：支持未加密与口令加密包、大附件流式读写、预检摘要核对与失败自动回退。
- **原件引用保护（`ContentCleanupService` + `RetainedMediaReferences`）**：扫描真实受控数据库目录（`acquireOwnership()`）中的 `ha_snapshot.json`、`dont_forget_v3.mirror.db`、`recovery-*`、`schema-upgrade-*` 与迁移回执，同时保护回收站、归档、分享草稿与外部登记备份引用；遇到未知或损坏材料保守阻断清理。

### 2.3 跨设备局域网同步与分享采集（LAN Sync & Share）
- **局域网双向同步（`LanSyncService`）**：
  - 自动优先选择物理局域网 IPv4（`192.168.x` > `10.x` > `172.16–31.x`），避开 WSL/Hyper-V/Docker/VPN 虚拟网卡。
  - PIN 常量时间比对、错误计数锁定（429）、64 MiB 请求体未读拒收（`detachSocket` 立即返回 413 并断开连接）、入站并发上限（8 路，超限 503）与单次预加载合并（消除 N+1 SQL 查询）。
  - 支持任务附件原件双向传输（32 MiB 单附件限制、SHA‑256 摘要核对、暂存落盘并在事务回滚时清理）。
  - 冲突对比对话框（`LanSyncConflictsDialog`）支持差异字段摘要、本机/对端对比视图以及确认后采用对端文案或回收站状态。
- **分享采集（`SharedTextInbox`）**：所有分享附件严格限定于应用私有 `shared_handoff/<share-id>/` 目录，独立持久化不覆盖首页输入草稿，支持无配文或带配文经同一事务保存为备忘。

### 2.4 展现层、无障碍与性能（UI/UX & Performance）
- **设计系统（`AppTheme`）**：统一 Material 3 明暗主题令牌（Card / Dialog / PopupMenu / Chip / SnackBar / InputDecoration），保证 WCAG AA 文本对比度并支持 200% 系统字体缩放与窄屏响应式布局。
- **只读与显式编辑边界**：常规事项点击进入只读 `TaskDetailScreen`（支持一键复制正文与清单、查看/预览附件），仅点击「修改」进入 `TaskEditScreen`，杜绝误触写库。
- **性能热路径优化**：
  - `remindersByIdProvider` 与 `mediaRecordByIdProvider` 提供 `O(1)` 索引查找，避免卡片与详情面板随数据增长发生线性扫描。
  - `TaskBoard` 与 `TaskWorkspaceOverview` 对排序与分组投影按数据引用与分钟桶记忆化。
  - `HomeScreen` 10 秒心跳按需门控 Wi‑Fi 触发器探测与动态优先级跃迁扫描，空闲状态零冗余系统进程开销。
- **国际化一致性**：中／英／日三语全覆盖，`AppLocalizations.get` 统一回退英文，并由 `test/l10n_integrity_test.dart` 自动守卫键集合与占位符一致性。

---

## 3. 跨平台与交付工程

- **支持平台**：Windows x64（Inno Setup 安装器 + 便携 ZIP）、Linux x64（AppImage / tarball）、Android（ARM64 / 通用 APK / AAB）、iOS（未签名 IPA，供个人重签）。
- **固定工具链**：严格对齐 CI 基线 Flutter `3.44.9`（Dart `3.12.2`），通过 `scripts/check_flutter_version.py --strict` 与 `scripts/verify_artifacts.py` 校验版本与产物摘要。
- **Windows 运行中升级验收**：每个新版本均在运行中的旧版实例上执行最新数据备份→静默正常关闭升级（禁止强关）→载荷逐字节校验→SQLite 完整性与全字段哈希核对→DPAPI 凭据解保护核对→普通重开验证，并归档 JSON 回执至 `docs/benchmarks/`。
