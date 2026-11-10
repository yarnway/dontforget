# DontForget v1.8.2 · Android / Windows / Linux

学习计划管理更新，build70／schema17。

## 更新

- 学习计划、复习与每日练习可进入计划列表，按计划查看批次和状态，整组暂停、继续或移至回收站。
- 暂停和继续仅处理未完成、未归档的批次，保留原复习日期、词条进度和已完成批次；继续时不补发过期系统通知，过期内容仍可进入学习队列。
- 移至回收站前预览批次，保留学习历史、附件记录和原件。预览后计划成员或内容发生变化时拒绝整组操作；数据库事务失败全部回滚，通知同步失败则保留已保存状态并提供修复入口。
- 沿用1.8.1的输入、语音、卡片布局和Windows升级退出处理，无新增依赖和数据库迁移。个人模型与语音凭据仅保存在本地，不随公开包分发。

## 安装与验收范围

- Android固定发行签名APK／AAB、Windows x64 Setup／Portable、Linux x64归档；Linux基线Ubuntu24.04，Windows尚无Authenticode签名。
- 源码、自动化、普通安装包与真实设备验收范围分别记录，见[阶段台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)。
- 其他机型／IME、通知休眠与录音中断、Windows GUI、带附件跨设备及故障恢复、分享／LAN冲突与更多学习排程继续；Apple、独立ARM64正式附件、代码签名和商店分发另续。
