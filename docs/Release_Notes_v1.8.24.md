# DontForget v1.8.24 · Android / Windows / Linux / iOS

## 本版更新

- Windows 搜索框、即将提醒、搜索结果和底部录入区沿同一内容宽度对齐。搜索返回和清除按钮随搜索框缩放。
- Windows 中文输入法仍在选择候选时，快速录入暂缓发送。候选确认后可用回车保存。
- Windows 全局快捷记录设置写入失败后，「重试」继续执行原先的开启或关闭操作。应用启动读取设置失败时可重新读取。
- 模型密钥输入框在支持的平台上停用输入法个性化学习。DeepSeek 继续提供服务地址和模型预设，云服务凭据由用户在应用设置中管理。
- Android 和 iOS 的语音编辑框只显示编辑区、「发送原语音」和「发送」，去掉外层背景卡片。删除全部文字即可退出。编辑框带有读屏名称及识别未完成时的读屏提示。

## 下载与安装

- Windows x64 提供安装器与便携 ZIP。安装器未做 Authenticode 签名。
- Linux x64 提供 TAR.GZ 文件，构建基线为 Ubuntu 24.04。
- Android 提供 ARM64 APK、通用 APK 和 AAB，沿用固定发行证书。
- iOS 提供未签名 IPA，需要用 AltStore 个人重签。免费账户通常每 7天 续期。安装步骤见 [Windows 上的 iOS 安装说明](https://github.com/yarnway/dontforget/blob/main/docs/iOS_Sideload_Windows.md)。App Store 和 TestFlight 分发不在本版范围内。

## 验证记录

- build 97 在固定 Flutter 3.44.9 下通过全量回归。build 98 语音编辑、布局和无障碍定向回归 96 项通过。
- build 97 的 GitHub Windows 安装包已完成运行中覆盖、普通重开、安装文件、业务数据和 DPAPI 凭据核对。Pixel 8 Pro 已完成同签名覆盖，任务、附件、设置和云服务配置通过核对。
- build 98 的 Windows 本地候选安装包已通过运行中覆盖和数据核对。Pixel 隔离测试包已验证语音编辑布局和控件。各制品的实际验收范围见 [后续阶段与任务](https://github.com/yarnway/dontforget/blob/main/docs/Next_Steps_2026-11-02.md)。
- build 99 的清空退出流程通过 Windows 全量回归。去掉外层背景卡片后的定向测试 99 项通过，Pixel 隔离包实测原生键盘删空即关闭。
