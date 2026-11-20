# DontForget v1.8.18 · Android / Windows / Linux / iOS

面向可用性、易用性与视觉一致、稳定性与性能以及全局架构收敛的综合稳定版本（涵盖 `v1.8.15`–`v1.8.18` 四轮迭代及跨设备附件分享／局域网同步升级）。build89／schema17。

## 主要更新

### 功能可用性与跨设备工作流
- **图片与文件分享采集**：Android 系统分享支持接收图片与文件（`image/*` / `application/*`，私有暂存边界 `shared_handoff/<id>/`、单文件 32 MiB 与 16 条队列上限），分享收件箱展示有界图片缩略图并在确认页支持图文保存为备忘，全程保留首页输入草稿。
- **局域网同步全面增强**：支持跨设备双向同步 `MediaRecords` 与附件原件（SHA‑256 校验、事务回滚清理暂存、未绑定既有媒体不重绑）；局域网服务端优先选取物理网卡 IP（避开 WSL／Docker／Hyper‑V／VPN 虚拟网卡）；客户端细分失败码与本地化提示，超大请求体未读拒收直接断开防止挂起；提供地址与配对码一键复制、PIN 回车直连，并支持跨设备回收站移入／恢复差异确认采用。
- **事项操作与附件体验**：事项卡片新增「调整分类（Q1–Q4）」与快捷「延后提醒（+15分钟／+1小时／今晚／明早）」；只读事项详情支持一键复制正文与清单；文件附件预览升级为异步 128 KiB 有界 UTF‑8 预览（NUL 安全、CJK 截断安全、一键复制）并展示异步文件体积；加密备份／恢复补齐密码显隐切换；首页补全「移动通勤」情境、`U`/`,` 快捷键、`PopScope` 优先关闭搜索、跨平台视频打开、音频停止及待处理分享草稿提示条。

### 易用性与视觉统一
- 完善 `AppTheme` 的 Material 3 组件令牌（弹窗、菜单、Chip、SnackBar），消除明暗主题下的硬编码低对比度色值，统一 WCAG AA 对比度。
- 优化事项卡片视觉层次（优先级竖条色带、桌面悬停边框、逾期／置顶强调与语义描边徽标）、四象限计数胶囊与空态引导、局域网冲突双色对比卡片与字段摘要、统计页四象限语义配色条。

### 稳定性与性能
- 修复 `RetainedMediaReferences` 扫描目录偏差（改扫受控数据库目录），确保附件清理可靠保护镜像库、快照与恢复备份引用。
- 修复 `DatabaseMaintenanceLease` 历史版本检查范围（动态覆盖 `7..schemaVersion`，兼容 v15／v16 中断恢复）。
- 修复录音停止异常时的未完成 PCM 句柄泄漏与状态锁死，显式取消实时转写不再误存音频备忘；增强错过提醒批量确认容错、`WindowsToast` 按码点截断与桌面 `error_log.txt` 1 MiB 轮转。
- 新增 `O(1)` 提醒与媒体索引提供器，为看板与工作区概览加入投影记忆化并完善定时／恢复缓存失效；首页轮询按需门控 Wi‑Fi `netsh` 探测；局域网同步合并改为单次预加载并设置并发上限（8 路）。

### 全局收敛与多语言一致
- 清理未引用死代码，抽取共享体积格式化工具 `formatByteSize`，收口附件清理逻辑。
- `AppLocalizations` 缺失键跨主表及合并子表统一回退英文，补齐中／英／日三语对称词条，`StorageUnavailableScreen` 升级为三语与明暗双主题；CLI 版本对齐 `v1.8.18` 并优化过滤与截断安全；同步更新架构设计与变更日志。
- 不更改数据库 schema17、依赖锁文件或既有模型／语音凭据存储格式。

## 下载与安装

- Windows x64：`DontForget_Setup_v1.8.18.exe` 安装版或 `DontForget_Windows_Portable_v1.8.18.zip` 便携包，未做 Authenticode 签名。
- Linux x64：`DontForget_Linux_v1.8.18.tar.gz`，Ubuntu 24.04 基线。
- Android：固定发行证书签名的通用 APK（`DontForget_Android_v1.8.18.apk`）、ARM64 APK（`DontForget_Android_arm64_v1.8.18.apk`）及 AAB（`DontForget_Android_v1.8.18.aab`）。
- iOS：`DontForget_iOS_unsigned_v1.8.18.ipa` 为未签名 IPA，需要通过 AltStore 个人重签；免费账号通常每 7天 续期。安装方式见[说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)，不属于 App Store 或 TestFlight 分发。

## 验收范围与限制

源码、自动化测试、安装包与真实设备验收分别记录，详见[后续阶段与验收台账](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)：
- **自动化**：固定 Flutter `3.44.9` 下静态分析 0 问题，Windows 全量测试 2,686 通过／20 项文档化 Windows 跳过／0 失败，Python 脚本测试 180 通过；并经本版主线 CI Linux／Windows 双端质量与五平台构建校验。
- **Windows 本机运行中升级**：本机已完成 `v1.8.14+85`→`v1.8.15+86`→`v1.8.16+87`→`v1.8.17+88`→`v1.8.18+89` 连续四轮运行中最新保全覆盖升级、39 载荷逐字节核对、全业务字段与 DPAPI 凭据及普通重开保持；发版前并对最终 CI 安装包补齐运行中覆盖升级验收。
- **Android 实机（Pixel 8 Pro）**：隔离 QA 包已完成同签名保全升级、微信输入法真实中文拼音组合与草稿保护、大字号（`1.3x`）密度零溢出、提前 10 分钟提醒后台送达＋通知栏「15分钟后」延后＋15 分钟二次送达闭环、有真实附件时的内容管理清理，以及与 Windows 隔离对端在同一真实 Wi‑Fi 子网直连（零 USB 转发）双向附件同步与跨设备回收站移入／恢复验收。
- **未验／限制范围**：Windows 原生 GUI／托盘／Toast 交互（非交互会话 UIA 受限）、iPhone 真机安装与运行（本机无连接 iPhone 且无 macOS／Xcode，不自动处理 Apple 认证）、build84 历史语音重复根因与读屏、Windows 历史 LocalAppData 目录人工接管、系统分享面板手选文档未在本轮真机完成，不记为全部原生矩阵通过。
