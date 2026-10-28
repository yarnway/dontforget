# 通知动作能力一致性修复与暂停收口（2026-10-28）

用户要求暂停后续阶段，仅收尾已验证代码并提交main。本记录不新增原生验收结论。

## 本次修复

普通周期任务生成的独立日期事项使用`isRecurring=false`，但现有`canSkipOccurrence`允许跳过。此前原生通知按`isRecurring`选择动作，导致应用内可跳过而系统菜单缺少跳过。

- `lib/services/notification_service.dart`的Android动作、iOS/macOS类别及现有自定义macOS通道统一按`canSkipOccurrence`选择；原生签名保留`isRecurring`并加入该能力，能力变化后通过既有reconcile重排。
- `test/notification_action_bridge_test.dart`净增7项，覆盖独立日期子项、能力往返变化、关闭子项、周期owner、既有medication/departure计划事项和自定义macOS通道。普通一次任务保持不显示skip。
- 沿用原有payload、journal、revision、pending及业务操作；无新增schema、迁移、DatabaseHelper、通知系统或用户文案。

## 固定源验证

首轮使用精确`897104c269eb613db6b63e705c0bbd79996a8825`归档，只叠加上述两份文件，完整Flutter测试1963项通过、相关44项通过、`flutter analyze --no-pub`为0 issues。其他归档文件逐字节不变。验证材料：`build/native_acceptance/trust-stage6-series-actions-897-materials/validation.json`。

一次同时启动相关/全量测试引起隔离副本native-assets构建竞争，失败日志保留；完整测试结束后顺序重跑相关44项通过，未修改产品以绕过失败。

主线随后推进到`fb476d50cbe584405f7a4a0134705103ca47c431`。收尾再次从该精确归档仅叠加同两文件，顺序执行离线pubget、静态分析0 issues、相关44项通过；全量为2020通过、1项失败。唯一失败为`schema16_integration_test.dart`的AI标题确认保留元数据测试，实际repeat/history与旧整JSON断言不一致。使用原fb生产代码、不含本通知补丁运行同一个用例仍复现相同失败，确认属于该主线基线的交叉问题；未回退或改写其他任务源码。原基线、overlay与A/B日志均保留在`build/native_acceptance/trust-stage6-final-main-fb476d5-materials/`。最终主线组合修复与回归由主线协调任务统一收口，本记录不将该失败轮次写成全量通过。

## 暂停边界

- 未启动新原生候选、未实际接收新Mac UI窗口，未操作phone/Mirroring或真实用户数据库/通知；此前1430已完成的清理与回退材料保留，1130配置、旧1110及日常身份保护。
- Android暂无设备，真机验证保留；iOS/macOS尾项、任务信息人工验收及新增原生观测均暂停，不能由本次代码测试推定通过。
- 仅将本次两份已验证代码与本记录限定提交main，其他并行工作保持独立。
