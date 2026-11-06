# 发布与验证策略

2026-11-06最新三端发行版为[v1.7.2](https://github.com/yarnway/dontforget/releases/tag/v1.7.2)，build61／schema17、固定源码8514c86；源码CI42153031005与发布工作流42156389816成功，16附件及标签／正文／摘要独立读回通过。+61未本机覆盖安装，原生UI与其余阶段仍待验；[分层发行记录](Platform_Release_61_2026-11-06.md)。下列历史记录保留各自归属。

2026-11-06前轮续行：[v1.7.1](https://github.com/yarnway/dontforget/releases/tag/v1.7.1)已发布，build60／schema17、固定源码559ab5a、16附件，发布门禁和独立读回均通过；详见[发行记录](Platform_Release_60_2026-11-06.md)。旧v1.7.0及历史记录保留。

更新：2026-11-05，按用户最新要求执行。

用户本轮明确：完成Android、Windows、Linux新版后可发布GitHub Release。本轮[v1.7.0](https://github.com/yarnway/dontforget/releases/tag/v1.7.0)已发布，build59、源码71602c8，16附件已读回；发布工具初次错误与本地修正复验见[发行记录](Platform_Release_59_2026-11-05.md)。此指令替代此前等待macOS／iOS再发布的范围限制；旧验收结果与后续任务保留。

- main、手动运行与现有标签继续执行质量检查、五平台构建和产物校验。验证包保留在 GitHub Actions artifacts；不自动创建或发布 RC，也不自动创建 GitHub Release 草稿。
- 主线构建工作流保持 `contents: read`。新增仅手动触发的三平台发布工作流，校验阶段为只读，实际发布阶段单独授予 `contents: write`。现有历史RC标签、草稿及验收证据保留，不修改旧草稿。
- 以固定源码、版本、清单和摘要识别验证包；发布页面、CI 通过和真机通过分别记录。
- 本轮Android／Windows／Linux独立发布：固定通过CI的源码和版本，核对五包、三平台清单及隔离验收报告；Android须采用固定发行证书，APK／AAB均验证。发布后读回标签指向、正文、附件完整集合、大小及摘要。macOS／iOS另行完成验收后再纳入后续发布。
- 源码、自动化、安装包与真实设备结果分别记录；真实腾讯云、输入法、通知、跨设备恢复及Apple设备矩阵等未验收项目在发行说明明确列为限制或后续，不标记全部通过。Windows未做Authenticode签名，Android商店分发仍单列，不宣称已上架。

2026-10-28历史：`1.7.0+37` / `dfb34f1` 已完成七项 CI；最初草稿在发布前已从远端消失，公开发布未完成。用户调整策略后，停止重建该草稿；仅从对应 CI 恢复并核验产物，没有重新上传或创建 Release。未改变旧的无标签草稿。

策略变更 `caa488d` 的[主线 CI](https://github.com/yarnway/dontforget/actions/runs/40614747575) 已通过质量检查与五平台构建，共六项成功；标签专用校验按 main 分支条件跳过。五份内部 artifact 已保留，工作流没有创建 Release。正式版仍需完成验收总表中的剩余项目。

参见[发布验收总表](Release_Acceptance_v1.7.md)及[本轮证据](benchmarks/build37-and-native36-2026-10-28.json)。

2026-10-28 后续主线使用内部 **1.7.0+38** 区分已合入的离线管理与搜索／语音圆弧源码。固定 `dfb34f1` 的手机 +37 已升级及完成 QA39 到期／取消读回；普通通知点击等门槛仍开放，历史留存差异单独追踪。没有新增 RC 标签或 Release；详见[阶段三十四证据](benchmarks/iphone37-native-upgrade-2026-10-28.json)。

内部 +38 的[主线 CI 40622083457](https://github.com/yarnway/dontforget/actions/runs/40622083457) 已通过质量与五平台构建，五份 artifact 的源码身份和摘要字段已核对。Release 列表仍只读到原有未命名草稿，本轮没有新增 RC、标签或正式发布。
