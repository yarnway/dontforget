# DontForget v1.8.5 · Android / Windows / Linux

跨计划管理与界面改进，build74／schema17。

## 更新

- 学习计划页支持多选计划，一次暂停或继续；显示已选数量，自动禁用不可用操作。
- 同一事务校验所有所选计划的完整快照；选择后发生新增、编辑、移组或删除时拒绝整次操作，避免部分更新。写入失败全部回滚，通知同步失败保留已提交结果并提供修复入口。
- 保留复习日期、词条进度、附件及完成／归档批次；继续计划不改写过期周期批次的日期。
- 多选操作结束或取消后清除选择；回收站仍按单计划确认。计划卡片裁剪内部交互背景，底部按钮适配窄屏及大字号，中英日文同步。
- 保留七天已排词量概览和ARM64小包，无新增依赖或数据库迁移。

## 安装与验收范围

- Android固定签名ARM64 APK／通用APK／AAB、Windows x64 Setup／Portable、Linux x64归档；Linux基线Ubuntu24.04，Windows未做Authenticode签名。
- 源码、自动化、普通安装包与真实设备分别记录，见[阶段台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)。
- 批量改期、动态反馈预测、档案与分享同步继续；其他IME／机型、通知休眠与录音中断、Windows GUI、恢复故障、Apple设备／签名及商店仍待验。
