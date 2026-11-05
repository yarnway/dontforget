# 显式容量验收

`backup_capacity_test.dart` 使用随机临时目录、合成数据库和合成附件，不读取真实应用数据或系统凭据。它放在 `test/` 之外，避免普通测试和每次 CI 自动执行多 GiB 压力任务。

Windows 使用 Windows Flutter 启动器（共享 SDK 环境不要调用 Linux 启动器）：

```bat
C:\src\flutter\bin\flutter.bat --no-version-check test --no-pub scripts/acceptance/backup_capacity_test.dart --dart-define=DF_BACKUP_CAPACITY_REPORT=build/backup-capacity-run.json --reporter expanded
```

其他独立 SDK 环境可使用对应的 `flutter test`，参数一致。本轮仅在 Windows 宿主执行，其他宿主需分别验收。先使用项目固定 SDK 和锁文件准备依赖；不要同时运行共享原生 SQLite DLL 的另一组 Flutter 测试。

默认生成四份真实 512 MiB 附件，验证 2 GiB 总附件的普通备份导出、预览、恢复、原件和恢复件 SHA-256、恢复中取消及数据库恢复后重开；另验证单附件／总附件超限一字节被拒绝。加密路径单独验证一份 512 MiB 附件的 AES-GCM 导出、预览和恢复，不据此宣称 2 GiB 加密路径已验收。

预留至少 10 GiB 临时空间及 30 分钟；样本与中间文件在测试结束时清理，报告仅包含阶段耗时、RSS 高水位、字节数和结果。报告路径建议每次使用新文件名，并同时核对进程成功退出、日志末尾 `All tests passed!` 和报告的 `full_capacity_boundary`／`outcome`，避免沿用旧报告。

先检查工具流程可加 `--dart-define=DF_BACKUP_CAPACITY_MIB=4`；它只运行 16 MiB 总附件的冒烟，报告会标明不是完整容量验收。

宿主服务测试不替代手机文件选择器、真实跨设备恢复、磁盘满、断电、系统安全存储锁定或正式分发验收。当前结果按 `docs/Next_Steps_2026-11-02.md` 分层记录。

GitHub Actions 的 **Backup Capacity Acceptance** 仅通过 `workflow_dispatch` 手动运行，可选择 `4` 或 `512`。它在 Linux／Windows 的项目固定 Flutter SDK 上分别分析并执行验收，报告保留为带平台和容量标识的 artifacts；不会创建安装包、Release 或修改应用数据。
