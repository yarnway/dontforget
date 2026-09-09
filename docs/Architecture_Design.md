# “别忘了” (Don't Forget) - 项目及产品架构文档

## 1. 产品概述
**产品名称**：别忘了 (Don't Forget)
**产品定位**：一款主打“端侧隐私安全+AI智能提取”的全平台智能备忘录与任务管理应用。
**支持平台**：桌面端 (Windows, macOS, Linux)、移动端 (Android, iOS)
**支持语言**：中文 (zh), 英文 (en), 日语 (ja)

## 2. 核心价值主张
* **多模态记录**：支持文字、语音、视频、图片的碎片化输入。
* **大模型驱动**：用户自定义大模型 API Key（BYOK），由大模型自动提取关键提醒信息。
* **智能四象限**：基于提取的信息，自动划分为“紧急且重要”、“紧急不重要”、“重要不紧急”、“不重要不紧急”，并匹配不同的提醒策略。
* **绝对隐私**：所有用户数据（笔记、语音、图片、提取的核心提醒）全部通过 SQLite 存储在本地，绝不上传私有云端。

## 3. 技术栈选型建议
* **前端/跨平台框架**：**Flutter** (一份代码编译 Desktop 和 Mobile，生态丰富，容易实现极为美观流畅的 UI 交互)。
* **本地数据库**：`sqflite` (移动端) + `sqflite_common_ffi` (桌面端) 或 `Isar` (高性能本地数据库)。
* **本地化 (i18n)**：`flutter_localizations` + `intl` 包。
* **多模态处理**：
  * 图片/视频：`image_picker`, `camera`
  * 录音：`record`, `audioplayers`
* **通知与提醒**：`flutter_local_notifications` (纯本地触发推播)。
* **大模型接口**：`dio` 或 `http` 进行网络请求 (只和用户指定的第三方/自建大模型 API 通信)。

## 4. 架构设计
### 4.1 展现层 (Presentation Layer)
* 采用 Material 3 或 Cupertino 风格设计，支持亮暗色模式 (Dark/Light Mode)。
* 包含：瀑布流/列表视图（展示记录）、四象限看板（任务分级）、多模态输入悬浮菜单、设置中心（API Key、语言切换）。

### 4.2 业务逻辑层 (Domain Layer)
* **LLM Engine**：负责将用户的输入封装为特定的 Prompt 交由大模型处理，并解析返回的 JSON。
* **Task Classifier**：四象限映射逻辑与提醒时间调度器。
* **File Manager**：管理本地多媒体文件（图片、音视频）的存储路径与生命周期。

### 4.3 数据层 (Data Layer)
* **SQLite Repository**：封装 CRUD 操作。
* 数据表设计示例：
  * `Records` (id, type, raw_content, file_path, created_at)
  * `Reminders` (id, record_id, extracted_text, quadrant_level, remind_time, is_completed)
  * `Settings` (api_key, base_url, language, model_name)
