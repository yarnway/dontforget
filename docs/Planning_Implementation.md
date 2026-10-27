# 计划管理：实现与验收索引

日期：2026-10-27。最新边界源码 `9ec94b9` 已保存到本地 main，沿用 schema 16；**1508 Flutter、126 Python、静态分析 0 issues、洛杉矶专项 51 项通过**，本次没有构建、安装、推送或发布。总状态见[阶段台账](Recording_Reminders_Phases.md)，详细分阶段结果见[持续日期与容量验收](P1_Rolling_Notification_Window.md)；`e336f05` 的 1499 项和双平台调试构建、`d04a3b0` 的集成结果保留原有归属。

## 使用入口

原生结果另见 [P1 容量、退出进程与跨日验收](P1_Native_Acceptance_2026-10-27.md)：本轮固定 e336f05 的 Mac 前三阶段已通过，跨日待真实时间，iPhone 新身份待签名。原生验收固定的构建与当前主线后续修改分别记录。

从“更多功能”搜索“计划与清单”或 /plans，进入用药、出门、管理、备份、学习管理五个面板。

- **用药**：先填写或从已保存文字、图片、录音提取草稿，逐药核对药名、规格、数量、单位、饭前饭后说明和具体时刻，再填写起止日期。单药日期留空时沿用计划日期；不完整仍可保存草稿。预览首末剂次，逐药核对并勾选确认后启动。选择计划和日期查看每剂记录；详情可返回对应计划修改未来安排。
- **出门**：填写场景与出门时刻、提前量、重复星期及清单。未来 60 日范围内逐日独立保存并在前台补排，常备项按日期独立，一次性项同步到未来日期。天气与出门习惯记录分别主动开启；支持设置返程观察时段，前台预取有效天气并更新通知正文。延后提醒按新的通知时间检查缓存；失效或缺测保留清单并提示未知。记录出门只修改观察记录，正式时刻、地点、城市和授权须经采用、预览、保存后改变。
- **管理**：查找标题、标签和项目，编辑清单及重复规则；暂停、回收站恢复、已完成归档，以及浏览执行记录。一般删除保留在回收站，旧撤销不能跨数据恢复代次执行。原有明确的永久清理操作继续保持其含义。
- **备份**：选择位置导出任务与附件包，模型密钥被排除；附件合计 32 MiB、整个包 64 MiB。导入先准备独立附件副本，再通过现有预检和确认恢复数据库；原文件不被覆盖，准备材料在取消后保留。不加密，大附件与可选加密仍待后续实现。
- **学习管理**：查看逐词档案、记录开始后的趋势及七日到期量，逐批暂停、继续、校对词条；调整后续“认识”反馈的五级间隔；粘贴 Tab 分隔的单词、释义、例句，预览后创建最多七批；进行不会自动更改掌握度的拼写练习。

模型配置测试为用户主动的一次文字 JSON 请求，既不携带任务内容，也不创建任务；成功不证明图片、语音能力。

## 代码索引

| 部分 | 入口 |
| --- | --- |
| 计划面板与管理 | [planning_panel.dart](../lib/ui/widgets/planning_panel.dart) |
| 用药模型与界面 | [medication_plan.dart](../lib/models/medication_plan.dart)、[medication_plan_panel.dart](../lib/ui/widgets/medication_plan_panel.dart) |
| 出门模型与界面 | [departure_plan.dart](../lib/models/departure_plan.dart)、[departure_plan_panel.dart](../lib/ui/widgets/departure_plan_panel.dart) |
| 日期补排与覆盖界面 | [departure_routines.dart](../lib/providers/departure_routines.dart)、[routine_coverage_panel.dart](../lib/ui/widgets/routine_coverage_panel.dart)、[notification_coverage.dart](../lib/ui/formatters/notification_coverage.dart) |
| 共用通知窗口与状态 | [notification_window.dart](../lib/services/notification_window.dart)、[notification_service.dart](../lib/services/notification_service.dart)、[notification_schedule_reader.dart](../lib/services/notification_schedule_reader.dart) |
| 通用扩展与周期 | [task_details.dart](../lib/models/task_details.dart)、[reminder.dart](../lib/models/reminder.dart) |
| 原子变更、历史及组操作 | [providers.dart](../lib/providers/providers.dart)、[task_management.dart](../lib/providers/task_management.dart) |
| 天气接口与数据校验 | [departure_weather_service.dart](../lib/services/departure_weather_service.dart) |
| 附件备份与恢复准备 | [portable_backup_service.dart](../lib/services/portable_backup_service.dart)、[portable_backup_panel.dart](../lib/ui/widgets/portable_backup_panel.dart) |
| 学习管理与队列 | [learning_management_panel.dart](../lib/ui/widgets/learning_management_panel.dart)、[learning_queue_service.dart](../lib/services/learning_queue_service.dart) |
| 三语控件文案 | [planning_strings.dart](../lib/l10n/planning_strings.dart) |
| 冻结格式 | [当前 v16](../test/fixtures/schema_v16.sql)、[历史 P0 v15](../test/fixtures/schema_v15.sql)、[历史任务管理 v15](../test/fixtures/schema_v15_task_management.sql) |

天气接口按 Open-Meteo 的[小时预报](https://open-meteo.com/en/docs)和[城市查询](https://open-meteo.com/en/docs/geocoding-api)文档实现，使用 UTC 时间戳对齐预报时段。需用户开启天气并手选城市；允许主动查询，以及出门前六小时内的前台有限预取，不采集 GPS、不发送出门记录给天气服务。每计划 30 分钟冷却，每轮最多三个请求，退出前台或设置变化后的迟到结果丢弃。AI 时间建议仅发送样本数量、所选星期和时刻中位数摘要，地点标签、坐标和轨迹不进入该请求。

## 存储与生命周期

当前 schema 16 保留原三表及旧字段，统一提醒时间来源与 Reminders.details_json；识别历史两类 v14／v15，兼容方案见 [P0/P1 集成验收](UX_P0_Record_Reminder.md)。扩展结构有版本、大小、枚举、日期、重复 ID 和数组限制，嵌套数据不可变。普通、用药、出门和学习记录共享现有数据库准入与提醒串行队列。

用药计划由一个管理记录和有限的独立剂次组成；管理记录不进入普通事项列表，每剂保留原定事项时刻。重复点击、过期预览、不同代次、旧轮次及不完整保存均不能生成额外剂次。编辑不重写已处理或历史剂次；暂停、回收站和替换未来安排独立执行通知取消，失败进入现有修复流程。已保存、提交系统、实际送达和用户反馈始终分别记录。服药结局单独保存；归档、回收站恢复及历史滚动不会把“未服用”改判为“已服用”。

普通重复规则保存原始锚点、可选结束范围、间隔及星期；工作日间隔按周一至周五计数，月末保留原始日期。普通任务与用药的“延后”只改变本次通知，不重写原始说明。执行记录最多保留每项 512 条，界面取最近 300 条；逐词趋势仅来自实际留下的反馈事件，不重建缺失历史。

回收站保留原批次数据；永久删除词汇批次或清理已完成时，对仍能对应的逐词反馈建立独立档案，后续同词复用最新反馈，已完成清理保留这些档案。档案的统一管理／清除、内容身份更正后的迁移仍列为第三阶段剩余任务。

## 自动化证据

- [常用筛选](P1_Saved_Task_Filters.md)：当前分类与关键词的命名保存／应用、重命名、删除撤销、原工作区字段持久化及备份恢复；专项 126 项包含三语三种宽度及小屏键盘。新增源码全量 **1542 Flutter、126 Python 通过，静态分析 0 issues，macOS／iOS 模拟器调试构建通过**；未安装或启动新构建，原生筛选界面待验。
- [departure_rolling_test.dart](../test/departure_rolling_test.dart)、[departure_refill_recovery_test.dart](../test/departure_refill_recovery_test.dart)：独立日期、跨午夜、补排去重、重启保留、长时间缺席、单独删除、整组恢复、独立跳过和天气有效期。
- [notification_window_test.dart](../test/notification_window_test.dart)、[notification_capacity_recovery_test.dart](../test/notification_capacity_recovery_test.dart)、[notification_capacity_status_test.dart](../test/notification_capacity_status_test.dart)：跨计划容量、取消／提交故障、冷启动和维护恢复、相同时刻覆盖边界、单条待补排状态。
- [notification_coverage_ui_test.dart](../test/notification_coverage_ui_test.dart)：三语、三种宽度和 2 倍文字、空／未确认状态，以及手动和前台刷新。
- [planning_routines_test.dart](../test/planning_routines_test.dart)：有限疗程、四药独立剂次、原子保存和重复确认、暂停／恢复、记录未服用、回收站、清单重置、工作日间隔、短月与跨周事项时间、旧代次、逐词档案与自定义间隔、历史 v14 升级与当前 v16 预检。
- [planning_panel_test.dart](../test/planning_panel_test.dart)：375／768／1440、中英日及大字体，实际加载后的五个面板；用药确认真实写入临时库，非法出门输入和损坏草稿处理。
- [portable_backup_test.dart](../test/portable_backup_test.dart)：附件字节、密钥排除、原件不变、独立恢复路径、摘要变化与损坏拒绝、文件名路径穿越防护、缺失清单及旧会话拒绝。
- [planning_transport_test.dart](../test/planning_transport_test.dart)：已配置网关及 JSON 提案、非法响应拒绝、天气 API、无模型凭证的城市查询、UTC 时段及异常预报字段。
- 既有数据库恢复、通知、原文记录、三语布局、输入手势和脚本测试随全量回归执行；`e336f05` 的 **1499 Flutter、126 Python 通过，静态分析 0 issues** 见 [P1 机器证据](benchmarks/p1-rolling-window-2026-10-27.json)，新增筛选源码的当前全量结果见上条独立记录。

前一轮 d04a3b0 的合并专项 151 项、洛杉矶时区专项 64 项及双平台构建保留在[原集成证据](benchmarks/p0-p1-integration-2026-10-27.json)。本轮 e336f05 的洛杉矶专项 43 项、macOS arm64 Debug／严格签名检查与 iOS 模拟器主应用／WidgetKit 构建均通过；没有安装或启动新构建，各轮专项不与全量相加。

所有业务数据库均为临时目录，模型、天气和通知使用替身。这里不是处方正确性、真实服药、外部服务、通知必达、原生后台能力或跨设备恢复的证明。真实采集、平台容量、送达／取消／点击、连续日期与时区验收仍按阶段台账执行。
