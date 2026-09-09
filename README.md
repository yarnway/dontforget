# 别忘了 (DontForget)

<div align="center">

![DontForget Logo](assets/app_icon.png)

**端侧隐私第一 · 大模型驱动 · 3D 全息 AI 视觉 · 全平台智能备忘与任务调度系统**

[![Flutter Version](https://img.shields.io/badge/Flutter-3.24%2B-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5%2B-0175C2?logo=dart)](https://dart.dev)
[![Release Version](https://img.shields.io/badge/Release-v1.2.4-00E5FF)](https://github.com/yarnway/dontforget/releases)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-blue)](#-全平台支持与系统要求)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[功能特性](#-核心特性) • [下载体验](#-快速下载与安装) • [使用指南](docs/User_Guide.md) • [技术架构](docs/Architecture_Design.md) • [开发构建](docs/Developer_Guide.md) • [变更日志](docs/Changelog.md)

</div>

---

## 📖 项目简介

在信息碎片化时代，灵感与待办事项往往转瞬即逝。**别忘了 (DontForget)** 致力于打造下一代智能备忘体验：
您只需用最自然的日常习惯随手记下一句话、录一段语音或丢一张截图，**内置的大模型引擎便会自动为您提炼任务、评估应该提前多久提醒、安排合理的时间并智能分类**。同时，所有数据全部通过 SQLite 物理存储在您的本地设备中，绝不上传私有云，保障绝对的数据主权与隐私安全。

---

## ✨ 核心特性

### 🌌 1. 3D 全息 AI 空间粒子系统 (Astra & DeepSeek 灵感)
- **参数化 3D 点云塑形**：620+ 空间粒子汇聚成精致的立体 LOGO 与双轴倾斜交错的天体轨道环，拥有逼真的三维透视投影与近大远小景深层级；
- **深空星光与 4 芒光学十字星刺**：150 颗自主呼吸的深空恒星背景，高能耀斑恒星自动激发光学衍射十字星芒刺；
- **线束脉冲传输**：粒子连线编织出光纤线缆，白蓝色高能光子以不同速度在节点间飞驰穿梭，呈现大模型神经网络突触放电的磅礴算力感；
- **流体阻尼与波纹推散**：鼠标轻扫激起能量涟漪，点击引爆 3D 冲击波；推散后的粒子在微重力阻尼模型下**如星云般缓慢、丝滑、悠闲地凝聚复位**，手感极佳。

### 🧠 2. 大模型智能评估「提前量（Lead Time）」
- 告别在事件发生瞬间才提示的手忙脚乱！大模型结合生活经验智能推算提前提醒时机：
  - **会议 / 沟通**：提前 15 ~ 30 分钟提醒（留出准备与入会时间）；
  - **差旅 / 出行 / 赶车**：提前 60 ~ 120 分钟提醒（留出通勤与安检时间）；
  - **工作汇报 / 材料截止**：提前 1 ~ 3 小时提醒（留出收尾与复核时间）；
  - **即刻行动**：准点即时提醒；
  - **普通无定时待办**：合理避开深夜，智能推演安排在今晚 20:00 或明早工作时间。

### 🧼 3. 极简主义纯图标线框 UI
- **彻底去除干扰**：移除了所有“重要且紧急/不重要不紧急”文字，移除“Q1/Q2/Q3/Q4”代号，并去除了右上角冗余的计数微标；
- **纯粹矢量微标**：以 🔥（核心）、⭐（重要）、⚡（协同）、☕（休闲）纯图标呈现，视线焦点回归待办卡片本身；
- **状态感知**：微型呼吸 LED 状态灯常驻标题栏旁（绿色待机/青蓝推理中），通知提示 3 秒自动平滑退场。

### 🔒 4. 端侧绝对隐私 (Zero Cloud, Local-First)
- 遵循 **BYOK (Bring Your Own Key)** 模式，用户直接对接大模型服务商（DeepSeek、Gemini 或自定义 API）；
- 备忘记录、语音附件、图片素材、数据库配置**百分之百存储在用户本地**，无中继服务器，安全无忧。

### 🎙️ 5. 全能多模态随手记
- **文字记录**：自然语言直接输入，支持任意模糊时间与重复周期（每天、工作日、每周、每月）；
- **语音备忘**：一键录音，自动保存并调用模型转录解析，卡片支持随时重播原始录音；
- **图片与截图提取**：支持上传便签照片、会议白板截图，Vision 大模型自动提炼待办；
- **文档与视频关联**：本地多媒体素材快速预览与关联。

---

## 💻 全平台支持与系统要求

| 平台 | 最低系统版本 | 架构 | 特性支持 |
|---|---|---|---|
| **Windows** | Windows 7 SP1 / 8 / 10 / 11 | x64 | **已内嵌 VC++ CRT 与 DirectX DLL**，纯净系统免装运行库直启；支持托盘最小化、开机自启 |
| **macOS** | macOS 11.0 (Big Sur) 及以上 | x64 / ARM64 (Apple Silicon) | 支持深色模式与原生菜单栏 |
| **Linux** | Ubuntu 20.04 LTS / Debian 11+ | x64 | GTK 3 原生窗口与系统托盘 |
| **Android** | Android 7.0 (API 24) 及以上 | ARM64 / ARMv7 | 移动端触摸手势优化、通知推播 |
| **iOS** | iOS 13.0 及以上 | ARM64 | 移动端平滑触控交互 |

---

## 🚀 快速下载与安装

前往 [GitHub Releases](https://github.com/yarnway/dontforget/releases) 下载最新发行版（当前最新：**v1.2.4**）：

- **Windows 独立安装版**：下载 `DontForget_Setup_v1.2.4.exe`，双击根据向导安装。
- **Windows 绿色免安装版**：下载 `DontForget_Portable_v1.2.4.zip`，解压后双击 `dont_forget.exe` 即可使用。

---

## ⚙️ 快速配置大模型

启动应用后，点击右上角齿轮图标 ⚙️ 进入设置：

1. **选择预设服务商**：
   - **DeepSeek**（推荐）：提供高性价比的大模型解析能力；
   - **Gemini**：具备极强的多模态图文解析能力；
   - **自定义**：兼容任何 OpenAI 规范接口（如本地 Ollama、OneAPI、vLLM 等）。
2. **填入 API Key**，点击保存即可开始使用！
3. **语言选择**：可在简体中文、English、日本語之间任意无缝切换。

---

## 📚 详细文档导航

DontForget 提供了详尽的模块化技术与使用文档：

- 📖 **[用户使用指南 (User Guide)](docs/User_Guide.md)**：各功能详细操作流程、多模态录制技巧、卡片管理与快捷操作。
- 🏛️ **[系统架构设计 (Architecture Design)](docs/Architecture_Design.md)**：Clean Architecture 架构划分、Riverpod 状态流与 SQLite FFI 持久化方案。
- 🛠️ **[开发者与源码构建手册 (Developer Guide)](docs/Developer_Guide.md)**：本地开发环境搭建、源码目录结构、自动化测试与调试指南。
- 📦 **[打包发布与持续集成 (Packaging & Deployment)](docs/Packaging_and_Deployment.md)**：Inno Setup 打包脚本、Windows 7-11 动态库内嵌机制与 GitHub Actions 云端 CI/CD。
- 🌌 **[3D 全息视觉与物理交互设计 (AI Vision & 3D Effects)](docs/AI_Vision_and_3D_Effects.md)**：3D 点云数学模型、深空星光十字芒、线束脉冲与阻尼慢速复位物理白皮书。
- 📝 **[版本演进日志 (Changelog)](docs/Changelog.md)**：从 v1.0.0 到当前版本的演变历程。

---

## 🔨 开发者本地快速构建

```bash
# 1. 克隆代码仓库
git clone https://github.com/yarnway/dontforget.git
cd DontForget

# 2. 安装 Flutter 依赖
flutter pub get

# 3. 运行静态代码扫描与全量测试
flutter analyze
flutter test

# 4. 本地运行调试 (Windows)
flutter run -d windows

# 5. 一键打包 Windows 生产发布包 (Setup.exe + Portable.zip)
powershell -ExecutionPolicy Bypass -File .\scripts\package_windows.ps1
```

---

## 📄 开源许可证

本项目采用 [MIT License](LICENSE) 开源许可证。欢迎提交 Issue 或 Pull Request 共同改进！
