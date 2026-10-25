# macOS 隔离环境 DST 通知验收

本流程验证真实 macOS 客体时钟跨越夏令时边界后的系统通知行为。宿主保持原日期、时区和电源设置。切换时区、进程的 `TZ` 测试、应用重开和生成夹具均不等于真实 DST 验收通过。

## 准备与输入

使用新的、归属明确的 macOS 虚拟机。记录宿主与客体版本、虚拟机 UUID、磁盘路径、镜像来源/摘要及候选源码/签名。关闭默认宿主 Home 共享；仅提供合成 JSON 和已核验的独立通知身份候选。不要复制用户数据库、真实模型密钥或宿主重启基线。

安装器返回成功后，仍需完成客体初始化并实际进入桌面，才能安装候选和核验客体时间。语言选择、数据迁移或账户创建页面不算客体就绪。原生操作工具若要求用户本人创建登录凭据，应保留当前状态并记录阻塞；不得通过修改磁盘、关闭认证或跳过初始化来绕过该要求。

Parallels 的 macOS 客体默认可共享宿主 Home；官方支持用 `--shf-host-defined off` 关闭。时钟和时区同步在安装 Tools 后也可能启用，须分别读回并控制，不能只关闭客体网络时间。[共享配置](https://kb.parallels.com/en/128842)、[客体限制与同步能力](https://kb.parallels.com/en/128867)。

生成新目录，不覆盖旧输入：

```sh
python3 scripts/generate_dst_acceptance_fixture.py \
  --output /tmp/dontforget-dst-001
python3 -m unittest discover -s scripts/tests -p test_dst_acceptance_fixture.py -v
```

输出 `spring-v9.json`、`autumn-v9.json`、`empty-v9.json` 和 `manifest.json`。三份备份均为冻结 schema 9；现有产品恢复路径负责迁移到当前 schema，恢复导入不能作为启动升级验收。所有数据均为无密钥、无媒体、静音 Q3 合成任务。生成时用 SQLite 和系统时区库验证字段、引用完整性、时间和摘要。

## Apple 虚拟化验收窗口

Apple silicon / macOS 14+ 可构建项目自有的原生验收窗口。`--acceptance-root` 必须是已有专属目录，其中包含 `dst-stage30-materials` 和仅合成数据的 `dst-stage30-share`；客体固定保存在该目录的 `dst-stage30-apple-vm`。参数均使用绝对路径，输出必须是不存在的 `.app`。例如在仓库根目录：

```sh
bash scripts/build_macos_dst_lab.sh --help
bash scripts/build_macos_dst_lab.sh \
  --acceptance-root "$PWD/build/native_acceptance" \
  --output "$PWD/build/native_acceptance/DontForget DST Lab new.app"
python3 -m unittest discover -s scripts/tests -p test_dst_lab_build.py -v
```

构建仅编译、签名并验证窗口，不启动或修改客体；失败只清理本次临时构建目录，发布使用禁止覆盖的原子重命名。首次安装需要已核验的 `dst-stage30-image/restore.ipsw`（当前构建 26A434）。已安装客体启动无需镜像；只要客体目录存在就禁用安装，避免重装覆盖。

启动失败进入框架 `.error` 状态时，窗口释放这个非运行实例，使“Start guest”可重试、退出可用，并记录错误域、错误码与底层错误。运行中或状态切换中的实例不会被释放来规避存储锁。窗口没有配置宿主时间同步代理，但这不能证明客体网络时间已关闭；每轮测试仍须独立读回时间设置。

创建虚拟机实例前，窗口通过只读文件描述符对辅助存储和磁盘执行 `F_GETLK` 检查，拒绝符号链接、缺失文件及非普通文件。发现写入冲突时直接列出被锁文件并返回，不创建新的虚拟机实例；已知持有者记录 PID，未知持有者只记录 `owner_known=false`。检查不获取租约、不解锁、不改写磁盘，检查通过与实际启动之间仍可能出现竞争，最终锁定结果继续以虚拟化框架为准。

在 macOS 运行 `python3 -m unittest discover -s scripts/tests -p test_dst_storage_native.py -v` 可执行真实跨进程文件锁测试，覆盖空闲、竞争持有者、内容不变、持有者退出后恢复及无效路径。该测试已加入 macOS 候选 CI；Linux 质量作业明确跳过这个平台限定用例。

先使用“Request guest shutdown”正常关机。30 秒后仍未停止且框架允许停止，才启用“Stop unresponsive guest…”，再次确认后通过框架停止本客体。该方式可能丢失客体未保存状态，记录为异常停止，后续必须验证启动和文件系统；不能当作正常关机通过。此强制停止分支目前仅完成编译检查，尚无运行中客体实测。

若启动报告 `VZErrorDomain/2`、底层 `NSPOSIXErrorDomain/35`，应先记录锁和进程状态。`lsof` 无输出不足以证明磁盘可用；本机曾在工作进程处于退出状态、RSS=0 时，仍由 `F_GETLK` 读到全文件写锁且 owner PID=-1。只读查询不应获取或修改锁，未知 owner 不能据此指定归属。不得替换文件 inode、删除辅助存储或复制在线磁盘来绕过锁。磁盘、辅助存储、硬件模型及机器身份作为同一客体保留；[Apple 辅助存储说明](https://developer.apple.com/documentation/virtualization/vzmacauxiliarystorage)。

原宿主应用异常退出后的系统资源清理没有公开时限保证，公开 API 也不提供由新进程接管原客体的句柄。[Apple DTS 说明](https://developer.apple.com/forums/thread/850709)。因此不能凭宿主应用退出就声明客体停止完成；持续锁冲突应保留证据和客体文件，继续排查正常宿主重启路径，不反复终止不明归属进程。

## 两轮独立验收

客体时区固定 `America/Los_Angeles`，每轮只恢复一份备份。时钟定位到边界前十分钟后，让系统自然走过边界；观察期间不可跳钟、暂停或恢复虚拟机。

| 场景 | UTC 边界 | 边界前通知的本地时间 | 边界后通知的本地时间 |
| --- | --- | --- | --- |
| 春季 | 2026-03-08 10:00:00Z | 01:59:40 -08:00 | 03:00:20 -07:00 |
| 秋季 | 2026-11-01 09:00:00Z | 01:59:40 -07:00 | 01:00:20 -08:00 |

每轮流程：

1. 保存客体原时间、时区、网络时间及虚拟机时间同步设置。确认关闭客体网络时间与宿主同步后，再设置测试日期和时区；记录独立读回。
2. 在原生恢复确认界面导入对应 JSON；核验两条任务、UTC 触发时间、业务行、通知日志、稳定 ID 和系统待发送数量。无其他测试通知后才开始观察。
3. 同时采集宿主单调时钟与客体 UTC/本地时间。连续记录须跨越偏移变化，明确显示自然经过边界；长时间失联、跳钟或意外同步应判为本轮证据不足。
4. 独立系统日志与原生通知界面逐 ID 核对送达次数和时间；仅 pending/submitted 不代表送达。记录延迟，任何缺失、重复、提前或明显延后均需定位原因，不直接判通过。
5. 导入空备份并核验系统 pending=0、retained=0，保存验后业务/日志证据；恢复客体设置，正常关闭客体。回退材料留在专属目录，测试缓存仅在无占用且保留材料摘要一致后清理。

这两轮覆盖边界附近的一次性提醒。浮动本地时间的每日循环、重复小时中相同墙钟时刻的两次出现、宿主系统重启和其他平台仍需独立验收；不能从夹具或本流程推断通过。

## 未使用空客体的清理

仅清理本次创建、未安装、未启动的空客体。先保存精确 UUID、配置和磁盘描述，确认 stopped/uptime=0、没有文件占用，再通过受支持的管理界面或命令注销。注销后再次枚举，确认 UUID 已消失；磁盘目录归属与状态仍一致后才删除。不要直接删除仍在注册表中的客体目录，也不要修改其他客体或运行中磁盘。

本机 Parallels 的 `prlctl unregister <UUID>` 可成功注销空客体，尽管此前 `set`/`start` 受版本限制。注销会清空配置中的 `ServerUuidAs`，这项预期变化应单独核对，其余字段应保持一致。实际释放量按已分配块记录；128 GiB 稀疏磁盘的逻辑容量不能记作释放了 128 GiB。
