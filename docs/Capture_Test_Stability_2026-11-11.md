# 录入异步验收等待方式（2026-11-11）

README／附件验收工具提交511ba9c的[首轮CI42955002071](https://github.com/yarnway/dontforget/actions/runs/42955002071)中，Linux质量检查成功，Windows完整套件2384通过／20跳过／1失败，后续构建被门禁跳过。失败为`raw capture is durable before model returns; retry does not duplicate`，栈定位到通用`until`轮询断言，不能记首轮全部通过。

旧辅助函数以300次、每次2ms轮询真实异步状态，没有产品600ms承诺。改为模型请求的明确事件和录入状态的订阅，使用30秒有界失败保护；请求数量仍要求精确匹配，结束后关闭订阅。核心场景新增可控模型派发屏障，在放行模型前就实际读取SQLite并核对原文与待确认标志，完成重试后再次断言恰好两次模型调用和一条事项。保留原文先落盘、模型迟到不覆盖用户修改、重试不重复等所有业务断言。

本地相关46通过、分析0。应用运行时代码、版本与依赖保持不变；修改的是测试等待协议，不是用户界面响应时间或性能承诺。最终固定SDK CI结果见下方收口，本地与云端分别记录。[机器证据](benchmarks/capture-ci-wait-fix-2026-11-11.json)。

固定修正源码`bda32770ba73164446b5ca1499465db0b87c9728`的[CI42957739486](https://github.com/yarnway/dontforget/actions/runs/42957739486)七项成功，Linux Flutter2403通过／2跳过、Windows2385通过／20跳过，Python各161运行（4／6跳过）。首轮失败保留，不将重试通过记作首次通过。
