# v1.8.11／build80：外部备份引用登记与四平台发行

当前为发行准备，尚未发布。用户2026-11-16明确要求最新迭代稳定后发布Windows、Linux、Android、iOS新版，并授权继续开发与验收；正式latest暂仍v1.8.10+79。

## 源码与自动化

应用lib树保持`0b85d48fbffc38d4f8f2230e25520a524953ac87`，外部备份引用登记的源码、相关140通过／3跳过、分析0与独立Pixel SAF真实操作证据见[功能记录](External_Backup_References_2026-11-15.md)。这些结果保留原源码和版本归属，不作为build80已完成升级的依据。

发布器新增显式`--include-ios`，工作流可选择四平台；三平台历史调用保持。iOS需同一成功CI的来源与摘要，检查实际IPA的主／扩展身份、版本、可执行文件、WidgetKit声明、CRC及无描述文件。发行说明必须注明未签名、AltStore个人重签及7天续期；来源回执不标记App Store、TestFlight或全部真机通过。专项19项通过；Linux／Windows原生Python各180运行，4／6跳过，均成功；[本机回执](benchmarks/release-80-preparation-2026-11-16.json)。新版本固定CI待执行。

## iPhone当前验收

用户通过手机AltStore安装独立build79；USB已独立读回预期名称／身份模式和1.8.10／79。用户报告首启、关闭后重开、中文键盘发送及再次重开保留通过。只读保全Documents与Library/Preferences，派生SQLite备份schema17、integrity ok；原有1记录／1媒体／1设置与音频均保持，新增1条QA记录。原始输入未独立采集，预期句子与读回有一处空格差异，仅记忽略空白后匹配。[分层回执](benchmarks/iphone-personal-sideload-2026-11-16.json)。

容器首次守卫因AltStore改写CFBundleName而拒绝，没有读取或复制容器；改以既定bundle模式、显示名和版本核对后成功。上述用户触屏与USB读回不等同于全自动GUI或PID证明，不覆盖Keychain、整个Library或完整设备备份。build80同身份升级尚未执行。

## 发布门槛与剩余

- 固定最终源码CI，核对Android固定证书的三包、Windows两包、Linux归档和iOS未签名IPA及清单／摘要。
- Windows最新保全、旧公开包核对、运行中正常覆盖80、payload／业务字段／DPAPI和正常重开；失败保留原证据后续验。
- 双Android分别最新保全与79→80升级，原件／业务全字段／实际凭据和普通重开；正式两APK互换与最终CI字节核对。
- iPhone独立身份同版候选的个人重签升级与数据保持；通知／录音／附件备份／灵动岛／续期矩阵继续分别验收。
- 发布四平台Release后，读回标签源码、正文、完整附件集合、大小和摘要。macOS设备／公证、Windows签名／商店及阶段46—49余项见[阶段台账](Next_Steps_2026-11-02.md)。
