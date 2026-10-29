# iOS 真机验收 Runbook（iPhone 15 Pro Max）

> 本文件给出 iOS 真机验收的可执行步骤。**iOS 构建与安装只能在 macOS + Xcode 上完成**；当前开发机为 Windows，Flutter 无法把应用安装到已连接的 iPhone，因此本文是"待 Mac 可用时一次跑完"的清单，不代表已执行。
>
> 数据与证据口径沿用[发布验收总表](Release_Acceptance_v1.7.md)、[发布策略](Release_Policy.md)与[手动续行检查点](Task_Resume_Checkpoint.md)。

## 1. 前置条件

| 项 | 要求 |
| --- | --- |
| 工具链 | macOS + Xcode（含 iPhoneOS SDK）、CocoaPods、`xcrun devicectl` |
| Flutter | **3.44.9 / Dart 3.12.2**（仓库 lockfile 固定；勿用其他版本出验收包） |
| 设备 | iPhone 15 Pro Max，iOS 15+，已信任开发证书 |
| 签名 | 两份 Apple Development profile：Runner 与 `ReminderActivity.appex`，需匹配 bundle id、团队与设备 UDID，且未过期 |
| 身份 | 独立验收身份 `com.yarnway.dontforget.acceptance.<run-id>`，扩展为 `<host>.ReminderActivity`；**不得覆盖 `iphone17` 等含真实数据的身份** |
| 可追溯 | 从**干净 commit** 导出（`git archive`），不把脏工作区构建当作可追溯产物 |

## 2. 构建与安装

```bash
# 1) 只读预检：设备可见、签名条件
python3 scripts/check_ios_device.py            # 退出码 0 仅表示 REQUIRES_SIGNED_INSTALL

# 2) 从固定提交导出干净副本
git archive <commit> | tar -x -C <clean-dir>

# 3) 在副本中改写验收身份（主应用 + 扩展 + URL scheme/显示名）
#    ios/Runner.xcodeproj/project.pbxproj 的 PRODUCT_BUNDLE_IDENTIFIER
#    ios/Runner/Info.plist 的显示名，URL scheme 现为 dontforget-live

# 4) 依赖与回归
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
python3 -m unittest discover -s scripts/tests

# 5) 归档与导出（development）
xcodebuild archive -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -archivePath build/ios/Runner.xcarchive \
  -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/ios/Runner.xcarchive \
  -exportPath build/ios/export -exportOptionsPlist <ExportOptions.plist>

# 6) 包校验与安装
python3 scripts/package_artifacts.py --platform ios ...
codesign --verify --deep --strict --verbose=2 <Runner.app>
xcrun devicectl device install app --device <UDID> <Runner.app>
xcrun devicectl device process launch --device <UDID> <bundle-id>
```

CI 复用：`gh run download <run-id> -n ios-deliverables`，用 `scripts/verify_artifacts.py` 核对源码身份与摘要；CI 产物未签名，须同 commit 本地重签，并核验非签名字节与资源未变。构建通过不等于真机通过。

## 3. 真机验收清单（逐项勾选，附证据形式）

| # | 项目 | 判定标准 | 证据 |
| --- | --- | --- | --- |
| 1 | 安装与首启 | 独立身份安装成功，首启进入空工作台 | 截图 + `devicectl` 元数据 |
| 2 | 同身份升级 | 安装前后 Documents 逐字节一致，schema 16、integrity ok | 前后快照摘要 |
| 3 | 通知热点击 | 应用在前台时点击通知，打开对应事项 | 截图 + 系统日志 `Received response` |
| 4 | 通知冷点击 | 终止进程后点击通知，新进程打开对应事项 | 进程/PID + 截图 |
| 5 | 动作菜单 | 周期 4 项（完成本次/15 分钟/1 小时/跳过本次）、非周期 3 项 | 截图（中英日各一次） |
| 6 | 三语菜单 | 切换语言后类别重新注册，菜单标题随语言变化 | 截图 + 系统日志 |
| 7 | 前后台与终止态消费 | 三种运行态各触发一次动作，业务结果正确 | 数据库读回 |
| 8 | 延后语义 | snooze15/60 目标时刻与 eventTime、周期锚点保持 | 数据库读回 |
| 9 | 周期与跳过 | 完成后推进下一本地日；跳过不完成且推进 | 数据库读回 |
| 10 | 重开补排去重 | 重开只补缺失项，重复重开不变 | 队列 + DB 行数 |
| 11 | 跨日与容量 | 共用预算 50 内补排，跨日不重复送达 | 系统待发/保留读回 |
| 12 | 自检面板 | 权限、待安排数、待修复、journal 近期失败显示可读 | 截图 |
| 13 | 灵动岛同步 | 编辑/暂停/删除后活动更新；不支持设备正常回退 | 截图 |
| 14 | 日文软键盘 | 组词、横向/窄屏避让、提交 | 屏幕录像/截图 |
| 15 | 真实录音手势 | 长按录音、上滑左取消、上滑右转文字并编辑、直接发送；听感正常 | 本机操作 + 截图 |
| 16 | 附件闭环 | 选图、预览、保存重开、移除撤销 | 截图 + Documents 读回 |
| 17 | 便携备份 | 导出（可选密码）→ 恢复预检 → 恢复后重开 | 包摘要 + 数据库读回 |
| 18 | 清理与保护 | 仅软删除自建合成数据，OS 待发/保留回读归零 | 系统读回 + DB 读回 |

## 4. 数据保护规则（硬约束）

- 验收前只读复制 `Documents` 与 `Library/Preferences`，并用 `sqlite3 mode=ro .backup` 取库快照；**不整目录复制 Library**，不得称"完整备份"。
- 禁止整库覆盖、卸载重装、`cancelAll()`、用空基线擦除；恢复只走产品备份检查页或 `RecoveryCoordinator`（会轮换 epoch）。
- 合成数据统一以 `QA ...` 前缀命名，只通过产品入口软删除，并独立读回该 ID 的系统取消。
- 材料放私有目录（`build/native_acceptance/<run-id>/`），不入库、不提交用户数据/凭据/设备画面。

## 5. 必须人手的项目

麦克风采集与听感、软键盘日文组词与横屏、系统通知中心与动作菜单的真实点击、灵动岛系统展示、连续触摸手势、系统权限/专注模式/辅助触控、自然跨日与真实 DST。镜像硬件键盘、AX `setValue`、CI 冒烟都不能替代。

## 6. 已知坑（历史结论，勿重复踩）

- 镜像硬件键盘 ≠ 软键盘通过；`AX setValue` 只改无障碍缓存（曾出现 `typeText` 乱序、`paste` 未替换）。
- iOS→Mac 转发日志 ≠ 手机送达；"已提交系统" ≠ 送达；横幅出现 ≠ 点击通过。
- 同 bundle id 不同 cdhash 视为不同通知来源；`+37` 两条历史留存通知曾自行消失，原因未定，勿把"保留 2 条"当预期。
- 未保存草稿不排通知；系统按整秒投递，数据库按微秒记录。
- 中文全角「：」曾被 `HH:mm` 拒绝（`c2ebdca` 已归一化）。
- 手机通知权限未开启时，容量与送达项全部无效，必须先读回"允许"。

## 7. 与 Windows 的分工

Windows 侧可验证：构建、UI、快速录入、应用内到期、Windows Toast、托盘、录音、文件对话框、本地数据与备份。iOS 侧必须在 Mac 上验证：签名安装、系统通知与动作、灵动岛、软键盘、麦克风、跨日与 DST。两侧结论分别记录，不互相替代。
