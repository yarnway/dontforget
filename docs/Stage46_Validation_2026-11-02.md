# 阶段46：候选质量修复与验收（2026-11-02）

范围：以 `2826e26` 为基础的本轮工作区修改，版本 `1.7.0+45`、schema16。没有提交、推送、标签或Release操作。后续任务及退出标准见[阶段46—50清单](Next_Steps_2026-11-02.md)。

## 已完成的源码修复

- **D1**：`selectMissedReminders`按完整 `occurrenceIdentity` 排除当前到期面板中的事项；主页将同一筛选结果提供给错过横幅、页签及列表。最近到期以及会话内保留超过15分钟的提示不会重复计数，新修订不被旧轮次误排除；“全部知道了”只确认错过集合。
- **性能保护**：心跳仅在错过列表成员变化时更新工作区，已有“空闲心跳保留TaskBoard实例”的回归继续通过。
- **D5**：`pubspec.yaml`从 `+44` 对齐 `+45`。Windows打包新增 `-NoPub`，可复用本地已经测试的依赖，不在打包阶段重新解析并改写lockfile；默认CI解析流程保留。
- **重试构建路径**：修复CMake首次配置失败后默认系统安装前缀残留的问题，每次配置均将运行依赖组装到可执行文件所在的构建目录。安装器编译前检查可执行文件、Flutter运行库与资源目录，缺件立即停止。
- **CI**：`quality-windows`取消软失败，构建依赖Linux和Windows两组质量检查，Windows启用现有SDK严格检查。版本查询关闭远端更新检查、30秒超时，避免本地基线检查被 `git fetch --tags` 阻塞。
- **台账**：新增后续阶段清单，更新README、开发计划、检查点和发布验收入口；纠正将旧包安装结果、协议调用和源码测试记为全部原生场景通过的表述。

## 自动化结果

环境：Windows、本机Flutter3.47.2／Dart3.13.2；CI基线仍为Flutter3.44.9。本机测试不替代基线SDK的云端结果。

| 验证 | 本轮结果 |
| --- | --- |
| `flutter --no-version-check analyze --no-pub` | 0 issues |
| `flutter --no-version-check test --no-pub --reporter expanded` | **2105通过／20跳过／0失败**，259秒 |
| 提醒与主页专项：`test/missed_reminders_bar_test.dart test/widget_test.dart` | **34通过**，包含在全量中，不重复累计 |
| `python -m unittest discover -s scripts/tests -v` | **134运行／128通过／6平台跳过／0失败** |
| Windows跳过清单 | 14处声明有平台原因；参数化后实际跳过20个测试 |
| `git diff --check` | 通过 |

新增回归验证：可见轮次排除与新修订独立；最近到期／较早会话提示／历史错过三类在真实主页同时呈现，错过筛选不混入前两类，一键已读不修改到期事项。旧72小时边界、三语言／三宽度／大字体、确认后重开及键盘／焦点测试继续通过。测试库在系统临时目录，通知及平台能力使用替身。

首次全量发现时钟包装导致看板重建，已修复并重新跑完整套件。初次构建与测试并发导致 `build/native_assets/windows/sqlite3.dll` 被占用；后续串行构建发现当前应用正使用默认Release可执行文件，故转入 `build/stage46/package-source/` 隔离源码快照打包，没有为释放文件锁终止用户应用。

## Windows产物

隔离快照完成Windows Release构建、Inno Setup安装器与便携包生成，已替换工作区 `dist/` 的旧产物。旧安装包、便携包、清单及摘要保留于 `build/stage46/previous-dist/`。

| 产物 | 大小（字节） | SHA-256 |
| --- | --- | --- |
| `dist/DontForget_Setup_v1.7.0.exe` | 14,106,080 | `33a03f08c0171a8756187738ac40c4865b77c451bd40e48d42d7123be999f229` |
| `dist/DontForget_Windows_Portable_v1.7.0.zip` | 17,146,267 | `1ef3aa0b544dd0c5560763edc9651d963405014b080ad2d67be67ef11a2aecc6` |

- 原生exe `ProductVersion`为 `1.7.0+45`；便携包中的exe与构建产物字节一致，Flutter运行库在包内，两个产物通过 `verify_artifacts.py`。
- 对比主工作区、隔离快照的211份源码输入全部一致，源码摘要为 `4c24ecc0bd4ce2ff57dedfbfcc8cd04e7127b701ddf6f22bbfd070a3fa5da066`；`pubspec.lock`未改写。
- 这是未提交工作区的本机验证包，清单明确标注 `working_tree_dirty`、基线提交、SDK与源码摘要；本地身份为 `2826e2671df8a0d12305f61f2cdefd3816e2a820-worktree-4c24ecc0bd4c`，不冒充干净提交或固定SDK的CI包。
- 修复后的CMake安装输出清单全部位于隔离构建的 `runner/Release` 内；构建、归档校验通过不代表安装、原生运行或正式分发通过。

机器摘要见[stage46-quality-2026-11-02.json](benchmarks/stage46-quality-2026-11-02.json)。本机原始日志为 `build/stage46-flutter-tests.log`、`stage46-focused-tests.log`、`stage46-analyze.log`、`stage46-python-tests.log`和`stage46-windows-package.log`；这些本机日志及输入快照不纳入Git。

### 构建副作用记录

隔离构建第一次配置因NuGet下载中断而失败。重试时，原CMake的 `CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT` 条件已不成立，缓存仍为 `C:/Program Files/dont_forget`，造成运行文件被复制到该已有目录，且该次构建目录缺少依赖，归档阶段拒绝打包。现已修复为每次明确设置应用构建目录，增加安装器编译前完整性检查。

该系统目录在本轮前已存在；没有其旧程序文件的完整备份，不能证明原字节可恢复，因此没有擅自删除目录或宣称已回滚。该次27份安装输出的清单和当前摘要保留于 `build/stage46/unintended-system-install-manifest.txt`、`unintended-system-install-files.json`。当前运行中的原Release实例未终止，后续构建不再写该系统目录。NuGet和SQLite网络下载失败分别通过校验插件／包内声明的SHA-256后复用已有缓存解决。

## 仍未闭合

- **G2安装验收**：新包仍需在隔离GitHub runner执行 `scripts/smoke_windows_installer.ps1` 的安装／升级／卸载及旧文件保持。该脚本明确拒绝本地执行，本轮没有伪造CI环境绕过限制，也没有运行会改写当前账户快捷方式／协议注册的安装器。
- **CI实际运行**：本轮未推送，不存在可报告的新run ID；硬门禁为配置完成，不能记为云端通过。
- **G1／R1**：Android深链未接线、窗口偏好与草稿共存的存储设计后续处理；本轮未引入schema迁移。
- **原生矩阵**：Toast按钮真实点击、托盘三语、真实ADTS录音，以及当前源码的macOS／iOS通知与设备验收仍开放。没有操作手机、用户数据库或真实模型凭据。

因此，本轮完成候选缺陷的源码收口与本机回归，不宣布稳定版发布就绪。
