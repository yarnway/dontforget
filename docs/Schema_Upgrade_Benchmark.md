# 万条升级与回退快照测量

`benchmark/schema_upgrade_snapshot_test.dart` 是显式启用的隔离测量入口，不随常规 `test/` 回归执行。使用 Flutter 3.44.9 / Dart 3.12.2，在 Flutter test JIT 中调用真实 `DatabaseHelper`、SQLite FFI、目录租约和文件系统；不启动应用、不调用 AI 或系统通知，不访问主应用数据库。

必须提供上一阶段固定的万条 `ha_snapshot.json`。入口检查文件 SHA-256 为 `ffe48931fba0f93c79c3f0c60daaa0dc0e3dcfa26f1210d82c7ccd531203e669`、schema 9、任务数 10000，任何不符均拒绝。文件仅只读。每轮在全新临时目录按冻结 v9 schema 重建数据库，结束时仅删除此次创建的临时目录。

```sh
export DONTFORGET_UPGRADE_FIXTURE='/absolute/path/to/tasks-10000/ha_snapshot.json'
export DONTFORGET_UPGRADE_REPORT='/absolute/path/to/new-upgrade-report.json'
export DONTFORGET_UPGRADE_SAMPLES=5
flutter test --no-pub benchmark/schema_upgrade_snapshot_test.dart --reporter expanded
```

- `DONTFORGET_UPGRADE_FIXTURE`：必填，固定夹具文件绝对路径。
- `DONTFORGET_UPGRADE_REPORT`：必填，尚不存在的 JSON 报告路径，父目录须已存在。不得指向已有回退材料。
- `DONTFORGET_UPGRADE_SAMPLES`：可选，3–10，默认 5；每个进程先完成两次预热。
- 两个路径都未提供时跳过；缺一个、报告已存在或夹具不匹配时失败。多次测量需不同报告文件。

计时从产品 helper 打开旧库开始，到完整升级完成结束，包含升级前逻辑快照的查询、编码、flush、读回摘要校验、manifest，以及后续 schema 迁移。重开单独计时。报告给出原始样本、p50/p95/max、快照字节和打开前后的进程 RSS；RSS 不是峰值或分配量，预热后的同机样本也不代表磁盘冷缓存。

计时外逐字段核对升级后所有业务行、快照 SHA-256、全部旧行、重开数据，并从实际生成的快照重建独立 v9 数据库，再核对完整性和全部旧行。不会让旧程序打开 v10 主库。

该结果是**完整数据库升级（包含必需快照）的成本**，不能拆写成“纯快照耗时”；也不能当作完整产品原生冷启动、首帧、跨机器性能或真实断电验收。报告不输出密钥或业务内容。

## 原生测量补验

2026-10-24 使用同一固定夹具完成了真实 `lib/main.dart` release 的 v9→v10 升级、自动快照及逐字段回退重建，并保留一次升级启动、两次已升级库新进程启动样本。[阶段 4F 原始证据](benchmarks/native-upgrade-4f-2026-10-24.json)。

这些样本未取得窗口焦点，OS 缓存未清空，不能标记为全程前台或系统重启后的冷缓存测量。固定夹具到期时间在测量时已过去，系统未来提醒为 0；该轮不包含万条未来通知的 OS 提交成本。首帧早于任务加载，应分别报告进程出生到 storage_ready、tasks_loaded、notifications_ready、routes_ready_frame 和首帧的时间。
