# DontForget (别忘了) - 开发者指南与源码构建手册

本文档面向准备参与 DontForget 开发、二次定制或本地源码编译的研发工程师。

---

## 1. 开发环境要求

- **操作系统**：Windows 10 / 11 (64-bit) 推荐；macOS / Linux 亦可支持对应平台开发。
- **Flutter SDK**：CI 固定为 `3.44.9`，项目最低约束为 `3.44.0`。本地应使用与 CI 一致的版本；其他 SDK 的验证结果单独记录。
- **Dart SDK**：`>= 3.12.0 < 4.0.0`（随上述 Flutter 提供）。
- **依赖与质量检查**：使用提交的 lockfile，执行 `flutter pub get --enforce-lockfile`、`flutter analyze`、`flutter test`。测试使用临时数据库，不读取用户应用数据。
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
│   ├── Next_Steps_2026-11-02.md
│   └── Changelog.md
├── lib/
│   ├── data/                   # SQLite 存储、读写事务与旧目录迁移
│   │   ├── database_access.dart
│   │   ├── database_helper.dart
│   │   └── database_location_migrator.dart
│   ├── l10n/                   # 模块化三语本地化字典 (中/英/日)
│   │   ├── app_localizations.dart
│   │   └── *_strings.dart
│   ├── models/                 # 数据领域模型 (Reminder, MediaRecord, AppSettings 等)
│   ├── providers/              # Riverpod 状态与工作区控制器
│   │   ├── home_controller.dart
│   │   └── providers.dart
│   ├── services/               # 业务逻辑服务层
│   │   ├── ai/                 # AI 路由与调度辅助
│   │   ├── content/            # 媒体引用保留、外部备份引用与清理
│   │   ├── recovery/           # 存储启动检查、恢复规划与运行门禁
│   │   ├── security/           # 系统安全凭据仓库
│   │   ├── lan_sync_service.dart
│   │   ├── llm_service.dart
│   │   ├── notification_service.dart
│   │   ├── text_bounds.dart
│   │   └── windows_toast.dart
│   ├── ui/                     # 界面展现层
│   │   ├── formatters/         # 共享字节大小与时间格式化器
│   │   ├── screens/            # 页面 (HomeScreen, TaskDetailScreen, SettingsScreen 等)
│   │   ├── theme/              # AppTheme Material 3 令牌与对比度规范
│   │   └── widgets/            # 组件 (QuadrantView, TaskBoard, TaskCard, InputBottomBar,
│   │                           #       LanSyncConflictsDialog, TaskDetailsDialog 兼容入口等)
│   └── main.dart               # GUI 与 CLI 统一启动入口
├── linux/                      # Linux GTK 原生工程
├── macos/                      # macOS Cocoa 原生工程
├── scripts/                    # 构建、版本门禁、校验与回归脚本库
│   ├── check_flutter_version.py
│   ├── package_artifacts.py
│   ├── package_windows.ps1
│   ├── report_windows_skipped_tests.py
│   ├── verify_artifacts.py
│   └── tests/                  # Python 与原生脚本测试套件
├── test/                       # Flutter 单元、组件与端到端测试集
│   ├── database_test.dart
│   ├── l10n_integrity_test.dart
│   └── widget_test.dart
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
在提交任何代码前，必须确保通过版本门禁、静态代码扫描、Flutter 与 Python 测试套件：
```bash
# 校验 Flutter SDK 与 CI 基线 (3.44.9) 完全一致
python scripts/check_flutter_version.py --strict

# 执行代码静态分析 (确保 0 issues)
flutter analyze --no-pub

# 执行全量 Flutter 测试与 Python 脚本回归（Windows 下勿与 flutter build windows 并行）
flutter test --no-pub --concurrency 2 --timeout 2m
python -m unittest discover -s scripts/tests -v
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
- 当前生产数据库（Schema 17）由 `lib/data/database_helper.dart` 与 `lib/services/recovery/storage_bootstrap.dart` 统一初始化，Windows 默认目录位于 `%APPDATA%\com.yarnway.dontforget\DontForget\databases\dont_forget_v3.db`。
- 早期遗留目录（如 `%LOCALAPPDATA%\DontForget\databases` 或历史 `app_database.db`）通过 `DatabaseLocationMigrator` 安全检测与隔离迁移，并搭配运行目录租约锁防止多进程同时写入损坏数据。
- 启动自动校验并创建数据表索引，提高按分类与时间排序检索的效率。

### 4.3 多语言国际化机制
- 核心总表与合并解析位于 `lib/l10n/app_localizations.dart`，各业务域文案拆分在 `lib/l10n/*_strings.dart`（支持 `zh`、`en`、`ja`，并向英文回退）。
- 在任意 Widget 内使用 `AppLocalizations.of(context).get('key')` 或对应域辅助函数（如 `aboutText`、`sharedTextLabel`、`protectionText`）取到翻译。
- `test/l10n_integrity_test.dart` 自动守卫核心与合并词表的 `en / zh / ja` 键集合及 `{placeholder}` 100% 对齐。

---

## 5. 常见问题排查 (Troubleshooting)

1. **Windows 编译报错缺少 MSVC 或 CMake**：
   - 请确保在 Visual Studio 安装器中勾选了“使用 C++ 的桌面开发”，并检查环境变量 `PATH` 中是否能找到 `cl.exe` 和 `cmake.exe`。
2. **Windows 下 `flutter test` 与 `flutter build windows` 冲突**：
   - 两者共用 `build/native_assets/windows/sqlite3.dll`，Windows 环境必须**串行执行**，不可同时后台并发运行。
3. **测试时遇到 `sqflite default factory` 警告**：
   - 属于单元测试环境下内存 SQLite 驱动的正常信息，不影响测试断言与功能。

## Android／Windows／Linux／iOS 发布说明

主线由 `.github/workflows/build_and_release.yml` 执行质量检查与五平台构建校验（包含 Linux、Windows 质量门禁及 Windows / Linux / Android / macOS / iOS 构建）。明确发布时，手动运行 `.github/workflows/publish_release.yml`（详见 [Release_Policy.md](Release_Policy.md)），校验完整构建摘要、Android 发行证书及平台产物后发布并读回核验。不要把旧源码 run ID 用于新提交，也不得修改已有 Release 标签。

Android发行材料由 `DONTFORGET_ANDROID_KEYSTORE_BASE64`、`DONTFORGET_ANDROID_STORE_PASSWORD`、`DONTFORGET_ANDROID_KEY_ALIAS`、`DONTFORGET_ANDROID_KEY_PASSWORD`、`DONTFORGET_ANDROID_CERT_SHA256` 五项仓库Secrets供CI使用，值不写入源码、参数或日志。公开证书固定在 `android/release-certificate.sha256`；更换证书会影响已有安装，普通版本更新不可重新生成签名身份。

本机发行身份位于当前Windows用户 `%LOCALAPPDATA%\DontForget\Signing`，密码在系统凭据库专用项 `DontForget/AndroidDistribution/v1/password`，DPAPI恢复文件绑定当前用户环境。保留PKCS12、系统凭据及加密恢复副本；不要清理、上传到Release或写入Git。腾讯云服务凭据与发行签名完全独立，本轮没有读取腾讯云凭据。Windows代码签名、Android商店上架及Apple签名公证另行处理。
