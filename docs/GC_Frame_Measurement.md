# 768 宽首帧与 GC 观测

隔离 profile 工具提供三个互斥模式。默认完整测量保持原协议：100/1,000/10,000 条任务，375/768/1440 宽、792 高，每组一次预热和五次测量。详细组件诊断仅用于定位构建/布局/绘制，耗时不合入普通基线。

`Observe GC at 768px` 使用相同任务夹具和 768 × 792 视口，一次预热后测量 30 次新看板/ProviderScope 挂载。协议 v2 可选择 1,000 或 10,000 条，报告必须声明数量；v1 固定万条。组件 profiling 必须关闭；挂载期间没有时间线 RPC，全部挂载完成后只读取一次时间线。这个观测仍不是完全无观测的基线，不能直接与普通五次测量合并。

测量外壳默认缓存相同的 ThemeData，避免 MaterialApp 的默认主题在每次外壳重建时重新分配。`Rebuild default theme per mount (legacy shell)` 保留旧行为，允许同一包交替验证外壳影响。报告中的 `shell_theme_protocol` 必须一致才能比较产品优化；比较两种外壳时只能得出测量干扰的结论，不能称为产品提速。看板及 ProviderScope 仍每次重新挂载，不能缓存被测树。

构建：`bash scripts/build_macos_performance.sh`，要求固定 Flutter 3.44.9、完整 Xcode 和 macOS。CI 也可构建独立验收包。准备具有全新身份的隔离副本，原生界面选择 GC 模式并点击 Start；保持全程前台，不同时下载、编译或运行其他测量。失败或清理状态不确定时，必须重开该隔离进程。

只读分析：

```sh
python3 scripts/analyze_gc_frames.py --report /absolute/path/to/results.json
```

分析器要求完成、无错误、全程前台、单次延后读取、31 次固定视口挂载，以及匹配的任务数量和外壳协议。以引擎 `FrameTiming` 的 buildStart/buildFinish 为区间，用该区间内的 Dart BUILD 确定 UI 线程。GC 类别中的 CollectNewGeneration、CollectOldGeneration、Scavenge 区间裁剪后取并集，排除工作线程与帧外事件。缺失配对、线程不明、区间不一致均拒绝，不把“未知”记为无 GC。

报告按有/无同线程 GC 区间列出帧耗时分布和全部样本。区间重叠是关联证据，不是 GC 导致尾部的因果证明；GC scope 的墙钟时间也不是纯 CPU 时间。不得把嵌套 GC、工作线程耗时相加，或把扣除 GC 后的数值当成优化结果。产品优化仍需用普通协议交替复测，保留失败/失焦样本。

产品候选的分配优化包括按不可变 Reminder 缓存只读子任务解析结果、窄屏分类焦点节点按需创建。解析缓存随任务对象释放，copyWith 得到新缓存，历史可变列表接口保留；不改变展开内容或存储格式。比较产品候选时两边必须使用相同的缓存主题外壳。此协议每次重建看板/ProviderScope，但复用同组任务对象，预热也会预热模型的惰性缓存；不能把结果称为首次解析或完整产品冷启动性能。

2026-10-23 的[测量壳对照](benchmarks/gc-shell-3d12-2026-10-23.json)证明只缓存 ThemeData 并未稳定修复万条尾部。产品优化后的[普通交替复测](benchmarks/product-allocation-3d12-2026-10-23.json)与[GC 分组复测](benchmarks/gc-product-3d12-2026-10-23.json)分开保存；千条 GC 慢帧 7/90 → 2/90，万条 16/90 → 11/90，但万条 max 未改善。[最终源码单次普通补测](benchmarks/final-profile-3d12-2026-10-23.json)仍有 20.113 ms 的有效慢帧，不据此关闭尾部优化任务。

参考：[Dart VM 时间线流与环形记录器](https://github.com/dart-lang/sdk/blob/main/runtime/docs/timeline.md)、[Flutter 内存与 GC 观测](https://docs.flutter.dev/tools/devtools/memory)。时间线记录器可能覆盖旧事件，所以缺少所需 BUILD/GC 边界的报告不能用来证明 GC 缺席。该模块不由正式产品入口导入，不改 VM 堆大小，不强制 GC。

本轮候选将看板投影改为一次分类后填充定长分组，以 Uint8List 暂存分类，避免万条引用数组反复扩容；折叠判定仍只执行一次，顺序、计数和单次 Iterable 语义有回归覆盖。该变化尚需与保留的 `9dca8cb` 普通/GC 原生测量对照，不能仅由分配方式推断尾部已经改善。

本轮[六轮普通交替复测](benchmarks/exact-size-board-3d14-2026-10-23.json)共 108 个全程前台片段、270 个首帧，旧新版均无 build >16.667 ms；万条/768 中位数却从 9.006 升到 11.085 ms，千条 max 从 10.807 升到 12.767 ms。定长两遍分组没有得到稳定收益支持，已撤回产品分组改动，保留单遍投影和新增语义回归。此对照同时包含增量日志接入，不能将全部差值归因于分组；历史 GC 尾部也不能凭本轮未复现而关闭。
