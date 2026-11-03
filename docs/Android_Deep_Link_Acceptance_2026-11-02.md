# 阶段47：Android深链与Pixel验收（2026-11-02）

源码版本 `1.7.0+46`、schema16。上一阶段Windows验证包仍固定为 `+45`，其产物与本轮源码分别记录，不沿用旧包验收。

## 源码与自动化

- Android `MainActivity`通过原有协议通道接收 `ACTION_VIEW`；冷启动先保留链接，Dart安装接收器后握手取出；`singleTop`热激活经 `onNewIntent`送达。初始化前多次激活保留最近一条，销毁时解除通道。
- 关闭Flutter默认深链导航，避免同一链接重复进栈。Android仅声明实际支持的 `dontforget`，移除没有Android处理端的 `dontforget-live`。
- 完整URI校验：限制8192字符，不接收命令行、用户信息、端口、片段、额外路径、重复／未知参数或控制字符。
- 查看详情使用 `dontforget://task/<URI编码ID>`。同一详情打开期间重复激活不再进栈，关闭后可再次打开；删除或不存在的事项不打开。
- Android完成及延后必须附带现有 `NotificationPayload`，在现有数据库事务中复验数据代次、事项ID、提醒时间和修订号；支持完成、延后15／60分钟。裸ID动作不执行，重复或旧链接不推进下一次周期。Windows既有协议保持兼容。
- 链接等待数据、通知和导航就绪；进入恢复时清空排队链接，并作废尚未返回的初始链接，避免旧输入进入恢复后的数据。

最终复验：Flutter全量 **2142通过／20跳过／0失败**（260秒），协议与应用路由专项 **63通过**，Python **134运行／128通过／6跳过**，静态分析 **0 issues**（48.2秒）。专项计入全量，不重复累计。新增37项，包含真实临时SQLite的完成、延后与重复操作。最终复验包含真机调试后增加的debug启动诊断，诊断只记录异常类型、文件系统错误码与有限栈帧。

## Pixel环境与USB诊断

用户已授权Pixel 8 Pro调试及APP验证，并在手机上允许本机新出现的RSA授权。设备读取为 **Pixel 8 Pro／Android17**，不在公开台账记录序列号。

1. 初始Windows仅枚举MTP（`wpdmtp.inf`，问题码0）；随后手机开启调试后枚举WinUSB（`winusb.inf`，问题码0），没有据此判定驱动损坏。
2. ADB37.0.1在5037和5038启动失败，日志为Winsock **10013**。`netsh interface ipv4 show excludedportrange protocol=tcp`显示系统保留范围 **4955—5054**，独立socket绑定测试复现这两个端口失败，而15037成功。
3. 改用 **15037** 后ADB服务启动，先返回 `unauthorized`，用户允许手机RSA提示后转为 `device`。使用默认 **LIBADBUSB** 后端；没有移除端口保留、改防火墙、强换驱动或关闭USB电源管理。
4. 授权后30次有界ADB采样全部为 `device`，最大请求耗时47ms；三轮32MiB随机文件推送／拉回全部SHA-256一致，各约3秒，测试远端临时文件已删除。该结果证明本轮观察和传输期间稳定，不证明长时间、换线或休眠后永不掉线。

本机命令（端口必须一致）：

```powershell
./build/android-tools/platform-tools/adb.exe -P 15037 devices -l
$env:ADB_SERVER_SOCKET = 'tcp:127.0.0.1:15037'
```

Platform-Tools、SDK平台36及插件需要的34、Build-Tools36.0.0、NDK28.2.13676358及CMake3.22.1放在本轮 `build/` 内。初用IDE精简运行时缺少 `jlink`，后在测试目录安装并校验完整Temurin21.0.13+9；未改全局JAVA_HOME。命令行工具和JDK下载核对官方SHA-256。

Windows本机还复现Kotlin增量缓存跨盘错误（Pub缓存在C盘、项目在D盘，`this and base files have different roots`）；本轮通过 `kotlin.incremental=false`关闭该缓存并限制两个Gradle工作线程完成重试，不删除共享缓存或修改插件源码。Android构建脚本提供 `-DisableKotlinIncremental`，以及复用已解析依赖的 `-NoPub`，并预检原生插件注册文件是否存在。脚本PowerShell语法校验通过；原生构建实际使用了关闭增量缓存的参数，本轮未执行完整release APK／AAB发布脚本。相关开关依据[Kotlin官方文档](https://kotlinlang.org/docs/gradle-compilation-and-caches.html)。

## 原生构建与设备结果

隔离源码目录 `build/stage47/android-source/`；仅测试变体将applicationId改为 `com.yarnway.dontforget.acceptance.p4720261102`、显示名改为“别忘了 QA47”。初始查询未发现生产应用，仍使用隔离身份避免混用。

**构建、隔离安装与深链矩阵通过**。最终APK为debug多ABI包，`versionName=1.7.0`、`versionCode=46`、minSDK24、targetSDK36；Pixel实际运行arm64。大小 **97,849,742 bytes**，SHA-256：

```text
7b1e78c98663af016b5513a8606c73c4eff8c72bbfffee49d1e8043a5abfe1e8
```

218份构建输入（含生成的原生插件注册文件）已冻结摘要；与工作区逐文件比较，测试目录仅有applicationId、显示名和本机构建参数三处差异。输入摘要、APK清单与原始证据位于本机忽略目录 `build/stage47/`，公开摘要见[机器记录](benchmarks/stage47-android-2026-11-02.json)。

首次隔离快照漏拷被git忽略的 `GeneratedPluginRegistrant.java`，导致原生插件缺失、首启进入存储错误页；日志明确出现注册类找不到。补齐生成文件后重建，并卸载／重装**仅QA身份**，真实空库首启成功，schema16与通知代次文件正常创建。该项为测试快照准备错误，不记录为生产数据库修复；构建脚本现已加入缺少注册文件时提前失败的检查。

| 验证 | 结果与读回 |
| --- | --- |
| 空库首次启动 | 通过；0提醒／0媒体、schema16，首页正常 |
| 查看详情冷启动 | 通过；OS记录COLD，加载后打开目标事项，查看不确认提醒 |
| 热激活与导航去重 | 同PID重复URI只保留一层详情；一次返回即到首页，关闭后可再次打开 |
| 热完成与延后15／60分钟 | 各动作重复发送两次；SQL修订号均只从0到1，延后时长读回正确，周期完成只前进一步 |
| 有效动作冷启动 | 独立非周期事项冷启动完成，完成状态与修订号均正确；再次冷启动重放旧payload不变更 |
| 非法／失效输入 | 缺失事项、额外路径、裸ID、旧轮次、错误代次、修订号或事项哈希均未改错任务；SQL全字段比对保持 |
| 删除后链接 | 通过；产品软删除后同一详情URI不打开 |
| 产品清理与系统队列 | 5条合成事项全部通过详情页删除，库保留5条回收站历史、0媒体、草稿为空、完整性ok；系统活动闹钟0／活动通知0，QA进程已停止，测试包保留 |

首次ADB硬件Enter尝试只保存了未发送草稿，**未计为文本录入通过**；该草稿现已从界面清空。原生URI调用仅覆盖协议入口，未计为通知正文／按钮点击、权限或实际送达通过。系统闹钟删除历史中的快照与当前待发队列分别核对。

## 原生复验步骤

在独立身份中准备合成事项，记录初始数据库与系统通知；不读取用户其他APP资料。

1. 首次安装、启动已完成；文本保存／重开仍需通过实际输入法发送动作验收。
2. `adb -P 15037 shell am start -W -a android.intent.action.VIEW -d 'dontforget://task/<ID>' -p <QA包名>`：热激活进入正确详情，重复不进第二层；退出详情后可重开。
3. 停止仅QA进程后从同一URI冷启动，确认数据加载后打开正确详情且未被自动确认。
4. 用该隔离库当前代次与提醒轮次生成payload，构造完成及15／60分钟延后URI；核对SQL只变更一次，重复、旧修订、错误代次与裸ID不修改数据。
5. 非法路径、未知事项及已删除事项不跳错记录；不把URI调用记为通知按钮点击。
6. 清理本轮合成事项和通知，核对系统队列；保留隔离测试包和证据供复核。

后续Android通知送达／按钮点击、权限、前后台／终止、重开补排和真实录音仍需单独设备矩阵。

## 本机Codex重连配置

用户另要求将截图中的流式重连上限从5改为2，并明确批准自定义provider方案。已备份用户级 `config.toml`，切换至 `openai-two-retries`，沿用OpenAI登录与既有模型，设置 `stream_max_retries=2`；本机 `app-server --print-startup-config --strict-config`复验通过。当前会话即时重载未验证，未为此重启Codex；需下次启动确认实际显示。HTTP请求重试次数未修改。该配置是本机设置，不进入项目源码。

实现依据：[Flutter平台通道](https://docs.flutter.dev/platform-integration/platform-channels)、[Flutter深链处理](https://docs.flutter.dev/release/breaking-changes/deep-links-flag-change)、[Android ADB](https://developer.android.com/tools/adb)、[Google USB驱动说明](https://developer.android.com/studio/run/win-usb)。
