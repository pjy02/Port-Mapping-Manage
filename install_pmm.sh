#!/bin/bash
# ----------------------------------------------------------------------------
# install_pmm.sh
# 一键安装 Port Mapping Manager 及启动器脚本 (pmm)
# 功能：
#   1. 自动检测 Linux 发行版及包管理器
#   2. 检查并安装依赖：curl、iptables、iptables-save、iptables-restore
#   3. 下载最新脚本并安装到系统目录
# 使用示例：
#   bash <(curl -fsSL https://raw.githubusercontent.com/pjy02/Port-Mapping-Manage/main/install_pmm.sh)
# ----------------------------------------------------------------------------

set -euo pipefail

############################## 全局配置 ######################################
REMOTE_BASE="https://raw.githubusercontent.com/pjy02/Port-Mapping-Manage/main"  # TODO: 替换为真实仓库地址
INSTALL_DIR="/usr/local/bin"
SCRIPT_DIR="/etc/port_mapping_manager"
TMP_DIR="$(mktemp -d)"
REQUIRED_CMDS=(curl iptables iptables-save iptables-restore)
##############################################################################

# --------------------------- 日志输出辅助 -----------------------------------
info()  { echo -e "\033[0;32m[INFO] $*\033[0m"; }
warn()  { echo -e "\033[1;33m[WARN] $*\033[0m"; }
error() { echo -e "\033[0;31m[ERROR] $*\033[0m" >&2; }

# --------------------------- 系统检测函数 -----------------------------------
PACKAGE_MANAGER=""
SUDO=""

detect_system() {
    # 设置 sudo 前缀（若当前非 root）
    if [[ $(id -u) -ne 0 ]]; then
        if command -v sudo &>/dev/null; then
            SUDO="sudo"
        else
            error "检测到非 root 用户且系统缺少 sudo，请以 root 身份重新执行。"; exit 1
        fi
    fi

    # 检测包管理器
    if command -v apt-get &>/dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGER="yum"
    elif command -v pacman &>/dev/null; then
        PACKAGE_MANAGER="pacman"
    else
        PACKAGE_MANAGER="unknown"
    fi

    if [[ "$PACKAGE_MANAGER" == "unknown" ]]; then
        warn "无法识别的包管理器，自动安装依赖将被跳过，请手动确保依赖存在。"
    else
        info "已检测到包管理器: $PACKAGE_MANAGER"
    fi
}

# --------------------------- 依赖检测函数 -----------------------------------
install_packages() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    case $PACKAGE_MANAGER in
        apt)
            $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${pkgs[@]}" ;;
        yum|dnf)
            $SUDO $PACKAGE_MANAGER install -y -q "${pkgs[@]}" ;;
        pacman)
            $SUDO pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
        *)
            warn "未知包管理器，无法自动安装：${pkgs[*]}" ;;
    esac
}

check_dependencies() {
    local missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "缺少依赖：${missing[*]}，尝试自动安装..."
        install_packages "${missing[@]}"
    fi

    # 再次检查
    for cmd in "${missing[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            error "依赖 $cmd 安装失败，请手动安装后重试。"; exit 1
        fi
    done
    info "所有依赖已就绪。"
}

# --------------------------- 主安装流程 -------------------------------------
main() {
    detect_system
    check_dependencies

    local core_script="pmm.sh"
    local modules=("config.sh" "core.sh" "ui.sh" "utils.sh")

    info "正在下载最新脚本..."
    # 下载主脚本
    info "  - $core_script"
    curl -fsSL "$REMOTE_BASE/$core_script" -o "$TMP_DIR/$core_script"
    chmod +x "$TMP_DIR/$core_script"

    # 下载模块
    mkdir -p "$TMP_DIR/modules"
    for m in "${modules[@]}"; do
        info "  - modules/$m"
        curl -fsSL "$REMOTE_BASE/modules/$m" -o "$TMP_DIR/modules/$m"
    done

    info "复制文件到系统目录 (需要 root 权限)"
    $SUDO mkdir -p "$SCRIPT_DIR/modules" "$INSTALL_DIR"
    # 将主脚本和模块复制到目标位置
    $SUDO cp "$TMP_DIR/$core_script" "$SCRIPT_DIR/pmm.sh"
    $SUDO cp "$TMP_DIR/modules/"* "$SCRIPT_DIR/modules/"

    # 创建一个指向主脚本的包装器，并放置在 $INSTALL_DIR
    cat <<EOF | $SUDO tee "$INSTALL_DIR/pmm" > /dev/null
#!/bin/bash
# Wrapper script to execute Port Mapping Manager
exec "$SCRIPT_DIR/pmm.sh" "\$@"
EOF

    # 赋予执行权限
    $SUDO chmod +x "$SCRIPT_DIR/pmm.sh"
    $SUDO chmod +x "$INSTALL_DIR/pmm"

    rm -rf "$TMP_DIR"
    info "安装完成！现在可在任何目录直接运行： pmm"
}

main "$@"
