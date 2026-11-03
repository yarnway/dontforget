# Gemini 实施验收报告（2026-10-29）

后续处理（2026-11-02）：本报告保留原始验收结论；D1、D5／G2与CI门禁的修复结果及剩余边界见[阶段46验收](Stage46_Validation_2026-11-02.md)，后续任务见[阶段46—50清单](Next_Steps_2026-11-02.md)。

验收范围：`d476744..d091b4e`（12 个提交，对应提示词 P1–P13）。
验收方式：逐提交 diff 审查 + 全量测试/静态分析 + Python 工具链测试 + Windows Release 运行时验收（截图/数据库读回）。
验收环境：Windows 11、Flutter 3.47.2（本地）/ 3.44.9（CI 固定）、VS 2022 Build Tools、`flutter build windows --release` 产物。

## 总评：**有条件通过**

7 项合格、3 项部分合格、2 项受阻于环境（无 macOS / 无 Android SDK）。发现 **2 个必须修复的问题**（同一事项重复提醒、版本号未 bump 导致安装包滞后）和 **3 个建议修复项**。详见下文第 4 节。

| 指标 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | **0 issues** |
| `flutter test --no-pub` | **2103 passed / 20 skipped / 0 failed**（3 分 36 秒） |
| `python -m unittest discover -s scripts/tests` | **132 passed / 6 skipped** |
| Release 构建 | 通过（36.4s） |
| 迁移/窗口/协议运行时检查 | 通过（见证据） |

## 1 逐项结论

| 任务 | 结论 | 关键证据 | 备注 |
| --- | --- | --- | --- |
| P1 启动聚合"错过的提醒" | ✅ 通过（含缺陷 D1） | `gemini-start.png`：3 条逾期中计数 **2**（3 天前正确排除）；点“全部知道了”后横幅与筛选页签消失，DB 写入 `notice_acknowledged_at`；重启不再出现（`gemini-after-ack.png`、`gemini-restart.png`） | 72h 边界、未确认过滤、三语 key 均正确 |
| P2 窗口位置/尺寸/最大化持久化 | ✅ 通过（含风险 R1） | 用户态拖拽后 `Settings.workspace_drafts_json` 写入 `{"windowPreferences":{...}}`；重启窗口恢复为 `(268,194,1268,758)` | 仅真实用户拖动触发；用 `SetWindowPos` 外部改窗不会触发保存（可接受） |
| P3 录音 ADTS/MP4 与 250 ms 保护 | ✅ 通过（单元级） | 代码：Windows 映射 `.aac`、其他平台 `.m4a`；`RecordingDurationReader` 支持 ADTS 帧头；`home_controller` 两处按 `minimumCapture` 拒绝过短录音 | 本轮未复测真实麦克风采集（上一轮已验证可录制 m4a） |
| P4 Toast 协议激活与动作 | ✅ 通过（协议路径），⚠️ 按钮点击未取证 | 应用运行中打开 `dontforget://task/qa-missed-10m` → 详情页（`protocol-running.png`）；应用未运行同样冷启动打开详情（`protocol-coldstart.png`）；**点击 Toast 正文** → 打开对应详情（`p4-after-toast-click.png`）；`dontforget://action/complete?id=...` → DB `is_completed=1`、`notice_revision 0→1` | Toast 的 “Complete” 按钮真实点击未命中（Toast 约 5 秒后消失，自动化时序问题），以同一 URI 走协议验证了动作链路 |
| P5 i18n 硬编码清理 | ✅ 通过（静态） | 托盘菜单改用 `AppLocalizations(settings.language)`；`trayShowWindow/trayExitApp` 中英日三语齐全 | 未打开真实托盘菜单做视觉核对 |
| P6 CI Windows 测试作业 | ✅ 通过（配置） | `quality-windows`（windows-2022）：版本校验 → `--enforce-lockfile` → analyze → 全量 test → skip 清单校验 → python 测试 | 作业为 `continue-on-error: true`（软门禁）；本轮未实际运行 CI |
| P7 生产身份与数据库迁移 | ✅ 通过（运行时） | 启动后自动从 `%LOCALAPPDATA%\DontForget\databases` 迁移到 `%APPDATA%\com.yarnway.dontforget\DontForget\databases`，`migration.log` 记录，3 条数据完整 | 迁移源为上一轮遗留的候选目录，真实升级路径已被实际执行 |
| P8 文档同步 | ✅ 通过（含缺陷 D5） | CHANGELOG 新增 `1.7.0+45` 段落，数字（2103/20）与实测一致；README/架构/发布表已更新 | **pubspec 仍是 `1.7.0+44`**，版本号未 bump |
| P9/P10 iOS 工具与 Runbook | ⚠️ 部分通过 | `scripts/prepare_ios_acceptance.py --help` 可用；`test_ios_acceptance.py` 等 132 项 Python 测试通过；iOS `Info.plist` 同时含 `dontforget` 与 `dontforget-live` | 无 macOS，真机构建/安装/18 项清单未执行 |
| P13 Android 身份与深链 | ⚠️ 部分通过（静态） | `applicationId/namespace = com.yarnway.dontforget`、`MainActivity` 包路径一致、Manifest 声明 `dontforget`/`dontforget-live` | 无 Android SDK 未构建；新增 `dontforget` scheme 在 Dart 侧无处理入口（G1） |

## 2 运行时验收证据（本机 Release 包）

| 场景 | 结果 | 文件 |
| --- | --- | --- |
| 启动 + 错过提醒聚合 | 计数 2、3 天前排除 | `build/native_acceptance/windows-2026-10-29/gemini-start.png` |
| 全部已读 + 持久化 | 横幅/页签消失、重启不复现 | `gemini-after-ack.png`、`gemini-restart.png` |
| 窗口状态持久化 | 拖拽后重启恢复原文尺寸 | 终端记录 `rect-after-restart 268 194 1268 758` |
| 协议热激活 | 打开事项详情 | `protocol-running.png` |
| 协议冷激活 | 冷启动并打开详情 | `protocol-coldstart.png` |
| Toast 正文点击 | 打开对应事项详情 | `p4-after-toast-click.png` |
| 完成动作（协议） | `is_completed=1`、revision+1 | 终端 DB 读回 |
| 数据库迁移 | 旧目录 → 新目录，数据完整 | `%APPDATA%\com.yarnway.dontforget\DontForget\databases\migration.log` |

## 3 缺陷与风险

### 必须修复

**D1 同一事项重复提醒（P1）**：即将到期或刚到期（15 分钟内）的事项会同时出现在“提醒时间已到”横幅与“错过的提醒 · N”计数里。实测 20:21 时 `QA P4 Toast 点击验收` 同时在两处计数（`p4-toast-frame2.png`）。
原因：`selectMissedReminders` 只按“逾期 ≤72h 且未确认”判断，未排除当前会话已作为 due 提醒展示的 occurrence。
建议：`isMissed` 排除 `_dueNotices.containsKey(key)` 与 15 分钟内到期项，或让 missed 只统计“启动前已逾期”的集合（与 `_checkDueReminders` 的 `_launchTime` 口径一致）。

**D5 版本号未 bump（P8）**：CHANGELOG 写 `1.7.0+45`，`pubspec.yaml` 仍为 `1.7.0+44`，而 `dist/` 的安装包/便携包时间戳为 11:07（早于 P1–P13 的 18:xx 改动）。
建议：`pubspec.yaml` 升到 `1.7.0+45`，重新 `scripts/package_windows.ps1` 生成安装包/便携包，并对当前源码重跑静默安装/升级/卸载验收，替换 `dist/` 旧产物。

### 建议修复

**R1 P2 复用 drafts JSON（设计风险）**：窗口状态塞在 `Settings.workspace_drafts_json`，与草稿共用一行。当前 `workspace_drafts_provider` 采用“读取-合并-写回”，实测两者共存无覆盖；但 drafts state 会包含 `windowPreferences` 这个非草稿 key，后续若有人按 key 遍历渲染草稿可能出问题。建议后续加独立 `desktop_window_json` 列（需 schema 迁移）或本地文件。

**G1 Android 深链未接线**：`AndroidManifest.xml` 声明了 `dontforget` scheme，但 Dart 侧只有 Windows 的协议通道处理，Android 收到该 URI 会停在首页。建议接入 `app_links` 并复用 `ProtocolRoute.tryParse`，或先移除该 scheme 避免“声明了但无效”。

**G2 安装包滞后于源码**：见 D5，`dist/` 产物对应 `ce79a5f`，不含 P1–P13；W4 的安装验收结论不能直接沿用。

### 其他

- P6 的 `quality-windows` 目前 `continue-on-error: true`，等价软门禁；本地全量已绿，建议改为硬门禁（去掉该行）。
- `check_flutter_version.py` 在 3.47.2 下仅告警不失败（设计如此），CI 若要强约束需改 `--strict` 类行为。
- 文档口径：`docs/Windows_Acceptance_2026-10-29.md` 的 W2/W3 状态尚未随 P1–P13 更新（仍写“W3 待做”），建议在验收通过后统一补一次状态表。

## 4 环境清理

- 验收期间为验证 P4 临时插入 1 条 synthetic 提醒（`qa-p4-toast`），已删除；
- 验收时通过产品“全部知道了”写入的 `notice_acknowledged_at` 与完成动作写入的 `is_completed` 已复位，3 条 `qa-missed-*` 测试夹具恢复原状态；
- 未修改仓库中的任何产品代码；本轮只新增本报告。
- 设备/进程：验收用 Release 实例已停止，未改动任何真实用户数据。

## 5 结论与下一步

可以接受 Gemini 的这批实现作为**阶段性成果**：核心链路（迁移、协议激活、Toast 点击、错过聚合、窗口持久化）均在本机真实运行通过，测试与静态分析健康。

但**不能整体判为"完成"**，需先关闭 D1（重复提醒）与 D5/G2（版本与安装包），再补 G1（Android 深链）与 R1（drafts 共用行）。P9 iOS 仍必须回到 macOS 上按 [Runbook](iOS_Device_Acceptance_Runbook.md) 执行 18 项真机清单。
