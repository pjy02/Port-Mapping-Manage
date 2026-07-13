#!/bin/bash
# Port Mapping Manager verified installer

set -euo pipefail

RELEASE_REF="${PMM_RELEASE_REF:-v5.0.0}"
EXPECTED_MANIFEST_SHA256="${PMM_MANIFEST_SHA256:-267a70e3be90f156623d31b759e3366bbd2aaf8126b02dcbaabc45ba233f89c6}"
REMOTE_BASE="https://raw.githubusercontent.com/pjy02/Port-Mapping-Manage/$RELEASE_REF"
LOCAL_SOURCE_DIR="${PMM_LOCAL_SOURCE_DIR:-}"
VERIFY_ONLY="${PMM_VERIFY_ONLY:-false}"
INSTALL_DIR="/usr/local/bin"
SCRIPT_DIR="/etc/port_mapping_manager"
TMP_DIR=$(mktemp -d)
FILES=(port_mapping_manager.sh pmm)
PACKAGE_MANAGER=""
SUDO=""

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

info()  { echo -e "\033[0;32m[INFO] $*\033[0m"; }
warn()  { echo -e "\033[1;33m[WARN] $*\033[0m"; }
error() { echo -e "\033[0;31m[ERROR] $*\033[0m" >&2; }

detect_system() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        elif [ "$VERIFY_ONLY" != true ]; then
            error "需要 root 权限或 sudo"
            return 1
        fi
    fi

    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    else
        PACKAGE_MANAGER="unknown"
    fi
}

install_packages() {
    local packages=("$@")
    [ ${#packages[@]} -gt 0 ] || return 0
    case "$PACKAGE_MANAGER" in
        apt) $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${packages[@]}" ;;
        dnf|yum) $SUDO "$PACKAGE_MANAGER" install -y -q "${packages[@]}" ;;
        pacman) $SUDO pacman -Sy --noconfirm --needed "${packages[@]}" ;;
        *) error "无法自动安装依赖: ${packages[*]}"; return 1 ;;
    esac
}

ensure_verification_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
    [ ${#missing[@]} -eq 0 ] || install_packages "${missing[@]}"
    command -v curl >/dev/null 2>&1 || { error "缺少 curl"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { error "缺少 sha256sum"; return 1; }
}

fetch_file() {
    local name=$1 destination=$2
    if [ -n "$LOCAL_SOURCE_DIR" ]; then
        cp -- "$LOCAL_SOURCE_DIR/$name" "$destination"
    else
        curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 60 "$REMOTE_BASE/$name" -o "$destination"
    fi
}

manifest_hash_for() {
    local filename=$1 manifest=$2
    awk -v name="$filename" '$2 == name && $1 ~ /^[0-9a-fA-F]{64}$/ {print tolower($1)}' "$manifest"
}

verify_release() {
    local manifest="$TMP_DIR/release-manifest.sha256"
    local actual_manifest_sha256 expected actual count file

    [[ "$RELEASE_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || { error "无效发布引用"; return 1; }
    [[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
        error "缺少有效的受信任清单 SHA-256；安装已拒绝"
        return 1
    }

    fetch_file release-manifest.sha256 "$manifest"
    actual_manifest_sha256=$(sha256sum "$manifest" | awk '{print tolower($1)}')
    if [ "$actual_manifest_sha256" != "${EXPECTED_MANIFEST_SHA256,,}" ]; then
        error "发布清单 SHA-256 与安装器信任锚不匹配"
        return 1
    fi

    for file in "${FILES[@]}"; do
        count=$(awk -v name="$file" '$2 == name {count++} END {print count+0}' "$manifest")
        [ "$count" -eq 1 ] || { error "清单中的 $file 条目数量异常"; return 1; }
        expected=$(manifest_hash_for "$file" "$manifest")
        [ -n "$expected" ] || { error "清单缺少 $file"; return 1; }
        fetch_file "$file" "$TMP_DIR/$file"
        actual=$(sha256sum "$TMP_DIR/$file" | awk '{print tolower($1)}')
        if [ "$actual" != "$expected" ]; then
            error "$file SHA-256 校验失败"
            return 1
        fi
    done

    bash -n "$TMP_DIR/port_mapping_manager.sh" || { error "主脚本语法检查失败"; return 1; }
    bash -n "$TMP_DIR/pmm" || { error "启动器语法检查失败"; return 1; }
    info "发布引用、清单和全部负载校验通过"
}

install_runtime_dependencies() {
    local missing_packages=()
    command -v iptables >/dev/null 2>&1 || missing_packages+=(iptables)
    command -v ip6tables >/dev/null 2>&1 || missing_packages+=(iptables)
    install_packages "${missing_packages[@]}"
}

install_verified_release() {
    local trust_file="$TMP_DIR/trusted-release.conf"
    printf 'RELEASE_REF=%s\nMANIFEST_SHA256=%s\n' \
        "$RELEASE_REF" "${EXPECTED_MANIFEST_SHA256,,}" > "$trust_file"

    $SUDO install -d -m 0755 "$SCRIPT_DIR" "$INSTALL_DIR"
    $SUDO install -m 0755 "$TMP_DIR/port_mapping_manager.sh" "$SCRIPT_DIR/port_mapping_manager.sh"
    $SUDO install -m 0755 "$TMP_DIR/pmm" "$INSTALL_DIR/pmm"
    $SUDO install -m 0644 "$TMP_DIR/release-manifest.sha256" "$SCRIPT_DIR/release-manifest.sha256"
    $SUDO install -m 0644 "$trust_file" "$SCRIPT_DIR/trusted-release.conf"
    info "已安装经过校验的 Port Mapping Manager $RELEASE_REF"
}

main() {
    detect_system
    ensure_verification_tools
    verify_release
    [ "$VERIFY_ONLY" = true ] && return 0
    install_runtime_dependencies
    install_verified_release
}

main "$@"
