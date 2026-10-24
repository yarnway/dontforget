# macOS 输入与原生菜单

Mac 应用菜单新增“快速输入…”（Command-N），原生“设置…”（Command-,）连接到产品设置页。快速输入使用 AppKit 编辑框：写入文本后按“发送”才进入现有任务处理流程；取消或空白文本不产生任务。模型调用、失败时保存本地事项、任务持久化和错误反馈继续由 `HomeController.processText` 处理。界面文字跟随应用的中文、英文、日文设置。

原生输入框属于打开时的数据和运行时会话。恢复开始会关闭它并废弃旧回答；即使平台迟到返回文本，也不能写入恢复后的数据。重复打开命令在当前输入完成前被拒绝，设置菜单在输入框打开或数据恢复期间不可用。这里只提供常规产品入口，没有验收专用文本、自动提交或绕过恢复检查的分支。

## 问题证据与边界

旧候选原生菜单中的 Settings… 没有绑定 action，实际菜单显示 disabled。Flutter 输入框的 AXValue 写入可以读回，但画面仍显示占位文本，发送按钮也未启用；单看辅助功能树会误判输入成功。

项目锁定 Flutter 3.44.9，framework revision `6b182d2c7585eba26d4edce0f97630effd256c33`。该版本的 [FlutterTextInputSemanticsObject.mm](https://github.com/flutter/flutter/blob/6b182d2c7585eba26d4edce0f97630effd256c33/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterTextInputSemanticsObject.mm) 为语义文本建立 NSTextField 代理，通过 FlutterTextInputPlugin 作为编辑器，但没有为 AXValue 写入覆盖 `setAccessibilityValue:`。结合本机截图和 AX 读回，推断它解释了本次“原生代理值改变、Dart 输入未改变”的现象；[Flutter 上游问题 191503](https://github.com/flutter/flutter/issues/191503) 也记录了相同失败机制。

本次提供真正的 AppKit 编辑入口并在确认时读取其原生值，没有改写 Flutter 引擎或使用私有 API，也没有声称修复所有 Flutter 控件的 AX 写入行为。坐标工具返回 `noWindowsAvailable` 是另一项操作限制，新增菜单不能作为该限制已解决的证据。

## 验证方式

- 通道测试覆盖确认、空输入、取消、重复打开、会话失效、恢复后迟到回调、销毁和平台失败后的重试。
- 真实 SQLite 与产品 HomeController 的集成测试证明确认文本进入模型提取接口并只保存一次；该测试的模型响应是模拟值，不等于真实服务验收。
- 新候选须独立核验包摘要、源码身份和签名，再用合成文本确认实际 AppKit 画面、任务生成、数据库内容及重开一致性。真实 DeepSeek、辅助功能操作与全程前台测量分别记录，不能仅凭 AXValue 或构建成功宣称通过。
