# DontForget 3.0 私有化与极客生产力指南

## 🛡️ 数据主权与隐私设计原则
DontForget 始终秉承 **“100% 数据不离机、绝不上公共云端、零数据泄露”** 的安全铁律。本指南面向开发者与企业内网环境，指导如何进行本地端侧模型推理部署、去中心化局域网同步及 CLI 命令行生产力调用。

---

## 一、端侧大模型本地部署 (Edge AI)

DontForget 支持连接任意兼容 OpenAI 接口规范的本地端侧大模型推理引擎。

### 1. 使用 Docker Compose 一键启动 Ollama
在项目根目录下执行：
```bash
docker compose -f docker/docker-compose.yml up -d
```

### 2. 拉取推荐端侧模型
- **极速小模型 (无显卡 CPU 畅跑)**:
  ```bash
  docker exec -it dontforget-ollama ollama run qwen2.5:1.5b
  # 或
  docker exec -it dontforget-ollama ollama run llama3.2:1b
  ```
- **深度推理思考小模型**:
  ```bash
  docker exec -it dontforget-ollama ollama run deepseek-r1:1.5b
  ```

### 3. 一键端侧探测
打开应用进入 **设置 (Settings) -> 端侧本地模型推理探测**，点击 **“开始探测端侧引擎”**。应用将自动探测 `11434` 端口，点击 **“一键应用到当前配置”** 即可在断网状态下畅享端侧推理！

---

## 二、去中心化局域网多端同步 (Decentralized LAN Sync)

DontForget 拒绝中心化公共云数据库，采用 **安全 P2P 局域网传输 + 动态 6 位 PIN 鉴权** 模式：

1. **主机开启服务**:
   - 在主设备（如工作台 PC）的设置界面，开启 **“去中心化局域网多端同步”** 开关；
   - 系统将展示本机内网 IP（如 `192.168.1.100:42888`）及一次性动态 6 位配对 PIN（如 `839102`）。
2. **辅机连接配对**:
   - 在同一 Wi-Fi 下的另一台设备（如笔记本或局域网机器）上，输入主机的内网 IP 与 6 位 PIN；
   - 点击 **“开始双向同步”**，两端 SQLite 数据库将在毫秒内完成增量双向合并，无需经过任何公网服务器。

---

## 三、桌面端极客 CLI 命令行支持

DontForget 桌面端（Windows / macOS / Linux）支持无界面原生命令行静默录入与待办查询。

### 1. 快速录入待办 (`--add` / `-a`)
```bash
# 极速录入，自动分类至重点跟进，并智能设定默认提醒时间
dont_forget.exe --add "明天上午10点评审需求文档并通知研发团队"

# 简写形式
dont_forget.exe -a "下午2点给供应商付款"
```

### 2. 命令行查询待办清单 (`--list` / `-l`)
```bash
dont_forget.exe --list
```
输出示例：
```text
📋 Active Reminders (3):
  • [Q1] 紧急线上Bug修复 (Reminder: 2026-09-10 14:30)
  • [Q2] 明天上午10点评审需求文档并通知研发团队 (Reminder: 2026-09-10 09:45)
  • [Q3] 提交周报 (Reminder: 2026-09-12 18:00)
```

### 3. 命令行帮助 (`--help` / `-h`)
```bash
dont_forget.exe --help
```

---

## 四、认知干预与心理学辅助引擎说明

DontForget 3.0 集成了多项认知心理学机制：
- **反“社会懈怠 (Social Loafing)”**：卡片智能感知在重点跟进（Q2）中停滞超 24 小时的任务，提示“🧠 5分钟微习惯拆解”，将庞大任务拆解为极微、无痛启动的行动项；
- **“空船效应 (Empty Boat Effect)”**：当语音或文字输入带有情绪发泄、焦虑词汇时，AI 自动剥离情绪噪音，重构为平和有力的行动清单，并打上 `⛵ 空船效应已重构` 微标，大幅降低心理内耗。
