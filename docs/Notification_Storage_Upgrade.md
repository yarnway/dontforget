# v1.6 候选通知日志升级与回退

当前源码候选为 `1.6.0+4`，业务数据库仍为 schema 9。通知日志独立于业务备份，不从 JSON/SQLite 备份导入。

## 默认策略

macOS 产品入口在持有数据库目录租约后读取日志；没有显式选择器的 v1 日志自动迁移到增量格式。首次空目录先创建 epoch/v1 空日志，第一条意图持久化前迁移。Windows、Linux、Android、iOS 暂不自动迁移，但能读取已经选择的增量格式。其他平台的实际文件系统及业务验收仍独立进行。

迁移先保留 v1 原文件和导入副本，发布完整检查点，再原子切换 `notification-storage.json`。已选择增量后只读该代际；损坏、未知选择器或外部冲突会拒绝打开，不能回读陈旧 v1 伪装成功。引擎沿用实验阶段验证的格式标记 `incremental-experiment-1`，其文件协议没有另造不兼容版本。

产品 `NotificationJournal` 继续统一分配稳定 ID、合并最多 256 条意图；增量提交完成后才允许调用 OS。失败或中断保留 pending/failed，应用重开重放。每 24 帧检查点、前代固定、256 MiB/256 文件预算及符号链接拒绝继续生效。追加前按 UTF-8 序列化大小验证最新完整状态可放入 16 MiB 检查点/回退文件，禁止先确认一份无法回退的超限状态。

数据库与日志复用同一个 `StorageDirectoryLease`，不再次打开锁句柄；恢复门禁排空旧操作后切换 epoch、取消和重建通知。日志关闭拒绝新调用，等待实际未完成操作；借用日志关闭不会释放数据库租约。单所有者 isolate、协作式跨进程锁的约束不变。

## 离线维护

先正常退出应用。以下命令使用同一个目录租约，发现应用仍运行会失败，不删除或抢占锁。目录必须是绝对、规范路径；不要传入用户主目录或业务备份文件。

```sh
dart run scripts/notification_storage.dart --help
dart run scripts/notification_storage.dart --directory /absolute/path/to/databases --rollback
dart run scripts/notification_storage.dart --directory /absolute/path/to/databases --upgrade
```

`--rollback` 导出最新增量状态及 ID，然后选择 v1；中断回退由下一次打开校验并完成。已经处于 v1 的目录也会写入显式 v1 选择，防止下一次启动又自动升级。`--upgrade` 是解除该选择的显式操作，要求已有有效 v1 日志。两种命令均不改业务数据库、备份、附件或 OS 调度。脚本错误保留输入，输出仅含后端、epoch 和条目数量。

安装只理解 v1 的旧程序前，必须先退出新程序并完成上述回退，再核对输出；更旧的已发布程序不认识新选择器，不能直接打开增量目录。需要回退整个业务版本时，另外保留并恢复一致的升级前数据库和附件副本。

## 验证范围

产品测试覆盖 v1/增量两条调度路径、持久 pending 先于外部效果、批量/并发上限、失败重试、恢复门禁排空、换代、回退固定 v1、关闭后拒绝写入、SQL/日志共享租约，以及 pending/外部记录器效果/submitted 三处 SIGKILL。引擎和迁移原有故障边界回归继续执行。记录器不是真实 OS；SIGKILL 不等于系统重启、睡眠或断电。原生候选与系统事件验收在阶段记录中单列。
