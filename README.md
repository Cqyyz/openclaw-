# OpenClaw WSL2 一键部署脚本

[![Shell](https://img.shields.io/badge/Shell-Bash-green)](https://www.gnu.org/software/bash/)
[![OpenClaw](https://img.shields.io/badge/OpenClaw-v2026.3.28-blue)](https://docs.openclaw.ai)
[![Platform](https://img.shields.io/badge/Platform-WSL2%20Ubuntu-orange)](https://learn.microsoft.com/en-us/windows/wsl/)

> 一条命令完成 OpenClaw + 飞书机器人的全套部署，适用于 WSL2 Ubuntu 环境。

## 功能概述

本脚本自动完成以下全部步骤：

| 步骤 | 说明 |
|------|------|
| 基础工具检查 | 自动安装 `curl` / `git` / `unzip` / `openssl` |
| Python 检查 | 确保 Python ≥ 3.8 |
| Node.js 安装 | 通过 nvm 安装 Node.js ≥ 22，自动处理 nvm 冲突 |
| Java 检查 | 确保 Java ≥ 8（openjdk-11） |
| OpenClaw 安装 | 安装指定版本 OpenClaw（v2026.3.28） |
| 配置生成 | 交互式收集参数，自动生成 `~/.openclaw/openclaw.json` |
| 网关服务安装 | 安装 systemd 网关服务 |
| 飞书插件安装 | 自动安装 `@larksuite/openclaw-lark` 并配置 |

## 前置准备

在运行脚本前，请准备好以下凭据：

| 凭据 | 获取方式 |
|------|----------|
| **API Key** | 从 LLM API 服务提供方获取 |
| **模型 ID** | 需与 API 服务端支持的模型名称完全一致，如 `claude-opus-4-6`、`gpt-5.3-codex` |
| **飞书 App ID** | [飞书开放平台](https://open.feishu.cn) → 创建企业自建应用 → 获取 |
| **飞书 App Secret** | 同上，创建应用后可在凭证页面查看 |

> **API Base URL 已内置**（`https://api-aigw.corp.hongsong.club/v1`），无需额外配置。

## 快速开始

```bash
# 1. 下载并运行
bash <(curl -fsSL https://raw.githubusercontent.com/Cqyyz/openclaw-/main/install.sh)

# 2. 按提示依次输入：API Key → 模型 ID → 飞书 App ID → App Secret → 连接方式

# 3. 部署完成后，启动网关
openclaw gateway start
```

## 脚本运行过程

```
   ___                  ___ _
  / _ \ _ __   ___ _ _ / __| |__ ___ __ __
 | (_) | '_ \ / -_) ' \(__| / _/ _ \ V  V /
  \___/| .__/ \___|_||_\___|_\__\___/\_/\_/
       |_|  WSL2 Ubuntu 一键部署脚本

━━━ STEP 1 | 检查基础工具 ━━━
━━━ STEP 2 | 检查 Python ━━━
━━━ STEP 3 | 检查 Node.js ━━━
━━━ STEP 4 | 检查 Java ━━━
━━━ STEP 5 | 收集配置参数 ━━━      ← 交互式输入
━━━ STEP 6 | 安装 OpenClaw ━━━
━━━ STEP 7 | 写入配置 ━━━
━━━ STEP 8 | 安装网关服务 ━━━
━━━ STEP 9 | 安装飞书插件 ━━━
━━━ STEP 10 | 验证配置 ━━━
```

## 配置说明

脚本会自动生成 `~/.openclaw/openclaw.json`，包含：

- **模型配置**：支持输入多个模型 ID（空格分隔），第一个为默认主模型
- **飞书通道**：支持 `websocket`（推荐）和 `longpolling` 两种连接方式
- **网关配置**：默认端口 `18789`，本地回环绑定，自动生成随机鉴权 Token
- **插件配置**：自动启用 `openclaw-lark` 飞书插件

## 部署后常用命令

```bash
openclaw gateway start        # 启动网关
openclaw gateway status       # 查看网关状态
openclaw channels status      # 查看通道（飞书）连接状态
openclaw plugins list         # 列出已安装插件
openclaw logs                 # 查看运行日志
openclaw doctor --fix         # 自动诊断并修复问题
```

## 注意事项

- 脚本使用 `set -euo pipefail`，任何步骤失败会自动终止
- 已有配置文件会自动备份为 `openclaw.json.bak.<时间戳>`
- npm 默认配置淘宝镜像加速（`npmmirror.com`），Node.js 下载同样使用国内镜像
- 首次启动前建议**重新打开终端**以加载 nvm 环境变量

## 版本信息

- **脚本目标版本**：OpenClaw v2026.3.28
- v2026.3.28 为重大架构升级版本：
  - ClawHub 插件市场正式上线
  - Plugin SDK 重构为 `openclaw/plugin-sdk/*`
  - 环境变量前缀统一为 `OPENCLAW_*`
  - 工作目录迁移至 `~/.openclaw`

## 许可证

MIT
