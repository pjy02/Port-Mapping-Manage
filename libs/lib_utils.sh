#!/bin/bash

# libs/lib_utils.sh
#
# Port Mapping Manager 的实用函数库

# --- Color Definitions ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'

# --- Global Variables ---
LOG_DIR="/var/log/port_mapping_manager"
LOG_FILE="$LOG_DIR/port_mapping_manager.log"
CONFIG_DIR="/etc/port_mapping_manager"
CONFIG_FILE="$CONFIG_DIR/port_mapping_manager.conf"
BACKUP_DIR="$CONFIG_DIR/backups"

# --- Logging ---
# --- 日志记录 ---
log_message() {
    local type=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="$timestamp [$type] - $message"
    echo -e "$log_entry" >> "$LOG_FILE"
}

# --- Input Sanitization ---
sanitize_input() {
    local input=$1
        # 严格的输入清理：只允许字母、数字、下划线、连字符和点。
    # 禁止像'/'这样的路径字符，以防止路径遍历，除非有特定处理。
    echo "$input" | sed 's/[^a-zA-Z0-9_.-]//g'
}

validate_ip_address() {
    local ip=$1
    local ip_type=$2 # "4" or "6"

    if [[ "$ip_type" == "4" ]]; then
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            IFS='.' read -r -a octets <<< "$ip"
            for octet in "${octets[@]}"; do
                if (( octet > 255 )); then
                    echo "无效"
                    return
                fi
            done
            echo "有效"
        else
            echo "无效"
        fi
    elif [[ "$ip_type" == "6" ]]; then
        # 一个简单的IPv6正则表达式，虽然不完全详尽，但在许多情况下已经足够了。
        # 要进行真正可靠的验证，需要更复杂的函数或外部工具。
        if [[ $ip =~ ^([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}$ || # 1:2:3:4:5:6:7:8
              $ip =~ ^([0-9a-fA-F]{1,4}:){1,7}:$ ||                  # 1::
              $ip =~ ^:(:[0-9a-fA-F]{1,4}){1,7}$ ||                 # ::2
              $ip =~ ^([0-9a-fA-F]{1,4}:){1,}(:[0-9a-fA-F]{1,4}){1,}$ ]]; then # 1::8 or 1:2::8 etc.
            echo "有效"
        else
            echo "无效"
        fi
    else
        echo "无效类型"
    fi
}

# --- System Detection ---
detect_package_manager() {
    if command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "未知"
    fi
}

detect_persistence_method() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        echo "netfilter-persistent"
    elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q iptables-persistent; then
        echo "systemd_iptables_persistent"
    elif command -v service >/dev/null 2>&1; then
        echo "service"
    elif command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
    else
        echo "手动"
    fi
}

# --- Prerequisite Checks ---
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}错误：此脚本必须以 root 身份运行。请使用 sudo。${C_RESET}"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    for dep in iptables grep awk sed; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${C_RED}错误：缺少关键依赖项：${missing_deps[*]}.${C_RESET}"
        # 尝试安装
        local pm
        pm=$(detect_package_manager)
        if [ "$pm" != "未知" ]; then
            echo -e "${C_YELLOW}正在尝试使用 $pm 安装缺少的软件包...${C_RESET}"
            case $pm in
                apt) sudo apt-get update && sudo apt-get install -y iptables coreutils;;
                dnf) sudo dnf install -y iptables-services coreutils;;
                yum) sudo yum install -y iptables-services coreutils;;
                pacman) sudo pacman -Syu --noconfirm iptables coreutils;;
            esac
            # 安装后重新检查
            for dep in "${missing_deps[@]}"; do
                if ! command -v "$dep" >/dev/null 2>&1; then
                     echo -e "${C_RED}安装 '$dep' 失败。请手动安装并重新运行脚本。${C_RESET}"
                     exit 1
                fi
            done
        else
            echo -e "${C_RED}无法确定软件包管理器。请手动安装缺少的依赖项。${C_RESET}"
            exit 1
        fi
    fi
}

# --- Port Validation ---
validate_port() {
    local port=$1
    local protocol=$2 # Optional: tcp or udp

    if ! [[ $port =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "无效"
        return
    fi

    # 检查系统保留端口，但允许用户谨慎操作。
    if [ "$port" -lt 1024 ]; then
        echo "保留"
        # 我们返回 '保留' 但不退出，调用函数应处理此问题。
    fi

    # 使用ss更可靠地检查监听端口。
    # 正则表达式 `\s:$port(\s|$)` 确保我们匹配确切的端口号。
    local listen_check_cmd="ss -tln"
    if [[ "$protocol" == "udp" ]]; then
        listen_check_cmd="ss -uln"
    fi

    if $listen_check_cmd | awk '{print $5}' | grep -q -w ":$port"; then
        echo "监听中"
        return
    fi

    echo "有效"
}

# --- Byte Formatter ---
format_bytes() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(awk -v b=$bytes 'BEGIN {printf "%.2fK", b/1024}')"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(awk -v b=$bytes 'BEGIN {printf "%.2fM", b/1048576}')"
    else
        echo "$(awk -v b=$bytes 'BEGIN {printf "%.2fG", b/1073741824}')"
    fi
}