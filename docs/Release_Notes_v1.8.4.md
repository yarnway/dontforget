# DontForget v1.8.4 · Android / Windows / Linux

学习排期概览与验证稳定性改进，build73／schema17。

## 更新

- 学习计划管理页新增默认收起的未来7天概览，显示已排新词、复习词和超量日期；展开后可查看每日上限。
- 相同词条跨计划去重，采用最新进度；今日额度扣除已学习词量。暂停／继续计划后刷新，保留原复习日期、进度与附件。
- 概览按现有排期只读统计，逾期归入今天，不模拟未来学习反馈。支持中英日文、窄屏与大字号，跨日和恢复前台刷新。
- 修正两项Windows自动化保存测试的等待与计时器清理，增加持久化读回；应用保存逻辑不变。
- 保留ARM64 APK、通用APK和三ABI AAB，无新依赖或数据库迁移，个人模型／语音凭据不随公开包分发。

## 安装与验收范围

- Android固定签名ARM64 APK／通用APK／AAB、Windows x64 Setup／Portable、Linux x64归档；Linux基线Ubuntu24.04，Windows未做Authenticode签名。
- 各层验收独立记录，见[阶段台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)。
- 其他IME／机型、系统通知与录音中断、Windows GUI、带附件系统选择器恢复、凭据故障、动态负担预测与跨计划调整、分享／LAN冲突、Apple及商店继续验收。
