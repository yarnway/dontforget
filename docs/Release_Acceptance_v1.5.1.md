# v1.5.1 发布前验收记录

日期：2026-10-20。版本：1.5.1+2；数据库：v8；源码基线：e6bfbf3。本记录随源码提交，最终提交号由 Git 和 CI manifest 确认。

状态：**LOCAL_CHECKS_PASS / NATIVE_BUILD_PENDING / RELEASE_NOT_PERFORMED**。本阶段未关闭；v1.6 尚未启动。

## 已完成的本地检查

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| 锁定依赖解析 | PASS | Flutter 3.44.9 / Dart 3.12.2；record 6.1.2 / audioplayers 6.5.1 |
| Flutter 静态分析 | PASS，无问题 | 不含原生编译 |
| Flutter 测试 | PASS，49 项 | 临时 SQLite / widget；通知与录音不是设备测试 |
| 打包逻辑回归 | PASS，10 项 | 临时假产物；覆盖缺失、篡改、版本/提交错配、路径逃逸、私有数据、归档结构 |
| 工作流语法 | PASS，actionlint 1.7.12 | 未执行云端原生构建 |
| Shell / Python 语法 | PASS | PowerShell 和 Inno 的实际执行留给 Windows CI |
| Dart debug bundle | PASS | 不是可安装原生应用 |
| 源码自查 | 已执行 | 没有独立审查结论 |

已修复发布链问题：统一版本来源、Android desugaring、Linux 托盘构建依赖、macOS release LAN server entitlement、失败即停止、测试签名/未签名标记、产物哈希与提交号核验、手动构建不自动发布、Windows 安装/卸载不再额外递归清除历史数据。脚本设计说明见 [打包指南](Packaging_and_Deployment.md)。

## 尚待验收

| 阶段 | 操作与通过标准 | 当前结果 |
| --- | --- | --- |
| GitHub | 推送已验证源码；记录 commit/run URL | ff20128 已推送，首轮 run 39399319944；修订后重跑 |
| 五平台构建 | 所有 job 通过；下载七个包；版本/build/提交号/哈希匹配 | NOT_PERFORMED |
| 桌面启动 | 三平台隔离进程存活检查与日志无启动崩溃 | NOT_PERFORMED；不等于可用性验收 |
| 安装与卸载 | 新安装、覆盖升级、取消安装；路径含空格；卸载保留历史/用户数据；记录 OS 与包哈希 | NOT_PERFORMED |
| 真实 v7 升级 | 保存原始副本；核对设置、任务、媒体索引；自填密钥/模型保留，旧内置密钥清除 | 仅自动化临时库验证；真实脱敏样本待验证 |
| 备份 | 新增/完成/编辑后手动备份；只读/空间不足等故障有反馈；旧镜像可读；原库不受损 | 仅测试覆盖部分故障；设备操作待验证 |
| 提醒 | 授权/拒绝、编辑、完成、删除、重启、休眠恢复、时区变化；记录系统通知与任务一致性 | NOT_PERFORMED；既有调度闭环缺口留待 v1.6 |
| 设置 UI | 中/英/日，保存成功/失败、备份成功/失败，窄屏与键盘 | widget 覆盖部分路径；设备验收待验证 |
| 签名与外部凭据 | Android 正式签名、Apple 签名/公证；维护者撤销旧泄露凭据 | NOT_PERFORMED |
| 正式发布 | 验收问题关闭后创建可审核草稿，再单独决定公开发布 | NOT_PERFORMED |

本机只有 Xcode Command Line Tools，缺少完整 Xcode/CocoaPods/Android SDK；不将 bundle 或旧 CI 的 macOS/iOS 成功记录复用为当前候选验收。历史基线 run 34359947222 中 Windows/Android/Linux 失败，当前修订必须重新运行。

## 后续阶段

- v1.5.1：先完成以上构建、升级、安装与必要设备验收。遇到失败修复后重新构建，旧包不得混入新提交清单。
- v1.6 数据恢复：只读检查与预览、历史备份、恢复前备份、失败回退、启动存储故障提示、关联事务、日历锚点迁移。
- v1.6 提醒闭环：持久稳定通知 ID、串行且可等待的调度/取消、编辑/完成/删除一致性、重启重建、时区与休眠补偿。按模块测试并提交，分别记录模拟与设备证据。

## 原生构建修订

读取历史失败日志后确认 Android 缺少 `flutterEmbedding=2` 元数据，Windows 全局 `/await` 触发 MSVC STL1011。已补齐 v2 embedding 并将 Windows 标准设置迁到 C++20、删除旧协程扩展；仍需本轮 CI 验证。

第二次构建 [run 39399461749](https://github.com/yarnway/dontforget/actions/runs/39399461749)，源码 03e5785：质量、Linux、macOS、iOS 通过；Android 的 record 4.4.4 缺少 namespace，Windows 旧窗口插件不兼容全局 C++20。修订采用 record 6.1.2 的 AudioRecorder/RecordConfig API，C++20 限定到 audioplayers；修复 Linux 不支持 tooltip 导致托盘菜单初始化中断。新增 3 项录音协议回归（插件模拟，不是真实录音）。新插件需要全部平台重建，旧产物不作为新版本提交的验收证据。

第三次完整构建 [run 39400690334](https://github.com/yarnway/dontforget/actions/runs/39400690334)，源码 9f7c9f4：Linux、macOS、iOS 通过；Windows 已通过插件编译，失败在当前 Flutter SDK 不存在的 Impeller API；Android 已通过录音模块配置，失败在旧 audioplayers 的 compileSdk 33。移除无效 API 并升级 audioplayers 6.5.1 后，本地分析与 49 项测试通过。追加 Windows 隔离安装/覆盖升级/卸载文件保留检查；桌面启动从交付归档解压运行。这些新增原生验收待后续 CI 执行。
