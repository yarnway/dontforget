# DontForget (别忘了) - 系统与技术架构设计文档

> **版本**：v1.2.4  
> **更新时间**：2026-09-09  
> **定位**：端侧隐私第一 · 大模型驱动 · 3D 全息 AI 视觉 · 全平台智能备忘与任务调度系统

---

## 1. 架构总览

DontForget 采用现代清晰的分层架构（Clean Architecture）结合响应式状态管理（Riverpod），保障各层职责解耦、代码高内聚低耦合，并具备极致的跨平台运行能力。

```
┌─────────────────────────────────────────────────────────────┐
│                 展现层 (Presentation Layer)                  │
│  - 3D 全息粒子背景 (AiBackgroundEffect: CustomPainter)        │
│  - 纯净图标线框象限 (QuadrantView & TaskCard)                 │
│  - 统计数据看板 (DashboardScreen: Completion Ring & Pie)      │
│  - 悬浮微型状态指示灯 (LED Status Indicator)                   │
│  - 极速多模态底部输入流 (InputBottomBar & Media Sheets)        │
└──────────────────────────────┬──────────────────────────────┘
                               │ Watch / Read
┌──────────────────────────────▼──────────────────────────────┐
│                  状态层 (State Management Layer)             │
│  - remindersProvider (StateNotifierProvider<List<Reminder>>)│
│  - mediaRecordsProvider (StateNotifierProvider<MediaRecord>)│
│  - appSettingsProvider (StateNotifierProvider<AppSettings>) │
│  - homeControllerProvider (异步解析中/错误状态流)             │
└──────────────────────────────┬──────────────────────────────┘
                               │ Business Logic
┌──────────────────────────────▼──────────────────────────────┐
│                  领域与服务层 (Domain & Service Layer)       │
│  - LLMService (Dio HTTP Client, Prompt Engineering,         │
│               智能提前量评估, Vision & Audio 多模态流)       │
│  - NotificationService (flutter_local_notifications,        │
│                         系统托盘通知, 定时闹钟, Snooze 调度)│
│  - AudioEngine (record, audioplayers, Windows fmedia 内置核)│
│  - WindowManagerService (最小化到托盘, 隐藏到后台, 窗口守护) │
└──────────────────────────────┬──────────────────────────────┘
                               │ Local Storage Only
┌──────────────────────────────▼──────────────────────────────┐
│                    数据持久层 (Data Layer)                   │
│  - DatabaseHelper (SQLite, sqflite_common_ffi, WAL 模式)    │
│  - 本地表结构: reminders, media_records, settings            │
│  - 本地文件沙盒存储: app_data/media/ (音频/视频/图片)         │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 核心模块与职责划分

### 2.1 展现层 (Presentation Layer)
- **`AiBackgroundEffect`**：
  - 基于 Flutter `CustomPainter` 与 `SingleTickerProviderStateMixin` 打造的高性能 3D 光粒子画布。
  - 维护 620+ 空间点云（555 实体粒子 + 150 深空背景星），支持 3D 仿射变换、四点光学衍射十字星芒、突触脉冲光子传输。
  - 集成**流体阻尼跟踪**与**胡克定律弹性慢速复位模型**，带来科技而有生命的交互体验。
- **`HomeScreen`**：
  - 承载四象限矩阵网格、透明浮动 AppBar、LED 状态指示器与底部多模态输入栏。
  - 监听定时触发任务，展示到期提醒弹窗（支持一键推迟 5 分钟与直接标记完成）。
- **`QuadrantView` & `TaskCard`**：
  - 采用极简透明细线框与彩色徽标（🔥、⭐、⚡、☕），彻底剔除冗余分类文本与右上角计数，回归内容本身。
  - 支持拖拽换象限（`LongPressDraggable` & `DragTarget`），手势滑动删除、右键上下文菜单。
- **`DashboardScreen`**：
  - 纯图标化统计分析视图，支持中/英/日多语言动态适配，直观展示任务完成率与分类分布。

### 2.2 状态管理层 (State Management Layer)
- 基于 `flutter_riverpod: ^2.6.1`，全工程摒弃繁重的全局单例与命令式状态传递：
  - `remindersProvider`：响应式管理待办事项列表，提供增、删、改、查、分类过滤、清空历史完成等原子操作。
  - `appSettingsProvider`：热加载用户配置（API Key、Base URL、Model Name、语言、主题等）。
  - `homeControllerProvider`：统一调度后台大模型提取工作流，处理音频转录、视觉分析及异常错误透传。

### 2.3 领域与服务层 (Domain & Service Layer)
- **`LLMService`**：
  - 采用 OpenAI 兼容格式通信，支持 DeepSeek、Google Gemini 以及自定义兼容接口。
  - **智能提前量（Lead Time）规划**：大模型根据任务性质（会议、出行、截止期、即刻行动）自动返回 `lead_time_minutes` 与 `lead_time_desc`，并在客户端进行双重精准计算。
  - 具备重试机制（Exponential Backoff）、格式化错误翻译、Markdown 代码块及非标准 JSON 容错正则解析。
- **`NotificationService`**：
  - 封装桌面与移动端本地通知，支持分类通知渠道（High/Urgent 强提醒，General 常规提醒）。
  - 结合 `timezone` 库实现精准跨时区绝对时间调度。
- **`AudioService` & `FmediaEngine`**：
  - 录音使用跨平台统一插件 `record`。
  - Windows 端针对系统老旧版本（Windows 7/8/10 无内置编解码器）的问题，内嵌轻量级绿色免安装的 `fmedia` 原生音频引擎，保障在任何 Windows 环境下均可无损播放音频。

### 2.4 数据持久层 (Data Layer)
- **本地绝对隐私原则**：
  - 用户的所有数据（待办记录、语音文件、图片、本地设置、API Key）**完全存放在用户本机**，应用自身绝不搭建任何云端存储，真正做到数据物理隔离。
- **SQLite 架构**：
  - 桌面端：`sqflite_common_ffi` + `sqlite3.dll`，开启 Write-Ahead Logging (WAL) 模式保障高并发读写安全。
  - 移动端：原生系统 SQLite 驱动。
- **核心数据模型**：
  - `reminders` 表：`id`, `record_id`, `task_title`, `task_summary`, `quadrant_level`, `urgency_level`, `importance_level`, `trigger_time`, `is_completed`, `is_recurring`, `recurrence_rule`, `recurrence_description`。
  - `media_records` 表：`id`, `type`, `content_or_path`, `created_at`。
  - `settings` 表：`api_key`, `base_url`, `model_name`, `language`。

---

## 3. 跨平台兼容性设计

| 操作系统 | 架构 | 特殊适配措施 |
|---|---|---|
| **Windows 10 / 11** | x64 | 原生 64 位构建，支持现代毛玻璃亚克力与桌面右下角系统托盘集成 |
| **Windows 7 / 8 / 8.1** | x64 | **100% 免运行库直启**：构建流程自动内嵌 VC++ 2015-2022 CRT（`vcruntime140.dll`, `msvcp140.dll` 等）与 DirectX `d3dcompiler_47.dll`，杜绝缺少 dll 报错 |
| **macOS** | Universal | 支持 macOS 原生 MenuBar 与暗黑模式切换 |
| **Linux (Ubuntu)** | x64 | GTK 3.0 前端适配，遵循 XDG 桌面规范与桌面本地通知 |
| **Android & iOS** | ARM64 / ARMv7 | 触摸手势优化、移动端通知权限申请与麦克风/相册权限按需申请 |

---

## 4. 安全与性能指标

1. **凭据安全**：
   - 用户填写的 API Key 仅保存在本地 SQLite 数据库中，所有 HTTP 通信直接从客户端发送至对应模型服务商，无中间代理或中继服务器。
2. **渲染性能**：
   - 3D 光粒子全息系统采用独立的 `RepaintBoundary` 分离重绘区域。
   - 粒子连线与脉冲计算采用 $O(N)$ 临近局部检索算法，在常规桌面集成显卡上均能稳定跑满 60 FPS，CPU 占用率低于 2%。
3. **打包体积控制**：
   - 独立安装包（Setup.exe）体积压缩至仅约 **16.3 MB**。
   - 绿色便携包（Portable.zip）体积仅约 **20.1 MB**（已包含全部系统兼容 DLL 与音频引擎）。
