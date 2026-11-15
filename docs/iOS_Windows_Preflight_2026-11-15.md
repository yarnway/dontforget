# Windows连接iPhone：开发预检与独立候选

用户指定iPhone15ProMax为iOS目标设备，并确认目前只有Windows、免费Apple开发者账号。仓库已有Flutter iOS客户端；本轮继续推进原生前置条件与候选包，不新建另一套客户端。

## 已完成

`check_ios_device.py`新增Windows原生Python支持，连接本机Apple USB服务，只发`ListDevices`、`Connect`和3项`GetValue`。读回`iPhone16,2`／iOS27.2.1／24B156；Windows设备状态正常。不请求配对记录、序列号、设备名、账号或业务数据，也不修改信任、开发者模式或安装应用。报告排除这些私有字段，已有输出不覆盖。

报告分开描述设备与Xcode开发条件：Windows不执行macOS工具命令，保持`MACOS_BUILD_HOST_REQUIRED`／`BLOCKED`；配对、开发者模式与匹配描述文件均未验证，运行验收为`NOT_PERFORMED`。这里的安装门槛针对Xcode原生开发路径，不是对所有Windows第三方重签工具的可用性认证。

新增5项边界回归；最终Linux原生Python175运行／4跳过、Windows原生Python175运行／6跳过。Windows缺少AF_UNIX常量的首轮模拟测试已修正为显式模拟Mac地址族；Windows实际路径不依赖该常量。Linux全量中Flutter版本查询通过显式Windows命令包装读取原SDK，不使用Windows SDK内的Linux入口。

全量脚本首次误触共享SDK的Linux入口，造成Dart缓存平台替换，失败日志与Linux缓存已保全。随后从保留的Windows目录恢复，1040文件摘要前后相同；原生读回Flutter3.47.2／Dart3.13.2，未升级SDK、修改项目依赖或锁文件。恢复后的双平台全量175项结果与iPhone只读预检分别记录，不用前一失败轮次冒充通过。

## 编译、签名与安装分别记录

应用运行时代码仍为72a7080／lib树0b85d48；[固定SDK CI](https://github.com/yarnway/dontforget/actions/runs/43669528199)七项成功，其中iOS为未签名IPA。其11,314,521字节IPA已下载，artifact SHA／CRC、源码清单、IPA摘要、主应用及ReminderActivity扩展版本／身份均核对，最低iOS15，未嵌入描述文件。原始身份`com.yarnway.dontforget`，不直接作为覆盖手机既有应用的依据。

增加手动工作流`ios_device_candidate.yml`：仅接受完整源码SHA及独立run-id，先要求该源码固定SDK CI成功，再在云端Mac中使用既有准备脚本改写主应用／扩展身份，固定Flutter3.44.9构建。校验实际IPA内身份、版本、CRC及无描述文件，输出准备文件摘要与独立回执。只读GitHub权限、不使用Apple凭据、不发布Release。独立候选构建／下载结果继续补充；不等同于签名安装或真机运行。

## 免费账号与后续安装

[Apple官方说明](https://developer.apple.com/help/account/basics/about-your-developer-account)允许免费Personal Team在个人设备测试，但描述文件7天到期，另有设备／App ID／应用数量限制；当前免费账号不能据此当作已具备TestFlight分发条件。

[AltServer官方说明](https://github.com/altstoreio/FAQ/blob/main/release-notes/altserver.md)提供Windows直接侧载IPA的入口，需本机账号认证并定期重签；官方安装说明见[Windows指南](https://github.com/altstoreio/FAQ/blob/main/altstore-world/how-to-install-altstore-windows.md)。本轮未安装第三方签名软件、未登录Apple账号，也未验证其在iOS27.2.1上的兼容性。不会把Apple密码、验证码或签名私钥写入聊天、日志、仓库或CI。

接下来核对独立IPA与本机侧载工具／手机已有身份，用户在本机完成账号登录和授权后，才能尝试签名及独立安装。先做首启、正常重开、基础输入／附件／备份，再做通知热冷点击、录音与灵动岛；数据保全与未知现有身份保护沿用[Runbook](iOS_Device_Acceptance_Runbook.md)。现阶段没有iPhone安装、升级或运行通过证据。
