#!/usr/bin/env bash
# =============================================================
#  OpenClaw WSL2 Ubuntu 一键部署脚本 (生产级增强版)
#  安装版本：v2026.3.28
#  特性：
#     - 防 APT 锁死 / 网络超时挂起
#     - NVM 环境强一致性保证
#     - 插件安装超时控制与自动修复
#     - WSL2 Systemd 缺失优雅降级
#     - 部署报告自动生成
# =============================================================

set -euo pipefail

# -------------------- 颜色定义 --------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# -------------------- 版本配置 --------------------
OPENCLAW_VERSION="2026.3.28"
CUSTOM_API_BASE="https://api-aigw.corp.hongsong.club/v1"
PROVIDER_ID="custom-api-aigw-corp-hongsong-club"

# -------------------- 通用函数 --------------------
info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[✅ OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[⚠️  WARN]${RESET} $*"; }
error()   { echo -e "${RED}[❌ ERR]${RESET}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${RESET}"; }

# JSON 转义函数
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# 带超时的下载函数
safe_download() {
    local url="$1"
    local output="$2"
    curl --connect-timeout 15 --max-time 300 --retry 2 -fsSL "$url" -o "$output"
}

# 美化输入框
input_box() {
    local title="$1"
    local var_name="$2"
    local is_secret="${3:-false}"
    echo -e "\n${CYAN}┌─────────────────────────────────────────┐${RESET}"
    echo -e "${CYAN}│${RESET} ${BOLD}${title}${RESET}"
    echo -e "${CYAN}└─────────────────────────────────────────┘${RESET}"
    if [[ "$is_secret" == "true" ]]; then
        read -rsp "  ➜ 请输入: " "$var_name"; echo
    else
        read -rp "  ➜ 请输入: " "$var_name"
    fi
}

# -------------------- 启动 Banner --------------------
clear
echo -e "${CYAN}"
cat << 'BANNER'
   ___                  ___ _               
  / _ \ _ __   ___ _ _ / __| |__ ___ __ __  
 | (_) | '_ \ / -_) ' \ (__| / _/ _ \ V  V /
  \___/| .__/ \___|_||_\___|_\__\___/\_/\_/ 
       |_|  WSL2 Ubuntu 一键部署脚本
              版本：2026.3.28 (生产级增强版)
BANNER
echo -e "${RESET}"
echo -e "${YELLOW}⚠️  版本说明：v2026.3.28 是重大架构升级版本${RESET}"
echo -e "${YELLOW}   - ClawHub 插件市场正式上线${RESET}"
echo -e "${YELLOW}   - Plugin SDK 完全重构 (openclaw/plugin-sdk/*)${RESET}"
echo -e "${YELLOW}   - 环境变量前缀统一为 OPENCLAW_*${RESET}"
echo -e "${YELLOW}   - 工作目录迁移至 ~/.openclaw${RESET}"
echo ""

# ---------- 提前优化 WSL2 环境：屏蔽自动更新以避免锁冲突 ----------
if grep -qi microsoft /proc/version 2>/dev/null; then
    info "检测到 WSL2 环境，尝试屏蔽后台自动更新服务..."
    sudo systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
fi

# ============================================================================
# STEP 1：基础工具检查 (curl / git / unzip / openssl) —— 生产级防卡死版
# ============================================================================
step "STEP 1 | 检查基础工具 (curl / git / unzip / openssl)"

robust_apt_install() {
    local pkg="$1"
    local max_wait=10
    local wait_sec=5

    info "尝试安装/更新: $pkg"

    # 等待 apt 锁释放
    for ((i=1; i<=max_wait; i++)); do
        if sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
           sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
           sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
            warn "APT 锁被占用，等待 ${wait_sec}s ... (尝试 $i/$max_wait)"
            sleep $wait_sec
        else
            break
        fi
    done

    # 强制清理残留僵死进程
    sudo pkill -9 -f "apt-get" 2>/dev/null || true
    sudo pkill -9 -f "apt" 2>/dev/null || true
    sleep 2

    # 修复 dpkg 中断状态
    sudo dpkg --configure -a --force-depends 2>/dev/null || true

    # 带超时安装
    if timeout 120 sudo apt-get install -y -qq "$pkg"; then
        success "$pkg 安装/更新成功"
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            error "APT 安装 $pkg 超时 (120秒)，请检查网络或 /etc/apt/sources.list"
        else
            error "$pkg 安装失败 (错误码: $exit_code)，请手动执行 sudo apt-get install $pkg 排查"
        fi
    fi
}

check_or_install() {
    if command -v "$1" &>/dev/null; then
        success "$1 已就绪"
    else
        warn "$1 未安装，正在安装..."
        sudo apt-get update -qq 2>/dev/null || true
        robust_apt_install "$1"
    fi
}

check_or_install curl
check_or_install git
check_or_install unzip
check_or_install openssl

# ============================================================================
# STEP 2：检查 Python (≥3.8)
# ============================================================================
step "STEP 2 | 检查 Python (≥3.8)"
if command -v python3 &>/dev/null; then
    PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if [[ $(echo "$PYTHON_VER" | awk -F. '{print $1}') -eq 3 && $(echo "$PYTHON_VER" | awk -F. '{print $2}') -ge 8 ]]; then
        success "Python $PYTHON_VER (≥3.8) 已安装"
    else
        warn "Python $PYTHON_VER 低于 3.8，将升级..."
        check_or_install python3
        check_or_install python3-pip
    fi
else
    warn "Python3 未安装，正在安装..."
    check_or_install python3
    check_or_install python3-pip
fi

# ============================================================================
# STEP 3：检查 Node.js (≥22) —— NVM 环境强化版
# ============================================================================
step "STEP 3 | 检查 Node.js (≥22)"

clean_npmrc_conflict() {
    if [[ -f "$HOME/.npmrc" ]]; then
        if grep -q "prefix" "$HOME/.npmrc" || grep -q "globalconfig" "$HOME/.npmrc"; then
            warn "检测到 .npmrc 中存在与 nvm 冲突的配置"
            info "备份原 .npmrc 到 $HOME/.npmrc.bak"
            cp "$HOME/.npmrc" "$HOME/.npmrc.bak"
            sed -i '/^prefix=/d' "$HOME/.npmrc" 2>/dev/null || true
            sed -i '/^globalconfig=/d' "$HOME/.npmrc" 2>/dev/null || true
            if [[ ! -s "$HOME/.npmrc" ]]; then
                rm -f "$HOME/.npmrc"
                success "已删除空的 .npmrc 文件"
            else
                success "已清理 .npmrc 中的冲突配置"
            fi
        fi
    fi
}

install_nvm() {
    local nvm_install_script="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh"
    local nvm_mirror="https://gitee.com/mirrors/nvm/raw/master/install.sh"
    
    info "正在安装 nvm..."
    clean_npmrc_conflict
    
    if safe_download "$nvm_install_script" /tmp/nvm_install.sh; then
        bash /tmp/nvm_install.sh
        return 0
    fi
    warn "GitHub 访问失败，尝试使用 Gitee 镜像..."
    if safe_download "$nvm_mirror" /tmp/nvm_install.sh; then
        bash /tmp/nvm_install.sh
        return 0
    fi
    error "无法下载 nvm 安装脚本，请手动安装 nvm：\n\
    1. 访问 https://gitee.com/mirrors/nvm\n\
    2. 或执行：curl -o- https://gitee.com/mirrors/nvm/raw/master/install.sh | bash"
}

load_nvm() {
    export NVM_DIR="$HOME/.nvm"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        \. "$NVM_DIR/nvm.sh" --no-use
        return 0
    else
        return 1
    fi
}

get_node_major() {
    # 优先使用 NVM 绝对路径版本，防止环境变量丢失
    if [[ -x "$NVM_DIR/versions/node/v22.22.2/bin/node" ]]; then
        "$NVM_DIR/versions/node/v22.22.2/bin/node" -e "process.stdout.write(String(process.version.match(/v(\d+)/)[1]))"
    elif command -v node &>/dev/null; then
        node -e "process.stdout.write(String(process.version.match(/v(\d+)/)[1]))"
    else
        echo "0"
    fi
}

CURRENT_NODE=$(get_node_major)
if [[ "$CURRENT_NODE" -ge 22 ]]; then
    success "Node.js $(node -v) (≥22) 已安装"
else
    [[ "$CURRENT_NODE" -gt "0" ]] \
        && warn "Node.js v$CURRENT_NODE 低于 22，将升级..." \
        || warn "Node.js 未安装，通过 nvm 安装..."
    
    clean_npmrc_conflict
    
    if [[ ! -d "$HOME/.nvm" ]]; then
        install_nvm
    fi
    
    load_nvm || error "nvm 加载失败，请检查 $HOME/.nvm 目录"
    
    export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
    
    info "正在安装 Node.js 22（使用国内镜像加速）..."
    if ! nvm install 22; then
        warn "国内镜像失败，尝试官方源..."
        unset NVM_NODEJS_ORG_MIRROR
        nvm install 22 || error "Node.js 22 安装失败"
    fi
    
    nvm use --delete-prefix v22.22.2 --silent 2>/dev/null || nvm use 22 || error "无法切换到 Node.js 22"
    nvm alias default 22
    
    # 更新 shell 配置
    for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$RC" ]]; then
            if ! grep -q 'NVM_DIR' "$RC"; then
                cat >> "$RC" << 'NVM_EOF'

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
NVM_EOF
                success "已更新 $RC"
            fi
        fi
    done
    
    # 确保当前 shell 路径正确
    export PATH="$NVM_DIR/versions/node/$(nvm current)/bin:$PATH"
    success "Node.js $(node -v) 安装完成"
fi

# 确保 npm 可用
command -v npm &>/dev/null || error "npm 命令未找到，请检查 Node.js 安装"
success "npm：v$(npm -v)"

if ! npm config get registry | grep -q "npmmirror"; then
    info "配置 npm 镜像加速（使用淘宝镜像）..."
    npm config set registry https://registry.npmmirror.com
    success "npm 镜像配置完成"
fi

# ============================================================================
# STEP 4：检查 Java (≥8)
# ============================================================================
step "STEP 4 | 检查 Java (≥8)"
if command -v java &>/dev/null; then
    JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | awk -F. '{print $1}')
    if [[ "$JAVA_VER" -ge 8 ]]; then
        success "Java $JAVA_VER (≥8) 已安装"
    else
        warn "Java $JAVA_VER 低于 8，将升级..."
        check_or_install openjdk-11-jre-headless
    fi
else
    warn "Java 未安装，正在安装 openjdk-11-jre-headless..."
    check_or_install openjdk-11-jre-headless
fi

# ============================================================================
# STEP 5：收集配置参数
# ============================================================================
step "STEP 5 | 收集配置参数"
info "API Base URL（固定）：$CUSTOM_API_BASE"
echo ""

input_box "1. API Key" "CUSTOM_API_KEY" false
[[ -z "$CUSTOM_API_KEY" ]] && error "API Key 不能为空"
CUSTOM_API_KEY_ESC=$(json_escape "$CUSTOM_API_KEY")

echo -e "\n${CYAN}┌─────────────────────────────────────────┐${RESET}"
echo -e "${CYAN}│${RESET} ${BOLD}2. 模型 ID${RESET}"
echo -e "${CYAN}│${RESET} 输入要使用的模型 ID，多个用空格分隔，第一个为默认主模型"
echo -e "${CYAN}│${RESET} ${YELLOW}必须与 API 服务端支持的模型名称完全一致${RESET}"
echo -e "${CYAN}│${RESET} 常用模型：MiniMax-M2.5  claude-opus-4-6  gpt-5.3-codex"
echo -e "${CYAN}└─────────────────────────────────────────┘${RESET}"
read -rp "  ➜ 请输入: " MODEL_IDS_INPUT
[[ -z "$MODEL_IDS_INPUT" ]] && error "至少填写一个模型 ID"
read -ra MODEL_IDS <<< "$MODEL_IDS_INPUT"
PRIMARY_MODEL="${MODEL_IDS[0]}"
PRIMARY_MODEL_ESC=$(json_escape "$PRIMARY_MODEL")
info "主模型：$PROVIDER_ID/$PRIMARY_MODEL"

echo -e "\n${CYAN}┌─────────────────────────────────────────┐${RESET}"
echo -e "${CYAN}│${RESET} ${BOLD}3. 飞书 Channel 配置${RESET}"
echo -e "${CYAN}└─────────────────────────────────────────┘${RESET}"
input_box "飞书机器人 App ID" "FEISHU_APP_ID" false
[[ -z "$FEISHU_APP_ID" ]] && error "App ID 不能为空"
FEISHU_APP_ID_ESC=$(json_escape "$FEISHU_APP_ID")

input_box "飞书机器人 App Secret" "FEISHU_APP_SECRET" false
[[ -z "$FEISHU_APP_SECRET" ]] && error "App Secret 不能为空"
FEISHU_APP_SECRET_ESC=$(json_escape "$FEISHU_APP_SECRET")

echo -e "\n${CYAN}┌─────────────────────────────────────────┐${RESET}"
echo -e "${CYAN}│${RESET} ${BOLD}4. 连接方式${RESET}"
echo -e "${CYAN}│${RESET} ${CYAN}1${RESET}) websocket（推荐）  ${CYAN}2${RESET}) longpolling"
echo -e "${CYAN}└─────────────────────────────────────────┘${RESET}"
read -rp "  ➜ 选择 [1/2，默认 1]: " CONN_CHOICE
case "${CONN_CHOICE:-1}" in
  2) CONNECTION_MODE="longpolling" ;;
  *) CONNECTION_MODE="websocket" ;;
esac
info "连接方式：$CONNECTION_MODE"

success "参数收集完成，开始部署..."

# ============================================================================
# STEP 6：安装 OpenClaw (指定版本)
# ============================================================================
step "STEP 6 | 安装 OpenClaw v${OPENCLAW_VERSION}"
info "正在安装 OpenClaw ${OPENCLAW_VERSION}..."
export NPM_CONFIG_FETCH_TIMEOUT=60000
export NPM_CONFIG_FETCH_RETRIES=2

if command -v openclaw &>/dev/null; then
  info "已安装 $(openclaw --version 2>/dev/null)，将更新到 ${OPENCLAW_VERSION}..."
  npm install -g "openclaw@${OPENCLAW_VERSION}" --unsafe-perm --loglevel=error
else
  npm install -g "openclaw@${OPENCLAW_VERSION}" --unsafe-perm --loglevel=error
fi

command -v openclaw &>/dev/null || error "OpenClaw 安装失败，请检查网络或 npm 权限"
INSTALLED_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
if [[ "$INSTALLED_VERSION" != *"${OPENCLAW_VERSION}"* ]]; then
  warn "安装的版本 ${INSTALLED_VERSION} 与目标版本 ${OPENCLAW_VERSION} 不完全匹配"
else
  success "OpenClaw：${INSTALLED_VERSION}"
fi

# ============================================================================
# STEP 7：生成 openclaw.json
# ============================================================================
step "STEP 7 | 写入配置 (~/.openclaw/openclaw.json)"
OPENCLAW_DIR="$HOME/.openclaw"
CONFIG_FILE="$OPENCLAW_DIR/openclaw.json"
mkdir -p "$OPENCLAW_DIR"

[[ -f "$CONFIG_FILE" ]] && {
  BAK="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$BAK"
  warn "原配置已备份至 $BAK"
}

# 构造 models 数组
MODELS_JSON="["
for i in "${!MODEL_IDS[@]}"; do
  M="${MODEL_IDS[$i]}"
  M_ESC=$(json_escape "$M")
  [[ $i -gt 0 ]] && MODELS_JSON+=","
  MODELS_JSON+=$(cat << MEOF
{
            "id": "$M_ESC",
            "name": "$M_ESC",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 200000,
            "maxTokens": 8192
          }
MEOF
)
done
MODELS_JSON+="]"

# 构造 alias map
ALIAS_MAP="{"
for i in "${!MODEL_IDS[@]}"; do
  M="${MODEL_IDS[$i]}"
  M_ESC=$(json_escape "$M")
  [[ $i -gt 0 ]] && ALIAS_MAP+=","
  ALIAS_MAP+="\"$PROVIDER_ID/$M_ESC\": {\"alias\": \"$M_ESC\"}"
done
ALIAS_MAP+="}"

GATEWAY_TOKEN=$(openssl rand -hex 24)

cat > "$CONFIG_FILE" << JSONEOF
{
  "models": {
    "mode": "merge",
    "providers": {
      "$PROVIDER_ID": {
        "baseUrl": "$CUSTOM_API_BASE",
        "apiKey": "$CUSTOM_API_KEY_ESC",
        "api": "anthropic-messages",
        "models": $MODELS_JSON
      }
    }
  },
  "agents": {
    "defaults": {
      "timeoutSeconds": 1200,
      "model": {
        "primary": "$PROVIDER_ID/$PRIMARY_MODEL_ESC"
      },
      "models": $ALIAS_MAP,
      "workspace": "$OPENCLAW_DIR/workspace",
      "compaction": {
        "mode": "safeguard"
      }
    }
  },
  "channels": {
    "feishu": {
      "enabled": true,
      "connectionMode": "$CONNECTION_MODE",
      "domain": "feishu",
      "groupPolicy": "open",
      "appId": "$FEISHU_APP_ID_ESC",
      "appSecret": "$FEISHU_APP_SECRET_ESC"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "$GATEWAY_TOKEN"
    }
  },
  "plugins": {
    "allow": ["openclaw-lark"],
    "entries": {
      "openclaw-lark": {
        "enabled": true
      }
    }
  },
  "tools": {
    "profile": "full"
  }
}
JSONEOF

[[ -f "$CONFIG_FILE" ]] || error "配置文件写入失败，请检查磁盘空间或权限"
success "配置文件写入完成：$CONFIG_FILE"

# ============================================================================
# STEP 8：安装网关服务（容错处理）
# ============================================================================
step "STEP 8 | 安装 OpenClaw 网关服务"
if command -v systemctl &>/dev/null && systemctl --user --quiet is-failed 2>/dev/null; then
    if openclaw gateway install; then
        success "网关服务安装完成"
    else
        warn "网关服务安装失败 (可能缺少 systemd 支持)"
        warn "WSL2 用户请手动启动: openclaw gateway start --daemon"
    fi
else
    warn "未检测到运行中的 Systemd，跳过服务安装。"
    info "生产环境请使用进程管理器 (如 pm2) 守护 openclaw gateway"
fi

# ============================================================================
# STEP 9：安装飞书插件（超时控制与自动修复）
# ============================================================================
step "STEP 9 | 安装飞书插件 (npx @larksuite/openclaw-lark install)"

export NPM_CONFIG_FETCH_TIMEOUT=60000
export NPM_CONFIG_FETCH_RETRIES=2

if timeout 180 npx --yes @larksuite/openclaw-lark install; then
    success "飞书插件安装成功"
else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
        error "插件安装超时 (180s)，请检查网络与 npm 源"
    else
        warn "插件安装异常，尝试修复依赖后重试..."
        PLUGIN_DIR=$(find "$HOME/.openclaw" -name "openclaw-lark" -type d 2>/dev/null | head -1)
        if [[ -n "$PLUGIN_DIR" && -f "$PLUGIN_DIR/package.json" ]]; then
            cd "$PLUGIN_DIR"
            npm cache clean --force 2>/dev/null || true
            npm install --prefer-offline --no-audit --no-fund --loglevel=error
            cd - > /dev/null
        fi
        if ! timeout 120 npx --yes @larksuite/openclaw-lark install; then
            error "飞书插件安装最终失败，请检查网络或手动执行：npx -y @larksuite/openclaw-lark install"
        fi
        success "飞书插件修复安装成功"
    fi
fi

if command -v openclaw &>/dev/null && openclaw plugins list 2>/dev/null | grep -qi "lark"; then
    success "飞书插件已被 OpenClaw 识别"
else
    warn "飞书插件安装完成，但尚未出现在插件列表中。启动网关后会自动加载。"
fi

# ============================================================================
# STEP 10：验证配置与连通性测试
# ============================================================================
step "STEP 10 | 验证配置与连通性"

# 预览配置（敏感值隐藏）
if command -v python3 &>/dev/null; then
  info "配置预览（敏感值已隐藏）："
  python3 - << PYEOF
import json, re
with open("$CONFIG_FILE") as f:
    raw = f.read()
masked = re.sub(r'("apiKey"|"appSecret"|"token"):\s*"([^"]{4,})"',
                lambda m: f'{m.group(1)}: "****{m.group(2)[-4:]}"', raw)
print(masked)
PYEOF
else
  warn "python3 未安装，无法预览配置内容"
fi

# API 连通性测试
info "测试 API 连通性 (超时 30s)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer $CUSTOM_API_KEY" \
  "$CUSTOM_API_BASE/models" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "401" ]]; then
    success "API 基础连通性验证通过 (HTTP $HTTP_CODE)"
else
    warn "API 连通性测试返回异常码: $HTTP_CODE，请检查 API Key 或网络"
fi

# 生成部署报告
ENV_REPORT="$OPENCLAW_DIR/deploy-report-$(date +%Y%m%d%H%M%S).log"
{
    echo "=== OpenClaw 部署报告 ==="
    echo "时间: $(date)"
    echo "版本: $(openclaw --version 2>&1)"
    echo "Node: $(node -v)"
    echo "NPM: $(npm -v)"
    echo "WSL2: $(grep -qi microsoft /proc/version && echo 'Yes' || echo 'No')"
    echo "Systemd: $(systemctl --version 2>/dev/null | head -1 || echo 'Not found')"
    echo "API测试码: $HTTP_CODE"
} > "$ENV_REPORT"
success "部署报告已保存至: $ENV_REPORT"

# ============================================================================
# 完成
# ============================================================================
echo ""
echo -e "${GREEN}${BOLD}"
cat << 'EOF'
╔══════════════════════════════════════════╗
║         🎉 OpenClaw 部署完成！            ║
║           版本：2026.3.28               ║
╚══════════════════════════════════════════╝
EOF
echo -e "${RESET}"
echo ""
echo -e "  ${BOLD}📌 v2026.3.28 重要提醒：${RESET}"
echo -e "     • 插件安装优先使用 ClawHub 市场"
echo -e "     • Plugin SDK 已变更为 openclaw/plugin-sdk/*"
echo -e "     • 环境变量前缀统一为 OPENCLAW_*"
echo -e "     • 工作目录统一为 ~/.openclaw"
echo ""
echo -e "  ${BOLD}下一步 — 启动 OpenClaw 网关：${RESET}"
echo -e "    openclaw gateway start"
echo -e "    关闭当前窗口重新打开加载环境变量"
echo ""
echo -e "  ${BOLD}管理命令：${RESET}"
echo -e "    openclaw channels status   # 查看通道状态"
echo -e "    openclaw logs              # 查看日志"
echo -e "    openclaw plugins list      # 列出插件"
echo -e "    openclaw doctor --fix      # 自动修复配置问题"
echo ""
