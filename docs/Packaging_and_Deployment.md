# DontForget (别忘了) - 打包发布与部署运维指南

本文档详细介绍了 DontForget 的多格式发布打包体系、系统运行库兼容机制以及 GitHub Actions 云端持续集成流水线。

---

## 1. 软件发布形态

DontForget 在 Windows 平台上提供两种开箱即用的交付形态：

| 发布包形态 | 文件名示例 | 特性与适用场景 |
|---|---|---|
| **独立安装引导程序** | `DontForget_Setup_v1.2.4.exe` | 基于 Inno Setup 6 打造，自动检测权限、解压、创建开始菜单与桌面快捷图标，写入系统控制面板卸载项，适合大部分普通用户。 |
| **绿色免安装便携包** | `DontForget_Portable_v1.2.4.zip` | 包含完整的二进制、依赖 DLL、音频引擎与数据目录。解压后即可运行，支持在 U 盘、移动硬盘随身携带，数据自包含。 |

---

## 2. 本地自动化打包工作流

项目根目录的 `scripts/package_windows.ps1` 实现了全自动一键流水线，执行以下命令即可完成全套发布件制作：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_windows.ps1
```

### 脚本内部执行阶段解析：
1. **[阶段 1/3] 编译 Flutter 生产环境二进制**：
   - 执行 `flutter build windows --release` 生成优化后的机器码与资产文件。
2. **[阶段 1.5/3] 跨版本兼容性 DLL 注入（Windows 7/8/10/11 免运行库支持）**：
   - 从 `windows_redist/x64/` 自动提取官方签名的 Microsoft Visual C++ 2015-2022 CRT 依赖（`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`, `msvcp140_1.dll`, `msvcp140_2.dll`, `msvcp140_atomic_wait.dll`, `msvcp140_codecvt_ids.dll`）以及 DirectX 渲染核心组件 `d3dcompiler_47.dll`；
   - 强行内嵌注入到 Release 输出目录，彻底解决在老旧 Windows 7 / 8 或未装开发库的纯净 Windows 10/11 系统中报错 `缺少 MSVCP140.dll` 或 `DirectX 错误` 的问题。
3. **[阶段 1.8/3] 净化中间文件**：
   - 自动扫描清理临时数据库文件、开发调试日志与测试缓存，确保发布包为纯净出厂状态。
4. **[阶段 2/3] 调用 Inno Setup 编译器生成安装包**：
   - 自动定位系统中的 `ISCC.exe`，根据 `windows_installer/installer.iss` 编译生成高压缩率的 `dist/DontForget_Setup_v1.x.x.exe`。
5. **[阶段 3/3] 归档生成便携版 Zip**：
   - 将完整 Release 目录打包为 `dist/DontForget_Portable_v1.x.x.zip`。

---

## 3. 本地一键安装与测试验证

研发期间若需在本地快速部署安装验证，无需反复运行安装向导，直接执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install.ps1
```

脚本将自动执行：
- 结束正在运行的旧版进程；
- 覆盖更新文件至 `%LOCALAPPDATA%\Programs\DontForget`；
- 更新桌面与开始菜单快捷方式图标；
- 自动启动最新的应用程序。

---

## 4. GitHub Actions 云端多平台 CI/CD 流水线

工程配置了完整的 GitHub Actions 工作流（位于 `.github/workflows/build_release.yml`），由云端三台原生编译机协同工作：

```
                             [Git Push Tag: v1.2.4]
                                       │
                ┌──────────────────────┼──────────────────────┐
                │                      │                      │
        [Windows Runner]        [macOS Runner]        [Ubuntu Runner]
        (windows-latest)        (macos-latest)        (ubuntu-latest)
                │                      │                      │
       • 编译 Windows Release   • 编译 macOS App       • 编译 Linux App
       • 注入 CRT 兼容 DLLs    • 打包 .dmg / .zip     • 打包 .tar.gz
       • ISCC 生成 Setup.exe           │                      │
       • 压缩 Portable.zip             │                      │
                │                      │                      │
                └──────────────────────┼──────────────────────┘
                                       │
                          [GitHub Release 自动发布]
                     - DontForget_Setup_v1.2.4.exe
                     - DontForget_Portable_v1.2.4.zip
                     - DontForget_macOS_v1.2.4.zip
                     - DontForget_Linux_v1.2.4.tar.gz
```

### 触发发布流程：
只需在本地打上版本 Tag 并推送至 GitHub：
```bash
# 提交本地所有改动
git commit -am "chore: prepare release v1.2.4"
git push origin main

# 打 Tag 并推送触发云端打包
git tag -a v1.2.4 -m "Release v1.2.4"
git push origin v1.2.4
```
GitHub Actions 将自动拉起编译机，完成全平台多格式软件包的构建并自动发布到 GitHub Releases 页面供全球用户下载。
