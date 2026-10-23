# 完整产品前台真实 OS 失败自动重试

普通产品不记录诊断轨迹。构建 `bash scripts/build_macos_startup_measurement.sh --retry-trace` 会生成单独的 release 产物 `dist/retry/`，仍从 `lib/main.dart` 启动真实应用、HomeScreen、Provider 和原生通知服务；不提供人工重试钩子，不注入 NSError。帮助入口为 `--help`，未知参数在构建前拒绝。CI 的 `product_retry` 保存独立产物和源码摘要。

报告必须位于新隔离 bundle 的独立容器，非隔离路径不启用。`notification-retry-traces/` 每进程最多 128 个事件，保存阶段、前台状态、原生 ID、错误 domain/code、有限日志状态及 pending IDs；不保存标题、正文、平台错误消息或凭据。读 pending 失败为 unknown，不能推断为空。普通启动测量不启用这份轨迹，避免把额外 I/O 混入性能基线。

验收只使用合成任务并保留关闭时的一致快照。受控临时安装来源可以尝试真实 OS 拒绝，但若系统接受，应如实记录；不能制造错误替代。实际收到 `native_schedule_failed` / OS domain/code 后，确认 failed 已落盘；正常退出并确认进程缺席，再从正常验收路径启动同身份、同内容的应用。应用应保留同一近期失败及冷却；授权满足后保持前台，等待正常十秒心跳和一分钟冷却触发自动重试，期间不点手动重排、不改系统时钟。对应轨迹须出现 foreground worker、真实调度结果、同 ID submitted 和单一 pending。最后通过产品删除合成任务，确认取消落盘且 pending 为空。

启动仅对同一未来 occurrence 的近期 failed schedule 保留一分钟冷却；pending、改变的 trigger/revision、过期失败仍立即对账。手动重排保持立即执行。权限不足时自动调度保持阻止，不能把跳过误写为成功。应用重开不代表系统重启；pending 表示 OS 接受，不证明实际送达。

2026-10-23 完成实际产品隔离验收：真实 `UNErrorDomain 1` 落盘后，正常路径一分钟内重开保留冷却和同 ID；notEnabled 前台 worker attempted=0，系统设置开启该隔离身份后正常心跳 attempted=1 / failed=0，同 ID submitted 且真实 pending 一条。后一心跳 attempted=0；通过产品删除合成任务后 cancel/submitted，pending 为空，正常退出及关闭数据库一致备份均确认。[原始轨迹与范围](benchmarks/native-foreground-retry-3c12-2026-10-23.json)。这是受控安装来源负例，不推断任意路径或权限拒绝必然产生同一 NSError。
