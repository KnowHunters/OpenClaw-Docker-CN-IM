#!/bin/bash
# ╔════════════════════════════════════════════════════════════════════╗
# ║  OpenClaw Deploy - 终极版一键部署脚本                             ║
# ║  版本: 1.0.0 | 许可: MIT | 作者: KnowHunters (知识猎人)            ║
# ║  功能: 交互式配置 | 多模型预设 | 监控套件 | 自动备份               ║
# ║  GitHub: https://github.com/KnowHunters/openclaw-deploy            ║
# ╚════════════════════════════════════════════════════════════════════╝
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/KnowHunters/openclaw-deploy/main/install.sh | sudo bash
#   curl ... | sudo bash -s -- -n              # 非交互模式
#   curl ... | sudo bash -s -- -u              # 仅更新

set -e

# ════════════════════ 全局配置 ════════════════════
VERSION="1.0.3"
OPENCLAW_USER="openclaw"
WORKSPACE_DIR="/home/$OPENCLAW_USER/openclaw-bot"
SCRIPTS_DIR="/home/$OPENCLAW_USER/openclaw-scripts"
CONFIG_FILE="/home/$OPENCLAW_USER/.openclaw/openclaw.json"
NODE_MAJOR=22
MIN_RAM_MB=4096
TZ="Asia/Shanghai"

# 网关默认值 (安全优先: 仅本地访问)
DEFAULT_BIND="127.0.0.1"
DEFAULT_PORT="18789"
GATEWAY_BIND=${GATEWAY_BIND:-$DEFAULT_BIND}
GATEWAY_PORT=${GATEWAY_PORT:-$DEFAULT_PORT}

# 模式标记
NON_INTERACTIVE=false
UPDATE_MODE=false
START_TIME=$(date +%s)

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

# ════════════════════ 辅助函数 ════════════════════

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔══════════════════════════════════════════════════════════════════════════════╗
    ║                                                                              ║
    ║   ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗       ║
    ║  ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║       ║
    ║  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║       ║
    ║  ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║       ║
    ║  ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝       ║
    ║   ╚═════╝ ╚═╝     ╚══════╝╚╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝        ║
    ║                                                                              ║
    ║                    D E P L O Y   v1.0  by KnowHunters                        ║
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
    
    # 恢复光标在 run_step 结束时处理
}

run_step() {
    local msg="$1"
    local cmd="$2"
    local step_start=$(date +%s)
    
    # 启动后台进程
    eval "$cmd" > /tmp/openclaw_install.log 2>&1 &
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
    # \033[K = 清除光标后所有内容
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
    else
        echo -e "\r${RED}[✗]${NC} $msg $time_str"
        echo -e "${RED}错误详情:${NC}"
        tail -n 15 /tmp/openclaw_install.log
        exit 1
    fi
}

log_info()  { echo -e "${CYAN}[i]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# 错误捕获
cleanup_trap() {
    if [ $? -ne 0 ]; then
        echo -e "\n${RED}安装中断！${NC} 详情: /tmp/openclaw_install.log"
    fi
}
trap cleanup_trap EXIT

# ════════════════════ 参数解析 ════════════════════
print_usage() {
    cat <<EOF
OpenClaw 部署脚本 v${VERSION}

用法:
  curl ... | sudo bash -s -- [选项]

选项:
  --help, -h               显示帮助
  --fast, -f               快速模式 (跳过非关键确认)
  --update, -u             更新模式 (保留数据)
  --mirror <url>           使用自定义 NPM 镜像源
  --version <tag>          安装指定版本的 OpenClaw CLI (默认: latest)

示例:
  sudo bash install.sh --fast --mirror https://registry.npmmirror.com
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            print_usage
            exit 0
            ;;
        --fast|-n|-f)
            NON_INTERACTIVE=true
            ;;
        --update|-u)
            UPDATE_MODE=true
            ;;
        --mirror)
            if [ -n "$2" ]; then
                export npm_config_registry="$2"
                log_info "使用 NPM 镜像: $2"
                shift
            fi
            ;;
        --version)
            if [ -n "$2" ]; then
                CLI_VERSION="$2"
                shift
            fi
            ;;
        *)
            log_warn "未知参数: $1 (已忽略)"
            ;;
    esac
    shift
done

# ════════════════════ 安装确认菜单 ════════════════════
check_existing_installation() {
    if [ -f "$CONFIG_FILE" ] && [ "$NON_INTERACTIVE" = false ] && [ "$UPDATE_MODE" = false ]; then
        echo ""
        log_warn "检测到已有 OpenClaw 安装"
        echo ""
        echo "  1) 更新 OpenClaw (保留配置)"
        echo "  2) 完全重装 (需要确认)"
        echo "  3) 取消"
        echo ""
        read -p "请选择 [1-3]: " INSTALL_CHOICE
        
        case "$INSTALL_CHOICE" in
            1)
                UPDATE_MODE=true
                log_info "切换到更新模式"
                ;;
            2)
                echo ""
                log_warn "⚠ 危险操作：完全重装将删除所有配置！"
                read -p "确认删除？请输入 'DELETE' 确认: " CONFIRM
                if [ "$CONFIRM" != "DELETE" ]; then
                    log_info "已取消"
                    exit 0
                fi
                # 备份后删除
                local BACKUP_DIR="/home/$OPENCLAW_USER/openclaw-backups"
                mkdir -p "$BACKUP_DIR"
                local BACKUP_FILE="$BACKUP_DIR/pre-reinstall-$(date +%Y%m%d_%H%M%S).tar.gz"
                tar -czf "$BACKUP_FILE" -C "/home/$OPENCLAW_USER" .openclaw 2>/dev/null || true
                log_ok "配置已备份至: $BACKUP_FILE"
                rm -rf "/home/$OPENCLAW_USER/.openclaw"
                ;;
            *)
                log_info "已取消"
                exit 0
                ;;
        esac
    fi
}

# ════════════════════ 系统预检 ════════════════════
pre_flight_check() {
    echo ""
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  [1/6] 系统环境预检                                       ${NC}"
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    
    [ "$EUID" -ne 0 ] && log_error "必须使用 root 权限运行"
    
    run_step "检测网络连通性" "curl -sI https://github.com >/dev/null && curl -sI https://registry.npmjs.org >/dev/null"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "操作系统: $PRETTY_NAME"
        [ "$ID" != "ubuntu" ] && log_warn "本脚本针对 Ubuntu 优化，其他系统可能存在兼容性问题"
    fi
    
    log_info "部署目标: $OPENCLAW_USER @ $GATEWAY_BIND:$GATEWAY_PORT"
}

ensure_user_exists() {
    if id "$OPENCLAW_USER" &>/dev/null; then
        log_info "用户 $OPENCLAW_USER 已存在"
    else
        run_step "创建运行用户 ($OPENCLAW_USER)" "useradd -m -s /bin/bash $OPENCLAW_USER"
    fi
}

fix_node_permissions() {
    log_info "正在检查并修复关键文件权限..."
    # 修复 Node 二进制权限 (解决 PM2 spawn EACCES)
    # 遍历常见的 Node 路径，不管 which 结果如何，确保所有可能的 binary 都有执行权限
    local node_path
    local resolved
    local which_node
    local node_candidates=("/usr/bin/node" "/usr/local/bin/node" "/usr/bin/nodejs")

    which_node=$(command -v node 2>/dev/null || true)
    if [ -n "$which_node" ]; then
        node_candidates+=("$which_node")
    fi

    for node_path in "${node_candidates[@]}"; do
        [ -n "$node_path" ] || continue
        if [ -f "$node_path" ]; then
            chmod +x "$node_path"
            resolved=$(readlink -f "$node_path" 2>/dev/null || true)
            if [ -n "$resolved" ] && [ "$resolved" != "$node_path" ] && [ -f "$resolved" ]; then
                chmod +x "$resolved"
            fi
        fi
    done
    

}

# 优化: Git 配置安全检查 (防止用户本地 insteadOf 配置导致 clone 失败)
fix_git_github_config() {
    local github_ssh_config
    github_ssh_config="$(git config --global --get url."git@github.com:".insteadOf 2>/dev/null || true)"

    if [[ -n "$github_ssh_config" ]]; then
        log_warn "检测到 Git 全局 GitHub 配置，可能导致 HTTPS 克隆失败"
        log_info "正在临时禁用此配置..."
        git config --global --unset url."git@github.com:".insteadOf 2>/dev/null || true
        export GIT_CONFIG_BACKUP_VALUE="$github_ssh_config"
        trap restore_git_github_config EXIT
    fi
}

restore_git_github_config() {
    if [[ -n "$GIT_CONFIG_BACKUP_VALUE" ]]; then
        git config --global url."git@github.com:".insteadOf "$GIT_CONFIG_BACKUP_VALUE" 2>/dev/null || true
        log_info "已恢复 Git 全局 GitHub 配置"
    fi
}

ensure_openclaw_bin_link() {
    # 确保 /usr/local/bin/openclaw 软链存在且有效
    if ! command -v openclaw &>/dev/null; then
        local npm_root="$(sudo -u $OPENCLAW_USER npm root -g 2>/dev/null)"
        if [[ -f "$npm_root/openclaw/bin/openclaw" ]]; then
             ln -sf "$npm_root/openclaw/bin/openclaw" /usr/local/bin/openclaw
             log_ok "已修复 openclaw 命令链接"
        elif [[ -f "$npm_root/openclaw/dist/entry.js" ]]; then
             # Fallback logic if bin not found directly
             ln -sf "$npm_root/openclaw/dist/entry.js" /usr/local/bin/openclaw
             log_ok "已修复 openclaw 命令链接 (entry.js)"
        fi
    fi
}

# 优化: 严格的 Node 版本检查
verify_node_version() {
    if command -v node &>/dev/null; then
        local version=$(node -v | sed 's/v//' | cut -d. -f1)
        if [ "$version" -lt 22 ]; then
            log_error "检测到 Node.js v$version，但 OpenClaw 需要 Node.js v22+"
        else
            log_ok "Node.js 版本检查通过 ($(node -v))"
        fi
    fi
}

# 优化: 自动迁移与诊断
run_doctor() {
    if command -v openclaw &>/dev/null; then
        echo ""
        log_info "正在执行自动诊断与迁移..."
        if sudo -u $OPENCLAW_USER openclaw doctor --non-interactive; then
            log_ok "诊断与迁移完成"
        else
            log_warn "诊断过程中发现部分问题，建议后续手动运行 'claw doctor'"
        fi
    fi
}

# ════════════════════ 系统调优 ════════════════════

optimize_system() {
    [ "$UPDATE_MODE" = true ] && return
    
    echo ""
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  [2/6] 系统调优                                           ${NC}"
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    
    # Timezone
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
    if [ "$CURRENT_TZ" != "$TZ" ]; then
        run_step "设置时区 ($TZ)" "timedatectl set-timezone $TZ"
    else
        log_ok "时区已正确 ($CURRENT_TZ)"
    fi
    
    # Swap
    TOTAL_MEM=$(free -m | awk 'NR==2{print $2}')
    if [ "$TOTAL_MEM" -lt "$MIN_RAM_MB" ]; then
        SWAP_EXIST=$(free -m | awk 'NR==3{print $2}')
        if [ "$SWAP_EXIST" -eq 0 ]; then
            run_step "创建 2GB Swap" "
                fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
                chmod 600 /swapfile
                mkswap /swapfile
                swapon /swapfile
                grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            "
        fi
    fi
}

# ════════════════════ 依赖安装 ════════════════════
install_dependencies() {
    echo ""
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  [3/6] 依赖安装                                           ${NC}"
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    
    if [ "$UPDATE_MODE" = true ]; then
        run_step "准备 NPM 前缀目录" "mkdir -p /home/$OPENCLAW_USER/.npm-global && chown $OPENCLAW_USER:$OPENCLAW_USER /home/$OPENCLAW_USER/.npm-global"
        run_step "设置 NPM 前缀" "sudo -u $OPENCLAW_USER npm config set prefix '/home/$OPENCLAW_USER/.npm-global'"
        run_step "配置 NPM PATH" "if ! grep -q 'npm-global/bin' /home/$OPENCLAW_USER/.bashrc; then echo 'export PATH=/home/$OPENCLAW_USER/.npm-global/bin:\$PATH' >> /home/$OPENCLAW_USER/.bashrc; fi"
        run_step "更新 OpenClaw CLI" "sudo -u $OPENCLAW_USER npm install -g openclaw@latest"
        return
    fi
    
    export DEBIAN_FRONTEND=noninteractive
    
    # 系统库
    run_step "更新软件源" "apt-get update -qq"
    run_step "安装基础组件" "apt-get install -yqq curl wget git build-essential ca-certificates gnupg lsb-release jq unzip"
    run_step "安装开发工具" "apt-get install -yqq ripgrep fd-find bat htop tree"
    run_step "安装媒体工具" "apt-get install -yqq ffmpeg imagemagick graphicsmagick tesseract-ocr poppler-utils"
    run_step "安装 Python 环境" "apt-get install -yqq python3-full python3-pip python3-venv"
    
    # 软链修正
    [ ! -f /usr/bin/fd ] && ln -sf $(which fdfind) /usr/bin/fd 2>/dev/null || true
    [ ! -f /usr/bin/bat ] && ln -sf $(which batcat) /usr/bin/bat 2>/dev/null || true
    
    # Python AI 库
    run_step "安装 Python AI 工具" "pip3 install --upgrade yt-dlp pandas numpy beautifulsoup4 --break-system-packages"
    
    # GitHub CLI
    if ! command -v gh &>/dev/null; then
        local ARCH=$(dpkg --print-architecture)
        run_step "安装 GitHub CLI" "
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
            echo 'deb [arch=${ARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            apt-get update -qq && apt-get install -yqq gh
        "
    fi
    
    # Chromium (Ubuntu 24.04 使用 snap 安装)
    if ! command -v chromium-browser &>/dev/null && ! command -v chromium &>/dev/null; then
        run_step "安装 Chromium 浏览器" "
            apt-get install -yqq snapd || true
            snap install chromium
        "
    fi
    
    # Node.js
    if ! command -v node &>/dev/null; then
        run_step "安装 Node.js v$NODE_MAJOR" "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && apt-get install -yqq nodejs"
    fi
    
    verify_node_version
    
    # OpenClaw CLI


    # 确保 NPM 用户前缀目录存在
    run_step "准备 NPM 前缀目录" "mkdir -p /home/$OPENCLAW_USER/.npm-global && chown $OPENCLAW_USER:$OPENCLAW_USER /home/$OPENCLAW_USER/.npm-global"

    # 确保 NPM 用户前缀已设置（避免权限问题）
    run_step "设置 NPM 前缀" "sudo -u $OPENCLAW_USER npm config set prefix '/home/$OPENCLAW_USER/.npm-global'"
    run_step "配置 NPM PATH" "if ! grep -q 'npm-global/bin' /home/$OPENCLAW_USER/.bashrc; then echo 'export PATH=/home/$OPENCLAW_USER/.npm-global/bin:\$PATH' >> /home/$OPENCLAW_USER/.bashrc; fi"
    local cli_pkg="openclaw@${CLI_VERSION:-latest}"
    if [ -n "$npm_config_registry" ]; then
        run_step "安装 OpenClaw CLI ($cli_pkg)" "sudo -u $OPENCLAW_USER npm install -g $cli_pkg --registry=$npm_config_registry"
    else
        run_step "安装 OpenClaw CLI ($cli_pkg)" "sudo -u $OPENCLAW_USER npm install -g $cli_pkg"
    fi

    # Linuxbrew (Homebrew) - 解决 Skill 依赖问题 (camsnap, gog 等)
    if [ ! -d "/home/linuxbrew/.linuxbrew" ]; then
        run_step "准备 Linuxbrew 目录" "
            mkdir -p /home/linuxbrew/.linuxbrew
            chown -R $OPENCLAW_USER:$OPENCLAW_USER /home/linuxbrew
        "
        
        run_step "安装 Linuxbrew (耗时较长)" "
            su - $OPENCLAW_USER -c 'NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"'
        "
        
        run_step "配置 Linuxbrew 环境" "
            echo 'eval \"\$(\/home/linuxbrew\/.linuxbrew\/bin\/brew shellenv)\"' >> /home/$OPENCLAW_USER/.bashrc
            echo 'eval \"\$(\/home/linuxbrew\/.linuxbrew\/bin\/brew shellenv)\"' >> /home/$OPENCLAW_USER/.profile
        "
    else
        log_ok "Linuxbrew 已安装"
    fi
    
    # 将 brew 加入当前 PATH 供后续步骤使用
    if [ -d "/home/linuxbrew/.linuxbrew/bin" ]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
}

# ════════════════════ 部署工作区 ════════════════════
prepare_workspace() {
    echo ""
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  [4/6] 准备工作区                                         ${NC}"
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    
    run_step "初始化目录结构" "
        mkdir -p $WORKSPACE_DIR
        mkdir -p $SCRIPTS_DIR
        mkdir -p /home/$OPENCLAW_USER/.openclaw
        chown -R $OPENCLAW_USER:$OPENCLAW_USER /home/$OPENCLAW_USER
    "
    
    # 可选备份
    if [ -f "$WORKSPACE_DIR/package.json" ] && [ "$UPDATE_MODE" = false ]; then
        if [ "$NON_INTERACTIVE" = false ]; then
            echo ""
            log_warn "检测到现有安装"
            read -p "是否创建备份? [Y/n] " BACKUP_REPLY
            if [[ ! $BACKUP_REPLY =~ ^[Nn]$ ]]; then
                local BACKUP_NAME="backup_$(date +%Y%m%d_%H%M%S)"
                log_info "备份至 ${WORKSPACE_DIR}_$BACKUP_NAME..."
                cp -r "$WORKSPACE_DIR" "${WORKSPACE_DIR}_$BACKUP_NAME"
            fi
    fi
    fi

}

# ════════════════════ 管理优化套件 ════════════════════
install_monitoring_scripts() {
    echo ""
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  [5/6] 下载管理优化套件                                       ${NC}"
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    
    local scripts=("health-monitor.sh" "log-cleanup.sh" "backup.sh" "restore.sh" "manager.sh")
    for script in "${scripts[@]}"; do
        run_step "下载 $script" "curl -fsSL https://raw.githubusercontent.com/KnowHunters/openclaw-deploy/main/scripts/$script -o $SCRIPTS_DIR/$script"
        chmod +x "$SCRIPTS_DIR/$script"
        chown "$OPENCLAW_USER:$OPENCLAW_USER" "$SCRIPTS_DIR/$script"
    done
    
    # 创建全局快捷指令 (claw -> manager)
    ln -sf "$SCRIPTS_DIR/manager.sh" /usr/local/bin/claw
    chmod +x /usr/local/bin/claw
    log_ok "已创建全局指令: claw"

    # 创建全局快捷指令 (openclaw -> npm binary)
    # 注意: 这里使用具体路径，因为 PATH 可能未包含 npm bin
    # 注意: 这里使用具体路径，因为 PATH 可能未包含 npm bin
    ln -sf "/home/$OPENCLAW_USER/.npm-global/bin/openclaw" /usr/local/bin/openclaw
    log_ok "已创建全局指令: openclaw"
    
    # 配置 Cron 任务 (日志清理)
    run_step "配置日志自动清理" "(crontab -l 2>/dev/null | grep -v 'log-cleanup.sh'; echo '0 2 * * * $SCRIPTS_DIR/log-cleanup.sh >> $WORKSPACE_DIR/logs/cleanup.log 2>&1') | crontab -"
}

# ════════════════════ 基础设施配置 (不启动服务) ════════════════════
setup_infrastructure() {
    echo ""
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GRAY}  [6/6] 基础设施配置                                       ${NC}"
    echo -e "${GRAY}═══════════════════════════════════════════════════════════${NC}"

    # 创建空的 .env 文件 (仅当不存在时)
    if [ ! -f "$WORKSPACE_DIR/.env" ]; then
        touch "$WORKSPACE_DIR/.env"
        chown "$OPENCLAW_USER:$OPENCLAW_USER" "$WORKSPACE_DIR/.env"
        chmod 600 "$WORKSPACE_DIR/.env"
    fi

    # 配置 Systemd 服务
    local SYSTEMD_FILE="/etc/systemd/system/openclaw.service"
    local CLAW_BIN="/home/$OPENCLAW_USER/.npm-global/bin/openclaw"
    local CONFIG_DIR="/home/$OPENCLAW_USER/.openclaw"
    
    # 预生成默认配置文件 (防止服务启动失败)
    run_step "初始化默认配置" "
        mkdir -p $CONFIG_DIR
        if [ ! -f $CONFIG_DIR/openclaw.json ]; then
            # 生成随机 Token (48字符 hex)
            local generated_token=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -A n -t x1 | tr -d ' \n')
            
            cat > $CONFIG_DIR/openclaw.json <<JSON
{
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "$generated_token"
    },
    "port": $GATEWAY_PORT,
    "bind": "loopback",
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    }
  }
}
JSON
            log_info "已生成默认配置 (Token: ${generated_token:0:6}...)"
        fi
        chown -R $OPENCLAW_USER:$OPENCLAW_USER $CONFIG_DIR
    "

    run_step "注册 Systemd 服务" "
        cat > $SYSTEMD_FILE <<EOF
[Unit]
Description=OpenClaw AI Gateway
After=network.target

[Service]
Type=simple
User=$OPENCLAW_USER
Group=$OPENCLAW_USER
WorkingDirectory=$WORKSPACE_DIR
Environment=PATH=/home/$OPENCLAW_USER/.npm-global/bin:/usr/bin:/bin
Environment=NODE_ENV=production
ExecStart=$CLAW_BIN gateway
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable openclaw
    "
    
    run_step "启动服务" "systemctl restart openclaw"
    
    log_ok "基础设施配置完成"
}

# ════════════════════ 完成配置 (自动向导) ════════════════════
show_completion() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  🎉  部署成功！OpenClaw 服务已在后台运行${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e " ${BOLD}📊 系统信息:${NC}"
    echo -e "   - 用户: ${OPENCLAW_USER}"
    echo -e "   - 目录: ${WORKSPACE_DIR}"
    echo -e "   - 服务: openclaw (systemd)"
    echo -e "   - 端口: ${final_port}"
    if [ -n "$final_token" ]; then
        echo -e "   - 访问: ${CYAN}${BOLD}${access_url}${NC}"
    fi
    echo ""
    
    echo -e " ${BOLD}💡 常用命令:${NC}"
    echo -e "   服务运行用户: ${CYAN}$OPENCLAW_USER${NC} (非 Root)"
    echo -e "   手动调试时，请${RED}务必切换用户${NC}以避免权限错误："
    echo -e "   切换指令: ${GREEN}su - $OPENCLAW_USER${NC}"
    echo ""
    echo -e "${YELLOW}👉 下一步操作${NC}"
    echo -e "   自动进入管理菜单来管理一切 (含配置、更新、优化等)"
    echo -e "   手工快捷指令: ${GREEN}claw${NC}"
    echo ""
    
    # 自动倒计时进入
    for i in {5..1}; do
        echo -ne "\r${CYAN}🚀 正在为您自动启动配置向导 (按 Ctrl+C 取消): ${RED}$i${NC}s... "
        sleep 1
    done
    echo ""
    echo -e "${GREEN}启动中...${NC}"
    sleep 0.5
    
    # 移交控制权给 manager.sh
    exec "$SCRIPTS_DIR/manager.sh"
}

# ════════════════════ 主流程 ════════════════════
main() {
    print_banner
    
    check_existing_installation
    
    # 1. 系统检查与优化
    pre_flight_check
    optimize_system
    
    # 1.5 确保用户存在 (Linuxbrew 安装需要)
    ensure_user_exists

    # 2. 安装基础依赖和 CLI
    fix_git_github_config
    install_dependencies
    
    # 3. 准备工作目录
    prepare_workspace
    
    # 4. 安装监控脚本
    install_monitoring_scripts

    # 4.5 修复 Node 权限
    fix_node_permissions
    ensure_openclaw_bin_link
    
    # 5. 基础设施配置 (不启动)
    if [ "$UPDATE_MODE" = false ]; then
        setup_infrastructure
    else
        # 更新模式下，仅重启服务
        log_info "正在重置服务状态..."
        
        # 尝试清理旧的 PM2 进程 (如果从未迁移过)
        if command -v pm2 &>/dev/null; then
             pkill -u $OPENCLAW_USER -f pm2 >/dev/null 2>&1 || true
        fi
        
        run_step "重启 Systemd 服务" "systemctl restart openclaw"
    fi
    
    # 7. 执行自动诊断 (Round 2 Optimization)
    run_doctor
    
    # 8. 进入配置向导
    if [ "$UPDATE_MODE" = false ] && [ "$NON_INTERACTIVE" = false ]; then
        show_completion
    else
        log_ok "更新完成 / 非交互安装完成"
    fi
}

main "$@"
