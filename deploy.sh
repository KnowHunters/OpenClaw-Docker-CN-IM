#!/usr/bin/env bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/KnowHunters/OpenClaw-Docker-CN-IM"
INSTALL_DIR_DEFAULT="$HOME/openclaw"
BRANCH_DEFAULT="main"
IMAGE_TAG_DEFAULT="openclaw-docker-cn-im:local"

# ════════════════════ 颜色定义 ════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ════════════════════ 全局配置 ════════════════════
SCRIPT_VERSION="2026.2.6-40"


# Initialize log file
LOG_FILE="/tmp/openclaw_deploy.log"
INSTALL_DIR="${INSTALL_DIR:-$INSTALL_DIR_DEFAULT}"
: > "$LOG_FILE"

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

# ════════════════════ 交互函数 ════════════════════

print_banner() {
    echo -e "${CYAN}"
    cat << EOF
    ╔══════════════════════════════════════════════════════════════════════════════╗
    ║                                                                              ║
    ║   ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗       ║
    ║  ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║       ║
    ║  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║       ║
    ║  ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║       ║
    ║  ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝       ║
    ║   ╚═════╝ ╚═╝     ╚══════╝╚╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝        ║
    ║                                                                              ║
    ║               Docker Deployment v${SCRIPT_VERSION}  by KnowHunters           ║
    ╚══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

spinner() {
    local pid=$1
    local msg=$2
    local delay=0.1
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    # 隐藏光标
    tput civis 2>/dev/null || true
    
    while kill -0 $pid 2>/dev/null; do
        printf "\r${BLUE}[%s]${NC} %s..." "${chars:$i:1}" "$msg"
        i=$(( (i+1) % ${#chars} ))
        sleep $delay
    done
}

run_step() {
    local msg="$1"
    local cmd="$2"
    local step_start=$(date +%s)
    
    # 记录日志
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] START: $msg" >> "$LOG_FILE"
    
    # 启动后台进程
    eval "$cmd" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    
    # 显示 Spinner
    spinner $pid "$msg"
    
    wait $pid
    local exit_code=$?
    local step_end=$(date +%s)
    local duration=$((step_end - step_start))
    
    # 恢复光标
    tput cnorm 2>/dev/null || true
    
    # 清除行并重写最终状态
    local time_str=""
    if [ $duration -ge 60 ]; then
        local min=$((duration / 60))
        local sec=$((duration % 60))
        time_str="${GRAY}(${min}m ${sec}s)${NC}"
    else
        time_str="${GRAY}(${duration}s)${NC}"
    fi
    
    if [ $exit_code -eq 0 ]; then
        echo -e "\r${GREEN}[✓]${NC} $msg $time_str"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DONE: $msg" >> "$LOG_FILE"
    else
        echo -e "\r${RED}[✗]${NC} $msg $time_str"
        echo -e "${RED}错误详情:${NC}"
        tail -n 15 "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAIL: $msg (Exit $exit_code)" >> "$LOG_FILE"
        exit $exit_code
    fi
}

log_info()  { echo -e "${CYAN}[i]${NC} $1"; echo "[INFO] $1" >> "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}[✓]${NC} $1"; echo "[OK] $1" >> "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; echo "[WARN] $1" >> "$LOG_FILE"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; echo "[ERROR] $1" >> "$LOG_FILE"; exit 1; }

# 兼容旧函数名
log() { log_info "$1"; }
warn() { log_warn "$1"; }
err() { log_error "$1"; }
ok() { log_ok "$1"; }
execute_task() { run_step "$1" "${*:2}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }

detect_os() {
  local name="unknown"
  local ver="unknown"
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    name="${NAME:-$ID}"
    ver="${VERSION_ID:-$VERSION}"
    OS_ID="$ID"
    OS_CODENAME="${VERSION_CODENAME:-}"
    # Fallback for systems without VERSION_CODENAME (like older CentOS)
    if [ -z "$OS_CODENAME" ]; then
      OS_CODENAME="$VERSION_ID"
    fi
  fi
  
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    SUDO_CMD=""
  else
    if ! command -v sudo >/dev/null 2>&1; then
      err "非 root 用户且未找到 sudo，无法继续"
      exit 1
    fi
    SUDO_CMD="sudo"
  fi
  
  log "检测到系统: ${name} ${ver} (ID=$OS_ID, CODENAME=$OS_CODENAME)"
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
      execute_task "重载系统服务配置" sudo systemctl daemon-reload
      execute_task "重启 Docker 服务" sudo systemctl restart docker
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
    execute_task "重启 Docker 服务" sudo systemctl restart docker
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
    execute_task "正在更新软件源" sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    execute_task "正在安装依赖 (${pkgs[*]})" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "${pkgs[@]}"
    return
  fi
  if need_cmd dnf; then
    require_sudo
    execute_task "正在安装依赖 (${pkgs[*]})" sudo dnf install -y "${pkgs[@]}"
    return
  fi
  if need_cmd yum; then
    require_sudo
    execute_task "正在安装依赖 (${pkgs[*]})" sudo yum install -y "${pkgs[@]}"
    return
  fi
  if need_cmd zypper; then
    require_sudo
    execute_task "正在安装依赖 (${pkgs[*]})" sudo zypper --non-interactive install "${pkgs[@]}"
    return
  fi
  if need_cmd pacman; then
    require_sudo
    execute_task "正在安装依赖 (${pkgs[*]})" sudo pacman -Sy --noconfirm "${pkgs[@]}"
    return
  fi
  if need_cmd apk; then
    require_sudo
    execute_task "正在安装依赖 (${pkgs[*]})" sudo apk add --no-cache "${pkgs[@]}"
    return
  fi
  err "未识别到受支持的包管理器，请手动安装依赖"
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
    execute_task "安装 Docker 依赖" $SUDO_CMD DEBIAN_FRONTEND=noninteractive apt-get update -y
    execute_task "安装基础工具" $SUDO_CMD DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    $SUDO_CMD install -m 0755 -d /etc/apt/keyrings
    
    # Fix: properly quote the command for execute_task so bash -c sees a single argument
    execute_task "添加 Docker GPG 密钥" "bash -c \"curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | $SUDO_CMD gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes\""
    $SUDO_CMD chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable" | $SUDO_CMD tee /etc/apt/sources.list.d/docker.list >/dev/null
    
    execute_task "更新软件源 (Docker)" $SUDO_CMD DEBIAN_FRONTEND=noninteractive apt-get update -y
    execute_task "安装 Docker Engine" $SUDO_CMD DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return
  fi

  if need_cmd dnf; then
    require_sudo
    execute_task "安装 Docker 依赖" sudo dnf -y install dnf-plugins-core
    execute_task "添加 Docker 源" sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    execute_task "安装 Docker Engine" sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return
  fi

  if need_cmd yum; then
    require_sudo
    execute_task "安装 Docker 依赖" sudo yum install -y yum-utils
    execute_task "添加 Docker 源" sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    execute_task "安装 Docker Engine" sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    return
  fi

  if need_cmd zypper; then
    require_sudo
    execute_task "安装 Docker" sudo zypper --non-interactive install docker docker-compose
    return
  fi

  if need_cmd pacman; then
    require_sudo
    execute_task "安装 Docker" sudo pacman -Sy --noconfirm docker docker-compose
    return
  fi

  if need_cmd apk; then
    require_sudo
    execute_task "安装 Docker" sudo apk add --no-cache docker docker-compose
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
    execute_task "启动 Docker 服务" sudo systemctl enable --now docker
  else
    execute_task "启动 Docker 服务" sudo service docker start
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
    log "检测到已有目录：$INSTALL_DIR"
    execute_task "正在更新仓库" git -C "$INSTALL_DIR" fetch --all --prune
    git -C "$INSTALL_DIR" checkout "$BRANCH" >/dev/null 2>&1 || true
    execute_task "拉取最新代码" git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
  elif [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    warn "目标目录已存在且非空：$INSTALL_DIR"
    if [[ "$(confirm_yesno "是否继续并在该目录中克隆？（可能失败）" "N")" =~ ^[Yy]$ ]]; then
      execute_task "正在克隆仓库" git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    else
      INSTALL_DIR="$(ask "请输入新的部署目录" "${INSTALL_DIR_DEFAULT}")"
      clone_or_update_repo
    fi
  else
    mkdir -p "$INSTALL_DIR"
    execute_task "正在克隆仓库" git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
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
    printf "${MAGENTA}[?]${NC} %s ${GRAY}[默认: %s]${NC}: " "$prompt" "$default" >&2
    read -r value
    value="${value:-$default}"
  else
    printf "${MAGENTA}[?]${NC} %s: " "$prompt" >&2
    read -r value
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
    printf "${MAGENTA}[?]${NC} %s ${GRAY}[默认: ******]${NC}: " "$prompt" >&2
    read -r -s value
    echo >&2
    value="${value:-$default}"
  else
    printf "${MAGENTA}[?]${NC} %s: " "$prompt" >&2
    read -r -s value
    echo >&2
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
  
  log_info "$prompt" >&2
  local i=1
  # Iterate pairs
  local args=("$@")
  for ((j=0; j<${#args[@]}; j+=2)); do
    echo "    $((j/2+1))) ${args[j]} - ${args[j+1]}" >&2
  done
  
  # Simple choice implementation for now since we don't have a complex menu selector in pure bash without TUI
  # But the original implementation was calling `ask`.
  # Let's clean up the prompt a bit.
  choice="$(ask "请输入选项" "$default")"
  printf "%s" "$choice"
}

confirm_yesno() {
  local prompt="$1"
  local default="${2:-N}"
  local default_prompt="y/N"
  if [ "$default" = "Y" ]; then
    default_prompt="Y/n"
  fi
  
  if [ "$use_tui" -eq 1 ]; then
    if whiptail --title "OpenClaw 一键部署" --yesno "$prompt" 10 70; then
      printf "Y"
    else
      printf "N"
    fi
    return
  fi
  
  printf "${MAGENTA}[?]${NC} %s ${GRAY}[%s]${NC}: " "$prompt" "$default_prompt" >&2
  read -r value
  value="${value:-$default}"
  printf "%s" "$value"
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

  
  local default_base_url="http://localhost:3000/v1"
  if [ "${INSTALL_AICLIENT:-0}" -eq 1 ]; then
    # AIClient 使用 Host 模式，OpenClaw 在容器内需要通过 host.docker.internal 访问宿主机
    default_base_url="http://host.docker.internal:3000/v1"
    log_info "检测到已安装 AIClient，推荐使用 Host 互联地址"
  fi

  while true; do
    BASE_URL="$(ask "API 地址 BASE_URL" "${BASE_URL:-$default_base_url}")"
    if validate_url "$BASE_URL"; then
      break
    fi
    warn "BASE_URL 格式不正确（需 http/https 开头）"
  done
  
  # API_KEY should be provided by user, no random default
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

  # Generate random Gateway Token for security
  local default_gw_token="$(openssl rand -hex 16 2>/dev/null || date +%s | md5sum | cut -c 1-32)"
  OPENCLAW_GATEWAY_TOKEN="$(ask "网关 Token OPENCLAW_GATEWAY_TOKEN" "${OPENCLAW_GATEWAY_TOKEN:-$default_gw_token}")"
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

  # Ensure override file exists to prevent startup error
  if [ ! -f "$INSTALL_DIR/docker-compose.override.yml" ]; then
    echo "services: {}" > "$INSTALL_DIR/docker-compose.override.yml"
  fi

  # Compose 文件加载顺序
  local compose_files="docker-compose.yml:docker-compose.override.yml"
  # 只有当安装了网络组件时才追加 network 文件
  if [ "${INSTALL_ZEROTIER:-0}" -eq 1 ] || [ "${INSTALL_TAILSCALE:-0}" -eq 1 ] || [ "${INSTALL_CLOUDFLARED:-0}" -eq 1 ] || [ "${INSTALL_FILEBROWSER:-0}" -eq 1 ] || [ "${INSTALL_AICLIENT:-0}" -eq 1 ]; then
    compose_files="$compose_files:docker-compose.network.yml"
  fi
  echo "COMPOSE_FILE=$compose_files" >> "$INSTALL_DIR/.env"
  
  # 保存安装状态标志，以便 modify config 时能恢复勾选
  cat >> "$INSTALL_DIR/.env" <<EOF

# Installation Flags (Internal)
INSTALL_ZEROTIER=${INSTALL_ZEROTIER:-0}
INSTALL_TAILSCALE=${INSTALL_TAILSCALE:-0}
INSTALL_CLOUDFLARED=${INSTALL_CLOUDFLARED:-0}
INSTALL_FILEBROWSER=${INSTALL_FILEBROWSER:-0}
INSTALL_AICLIENT=${INSTALL_AICLIENT:-0}
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
  log "局域网访问: http://$ip:$OPENCLAW_GATEWAY_PORT/?token=$OPENCLAW_GATEWAY_TOKEN"
  log "本机访问: http://127.0.0.1:$OPENCLAW_GATEWAY_PORT/?token=$OPENCLAW_GATEWAY_TOKEN"
  
  warn "[Firewall] 如果使用云服务器，请务必在安全组/防火墙中放行以下端口："
  warn "  - TCP $OPENCLAW_GATEWAY_PORT (OpenClaw 网关)"

  if [ "${INSTALL_AICLIENT:-0}" -eq 1 ]; then
    log ""
    log "AIClient-2-API (模型接入): http://$ip:3000"
    log "默认账号: admin / admin123"
    warn "  - TCP 3000 (AIClient 管理面板)"
    warn "  - TCP 8085-8087, 1455, 19876-19880 (OAuth 回调必要端口)"
  fi
  
  if [ "${INSTALL_FILEBROWSER:-0}" -eq 1 ]; then
    log ""
    log "FileBrowser (文件管理): http://$ip:$FILEBROWSER_PORT"
    log "默认账号: admin / admin"
    warn "  - TCP $FILEBROWSER_PORT (文件管理)"
  fi
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
  # Root check
  if [ "$(id -u)" != "0" ]; then
    warn "请使用 root 权限运行此脚本"
    exit 1
  fi

  print_banner
  
  CURRENT_STEP="prepare"
  detect_os
  install_git_curl
  check_network
  
  # 如果已安装 (.env 存在)，显示主菜单
  if [ -f "$INSTALL_DIR/.env" ]; then
    main_menu
  fi

  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GRAY}  [1/5] Docker 环境准备                                    ${NC}"
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"

  install_docker
  configure_docker_proxy
  configure_docker_mirror
  ensure_docker_running
  ensure_compose
  ensure_docker_permissions
  
  detect_cloud
  
  # Initialize wizard steps
  echo ""
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GRAY}  [2/5] 基础配置                                           ${NC}"
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  
  prompt_basic_settings
  
  # Step 2: Env Configuration
  prompt_env_collect
  
  echo ""
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GRAY}  [3/5] 网络配置 (可选)                                    ${NC}"
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  
  prompt_network_tools

  echo ""
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GRAY}  [4/5] 代码获取                                           ${NC}"
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  
  confirm_summary
  clone_or_update_repo
  
  echo ""
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GRAY}  [5/5] 构建与启动                                         ${NC}"
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  
  write_summary_file
  write_env_file
  generate_override_file
  generate_network_compose
  build_and_up
  health_check
  
  echo ""
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GRAY}  部署完成                                                 ${NC}"
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  
  show_next_steps
  if [[ "$(confirm_yesno "是否生成日志包用于排障？" "N")" =~ ^[Yy]$ ]]; then
    collect_logs_bundle
  fi
}

prompt_network_tools() {
  log "开始配置网络增强组件 (可选)"
  
  # ZeroTier
  if [[ "$(confirm_yesno "是否安装 ZeroTier (异地组网)?" "N")" =~ ^[Yy]$ ]]; then
    INSTALL_ZEROTIER=1
    ZEROTIER_ID="$(ask "ZeroTier Network ID (留空仅安装不加入)" "")"
  else
    INSTALL_ZEROTIER=0
  fi
  
  # Tailscale
  if [[ "$(confirm_yesno "是否安装 Tailscale (推荐组网神器)?" "N")" =~ ^[Yy]$ ]]; then
    INSTALL_TAILSCALE=1
    TAILSCALE_AUTHKEY="$(ask_secret "Tailscale Auth Key (留空需手动登录)" "")"
  else
    INSTALL_TAILSCALE=0
  fi
  
  # Cloudflare Tunnel
  if [[ "$(confirm_yesno "是否安装 Cloudflare Tunnel (内网穿透)?" "N")" =~ ^[Yy]$ ]]; then
    INSTALL_CLOUDFLARED=1
    CLOUDFLARED_TOKEN="$(ask_secret "Cloudflare Tunnel Token (必填)" "")"
    if [ -z "$CLOUDFLARED_TOKEN" ]; then
      warn "未提供 Token，将跳过 Cloudflare Tunnel 安装"
      INSTALL_CLOUDFLARED=0
    fi
  else
    INSTALL_CLOUDFLARED=0
  fi
  
  # FileBrowser
  if [[ "$(confirm_yesno "是否安装 FileBrowser (网页文件管理)?" "N")" =~ ^[Yy]$ ]]; then
    INSTALL_FILEBROWSER=1
    FILEBROWSER_PORT="$(ask "FileBrowser 端口" "8080")"
  else
    INSTALL_FILEBROWSER=0
  fi

  # AIClient-2-API
  if [[ "$(confirm_yesno "是否安装 AIClient-2-API (统一模型接入中间件)?" "N")" =~ ^[Yy]$ ]]; then
    INSTALL_AICLIENT=1
    log_info "AIClient-2-API 将使用 Host 网络模式，默认管理端口 3000"
  else
    INSTALL_AICLIENT=0
  fi
}

generate_network_compose() {
  if [ "$INSTALL_ZEROTIER" -eq 0 ] && [ "$INSTALL_TAILSCALE" -eq 0 ] && [ "$INSTALL_CLOUDFLARED" -eq 0 ] && [ "$INSTALL_FILEBROWSER" -eq 0 ] && [ "$INSTALL_AICLIENT" -eq 0 ]; then
    return
  fi
  
  log "正在生成网络组件配置..."
  cat > "$INSTALL_DIR/docker-compose.network.yml" <<EOF
services:
EOF

  if [ "$INSTALL_ZEROTIER" -eq 1 ]; then
    cat >> "$INSTALL_DIR/docker-compose.network.yml" <<EOF
  zerotier:
    image: zerotier/zerotier:latest
    container_name: zerotier
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
    devices:
      - /dev/net/tun
    volumes:
      - ./zerotier-data:/var/lib/zerotier-one
    ${ZEROTIER_ID:+environment:
      - ZEROTIER_JOIN_NETWORKS=$ZEROTIER_ID}

EOF
  fi

  if [ "$INSTALL_TAILSCALE" -eq 1 ]; then
    cat >> "$INSTALL_DIR/docker-compose.network.yml" <<EOF
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    volumes:
      - ./tailscale-data:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      ${TAILSCALE_AUTHKEY:+- TS_AUTHKEY=$TAILSCALE_AUTHKEY}
      - TS_USERSPACE=false

EOF
  fi

  if [ "$INSTALL_CLOUDFLARED" -eq 1 ]; then
    cat >> "$INSTALL_DIR/docker-compose.network.yml" <<EOF
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: always
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=$CLOUDFLARED_TOKEN

EOF
  fi
  
  if [ "$INSTALL_FILEBROWSER" -eq 1 ]; then
    cat >> "$INSTALL_DIR/docker-compose.network.yml" <<EOF
  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    restart: always
    user: "0:0"
    ports:
      - "$FILEBROWSER_PORT:80"
    volumes:
      - ./:/srv
      - ./filebrowser.db:/database.db

EOF
  fi

  if [ "$INSTALL_AICLIENT" -eq 1 ]; then
    cat >> "$INSTALL_DIR/docker-compose.network.yml" <<EOF
  aiclient:
    image: justlikemaki/aiclient-2-api:latest
    container_name: aiclient
    restart: always
    network_mode: host
    volumes:
      - ./aiclient-data:/app/configs
    # Host mode uses ports directly: 3000 (UI), 8085-8087 (OAuth), etc.

EOF
  fi
  
  # 如果安装了任何网络组件，为 OpenClaw Gateway 启用 host.docker.internal 解析
  # 这样 OpenClaw 才能通过 host.docker.internal 访问宿主机上的 AIClient (Host 模式)
  if [ "$INSTALL_AICLIENT" -eq 1 ] || [ "$INSTALL_FILEBROWSER" -eq 1 ]; then
    cat >> "$INSTALL_DIR/docker-compose.network.yml" <<EOF
  openclaw-gateway:
    extra_hosts:
      - "host.docker.internal:host-gateway"

EOF
  fi
  
  ok "已生成 docker-compose.network.yml"
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
        CURRENT_STEP="network"
        prompt_network_tools
        if [ "$use_tui" -eq 1 ]; then
          case "$(wizard_nav "网络组件配置完成")" in
            next) step=4 ;;
            back) step=2 ;;
            quit) exit 0 ;;
          esac
        else
          step=4
        fi
        ;;
      4)
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
            back) step=3 ;;
            quit) exit 0 ;;
          esac
        else
          local yn
          yn="$(confirm_yesno "确认写入 .env 并继续?" "Y")"
          if [[ "$yn" =~ ^[Yy]$ ]]; then
            write_env_file
            return
          else
            step=3
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


load_current_config() {
  if [ -f "$INSTALL_DIR/.env" ]; then
    log_info "正在加载当前配置..."
    # source .env safely
    set -a
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/.env"
    set +a
    
    # Reload INSTALL_* network flags from COMPOSE_FILE logic if possible, 
    # but easier to just let user re-select or we'd need to parse COMPOSE_FILE.
    # For now, let's just load env vars. Network tool selection state isn't saved in .env 
    # (except imply via COMPOSE_FILE), so user might need to re-select network tools if they modify config.
    # To improve this, we should save INSTALL_* vars to .env or a separate state file.
    # Let's save them to .env in write_env_file for future re-runs?
    # Yes, I will update write_env_file later to save INSTALL_* flags.
    # For now, we assume defaults (0) if not present.
    ok "配置已加载"
  else
    warn "未找到配置文件"
  fi
}

diagnostic_check() {
  # Load configuration to ensure variables like OPENCLAW_GATEWAY_PORT are set
  if [ -f "$INSTALL_DIR/.env" ]; then
    # Source directly to avoid noise, or use load_current_config function
    set -a
    source "$INSTALL_DIR/.env"
    set +a
  fi

  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GRAY}  OpenClaw 智能诊断                                        ${NC}"
  echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
  
  log_info "检查 Docker 容器状态..."
  cd "$INSTALL_DIR" || return
  if docker compose ps; then
    ok "容器列表获取成功"
  else
    warn "无法获取容器列表，请检查 Docker 是否运行"
  fi
  
  log_info "检查关键端口监听..."
  local ports_to_check=("$OPENCLAW_GATEWAY_PORT" "3000" "$FILEBROWSER_PORT")
  for p in "${ports_to_check[@]}"; do
    if [ -n "$p" ] && [ "$p" != "0" ]; then
      if check_port "$p"; then
        ok "端口 $p 正在监听 (正常)"
      else
        warn "端口 $p 未被监听 (如果该服务已启用，则可能未启动成功)"
      fi
    fi
  done
  
  log_info "检查环境变量配置..."
  if [ -f .env ]; then
    if grep -q "API_KEY=" .env; then
      ok "API_KEY 已配置"
    else
      warn "API_KEY 未找到"
    fi
    if grep -q "host.docker.internal" docker-compose.network.yml 2>/dev/null; then
      ok "Host 网络互联已配置"
    fi
  else
    warn ".env 文件不存在"
  fi
  
  echo ""
  read -r -p "诊断完成，按回车键返回..."
}

openclaw_cli_menu() {
  while true; do
    echo ""
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  OpenClaw CLI 工具箱                                      ${NC}"
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo " [1] 查看网关状态 (gateway status)"
    echo " [2] 健康检查 (gateway health)"
    echo " [3] 系统深度扫描 (gateway status --deep)"
    echo " [4] 系统医生 (doctor)"
    echo " [5] 查看实时日志 (logs --follow)"
    echo " [6] 返回上级菜单"
    echo ""
    local choice
    read -r -p "请选择执行命令 [1-6]: " choice
    
    local container_name="openclaw-gateway"
    # Verify container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
      warn "容器 $container_name 未运行，无法执行 CLI 命令"
      return
    fi

    case "$choice" in
      1)
        log_info "执行: openclaw gateway status"
        docker exec -it "$container_name" openclaw gateway status
        pause_key
        ;;
      2)
        log_info "执行: openclaw gateway health"
        docker exec -it "$container_name" openclaw gateway health
        pause_key
        ;;
      3)
        log_info "执行: openclaw gateway status --deep"
        docker exec -it "$container_name" openclaw gateway status --deep
        pause_key
        ;;
      4)
        log_info "执行: openclaw doctor"
        docker exec -it "$container_name" openclaw doctor
        pause_key
        ;;
      5)
        log_info "正在查看日志 (按 Ctrl+C 退出)..."
        docker exec -it "$container_name" openclaw logs --follow
        ;;
      6)
        return
        ;;
      *)
        warn "无效选择"
        sleep 1
        ;;
    esac
  done
  done
}

get_gateway_status() {
  if ! need_cmd docker; then
    echo -e "${RED}[🔴 Error] Docker 未安装${NC}"
    return
  fi
  
  if docker ps --format '{{.Names}}' | grep -q "^openclaw-gateway$"; then
    echo -e "${GREEN}[🟢 运行中] 网关服务${NC} (Port: ${OPENCLAW_GATEWAY_PORT:-18789})"
  # Check if container exists but stopped
  elif docker ps -a --format '{{.Names}}' | grep -q "^openclaw-gateway$"; then
    echo -e "${RED}[🔴 已停止] 网关服务${NC}"
  else
    echo -e "${GRAY}[⚪ 未安装] 网关服务${NC}"
  fi
}

main_menu() {
  # Load env to display port info
  if [ -f "$INSTALL_DIR/.env" ]; then
    set -a
    source "$INSTALL_DIR/.env" 2>/dev/null
    set +a
  fi

  while true; do
    clear
    echo -e "${BLUE}
   ____                    _____  _                  
  / __ \                  / ____|| |                 
 | |  | | _ __    ___   _ | |    | |   __ _ __      __
 | |  | || '_ \  / _ \ | || |    | |  / _\` |\ \ /\ / /
 | |__| || |_) ||  __/ | || |____| | | (_| | \ V  V / 
  \____/ | .__/  \___| |_| \_____||_|  \__,_|  \_/\_/  
         | |                                           
         |_|   Dashboard & Installer ${GRAY}v$SCRIPT_VERSION${NC}
"
    echo "当前安装目录: $INSTALL_DIR"
    echo "$(get_gateway_status)"
    echo ""
    echo " [1] 全新安装 / 强制重装"
    echo " [2] 修改当前配置 (重启服务)"
    echo " [3] 智能诊断 / 检查"
    echo " [4] 查看运行日志"
    echo " [5] 检查脚本更新"
    echo " [6] 退出脚本"
    echo ""
    read -r -p "请选择 [1-6]: " choice
    
    case "$choice" in
      1)
        if [[ "$(confirm_yesno "这将覆盖现有配置，确认重装?" "N")" =~ ^[Yy]$ ]]; then
          return 0 # Proceed to main installation flow
        fi
        ;;
      2)
        load_current_config
        # Jump to wizard
        run_wizard
        clone_or_update_repo # Update repo if needed
        generate_override_file
        generate_network_compose
        build_and_up
        show_next_steps
        pause_key
        ;;
      3)
        echo ""
        echo " [1] 自动智能诊断 (Auto Diagnostics)"
        echo " [2] OpenClaw 命令行工具 (CLI Tools)"
        echo " [3] 返回上级菜单"
        echo ""
        local diag_choice
        read -r -p "请选择: " diag_choice
        case "$diag_choice" in
          1) diagnostic_check ;;
          2) openclaw_cli_menu ;;
          *) ;;
        esac
        ;;
      4)
        collect_logs_bundle
        cd "$INSTALL_DIR" && docker compose logs -f --tail=100
        ;;
      5)
        check_self_update
        pause_key
        ;;
      6)
        exit 0
        ;;
      *)
        warn "无效选择"
        sleep 1
        ;;
    esac
  done
}

check_self_update() {
  if ! is_tty; then
    return
  fi
  log_info "正在检查脚本更新..."
  local raw_url=""
  # Use default REPO_URL if unbound, though it should be global. 
  # Using ${REPO_URL:-...} prevents set -u crash.
  local repo_url="${REPO_URL:-https://github.com/KnowHunters/OpenClaw-Docker-CN-IM.git}"
  local branch="${BRANCH:-main}"
  
  if [[ "$repo_url" =~ github.com/([^/]+)/([^/]+) ]]; then
    local owner="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    repo="${repo%.git}" # remove .git suffix if present
    raw_url="https://raw.githubusercontent.com/${owner}/${repo}/${branch}/deploy.sh"
  fi
  
  if [ -n "$raw_url" ]; then
    log "正在获取最新版本: $raw_url"
    if curl -fsSL "$raw_url" -o /tmp/deploy.sh.new; then
        # Simple string compare of version line
        local local_ver
        local remote_ver
        local_ver="$SCRIPT_VERSION"
        remote_ver="$(grep '^SCRIPT_VERSION=' /tmp/deploy.sh.new | cut -d'"' -f2)"
        
        if [ "$local_ver" != "$remote_ver" ]; then
            log "发现新版本: v$local_ver -> v${remote_ver:-unknown}"
            if [[ "$(confirm_yesno "是否更新脚本并重启?" "Y")" =~ ^[Yy]$ ]]; then
                cp /tmp/deploy.sh.new "$0"
                ok "脚本已更新，正在重启..."
                chmod +x "$0"
                exec bash "$0" "$@"
            else
                log "已取消更新"
            fi
        else
            ok "当前已是最新版本 ($local_ver)"
        fi
    else
        warn "下载更新失败"
    fi
  else
    warn "无法解析更新地址"
  fi
}
main "$@"
