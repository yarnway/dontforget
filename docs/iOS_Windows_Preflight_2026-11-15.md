# Windows连接iPhone：开发预检与独立候选

用户指定iPhone15ProMax为iOS目标设备，并确认目前只有Windows、免费Apple开发者账号。仓库已有Flutter iOS客户端；本轮继续推进原生前置条件与候选包，不新建另一套客户端。

## 已完成

`check_ios_device.py`新增Windows原生Python支持，连接本机Apple USB服务，只发`ListDevices`、`Connect`和3项`GetValue`。读回`iPhone16,2`／iOS27.2.1／24B156；Windows设备状态正常。不请求配对记录、序列号、设备名、账号或业务数据，也不修改信任、开发者模式或安装应用。报告排除这些私有字段，已有输出不覆盖。

报告分开描述设备与Xcode开发条件：Windows不执行macOS工具命令，保持`MACOS_BUILD_HOST_REQUIRED`／`BLOCKED`；配对、开发者模式与匹配描述文件均未验证，运行验收为`NOT_PERFORMED`。这里的安装门槛针对Xcode原生开发路径，不是对所有Windows第三方重签工具的可用性认证。

新增5项边界回归；最终Linux原生Python175运行／4跳过、Windows原生Python175运行／6跳过。Windows缺少AF_UNIX常量的首轮模拟测试已修正为显式模拟Mac地址族；Windows实际路径不依赖该常量。Linux全量中Flutter版本查询通过显式Windows命令包装读取原SDK，不使用Windows SDK内的Linux入口。

全量脚本首次误触共享SDK的Linux入口，造成Dart缓存平台替换，失败日志与Linux缓存已保全。随后从保留的Windows目录恢复，1040文件摘要前后相同；原生读回Flutter3.47.2／Dart3.13.2，未升级SDK、修改项目依赖或锁文件。恢复后的双平台全量175项结果与iPhone只读预检分别记录，不用前一失败轮次冒充通过。

本轮工具／工作流源码50d32b1的[最终固定SDK CI43673926065](https://github.com/yarnway/dontforget/actions/runs/43673926065)七项成功：Linux Flutter2609通过／2跳过、Python175运行／4跳过；Windows Flutter2591通过／20跳过、Python175运行／6跳过。五份普通候选artifact来源与摘要元数据已核对，未新做普通候选完整字节／本机覆盖升级或发行；iOS独立IPA另按下一节核对。[CI记录](benchmarks/github-ci-ios-windows-preflight-2026-11-15.json)。恢复后另用Windows Flutter实际运行4项模型测试通过。

## 编译、签名与安装分别记录

应用运行时代码仍为72a7080／lib树0b85d48；[固定SDK CI](https://github.com/yarnway/dontforget/actions/runs/43669528199)七项成功，其中iOS为未签名IPA。其11,314,521字节IPA已下载，artifact SHA／CRC、源码清单、IPA摘要、主应用及ReminderActivity扩展版本／身份均核对，最低iOS15，未嵌入描述文件。原始身份`com.yarnway.dontforget`，不直接作为覆盖手机既有应用的依据。

增加手动工作流`ios_device_candidate.yml`：仅接受完整源码SHA及独立run-id，先要求该源码固定SDK CI成功，再在云端Mac中使用既有准备脚本改写主应用／扩展身份，固定Flutter3.44.9构建。校验实际IPA内身份、版本、CRC及无描述文件，输出准备文件摘要与独立回执。只读GitHub权限、不使用Apple凭据、不发布Release。

独立[云端构建43673964163](https://github.com/yarnway/dontforget/actions/runs/43673964163)成功：工作流源码50d32b1、应用源72a7080，主应用为`com.yarnway.dontforget.acceptance.iphone15-20261115`，扩展为其`.ReminderActivity`。11,314,833字节IPA已下载，artifact SHA、外层ZIP／IPA CRC、来源清单、准备文件哈希、实际主／扩展身份与79版本及无描述文件核对通过；保留原包并提供带身份名称的本机副本。[候选证据](benchmarks/ios-isolated-candidate-2026-11-15.json)。仍为未签名候选，不等同于签名安装或真机运行。

## 免费账号与后续安装

[Apple官方说明](https://developer.apple.com/help/account/basics/about-your-developer-account)允许免费Personal Team在个人设备测试，但描述文件7天到期，另有设备／App ID／应用数量限制；当前免费账号不能据此当作已具备TestFlight分发条件。

[AltServer官方说明](https://github.com/altstoreio/FAQ/blob/main/release-notes/altserver.md)提供Windows直接侧载IPA的入口，需本机账号认证并定期重签；官方安装说明见[Windows指南](https://github.com/altstoreio/FAQ/blob/main/altstore-world/how-to-install-altstore-windows.md)。用户已明确选择继续采用AltServer，随后从官方CDN取得安装包，MSI版本1.8.04／主程序1.8.4.0。安装器及主程序Authenticode均为NotSigned，不把制造商文本当作签名认证；官方来源与完整摘要已保全。非交互安装至本机`LOCALAPPDATA/Programs/AltServer`返回0、不重启，MSI清单31项／27个唯一文件与源字节一致，程序已启动。未修改现有Apple组件或Windows安全设置。

computer-use按技能读取并初始化后仍在窗口发现前报`sandboxCwd is not a local file URI: file:///mnt/d/gitspace/opensources/dontforget`，未用PowerShell UIA替代。进程启动不计为GUI通过；账号认证必须由用户本人在本机完成，目前未登录Apple账号、未签名／安装手机应用，也未验证其在iOS27.2.1上的侧载兼容性。安装后只读USB元数据仍保持。不会把Apple密码、验证码或签名私钥写入聊天、日志、仓库或CI。[本机分层证据](benchmarks/ios-windows-preflight-2026-11-15.json)。

上述为11月15日准备状态；11月16日安装排查与后续路线见下节。数据保全与未知现有身份保护沿用[Runbook](iOS_Device_Acceptance_Runbook.md)。

## 2026-11-16安装排查

后续状态：用户已完成下载与手机AltStore安装，USB核对独立bundle模式／预期名称和1.8.10／79；用户首启／重开／中文录入与只读容器、SQLite、原声保持结果见[安装后回执](benchmarks/iphone-personal-sideload-2026-11-16.json)。下列“尚未安装／未下载”保留排查当时的事实，不代表最新安装状态。

用户先报告安装成功，后报告已信任开发者并开启开发者模式，但找不到“别忘了”。再次从AltServer的`Sideload .ipa…`选择文件后无新窗口，通知中心／Alt+Tab均未见提示。后台进程响应正常、无相关崩溃事件，不足以证明侧载任务执行或账号认证成功；不把静默结果写成安装通过。

为区分主屏幕未显示与实际未安装，使用AltServer已有的x86原生库和临时.NET命令行程序，只读查询安装元数据。通过现有配对记录在短期进程内建立会话，不重配对或保存材料，不执行安装／卸载，不读取应用容器／业务数据。只请求应用身份、名称、版本字段，非空清单／有效身份字段检查后，仅输出本项目匹配项及AltStore存在性，不保存其他应用清单。结果明确为AltStore存在、没有任何匹配“别忘了”的应用；独立候选尚未安装。Developer Mode与开发者信任仍只记录为用户已报告，不由元数据推定。

Downloads中的`DontForget-iPhone15ProMax-v1.8.10-79.ipa`为独立候选副本，11,314,833字节、SHA256 `ef56432557aefa7a8b9dcd01f03f91651eb4213bdbd8a9c9c040aa68e771c3d3`与已核对原包相同。桌面静默路径改为手机AltStore的My Apps → ＋导入；为传文件，准备同一GitHub构建artifact的短期下载二维码，下载内容为ZIP，需在“文件”中解压后选择内部`DontForget_iOS_unsigned_v1.8.10.ipa`。二维码只含单份artifact的临时下载权限，不含GitHub账号凭据；签名地址与二维码不进入版本库。[GitHub说明](https://docs.github.com/en/rest/actions/artifacts#download-an-artifact)规定重定向地址有效期1分钟，过期须重新生成。

随后用户提供的截图为AltStore的My Apps主页，仅显示AltStore，并确认尚未把ZIP下载／解压到iPhone；当前缺少可选IPA的原因已定位到文件尚未传入，不能推定导入入口失效。须先刷新二维码、手机实际下载与解压，再确认AltStore签名／安装与首启；用户自行完成Apple账号认证及验证码操作。后续先取得明确结果或错误，再只读核对安装身份／1.8.10与79版本，之后执行首启、正常重开、输入／附件／备份、通知热冷点击、录音与灵动岛。未发布新版本、未修改应用运行时代码，不新增自动化测试或iPhone运行通过结论。[脱敏回执](benchmarks/ios-installation-troubleshooting-2026-11-16.json)保留本轮证据摘要，11月15日旧回执保持原时间归属。
