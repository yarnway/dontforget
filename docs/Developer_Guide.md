# DontForget (别忘了) - 开发者指南与源码构建手册

本文档面向准备参与 DontForget 开发、二次定制或本地源码编译的研发工程师。

---

## 1. 开发环境要求

- **操作系统**：Windows 10 / 11 (64-bit) 推荐；macOS / Linux 亦可支持对应平台开发。
- **Flutter SDK**：`>= 3.2.0 < 4.0.0` (推荐 Flutter 3.24+ / 3.27+)
- **Dart SDK**：`>= 3.2.0`
- **C++ 编译工具链**（Windows 桌面端构建必备）：
  - Visual Studio 2022 / 2019，且安装了 **“使用 C++ 的桌面开发”** 工作负载（包含 MSVC v142/v143、Windows 10/11 SDK）。
- **打包安装工具**（生成 Setup 安装包必备）：
  - [Inno Setup 6](https://jrsoftware.org/isdl.php)（默认安装至 `C:\Users\<User>\AppData\Local\Programs\Inno Setup 6\ISCC.exe` 或配置到 PATH 中）。

---

## 2. 源码仓库结构

```
DontForget/
├── android/                    # Android 原生平台工程
├── assets/                     # 静态资源文件（图标、着色器、字体等）
│   ├── app_icon.ico
│   └── app_icon.png
├── docs/                       # 项目技术设计与用户文档库
│   ├── Architecture_Design.md
│   ├── User_Guide.md
│   ├── Developer_Guide.md
│   ├── Packaging_and_Deployment.md
│   ├── AI_Vision_and_3D_Effects.md
│   └── Changelog.md
├── fmedia/                     # 内置便携式音频处理引擎（Windows 平台解码支持）
├── lib/
│   ├── l10n/                   # 多语言国际化字典 (中/英/日)
│   │   └── app_localizations.dart
│   ├── models/                 # 数据领域模型 (Reminder, MediaRecord, AppSettings)
│   ├── providers/              # Riverpod 状态管理核心容器
│   │   └── providers.dart
│   ├── services/               # 业务逻辑服务层 (LLM, Database, Audio, Notification)
│   │   ├── database_helper.dart
│   │   ├── llm_service.dart
│   │   └── notification_service.dart
│   ├── ui/                     # 界面展现层
│   │   ├── screens/            # 页面 (HomeScreen, SettingsScreen, DashboardScreen)
│   │   └── widgets/            # 组件 (3D全息粒子, 象限网格, 任务卡片, 输入条等)
│   │       ├── ai_background_effect.dart
│   │       ├── input_bottom_bar.dart
│   │       ├── quadrant_view.dart
│   │       ├── task_card.dart
│   │       └── task_details_dialog.dart
│   └── main.dart               # 应用启动总入口
├── linux/                      # Linux GTK 原生工程
├── macos/                      # macOS Cocoa 原生工程
├── scripts/                    # 自动化脚本库
│   ├── Install.ps1             # Windows 本地一键部署与测试脚本
│   └── package_windows.ps1     # 生产环境编译、DLL 注入与双格式打包脚本
├── test/                       # 自动化测试用例集
│   ├── database_test.dart      # SQLite CRUD 与事务测试
│   ├── end_to_end_test.dart    # 端到端业务链路测试
│   └── widget_test.dart        # UI 组件渲染与交互测试
├── windows/                    # Windows 桌面平台原生 C++ 工程
├── windows_installer/          # Inno Setup 脚本与安装器资源
│   └── installer.iss
├── windows_redist/             # 预置的 VC++ CRT 与 DirectX 兼容 DLL 集合
├── pubspec.yaml                # 依赖与资源配置清单
└── README.md                   # 仓库主说明文档
```

---

## 3. 本地构建与快速上手

### 3.1 克隆仓库与依赖拉取
```bash
git clone https://github.com/yarnway/dontforget.git
cd DontForget
flutter pub get
```

### 3.2 运行静态检查与自动化测试
在提交任何代码前，必须确保通过静态代码扫描与测试套件：
```bash
# 执行代码静态分析 (确保 0 issues)
flutter analyze

# 执行全量单元测试与集成测试
flutter test
```

### 3.3 本地开发调试运行
```bash
# 启动 Windows 桌面版调试
flutter run -d windows

# 启动 macOS 桌面版调试 (macOS 环境)
flutter run -d macos

# 启动 Linux 桌面版调试 (Linux 环境)
flutter run -d linux

# 启动移动端调试 (连接真机或模拟器)
flutter run -d android
```

---

## 4. 核心子系统实现原理

### 4.1 响应式状态管理 (Riverpod)
DontForget 使用 `flutter_riverpod` 构建单向数据流：
- **`remindersProvider`**：
  - 继承自 `StateNotifier<List<Reminder>>`。
  - 所有新增、删除、状态修改、分类变更都会直接写入本地 SQLite，并同步更新内存列表，触发所有监听组件重新构建。
- **UI 消费范式**：
  - 尽量使用 `ConsumerWidget` 或 `ConsumerStatefulWidget`。
  - 通过 `ref.watch(provider)` 获取响应式数据，通过 `ref.read(provider.notifier)` 触发业务操作。

### 4.2 本地数据层 (SQLite FFI)
- 桌面平台通过 `sqflite_common_ffi` 调用原生 C 动态库 `sqlite3.dll`。
- 在 `main.dart` 初始化阶段：
  ```dart
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  ```
- 数据库位于用户应用数据目录下：`%LOCALAPPDATA%\DontForget\app_database.db`。
- 启动自动校验并创建数据表索引，提高按分类与时间排序检索的效率。

### 4.3 多语言国际化机制
- 集中维护在 `lib/l10n/app_localizations.dart`。
- 采用轻量高性能静态 Map 索引，避免生成过重的编译期代码。
- 在任意 Widget 内使用 `AppLocalizations.of(context).get('key')` 即可取到对应翻译。
- 若需新增语言（如法语、韩语），只需在 `_localizedValues` 字典中添加对应的语言代码键值即可。

---

## 5. 常见问题排查 (Troubleshooting)

1. **Windows 编译报错缺少 MSVC 或 CMake**：
   - 请确保在 Visual Studio 安装器中勾选了“使用 C++ 的桌面开发”，并检查环境变量 `PATH` 中是否能找到 `cl.exe` 和 `cmake.exe`。
2. **测试时遇到 `sqflite default factory` 警告**：
   - 属于单元测试环境下内存 SQLite 驱动的正常信息，不影响测试断言与功能。
3. **音视频播报异常**：
   - Windows 平台构建脚本已配置好 `fmedia` 绿色便携音频内核，请勿随意删除构建输出目录中的 `fmedia/` 文件夹。
