# Windows打包与Android隔离升级 +47（2026-11-03）

本轮接续[Windows动作／Android通知验收](Windows_Android_Validation_2026-11-03.md)，源码 `1.7.0+47 / schema16`，优先Windows与Android。未提交、推送、触发云端CI或发布Release。

## Windows当前候选包

在 `build/stage47/windows-source-47/` 冻结268份输入，未改变应用身份；使用本机Flutter3.47.2与已解析依赖构建Release（193.7秒），Inno Setup生成安装器并生成便携包。本机SDK与CI固定3.44.9的差异继续保留，不替代云端基线验收。

- PE原生版本 **1.7.0.47**，ProductVersion **1.7.0+47**。
- 安装器 **14,109,310 bytes**，SHA-256 `3c5661eba7369825e6f88b66c27ac08591c96564845ce3a7ba0f02e02a82ecc2`。
- 便携包 **17,148,741 bytes**，SHA-256 `fc4cae36c972c461c121700534232824740ca6099f6c80497b64a272bfa5ae3c`。
- 便携包37个文件全部与Release目录逐字节一致，包含AOT、Flutter资源与运行库；CMake安装清单所有目标均位于本轮构建目录。包清洁与摘要核验通过。
- 268份冻结输入摘要 `065ecae2166977f9938bcafa5bf1d8e306254a30e264246d2389651df4bfdb98`；运行源码与当前工作区一致。冻结后仅修改CI验收脚本及其测试，不改变已编译的运行源码。

产物保留于 `dist/candidate-1.7.0+47/`，包含安装器、便携包、manifest、校验和与冻结输入摘要；旧+45保留原归属，未覆盖。Windows产物未签名；没有在本机启动安装器或该Windows可执行文件，没有修改协议注册或执行卸载。本轮不将编译和打包记为启动、真实Toast点击或安装升级通过。

## Windows安装验收门禁修复

原检查仅比较ProductVersion的 `1.7.0` 前缀，旧+45可以与+47混淆。新增[只读PE版本检查](../scripts/windows_installer_checks.ps1)，按manifest的语义版本和构建号核对四段数字版本；真实+47通过，真实旧+45被拒绝。测试还覆盖真实系统PE、错误构建号、非法值和预发布版本形式，无需启动应用。

[安装验收脚本](../scripts/smoke_windows_installer.ps1)现在记录build_number与native_version；每次安装器运行最多300秒，超时只终止其自有进程树并有界等待退出，隐藏运行窗口；递归清理前核对绝对路径仍在RUNNER_TEMP内。脚本保留“Installer acceptance must run on an isolated GitHub runner”限制，新增反向验证确认本机调用在触及验收输出前被拒绝。没有伪造CI环境绕过限制。

本轮Python全量 **136运行／130通过／6跳过／0失败**（10.229秒），新增两项Windows原生检查；PowerShell语法通过。未改Dart代码，因此不重复全量Flutter测试；上轮2153通过／20跳过、分析0保留其源码归属。本轮Windows／Android原生编译均通过。

## Android +46→+47同身份升级

开始时ADB与Windows均未枚举Pixel，后续连接恢复。用户再次明确允许调试后，核对Pixel固定设备与QA身份 `com.yarnway.dontforget.acceptance.p4720261102`，当前安装为+46、进程已停止。保存16个文件与SQLite基线：9提醒（历史回收站）、0媒体、1设置。

使用完整JDK21、SDK36、已解析依赖，关闭本机跨盘Kotlin增量缓存，247秒构建+47 QA debug APK；三处变体差异为applicationId、显示名与本机构建参数。APK签名证书与+46一致，核对身份与versionCode47后执行保留数据升级。

- APK **174,549,380 bytes**，SHA-256 `17e8287c2a0f152767e2f7c0258225d261962df32f75068fb776968688864a6e`，保留于上述候选目录，另有 `android-qa-manifest.json`。
- 本轮debug APK包含三种Flutter ABI；旧+46仅含arm64 Flutter引擎，APK体积差异已核对，不能当作源码增加了等量业务内容。
- 安装成功后、首次启动前，16个数据文件逐字节一致。
- +47冷启动首页正常，Reminders／MediaRecords／Settings全部字段与基线一致，SQLite完整性ok。

此APK使用独立QA身份和debug签名，不是生产身份或正式Android发布包；本轮未构建release AAB。+46真实通知矩阵保留原归属，不能直接转记为+47全部通知场景通过。

## Android本地文本保存与重开

现有微信输入法仅显示候选条，未取得软件发送键。短暂尝试显示软键盘后已恢复原 `show_ime_with_hard_keyboard=0`；没有更换用户输入法。软件IME发送仍待验。

通过产品设置切换到“Send button only”，使用实际Send按钮保存合成文本：只新增1条本地事项、capture_pending=0、无媒体，保存后草稿清空；停止QA进程，再由该事项链接冷启动打开正确详情。随后从详情页软删除合成事项，并通过设置恢复原发送模式。

最终10条提醒含新回收站历史，原9行逐字段保持，全部设置字段恢复，0媒体、SQLite完整性ok；停止进程**之前**核对待发闹钟0／活动通知0。QA进程已停止，手机保留+47供后续调试。原件位于本机忽略目录 `build/stage47/upgrade-47-20261103/`，包含升级前后文件归档、SQL、原生页面与清理结果。

## 剩余顺序

1. Windows隔离CI中的安装／同包升级／卸载、当前包启动及真实Toast正文／动作；旧系统目录来源与恢复评估继续保留。
2. Android +47当前包的通知热／冷／终止状态动作与补排复验，实际软件IME发送、真实录音及取消／保存／重开。
3. Windows窗口偏好独立存储、跨屏与托盘；然后双端备份恢复、全局快捷采集／分享入口与同步冲突。
4. USB间歇断连不因连接恢复或升级成功而关闭；换线后仍复现，另一端口／主机对照条件具备后继续定位。
5. macOS／iOS后续平台矩阵及正式签名、公证与发布门槛。

机器摘要见[Windows本轮产物](benchmarks/windows-package-47-2026-11-03.json)及[Android升级](benchmarks/android-upgrade-47-2026-11-03.json)。
