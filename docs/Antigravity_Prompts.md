# “别忘了” (Don't Forget) - Antigravity 提示词大全

以下提示词 (Prompts) 用于给 AI 编程助手（如 Antigravity / Cursor / Cline）提供清晰、准确的指令，以分步生成项目代码。每次发给 AI 时，请新建一次上下文或在一个连贯的 Session 中按顺序提供。

---

## Prompt 1: 项目初始化与本地存储架构
**系统设定角色**：你是一个顶级的 Flutter 开发工程师和架构师，精通跨平台开发、状态管理（推荐使用 Riverpod 或 Provider）以及 SQLite 本地存储。
**任务要求**：
1. 帮我初始化一个 Flutter 项目，名称为 `dont_forget`。
2. 请实现基于 `sqflite` (兼容桌面端和移动端) 的本地数据库服务类 `DatabaseHelper`。
3. 需要三张表的 DDL：
   - `Settings`: 用于存储大模型 API Key, API Base URL, 选定的模型名, 当前语言。
   - `MediaRecords`: 存储用户录入的原始内容（字段：id, type [text/audio/video/image], content_or_path, created_at）。
   - `Reminders`: 存储大模型提取出的核心提醒信息（字段：id, record_id, task_title, task_summary, quadrant_level [1/2/3/4对应四象限], trigger_time, is_completed）。
4. 要求代码结构清晰，提供完整的 Repository 模式封装，且保证数据绝对不依赖任何云端服务。

---

## Prompt 2: 界面美化、国际化与多模态输入组件
**任务要求**：
1. 请为 `dont_forget` 项目配置国际化 (flutter_localizations)，实现中文、英文、日文三种语言的词典，并支持动态切换。
2. 设计应用的主界面 (Home Screen)，要求界面极其美观、具有现代感、支持亮暗模式切换。
3. 在首页底部设计一个富有创意的悬浮操作栏 (Floating Action Bar) 或展开式菜单，包含四个按钮：📝文字、🎤语音、📷拍照/图片、📹视频。
4. 编写对应的占位页面和优雅的过度动画。请给出完整的 UI 代码。

---

## Prompt 3: 大模型 (LLM) 智能提取核心引擎
**任务要求**：
1. 请编写一个 `LLMService` 类，利用 `dio` 库向配置好的 OpenAI 兼容 API 发起请求（读取设置表里的 API Key 和 Base URL）。
2. 构建一段极其严谨的 System Prompt（大模型提示词），用于发送给大模型进行处理。该 Prompt 的规则要求：
   - 输入：用户的杂乱文本（如果是语音，则先转文字；如果是图片，使用 Vision API）。
   - 任务：提取出核心的“待办事项”与“时间点”。
   - 评估规则：根据艾森豪威尔矩阵评估紧急与重要程度。
   - 输出：强制要求返回 JSON 格式，例如：`{"tasks": [{"title": "...", "time": "YYYY-MM-DD HH:MM", "quadrant": 1}]}` (quadrant 1=重要紧急, 2=重要不紧急, 3=紧急不重要, 4=不重要不紧急)。
3. 提供 JSON 的解析逻辑，并自动将其存储到上一步的 `Reminders` 表中。

---

## Prompt 4: 四象限任务看板视图
**任务要求**：
1. 基于用户的 `Reminders` 表数据，开发一个美观的“四象限看板” (Eisenhower Matrix) UI。
2. 屏幕分为四个漂亮的卡片区域，分别使用略微不同的柔和背景色区分优先级（如红色系对应紧急重要，蓝色系对应重要不紧急等）。
3. 支持用户拖拽 (Drag & Drop) 任务卡片在不同象限中移动，拖拽完成后更新数据库中的 `quadrant_level`。
4. 卡片上需展示任务标题、提取出的时间以及关联的原始多媒体图标（例如附带小话筒图标表示是从语音提取的）。

---

## Prompt 5: 本地分级提醒系统
**任务要求**：
1. 引入 `flutter_local_notifications` 库，编写 `NotificationService`。
2. 监听 `Reminders` 表的新增动作。当有带有时间戳的新任务插入时，注册本地系统的定时推送。
3. 根据任务的 `quadrant_level` 制定不同的通知策略：
   - Quadrant 1 (重要紧急): 设置最高优先级的弹窗提醒，并播放自定义急促提示音。
   - Quadrant 2 (重要不紧急): 设置普通优先级的横幅提醒。
   - Quadrant 3 & 4: 设置静音通知或不通知，仅在应用内标红。
4. 提供取消通知和标记已完成的逻辑实现。
