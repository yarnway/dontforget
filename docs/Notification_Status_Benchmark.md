# 万条任务的通知状态读取测量

入口：`benchmark/notification_schedule_read_test.dart`。比较设置页原先的全字段查询和产品 `NotificationScheduleReader` 的七字段投影；两条路径保留相同的目录所有权、操作代际、日志/epoch 核验、Reminder 解码和状态计数。

使用此前性能与 schema 升级验收的固定合成夹具，SHA-256 必须为 `ffe48931fba0f93c79c3f0c60daaa0dc0e3dcfa26f1210d82c7ccd531203e669`，schema 9、10000 条任务。输入只读，在新建临时目录中恢复冻结 schema 9 并升级到 schema 10；准备、升级和内容核验均不计入读回时间。禁止将用户备份作为夹具：其设置可能包含密钥。

使用 Flutter 3.44.9 / Dart 3.12.2，顺序执行，不与其他测试、构建或下载并发：

```sh
export DONTFORGET_STATUS_FIXTURE=/absolute/path/to/fixed/ha_snapshot.json
export DONTFORGET_STATUS_REPORT=/absolute/path/to/new/status-run-1.json
flutter test --no-pub benchmark/notification_schedule_read_test.dart
```

两个环境变量都缺少时跳过；只配置一个、摘要不匹配或报告已存在时失败。每个新进程先运行两组预热，再运行七组测量，交替旧/新顺序；另外两次执行需使用新的报告文件名。原始样本不删除异常值，七个样本的 p95 就是最大值，不据此推断跨设备分布。

每次两条路径的五项计数必须一致，结束时逐表核验业务数据未变和 SQLite 完整性，再关闭并删除自己的临时目录。该固定夹具的提醒时间已过期，日志为空，未调用系统通知；混合未来/过期、已完成、已确认、无时间、孤立和失败日志的计数由 `notification_durable_retry_test.dart` 单独覆盖。

报告中的 JSON 字节数仅是全行/投影数据量的统一表示，用于辅助解释查询成本，不是内存分配或 SQLite 通道的实际传输字节。这里测量 Flutter test JIT 下完整本地状态读取，不能替代 release 原生设置页、首次画面、系统冷启动或万条未来通知调度验收。

2026-10-24 的三个独立进程均通过计数等价、全部业务行不变和完整性核验：[全部原始样本](benchmarks/notification-status-3d27-2026-10-24.json)。

| 进程 | 全字段 p50 / 最大值 | 投影 p50 / 最大值 | p50 降幅 |
| --- | --- | --- | --- |
| 1 | 59.549 / 69.259 ms | 27.683 / 28.019 ms | 53.51% |
| 2 | 60.603 / 69.709 ms | 29.141 / 30.050 ms | 51.91% |
| 3 | 54.903 / 62.885 ms | 25.590 / 27.400 ms | 53.39% |

全行与投影的 JSON 表示分别为 7,344,451 和 1,887,781 B，减少 74.30%。该结果支持减少设置页本地状态读取成本，不用于声称整个应用提速相同比例。
