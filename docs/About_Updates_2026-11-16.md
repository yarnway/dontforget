# 设置中的关于信息与更新检查

本轮按用户追加要求，将设置的第六个入口设为“关于与更新”。当前为v1.8.11+81源码候选，尚未发布；此前build80的Windows与iPhone安装验收保持原归属，不能替代本轮新增功能验收。

## 行为

- 显示系统实际安装的应用名、版本与构建号，支持复制版本信息、打开项目主页与第三方许可。版本读取失败可重试，不伪造版本号。
- 仅在用户点击后查询本项目的GitHub公开发行版，比较三段数字版本；相同版本通过来源文件核对构建号。无法核对构建号时明确显示未核对，不冒称最新。
- 显示更新说明与对应平台下载入口。Windows区分安装器／便携版，Android区分通用／ARM64 APK，Linux为归档，iOS为需个人重签的未签名IPA。未提供当前平台包时仍可打开发布页，不提供自动覆盖安装。
- 网络失败、超时、无公开版本、限流或元数据异常均可重试。匿名GitHub API实际返回403／剩余额度0；项目公开`releases/latest/download/release-provenance.json`仍返回200，新增此官方入口的备用路径，并核对版本、构建、源码格式与文件清单。备用路径的完整更新说明在发布页查看。
- 更新请求独立使用不带账号认证的HTTP客户端，不读取模型、腾讯语音或安全存储配置；不向更新服务发送事项或设置内容。页面关闭后忽略晚到结果，保留设置页未保存偏好，不写业务表。

## 依赖与验证

`package_info_plus 10.2.2`由既有间接依赖提升为直接依赖，新增固定`url_launcher 6.3.3`及其平台实现；其余已锁定版本保持。未变更schema17。版本读取与外部浏览器能力采用插件的官方平台实现，依据[package_info_plus](https://pub.dev/packages/package_info_plus)、[url_launcher](https://pub.dev/packages/url_launcher)及[GitHub最新附件链接规范](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)。

从原SDK已有tag建立隔离Flutter3.44.9副本，源码提交`6b182d2c7585eba26d4edce0f97630effd256c33`与GitHub官方tag核对，Dart3.12.2；通过Windows原生`.bat`引导与解析依赖，不调用WSL的LinuxFlutter入口，不切换原SDK。原3.47.2 SDK保持原位置。新依赖与CI基线一致解析，未用SDK漂移修改既有锁定版本。

本机原生固定SDK新增服务／页面20项通过，设置相关五文件45项通过，覆盖手动触发、构建比较、无凭据的公开请求、异常／限流备用路径、缺包、复制链接、关闭晚回调、未保存偏好、三语／明暗／大字窄屏与桌面。首轮测试夹具的全局平台清理、滚动等待及中文返回按钮定位失败分别留证，修正夹具后通过；未把前轮失败冒记成通过。真实无认证联网读取公开v1.8.10成功，正确识别当前候选高于公开版。[本机回执](benchmarks/about-updates-source-2026-11-16.json)。

Linux／Windows Python各180运行、4／6跳过且均成功；全库分析0问题；固定CI、最终包与各端真实验收另记。Android设备暂不可用，不能将CI包构建或原功能历史Pixel结果写成+81真机升级通过。Windows必须再做最新保全与运行中80→81覆盖；iPhone也须先保全再同身份覆盖，核对关于页和检查更新。
