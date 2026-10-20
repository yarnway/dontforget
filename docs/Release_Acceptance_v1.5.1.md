# v1.5.1 发布前验收记录

日期：2026-10-20。版本：1.5.1+2；数据库：v8；候选源码：`7cdf85b766fbc9be437246803a5443b2ace32937`。后续验收文档提交不改变此候选包身份。

状态：**LOCAL_CHECKS_PASS / FIVE_PLATFORM_PACKAGES_PASS / DEVICE_ACCEPTANCE_PARTIAL / PUBLIC_RELEASE_NOT_PERFORMED**。打包与自动化验收完成；完整设备验收尚未关闭，v1.6 功能开发尚未启动。

**未关闭阻塞：MAC_RECORDING_RETEST_PENDING。** 66bf406 在当前 Mac 实际录音失败；修订后的 7cdf85b 已重新打包，但真机复测尚未完成。发布草稿仍保留 66bf406 原包供追溯；原生构建与进程启动成功不足以关闭该问题。

当前有效流水线：[run 39407526781](https://github.com/yarnway/dontforget/actions/runs/39407526781)。质量检查、五平台原生构建全部成功；分支推送跳过自动 release job。下载全部五份平台产物后，本地独立执行 `verify_artifacts.py --revision 7cdf85b766fbc9be437246803a5443b2ace32937 --tag v1.5.1`，七个交付包的版本、提交身份及 SHA-256 全部通过。旧失败流水线的包不混入本候选。

## 已完成的本地检查

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| 锁定依赖解析 | PASS | Flutter 3.44.9 / Dart 3.12.2；record 6.1.2 / audioplayers 6.5.1 |
| Flutter 静态分析 | PASS，无问题 | 不含原生编译 |
| Flutter 测试 | PASS，55 项（录音及通知初始化修订后） | 66bf406 的 CI 为 49 项；7cdf85b 云端质量检查和重建已通过。临时 SQLite / widget 不代替设备测试 |
| 打包逻辑回归 | PASS，10 项 | 临时假产物；覆盖缺失、篡改、版本/提交错配、路径逃逸、私有数据、归档结构 |
| 工作流语法 | PASS，actionlint 1.7.12 | 本候选另有云端原生构建成功证据 |
| Shell / Python 语法 | PASS | PowerShell 和 Inno 已在 Windows CI 执行 |
| Dart debug bundle | PASS | 不是可安装原生应用 |
| 源码自查 | 已执行 | 没有独立审查结论 |

已修复发布链问题：统一版本来源、Android desugaring、Linux 托盘构建依赖、macOS release LAN server entitlement、失败即停止、测试签名/未签名标记、产物哈希与提交号核验、手动构建不自动发布、Windows 安装/卸载不再额外递归清除历史数据。脚本设计说明见 [打包指南](Packaging_and_Deployment.md)。

## 尚待验收

| 阶段 | 操作与通过标准 | 当前结果 |
| --- | --- | --- |
| GitHub | 推送已验证源码；记录 commit/run URL | PASS，7cdf85b / run 39407526781 |
| 五平台构建 | 所有 job 通过；下载七个包；版本/build/提交号/哈希匹配 | PASS，五平台七个包；签名限制见下文 |
| 桌面启动 | 三平台隔离进程存活检查与日志无启动崩溃 | PASS，交付归档解压后进程运行 10 秒；不等于可用性验收 |
| 安装与卸载 | 新安装、覆盖升级、取消安装；路径含空格；卸载保留历史/用户数据；记录 OS 与包哈希 | PARTIAL，Windows CI 新安装、同候选覆盖安装、卸载、含空格路径及合成历史文件保留通过；取消安装、真实旧版安装及用户主机待验收 |
| 真实 v7 升级 | 保存原始副本；核对设置、任务、媒体索引；自填密钥/模型保留，旧内置密钥清除 | 仅自动化临时库验证；真实脱敏样本待验证 |
| 备份 | 新增/完成/编辑后手动备份；只读/空间不足等故障有反馈；旧镜像可读；原库不受损 | PARTIAL，Mac 空任务库手动备份产生可读镜像与 JSON；有任务/媒体及设备故障场景待验收 |
| 提醒 | 授权/拒绝、编辑、完成、删除、重启、休眠恢复、时区变化；记录系统通知与任务一致性 | NOT_PERFORMED；既有调度闭环缺口留待 v1.6 |
| 设置 UI | 中/英/日，保存成功/失败、备份成功/失败，窄屏与键盘 | PARTIAL，Mac 英文设置保存返回主页且数据库持久化；其余场景待验收 |
| 签名与外部凭据 | Android 正式签名、Apple 签名/公证；维护者撤销旧泄露凭据 | NOT_PERFORMED |
| 正式发布 | 保留候选草稿；验收问题关闭后单独决定公开发布 | 未公开发布；草稿不表示正式验收通过 |

本机只有 Xcode Command Line Tools，缺少完整 Xcode/CocoaPods/Android SDK。当前原生包由上述 CI 构建；Android 是测试签名 APK/AAB，macOS 未公证，iOS IPA 未签名。iPhone 安装需要有效 Apple 签名与设备授权，目前不能安装此 unsigned IPA。

## 当前 Mac 的设备证据

- 环境：macOS 27.0.1 arm64；启动本候选 ZIP 解压的 `dont_forget.app`。运行前未发现此应用的安装及支持数据目录。
- 首页与设置页可见；API Key 为空，LAN 开关关闭；未配置服务密钥或发起 AI 请求。
- 用户协助滚动设置页到底部（自动化滚动接口返回 `noWindowsAvailable`，应用仍正常运行）。点击 “Back up saved data” 后，镜像与快照更新时间为 2026-10-20 17:59:45 CST。
- 主库、镜像只读 `PRAGMA integrity_check` 均为 `ok`，schema 均为 8；Settings / MediaRecords / Reminders 数量均为 1 / 0 / 0。JSON 同为 v8，表数量一致，API Key 为空。仅证明空任务库备份可读，不代表带附件数据恢复通过。
- 点击 Save 后返回英文主页；只读核对主库 `language=en`。本轮未捕获备份成功提示，不能将文件成功写入等同于提示验收通过。
- 麦克风、系统通知、三语切换重启、有任务备份、真实 v7 数据迁移均未完成设备验收。

### Mac 继续验收（同一 66bf406 候选）

- 通过 UI 新建 `QA-MAC-151` 测试任务、修改标题、清空提醒时间、标记完成。主库只读核对标题更新、`trigger_time=NULL`、`is_completed=1`。
- 再次手动备份捕获 “Local backup created.”；2026-10-20 18:06:49 CST 的主库、镜像、JSON 均保留上述任务字段，主库/镜像完整性为 `ok`。
- 日语保存成功，正常退出后重启仍为日语且任务保持完成；随后切换中文并保存返回中文首页。未逐页验证完整三语翻译；发现英文页残留“点击修改”、中文剩余时长、预设服务商推荐文案，以及快捷菜单未翻译键名。
- 用户明确允许约 5 秒测试录音。界面进入录音状态，停止后未退出；系统日志记录 `AudioFileCreateWithURL failed (2003334207)` / `CreateDataFile failed`。未生成音频媒体记录。通过正常退出关闭候选进程，确认进程不存在；后续日志确认停止操作时底层音频输入已停，但 Dart 停止回调未完成。不能记为录音/回放通过。
- 根因证据：path_provider_foundation 2.6.0 的 `getTemporaryPath()` 返回带 bundle ID 的缓存目录但不创建；现场该子目录不存在。AVFoundation 接收开始操作后异步写文件失败，record_macos 1.2.2 的停止回调未返回。
- 修订：录音开始前创建缓存目录，媒体持久化前创建目标目录；没有 AI 密钥时生成关联原声备忘录；后台处理结束不隐式抹除反馈。回归先复现缺失目录失败，修订后静态分析和 52 项 Flutter 测试通过，覆盖不可用路径不启动原生录音、无密钥原声任务关联、反馈保留。原生包重新构建及真机复测仍待完成。

GitHub v1.5.1 草稿已上传 7 个包、5 份 manifest、5 份校验清单、4 份运行证据，共 21 个文件；GitHub 返回的 21 个 SHA-256 均与本地一致。草稿标记 Mac 录音阻塞；附件仍为 66bf406，不因源码修订而自动变成新候选。

### 通知初始化缺口

Mac 系统通知设置中未列出本应用；源码检索确认 `NotificationService.init()` 没有调用者，首次调度未初始化原生插件和 timezone 数据。补上首次有效提醒调度时的初始化（并发请求合并），并等待取消完成再重建。已完成/无时间任务只取消，不请求新权限。新增协议测试覆盖初始化完成后才调度、并发只初始化一次、取消完成顺序、已完成任务不请求权限；全量测试共 55 项通过。此修订不等于系统通知已到达，仍需新的 Mac 包与用户权限验收；稳定 ID、重启/休眠/时区完整闭环仍属于 v1.6。

## 发布剩余阻塞

1. Windows / Android 用户设备首次安装、录音和通知场景，Mac 的权限与提醒场景。
2. iOS 签名与手机安装；正式 Android 签名、Apple 公证。
3. 真实 v7 脱敏样本升级核对；外部服务商撤销历史内置凭据。
4. 按设备步骤补齐失败场景及三语 UI；任何新修复均需新提交与重新打包，不能沿用本候选哈希。

## 后续阶段

- v1.5.1：先完成以上构建、升级、安装与必要设备验收。遇到失败修复后重新构建，旧包不得混入新提交清单。
- v1.6 数据恢复：只读检查与预览、历史备份、恢复前备份、失败回退、启动存储故障提示、关联事务、日历锚点迁移。
- v1.6 提醒闭环：持久稳定通知 ID、串行且可等待的调度/取消、编辑/完成/删除一致性、重启重建、时区与休眠补偿。按模块测试并提交，分别记录模拟与设备证据。

## 原生构建修订

读取历史失败日志后确认 Android 缺少 `flutterEmbedding=2` 元数据，Windows 全局 `/await` 触发 MSVC STL1011。已补齐 v2 embedding 并将 Windows 标准设置迁到 C++20、删除旧协程扩展；仍需本轮 CI 验证。

第二次构建 [run 39399461749](https://github.com/yarnway/dontforget/actions/runs/39399461749)，源码 03e5785：质量、Linux、macOS、iOS 通过；Android 的 record 4.4.4 缺少 namespace，Windows 旧窗口插件不兼容全局 C++20。修订采用 record 6.1.2 的 AudioRecorder/RecordConfig API，C++20 限定到 audioplayers；修复 Linux 不支持 tooltip 导致托盘菜单初始化中断。新增 3 项录音协议回归（插件模拟，不是真实录音）。新插件需要全部平台重建，旧产物不作为新版本提交的验收证据。

第三次完整构建 [run 39400690334](https://github.com/yarnway/dontforget/actions/runs/39400690334)，源码 9f7c9f4：Linux、macOS、iOS 通过；Windows 已通过插件编译，失败在当前 Flutter SDK 不存在的 Impeller API；Android 已通过录音模块配置，失败在旧 audioplayers 的 compileSdk 33。移除无效 API 并升级 audioplayers 6.5.1 后，本地分析与 49 项测试通过。追加 Windows 隔离安装/覆盖升级/卸载文件保留检查；桌面启动从交付归档解压运行。这些新增原生验收待后续 CI 执行。

第四次完整构建 [run 39401703837](https://github.com/yarnway/dontforget/actions/runs/39401703837)，源码 a6cff9a：质量、Android、Linux、macOS、iOS 通过；Windows 编译及安装/覆盖安装/卸载/历史文件保留检查通过，归档启动以 0xC0000005 失败。打包中发现旧 UCRT 10.0.10240.16384 与 VC CRT 14.29.30139，下一次改用当前 Visual Studio 配套 CRT，并采集失败的启动日志和 Windows 应用事件。此时尚未确认崩溃根因，不能将更换运行库当作修复已验证。

第五次完整构建 run 39402846594，源码 66bf406：全部质量检查和五平台构建通过；Windows 改用当前 Visual Studio 配套 CRT 后，归档启动、安装覆盖及卸载保留检查全部通过。验证的是整个修订后的候选，未单独隔离定位到某一个旧 DLL。Linux 启动日志存在虚拟显示环境的 EGL/辅助功能警告，macOS 存在 sqflite factory 提示；均未导致本次进程启动失败，不代表这些日志已被消除。

用户具备 Mac、iPhone、Windows 主机与 Android 手机；[设备验收步骤](Device_Acceptance_v1.5.1.md) 已准备。当前 Mac 运行前未发现本应用安装或支持数据目录。

## 7cdf85b 新包复测恢复

2026-10-20 用户手动恢复验收。七包身份与哈希再次验证通过；新 Mac ZIP SHA-256 为 `9bf667a1c061165653205f2a6f2ddb965ce7da9bd508bf547cbb182ab511c787`。启动进程路径确认来自 run 39407526781 的解压目录；中文首页及旧测试任务仍可见。开始前 bundle 缓存目录仍不存在，可覆盖首次录音目录创建场景。

桌面工具可读取窗口，但点击录音未改变状态，坐标点击返回 `noWindowsAvailable`；没有证据表明录音已启动。已请求用户手动录制约 5 秒并停止，录音、回放、音频文件和媒体关联验证待完成。此工具阻塞不记为新包录音失败。发布草稿尚未替换旧附件，v1.6 尚未开始。
