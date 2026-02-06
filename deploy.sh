#!/usr/bin/env bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/KnowHunters/OpenClaw-Docker-CN-IM"
INSTALL_DIR_DEFAULT="$HOME/openclaw"
BRANCH_DEFAULT="main"
IMAGE_TAG_DEFAULT="openclaw-docker-cn-im:local"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Icons
ICON_RUNNING="*"
ICON_SUCCESS="+"
ICON_ERROR="x"
ICON_WARN="!"

SCRIPT_VERSION="2026.2.6-2"

log() { printf "${BLUE}[ %s ]${NC} [openclaw] %s\n" "$ICON_RUNNING" "$*"; }
warn() { printf "${YELLOW}[ %s ]${NC} [openclaw] 警告: %s\n" "$ICON_WARN" "$*" >&2; }
err() { printf "${RED}[ %s ]${NC} [openclaw] 错误: %s\n" "$ICON_ERROR" "$*" >&2; }
ok() { printf "${GREEN}[ %s ]${NC} [openclaw] 完成: %s\n" "$ICON_SUCCESS" "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }

# Main execution start
# Try to re-attach to TTY for interactive usage
if [ ! -t 0 ] && [ -t 1 ]; then
  if [ -r /dev/tty ]; then
    exec < /dev/tty
  fi
fi

log "OpenClaw Deployment Script v$SCRIPT_VERSION"

HAS_TUI=0
use_tui=0
CURRENT_STEP="init"
STEP_PERCENT=0
RETRY_MAX=3

on_error() {
  local code=$?
  err "部署失败（步骤: $CURRENT_STEP，退出码: $code）"
  warn "常见原因："
  warn "1) Docker 未正确安装或服务未启动"
  warn "2) 网络无法访问 GitHub 或 Docker 源"
  warn "3) 当前用户无 Docker 权限（需要重新登录或使用 root）"
  warn "4) 端口被占用（请在交互中更换）"
  warn "如需诊断，可执行：docker info、docker compose logs -f"
  exit "$code"
}

trap on_error ERR

validate_url() {
  [[ "$1" =~ ^https?:// ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_nonempty() {
  [ -n "$1" ]
}

retry() {
  local n=0
  local cmd=("$@")
  until "${cmd[@]}"; do
    n=$((n+1))
    if [ "$n" -ge "$RETRY_MAX" ]; then
      return 1
    fi
    warn "命令失败，正在重试 ($n/$RETRY_MAX)..."
    sleep 2
  done
}

detect_cloud() {
  if curl -fsSL --connect-timeout 1 http://100.100.100.200/latest/meta-data/ >/dev/null 2>&1; then
    echo "aliyun"
    return
  fi
  if curl -fsSL --connect-timeout 1 http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
    echo "aws"
    return
  fi
  if curl -fsSL --connect-timeout 1 http://metadata.tencentyun.com/latest/meta-data/ >/dev/null 2>&1; then
    echo "tencent"
    return
  fi
  if curl -fsSL --connect-timeout 1 http://169.254.169.254/metadata/instance?api-version=2019-06-01 >/dev/null 2>&1; then
    echo "azure"
    return
  fi
  if curl -fsSL --connect-timeout 1 http://169.254.169.254/computeMetadata/v1/instance/ -H "Metadata-Flavor: Google" >/dev/null 2>&1; then
    echo "gcp"
    return
  fi
  echo "unknown"
}

detect_tui() {
  if need_cmd whiptail && is_tty; then
    HAS_TUI=1
    use_tui=1
  fi
}

detect_os() {
  local name="unknown"
  local ver="unknown"
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    name="${NAME:-$ID}"
    ver="${VERSION_ID:-$VERSION}"
  fi
  log "检测到系统: ${name} ${ver}"
}

check_network() {
  log "正在检查网络连接..."
  if need_cmd curl; then
    if ! curl -fsSL --connect-timeout 5 https://github.com >/dev/null 2>&1; then
      warn "无法访问 GitHub，请检查网络或代理"
    else
      ok "网络连接正常"
    fi
  fi
}

detect_proxy_env() {
  PROXY_HTTP="${http_proxy:-${HTTP_PROXY:-}}"
  PROXY_HTTPS="${https_proxy:-${HTTPS_PROXY:-}}"
}

configure_docker_proxy() {
  detect_proxy_env
  if [ -z "${PROXY_HTTP}${PROXY_HTTPS}" ]; then
    return
  fi
  if [[ "$(confirm_yesno "检测到代理环境变量，是否为 Docker 配置代理？" "Y")" =~ ^[Yy]$ ]]; then
    require_sudo
    sudo mkdir -p /etc/systemd/system/docker.service.d
    sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY_HTTP}"
Environment="HTTPS_PROXY=${PROXY_HTTPS}"
Environment="NO_PROXY=localhost,127.0.0.1"
EOF
    if need_cmd systemctl; then
      sudo systemctl daemon-reload
      sudo systemctl restart docker
    fi
    ok "已为 Docker 配置代理"
  fi
}

configure_docker_mirror() {
  local cloud
  cloud="$(detect_cloud)"
  local choice
  choice="$(confirm_yesno "是否为 Docker 配置镜像加速？" "Y")"
  if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    return
  fi
  local mirrors=""
  case "$cloud" in
    aliyun) mirrors="https://registry.cn-hangzhou.aliyuncs.com" ;;
    tencent) mirrors="https://mirror.ccs.tencentyun.com" ;;
    huawei) mirrors="https://repo.huaweicloud.com" ;;
    *)
      mirrors="https://registry.docker-cn.com"
      ;;
  esac
  require_sudo
  sudo mkdir -p /etc/docker
  if [ -f /etc/docker/daemon.json ] && need_cmd jq; then
    sudo jq ".\"registry-mirrors\"=[\"$mirrors\"]" /etc/docker/daemon.json > /tmp/daemon.json
    sudo mv /tmp/daemon.json /etc/docker/daemon.json
  else
    if [ -f /etc/docker/daemon.json ]; then
      sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
      warn "已备份原配置到 /etc/docker/daemon.json.bak"
    fi
    sudo tee /etc/docker/daemon.json >/dev/null <<EOF
{
  "registry-mirrors": ["$mirrors"]
}
EOF
  fi
  if need_cmd systemctl; then
    sudo systemctl restart docker
  fi
  ok "已配置 Docker 镜像加速: $mirrors"
}

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if need_cmd sudo; then
      log "正在请求 sudo 权限..."
      sudo -v
    else
      log "未检测到 sudo，请使用 root 用户运行脚本"
      exit 1
    fi
  fi
}

pkg_install() {
  local pkgs=("$@")
  if need_cmd apt-get; then
    require_sudo
    log "正在更新软件源..."
    sudo apt-get update -y
    log "正在安装依赖: ${pkgs[*]}..."
    sudo apt-get install -y "${pkgs[@]}"
    return
  fi
  if need_cmd dnf; then
    require_sudo
    log "正在安装依赖: ${pkgs[*]}..."
    sudo dnf install -y "${pkgs[@]}"
    return
  fi
  if need_cmd yum; then
    require_sudo
    log "正在安装依赖: ${pkgs[*]}..."
    sudo yum install -y "${pkgs[@]}"
    return
  fi
  if need_cmd zypper; then
    require_sudo
    log "正在安装依赖: ${pkgs[*]}..."
    sudo zypper --non-interactive install "${pkgs[@]}"
    return
  fi
  if need_cmd pacman; then
    require_sudo
    log "正在安装依赖: ${pkgs[*]}..."
    sudo pacman -Sy --noconfirm "${pkgs[@]}"
    return
  fi
  if need_cmd apk; then
    require_sudo
    log "正在安装依赖: ${pkgs[*]}..."
    sudo apk add --no-cache "${pkgs[@]}"
    return
  fi
  log "未识别到受支持的包管理器，请手动安装依赖"
  exit 1
}

install_git_curl() {
  if need_cmd git && need_cmd curl; then
    return
  fi
  log "正在安装 git 与 curl"
  pkg_install git curl ca-certificates
}

install_tui() {
  if need_cmd whiptail; then
    return
  fi
  log "正在安装 TUI 依赖（whiptail）"
  if need_cmd apt-get; then
    pkg_install whiptail
    return
  fi
  if need_cmd dnf; then
    pkg_install newt
    return
  fi
  if need_cmd yum; then
    pkg_install newt
    return
  fi
  if need_cmd zypper; then
    pkg_install dialog || true
    pkg_install whiptail || true
    return
  fi
  if need_cmd pacman; then
    pkg_install libnewt
    return
  fi
  if need_cmd apk; then
    pkg_install newt
    return
  fi
  warn "无法自动安装 TUI 组件，将回退为普通命令行交互"
}

install_docker() {
  if need_cmd docker; then
    return
  fi
  log "未检测到 Docker，开始自动安装"

  if need_cmd apt-get; then
    require_sudo
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return
  fi

  if need_cmd dnf; then
    require_sudo
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return
  fi

  if need_cmd yum; then
    require_sudo
    sudo yum install -y yum-utils
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return
  fi

  if need_cmd zypper; then
    require_sudo
    sudo zypper --non-interactive install docker docker-compose
    return
  fi

  if need_cmd pacman; then
    require_sudo
    sudo pacman -Sy --noconfirm docker docker-compose
    return
  fi

  if need_cmd apk; then
    require_sudo
    sudo apk add --no-cache docker docker-compose
    return
  fi

  log "无法自动安装 Docker，请手动安装后重试"
  exit 1
}

ensure_docker_group() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return
  fi
  if ! id -nG "$USER" | grep -q "\bdocker\b"; then
    require_sudo
    if getent group docker >/dev/null 2>&1; then
      sudo usermod -aG docker "$USER"
      warn "已将当前用户加入 docker 组，请重新登录后再运行脚本"
      warn "你也可以执行: newgrp docker"
      exit 0
    fi
  fi
}

ensure_docker_permissions() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return
  fi
  if ! id -nG "$USER" | grep -q "\bdocker\b"; then
    if [[ "$(confirm_yesno "是否将当前用户加入 docker 组（免 sudo）？" "Y")" =~ ^[Yy]$ ]]; then
      require_sudo
      if getent group docker >/dev/null 2>&1; then
        sudo usermod -aG docker "$USER"
        warn "已加入 docker 组，请重新登录后再运行脚本"
        warn "你也可以执行: newgrp docker"
        exit 0
      fi
    fi
  fi
}

ensure_docker_running() {
  require_sudo
  if need_cmd systemctl; then
    sudo systemctl enable --now docker
  else
    sudo service docker start || true
  fi

  if ! docker info >/dev/null 2>&1; then
    log "Docker 服务不可用，请检查安装状态"
    exit 1
  fi
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi
  if need_cmd docker-compose; then
    return
  fi
  log "未检测到 Docker Compose，尝试安装"
  install_docker
}

clone_or_update_repo() {
  CURRENT_STEP="clone"
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "检测到已有目录，正在更新仓库：$INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --all --prune
    git -C "$INSTALL_DIR" checkout "$BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
  elif [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    warn "目标目录已存在且非空：$INSTALL_DIR"
    if [[ "$(confirm_yesno "是否继续并在该目录中克隆？（可能失败）" "N")" =~ ^[Yy]$ ]]; then
      git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    else
      INSTALL_DIR="$(ask "请输入新的部署目录" "${INSTALL_DIR_DEFAULT}")"
      clone_or_update_repo
    fi
  else
    log "正在克隆仓库到：$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi
}

gauge() {
  local percent="$1"
  local msg="$2"
  STEP_PERCENT="$percent"
  if [ "$use_tui" -eq 1 ]; then
    {
      echo "$percent"
      echo "XXX"
      echo "$msg"
      echo "XXX"
    } | whiptail --title "OpenClaw 一键部署" --gauge "部署进行中..." 8 70 0
  else
    log "$msg"
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [ "$use_tui" -eq 1 ]; then
    value="$(whiptail --title "OpenClaw 一键部署" --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3 || true)"
    if [ -z "$value" ]; then
      value="$default"
    fi
    printf "%s" "$value"
    return
  fi
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt: " value
  fi
  printf "%s" "$value"
}

ask_secret() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [ "$use_tui" -eq 1 ]; then
    value="$(whiptail --title "OpenClaw 一键部署" --passwordbox "$prompt" 10 70 3>&1 1>&2 2>&3 || true)"
    if [ -z "$value" ] && [ -n "$default" ]; then
      value="$default"
    fi
    printf "%s" "$value"
    return
  fi
  if [ -n "$default" ]; then
    read -r -s -p "$prompt [$default]: " value
    echo
    value="${value:-$default}"
  else
    read -r -s -p "$prompt: " value
    echo
  fi
  printf "%s" "$value"
}

choose_menu() {
  local prompt="$1"
  local default="$2"
  shift 2
  local choice=""
  if [ "$use_tui" -eq 1 ]; then
    choice="$(whiptail --title "OpenClaw 一键部署" --menu "$prompt" 12 70 6 "$@" 3>&1 1>&2 2>&3 || true)"
    if [ -z "$choice" ]; then
      choice="$default"
    fi
    printf "%s" "$choice"
    return
  fi
  log "$prompt"
  while [ "$#" -gt 0 ]; do
    log "$1) $2"
    shift 2
  done
  choice="$(ask "请选择" "$default")"
  printf "%s" "$choice"
}

confirm_yesno() {
  local prompt="$1"
  local default="${2:-N}"
  if [ "$use_tui" -eq 1 ]; then
    if whiptail --title "OpenClaw 一键部署" --yesno "$prompt" 10 70; then
      printf "Y"
    else
      printf "N"
    fi
    return
  fi
  ask "$prompt (y/N)" "$default"
}

pretty_header() {
  if [ "$use_tui" -eq 1 ]; then
    whiptail --title "OpenClaw 一键部署" --msgbox "欢迎使用 OpenClaw 一键部署向导\n\n将帮助你完成下载、配置、构建与启动。" 10 70
  else
    log "欢迎使用 OpenClaw 一键部署向导"
  fi
}

show_textbox() {
  local title="$1"
  local text="$2"
  if [ "$use_tui" -eq 1 ]; then
    printf "%s" "$text" > /tmp/openclaw_preview.txt
    whiptail --title "$title" --textbox /tmp/openclaw_preview.txt 20 80
    rm -f /tmp/openclaw_preview.txt
  else
    log "$title"
    printf "%s\n" "$text"
  fi
}

prompt_basic_settings() {
  local repo_default="${REPO_URL:-$REPO_URL_DEFAULT}"
  local dir_default="${INSTALL_DIR:-$INSTALL_DIR_DEFAULT}"
  local branch_default="${BRANCH:-$BRANCH_DEFAULT}"
  local image_default="${IMAGE_TAG:-$IMAGE_TAG_DEFAULT}"
  if is_tty; then
    while true; do
      REPO_URL="$(ask "Git 仓库地址" "$repo_default")"
      if validate_url "$REPO_URL"; then
        break
      fi
      warn "仓库地址格式不正确，请输入 http/https 开头的地址"
    done
    INSTALL_DIR="$(ask "下载/部署目录" "$dir_default")"
    BRANCH="$(ask "分支" "$branch_default")"
    IMAGE_TAG="$(ask "镜像标签" "$image_default")"
  else
    REPO_URL="$repo_default"
    INSTALL_DIR="$dir_default"
    BRANCH="$branch_default"
    IMAGE_TAG="$image_default"
    log "非交互环境，使用默认参数"
  fi
}

check_port() {
  local port="$1"
  if need_cmd ss; then
    ss -lnt | awk '{print $4}' | grep -q ":$port$" && return 1 || return 0
  fi
  if need_cmd lsof; then
    lsof -i TCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 1 || return 0
  fi
  return 0
}

port_usage_detail() {
  local port="$1"
  if need_cmd ss; then
    ss -lntp | grep ":$port" || true
  elif need_cmd lsof; then
    lsof -i TCP:"$port" -sTCP:LISTEN || true
  fi
}

find_available_port() {
  local start="$1"
  local p="$start"
  local i=0
  while [ "$i" -lt 50 ]; do
    if check_port "$p"; then
      printf "%s" "$p"
      return
    fi
    p=$((p+1))
    i=$((i+1))
  done
  printf "%s" "$start"
}

confirm_summary() {
  log "即将开始部署，参数如下："
  log "仓库: $REPO_URL"
  log "分支: $BRANCH"
  log "目录: $INSTALL_DIR"
  log "镜像: $IMAGE_TAG"
  if is_tty; then
    local yn
    yn="$(confirm_yesno "确认继续?" "Y")"
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
      log "已取消"
      exit 0
    fi
  fi
}

prompt_env_collect() {
  log "开始交互式生成 .env"

  while true; do
    MODEL_ID="$(ask "模型名称 MODEL_ID" "${MODEL_ID:-gemini-3-flash-preview}")"
    if validate_nonempty "$MODEL_ID"; then
      break
    fi
    warn "MODEL_ID 不能为空"
  done
  while true; do
    BASE_URL="$(ask "API 地址 BASE_URL" "${BASE_URL:-http://localhost:3000/v1}")"
    if validate_url "$BASE_URL"; then
      break
    fi
    warn "BASE_URL 格式不正确（需 http/https 开头）"
  done
  API_KEY="$(ask_secret "API 密钥 API_KEY" "${API_KEY:-}")"
  if [ -z "$API_KEY" ]; then
    warn "API_KEY 为空，可能导致无法调用模型"
  fi

  local proto_choice
  proto_choice="$(choose_menu "选择 API 协议" "openai-completions" \
    "openai-completions" "OpenAI/Gemini 等" \
    "anthropic-messages" "Claude")"
  if [ "$proto_choice" = "anthropic-messages" ]; then
    API_PROTOCOL="anthropic-messages"
  else
    API_PROTOCOL="openai-completions"
  fi

  CONTEXT_WINDOW="$(ask "上下文窗口 CONTEXT_WINDOW" "${CONTEXT_WINDOW:-1000000}")"
  MAX_TOKENS="$(ask "最大输出 MAX_TOKENS" "${MAX_TOKENS:-8192}")"

  local yn
  yn="$(confirm_yesno "是否配置 Telegram?" "N")"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    TELEGRAM_BOT_TOKEN="$(ask_secret "TELEGRAM_BOT_TOKEN" "${TELEGRAM_BOT_TOKEN:-}")"
  fi

  yn="$(confirm_yesno "是否配置飞书?" "N")"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    FEISHU_APP_ID="$(ask "FEISHU_APP_ID" "${FEISHU_APP_ID:-}")"
    FEISHU_APP_SECRET="$(ask_secret "FEISHU_APP_SECRET" "${FEISHU_APP_SECRET:-}")"
  fi

  yn="$(confirm_yesno "是否配置钉钉?" "N")"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    DINGTALK_CLIENT_ID="$(ask "DINGTALK_CLIENT_ID" "${DINGTALK_CLIENT_ID:-}")"
    DINGTALK_CLIENT_SECRET="$(ask_secret "DINGTALK_CLIENT_SECRET" "${DINGTALK_CLIENT_SECRET:-}")"
    DINGTALK_ROBOT_CODE="$(ask "DINGTALK_ROBOT_CODE（默认=CLIENT_ID）" "${DINGTALK_ROBOT_CODE:-$DINGTALK_CLIENT_ID}")"
    DINGTALK_CORP_ID="$(ask "DINGTALK_CORP_ID（可留空）" "${DINGTALK_CORP_ID:-}")"
    DINGTALK_AGENT_ID="$(ask "DINGTALK_AGENT_ID（可留空）" "${DINGTALK_AGENT_ID:-}")"
  fi

  yn="$(confirm_yesno "是否配置 QQ 机器人?" "N")"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    QQBOT_APP_ID="$(ask "QQBOT_APP_ID" "${QQBOT_APP_ID:-}")"
    QQBOT_CLIENT_SECRET="$(ask_secret "QQBOT_CLIENT_SECRET" "${QQBOT_CLIENT_SECRET:-}")"
  fi

  yn="$(confirm_yesno "是否配置企业微信?" "N")"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    WECOM_TOKEN="$(ask "WECOM_TOKEN" "${WECOM_TOKEN:-}")"
    WECOM_ENCODING_AES_KEY="$(ask_secret "WECOM_ENCODING_AES_KEY" "${WECOM_ENCODING_AES_KEY:-}")"
  fi

  OPENCLAW_GATEWAY_TOKEN="$(ask "网关 Token OPENCLAW_GATEWAY_TOKEN" "${OPENCLAW_GATEWAY_TOKEN:-123456}")"
  OPENCLAW_GATEWAY_BIND="$(ask "网关绑定 OPENCLAW_GATEWAY_BIND" "${OPENCLAW_GATEWAY_BIND:-lan}")"
  while true; do
    OPENCLAW_GATEWAY_PORT="$(ask "网关端口 OPENCLAW_GATEWAY_PORT" "${OPENCLAW_GATEWAY_PORT:-18789}")"
    if ! validate_port "$OPENCLAW_GATEWAY_PORT"; then
      warn "端口格式不正确，请输入 1-65535 之间的数字"
      continue
    fi
    if check_port "$OPENCLAW_GATEWAY_PORT"; then
      break
    fi
    local suggested
    suggested="$(find_available_port "$OPENCLAW_GATEWAY_PORT")"
    warn "端口 $OPENCLAW_GATEWAY_PORT 已被占用，推荐可用端口: $suggested"
    port_usage_detail "$OPENCLAW_GATEWAY_PORT" | sed 's/^/[占用] /'
    if [[ "$(confirm_yesno "是否使用推荐端口 $suggested ?" "Y")" =~ ^[Yy]$ ]]; then
      OPENCLAW_GATEWAY_PORT="$suggested"
    fi
  done
  while true; do
    OPENCLAW_BRIDGE_PORT="$(ask "桥接端口 OPENCLAW_BRIDGE_PORT" "${OPENCLAW_BRIDGE_PORT:-18790}")"
    if ! validate_port "$OPENCLAW_BRIDGE_PORT"; then
      warn "端口格式不正确，请输入 1-65535 之间的数字"
      continue
    fi
    if check_port "$OPENCLAW_BRIDGE_PORT"; then
      break
    fi
    local suggested2
    suggested2="$(find_available_port "$OPENCLAW_BRIDGE_PORT")"
    warn "端口 $OPENCLAW_BRIDGE_PORT 已被占用，推荐可用端口: $suggested2"
    port_usage_detail "$OPENCLAW_BRIDGE_PORT" | sed 's/^/[占用] /'
    if [[ "$(confirm_yesno "是否使用推荐端口 $suggested2 ?" "Y")" =~ ^[Yy]$ ]]; then
      OPENCLAW_BRIDGE_PORT="$suggested2"
    fi
  done
}

env_preview_text() {
  cat <<EOF
部署参数：
仓库: $REPO_URL
分支: $BRANCH
目录: $INSTALL_DIR
镜像: $IMAGE_TAG

模型配置：
MODEL_ID=$MODEL_ID
BASE_URL=$BASE_URL
API_PROTOCOL=$API_PROTOCOL
CONTEXT_WINDOW=$CONTEXT_WINDOW
MAX_TOKENS=$MAX_TOKENS

通道配置：
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:+已设置}
FEISHU_APP_ID=${FEISHU_APP_ID:+已设置}
DINGTALK_CLIENT_ID=${DINGTALK_CLIENT_ID:+已设置}
QQBOT_APP_ID=${QQBOT_APP_ID:+已设置}
WECOM_TOKEN=${WECOM_TOKEN:+已设置}

Gateway：
OPENCLAW_GATEWAY_TOKEN=已设置
OPENCLAW_GATEWAY_BIND=$OPENCLAW_GATEWAY_BIND
OPENCLAW_GATEWAY_PORT=$OPENCLAW_GATEWAY_PORT
OPENCLAW_BRIDGE_PORT=$OPENCLAW_BRIDGE_PORT
EOF
}

write_env_file() {
  mkdir -p "$INSTALL_DIR"
  cat > "$INSTALL_DIR/.env" <<EOF
# OpenClaw Docker 环境变量配置（由部署脚本生成）

# Docker 镜像配置
OPENCLAW_IMAGE=$IMAGE_TAG

# 模型配置
MODEL_ID=$MODEL_ID
BASE_URL=$BASE_URL
API_KEY=$API_KEY
API_PROTOCOL=$API_PROTOCOL
CONTEXT_WINDOW=$CONTEXT_WINDOW
MAX_TOKENS=$MAX_TOKENS

# Telegram 配置（可选）
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}

# 飞书配置（可选）
FEISHU_APP_ID=${FEISHU_APP_ID:-}
FEISHU_APP_SECRET=${FEISHU_APP_SECRET:-}

# 钉钉配置（可选）
DINGTALK_CLIENT_ID=${DINGTALK_CLIENT_ID:-}
DINGTALK_CLIENT_SECRET=${DINGTALK_CLIENT_SECRET:-}
DINGTALK_ROBOT_CODE=${DINGTALK_ROBOT_CODE:-}
DINGTALK_CORP_ID=${DINGTALK_CORP_ID:-}
DINGTALK_AGENT_ID=${DINGTALK_AGENT_ID:-}

# QQ 机器人配置（可选）
QQBOT_APP_ID=${QQBOT_APP_ID:-}
QQBOT_CLIENT_SECRET=${QQBOT_CLIENT_SECRET:-}

# 企业微信配置（可选）
WECOM_TOKEN=${WECOM_TOKEN:-}
WECOM_ENCODING_AES_KEY=${WECOM_ENCODING_AES_KEY:-}

# 工作空间配置（不要更改）
WORKSPACE=/home/node/.openclaw/workspace

# 挂载目录配置（按实际更改）
OPENCLAW_DATA_DIR=~/.openclaw

# Gateway 配置
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN
OPENCLAW_GATEWAY_BIND=$OPENCLAW_GATEWAY_BIND
OPENCLAW_GATEWAY_PORT=$OPENCLAW_GATEWAY_PORT
OPENCLAW_BRIDGE_PORT=$OPENCLAW_BRIDGE_PORT
EOF

  log ".env 已生成: $INSTALL_DIR/.env"
}

build_and_up() {
  CURRENT_STEP="build"
  cd "$INSTALL_DIR"

  if [ ! -f .env ]; then
    if is_tty && [ "$use_tui" -eq 1 ]; then
      run_wizard
    elif is_tty; then
      prompt_env_collect
      show_textbox "配置预览" "$(env_preview_text)"
      local yn
      yn="$(confirm_yesno "确认写入 .env 并继续?" "Y")"
      if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        log "已取消"
        exit 0
      fi
      write_env_file
    else
      log "未检测到 .env，但当前非交互环境，已从 .env.example 生成"
      cp .env.example .env
      log "请在生产环境中编辑 .env 填写模型与平台凭证"
    fi
  fi

  gauge 70 "开始构建 Docker 镜像"
  retry docker build -t "$IMAGE_TAG" .

  if docker compose version >/dev/null 2>&1; then
    gauge 90 "使用 docker compose 启动"
    retry bash -c "OPENCLAW_IMAGE=\"$IMAGE_TAG\" docker compose up -d"
  else
    gauge 90 "使用 docker-compose 启动"
    retry bash -c "OPENCLAW_IMAGE=\"$IMAGE_TAG\" docker-compose up -d"
  fi

  gauge 100 "部署完成"
  log "部署完成，可用以下命令查看日志：docker compose logs -f"
}

health_check() {
  CURRENT_STEP="health"
  local host="127.0.0.1"
  local port="$OPENCLAW_GATEWAY_PORT"
  gauge 95 "进行健康检查"
  for i in 1 2 3 4 5; do
    if (echo >/dev/tcp/$host/$port) >/dev/null 2>&1; then
      ok "端口 $port 可访问"
      return
    fi
    sleep 2
  done
  warn "健康检查未通过，端口 $port 仍不可访问"
  if docker compose version >/dev/null 2>&1; then
    docker compose logs --tail=200 || true
  else
    docker-compose logs --tail=200 || true
  fi
}

write_summary_file() {
  local summary_path="$INSTALL_DIR/deploy-summary.txt"
  env_preview_text > "$summary_path"
  log "已生成部署摘要: $summary_path"
}

show_next_steps() {
  local ip="127.0.0.1"
  if need_cmd hostname; then
    local hip
    hip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$hip" ]; then
      ip="$hip"
    fi
  fi
  log "访问提示："
  log "局域网访问: http://$ip:$OPENCLAW_GATEWAY_PORT"
  log "本机访问: http://127.0.0.1:$OPENCLAW_GATEWAY_PORT"
  log "Token: $OPENCLAW_GATEWAY_TOKEN"
}

collect_logs_bundle() {
  local bundle="$INSTALL_DIR/deploy-logs-$(date +%Y%m%d-%H%M%S).tar.gz"
  local tmpdir
  tmpdir="$(mktemp -d)"
  env_preview_text > "$tmpdir/summary.txt"
  docker info > "$tmpdir/docker-info.txt" 2>&1 || true
  if docker compose version >/dev/null 2>&1; then
    docker compose logs --tail=500 > "$tmpdir/compose-logs.txt" 2>&1 || true
    docker compose config > "$tmpdir/compose-config.txt" 2>&1 || true
  else
    docker-compose logs --tail=500 > "$tmpdir/compose-logs.txt" 2>&1 || true
    docker-compose config > "$tmpdir/compose-config.txt" 2>&1 || true
  fi
  tar -czf "$bundle" -C "$tmpdir" .
  rm -rf "$tmpdir"
  ok "已生成日志包: $bundle"
}

main() {
  log "开始检测并准备环境"
  CURRENT_STEP="prepare"
  detect_os
  install_git_curl
  check_network
  
  log "检查 TUI 环境..."
  install_tui
  detect_tui
  
  log "显示欢迎界面..."
  pretty_header
  
  prompt_basic_settings
  check_self_update
  
  gauge 20 "环境准备完成，开始安装 Docker"
  install_docker
  configure_docker_proxy
  configure_docker_mirror
  ensure_docker_running
  ensure_compose
  ensure_docker_permissions
  gauge 40 "Docker 就绪，开始确认参数"
  confirm_summary
  gauge 50 "开始获取代码"
  clone_or_update_repo
  gauge 60 "生成部署摘要"
  write_summary_file
  generate_override_file
  build_and_up
  health_check
  show_next_steps
  if [[ "$(confirm_yesno "是否生成日志包用于排障？" "N")" =~ ^[Yy]$ ]]; then
    collect_logs_bundle
  fi
}

wizard_nav() {
  local prompt="$1"
  if [ "$use_tui" -eq 1 ]; then
    local choice
    choice="$(whiptail --title "OpenClaw 一键部署" --menu "$prompt" 12 70 6 \
      "next" "继续" \
      "back" "返回上一步" \
      "quit" "退出" 3>&1 1>&2 2>&3 || true)"
    printf "%s" "${choice:-quit}"
    return
  fi
  printf "next"
}

run_wizard() {
  local step=1
  while true; do
    case "$step" in
      1)
        CURRENT_STEP="basic"
        prompt_basic_settings
        if [ "$use_tui" -eq 1 ]; then
          case "$(wizard_nav "基础设置完成")" in
            next) step=2 ;;
            back) step=1 ;;
            quit) exit 0 ;;
          esac
        else
          step=2
        fi
        ;;
      2)
        CURRENT_STEP="env"
        prompt_env_collect
        if [ "$use_tui" -eq 1 ]; then
          case "$(wizard_nav "模型与通道配置完成")" in
            next) step=3 ;;
            back) step=1 ;;
            quit) exit 0 ;;
          esac
        else
          step=3
        fi
        ;;
      3)
        CURRENT_STEP="preview"
        show_textbox "配置预览" "$(env_preview_text)"
        if [ "$use_tui" -eq 1 ]; then
          local choice
          choice="$(whiptail --title "OpenClaw 一键部署" --menu "确认写入 .env 并继续？" 12 70 6 \
            "write" "确认写入并继续" \
            "back" "返回修改" \
            "quit" "退出" 3>&1 1>&2 2>&3 || true)"
          case "${choice:-quit}" in
            write)
              write_env_file
              return
              ;;
            back) step=2 ;;
            quit) exit 0 ;;
          esac
        else
          local yn
          yn="$(confirm_yesno "确认写入 .env 并继续?" "Y")"
          if [[ "$yn" =~ ^[Yy]$ ]]; then
            write_env_file
            return
          else
            step=2
          fi
        fi
        ;;
    esac
  done
}

generate_override_file() {
  if [[ "$(confirm_yesno "是否生成 docker-compose.override.yml（资源限制/自定义）？" "N")" =~ ^[Yy]$ ]]; then
    local cpus mem
    cpus="$(ask "CPU 限制（例如 2.0，留空不限制）" "")"
    mem="$(ask "内存限制（例如 2g，留空不限制）" "")"
    cat > "$INSTALL_DIR/docker-compose.override.yml" <<EOF
services:
  openclaw-gateway:
    ${cpus:+cpus: "$cpus"}
    ${mem:+mem_limit: "$mem"}
EOF
    ok "已生成 docker-compose.override.yml"
  fi
}

check_self_update() {
  if ! is_tty; then
    return
  fi
  if [[ "$(confirm_yesno "是否检查并更新部署脚本？" "N")" =~ ^[Yy]$ ]]; then
    local raw_url=""
    if [[ "$REPO_URL" =~ github.com/([^/]+)/([^/]+) ]]; then
      local owner="${BASH_REMATCH[1]}"
      local repo="${BASH_REMATCH[2]}"
      raw_url="https://raw.githubusercontent.com/${owner}/${repo}/${BRANCH}/deploy.sh"
    fi
    if [ -n "$raw_url" ]; then
      log "正在更新脚本: $raw_url"
      curl -fsSL "$raw_url" -o /tmp/deploy.sh.new
      if [ -s /tmp/deploy.sh.new ]; then
        cp /tmp/deploy.sh.new "$0"
        ok "脚本已更新，请重新运行"
        exit 0
      fi
    else
      warn "无法解析脚本更新地址"
    fi
  fi
}
main "$@"
