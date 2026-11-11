# 阶段48：带附件的 Android／Windows 后端往返（2026-11-11）

本轮使用1.8.2+71的运行时代码，`lib`树`a324cae5fdbbb5a9e3321525bbdbd32be111044e`与正式版源码`de4bda47a8759c4bff634d115d65f8bd4ec7e14a`一致。新增独立验收工具，不修改应用版本、依赖或数据库结构。源码、安装身份、后端与界面范围分别记录。

## 结果

| 链路 | 普通流式备份 | 密码加密备份 |
| --- | --- | --- |
| Android原生SQLite导出 | 4事项／3附件 | 4事项／3附件 |
| Windows SQLite后端恢复并关闭重开 | 全字段及3文件摘要一致 | 全字段及3文件摘要一致 |
| Windows新增事项与附件后导出 | 5事项／4附件 | 5事项／4附件 |
| Android原生恢复并关闭重开 | 5事项／4附件，摘要及引用一致 | 5事项／4附件，摘要及引用一致 |
| 强停后新进程再次读回 | 一致 | 一致 |

三份原始文件为64044字节合成WAV、68字节PNG和5888字节中英日文文本，Windows新增82字节文本。除活跃事项外，包含已归档、回收站及暂停学习批次，检查所有事项字段、附件引用、词条进度和复习日期；媒体路径须重映射到目标设备的恢复目录，类型、扩展名、时间、字节数与SHA-256一致。源文件另行核对未变。Windows错误密码无恢复输出，两个平台的设备独立偏好保持，公开合成凭据哨兵未进入导出。

首次验收因要求保留原始文件名而失败；现有流式格式会生成`attachment-<序号>.<扩展名>`，原名不保留。修正验收预期后完整链路重新通过，未改动运行时代码。初次桌面日志后来被显式重试覆盖，保留了失败步骤日志与说明，不宣称首次即通过。[机器证据](benchmarks/attachment-round-trip-71-2026-11-11.json)包含各格式文件摘要、代码／包身份、日志摘要和清理结果。

## 身份与范围

- Pixel采用独立debug身份`com.yarnway.dontforget.acceptance.attachments20261111`、本机SDK3.47.2，仅合成数据。实际调用Android SQLite和产品备份／恢复服务；通知与凭据存储使用替身，不调用模型或腾讯云，不读用户库。
- Windows在Flutter测试宿主中使用真实SQLite FFI和同一产品服务，临时目录恢复、关闭重开及回传。它是桌面后端验收，不能记作已安装Windows GUI操作。
- 文件通过带临时认证的ADB本地转发传输，所有传输核对摘要。本轮不操作SAF选择器，不代表系统文件选择器、原生预览／播放、2GiB真机往返或磁盘满／断电通过。
- 临时应用已卸载、本轮转发已移除；正式版和QA47未重装、未清除，版本均保持71。原用户应用恢复前台。Windows已安装应用保持1.8.2+71；没有产生新的普通安装版本或Release。

## 复现入口

仅使用独立测试身份和合成文件。Android入口位于`scripts/acceptance/android_attachment_round_trip.dart`，共享夹具位于`scripts/acceptance/support/attachment_round_trip_fixture.dart`；入口拒绝正式包身份和缺少随机认证令牌的启动。普通`lib/main.dart`不会运行该入口。

1. 在隔离Android构建树设置上述applicationId，显式以该入口构建debug APK；通过`--dart-define=DF_ATTACHMENT_TOKEN=...`传入至少32字符的随机临时令牌，不使用真实服务密钥。确认同名测试身份原先不存在，再安装。
2. 用`adb forward --no-rebind tcp:17775 tcp:17775`建立本地转发。全部HTTP请求发到`127.0.0.1:17775`，带`Authorization: Bearer <临时令牌>`；`GET /source`核对初始4／3合成数据。
3. 下载`GET /export/plain`及`GET /export/encrypted`为同一交换目录下的`android-plain.dfbackup`、`android-encrypted.dfbackup`，校验响应`X-Backup-SHA256`。
4. Windows执行下列显式验收；输出路径不得已有返回文件。每份输出旁生成`.report.json`。

```powershell
flutter test --no-pub --concurrency 1 `
  --dart-define=DF_ATTACHMENT_EXCHANGE=build/attachment-exchange `
  scripts/acceptance/attachment_round_trip_test.dart
```

5. 将`windows-plain.dfbackup`、`windows-encrypted.dfbackup`分别POST至`/import/plain`、`/import/encrypted`，请求头`X-Backup-SHA256`填完整文件摘要。`GET /verify`须两种格式均5／4，随后强停并重新启动该测试应用，确认进程不同后再次核对。
6. 卸载本轮新建的临时身份，移除本轮转发，恢复原前台应用。失败时先保留诊断与步骤，不以重新运行成功覆盖首次结果。

## 剩余

带附件SAF／桌面GUI全链路、大文件设备往返、真实凭据锁定／重新授权、磁盘满／断电、保留管理和原声压缩继续。附件原始显示名跨设备保留属于现有格式的后续易用性改进；本轮只验证生成安全名称的既有行为。
