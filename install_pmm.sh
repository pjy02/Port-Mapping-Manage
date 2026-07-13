#!/usr/bin/env bash
# Port Mapping Manager v6 signed, atomic installer.

set -euo pipefail

RELEASE_REF="${PMM_RELEASE_REF:-latest}"
EXPECTED_MANIFEST_SHA256="${PMM_MANIFEST_SHA256:-}"
LOCAL_SOURCE_DIR="${PMM_LOCAL_SOURCE_DIR:-}"
LOCAL_PUBLIC_KEY="${PMM_PUBLIC_KEY_FILE:-}"
VERIFY_ONLY="${PMM_VERIFY_ONLY:-false}"
INSTALL_DEPENDENCIES="${PMM_INSTALL_DEPENDENCIES:-true}"
INSTALL_DIR="${PMM_INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${PMM_CONFIG_DIR:-/etc/port-mapping-manager}"
REPOSITORY="${PMM_REPOSITORY:-pjy02/Port-Mapping-Manage}"
REMOTE_BASE="${PMM_REMOTE_BASE:-https://github.com/$REPOSITORY/releases/download}"
LATEST_URL="${PMM_LATEST_URL:-https://github.com/$REPOSITORY/releases/latest}"
TMP_DIR=$(mktemp -d)
SUDO=()
PACKAGE_MANAGER=""

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT INT TERM

info() { printf '\033[0;32m[信息]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[错误]\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
从经过签名验证的 GitHub Release 安装端口映射管理器。

用法：install_pmm.sh [选项]
  --version vX.Y.Z  安装指定版本（默认：最新稳定版）
  --no-deps         不自动安装缺少的 curl、OpenSSL、iptables 依赖
  --verify-only     只验证发布文件，不执行安装
  --help            显示此帮助

安装器不会创建防火墙规则、迁移旧数据或启用持久化。
除强制验证发布签名外，还可通过 PMM_MANIFEST_SHA256 固定从独立可信渠道
获得的发布清单摘要。
EOF
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] || { error "--version 需要提供 vX.Y.Z 格式的版本号"; return 1; }
                RELEASE_REF=$2
                shift 2
                ;;
            --no-deps)
                INSTALL_DEPENDENCIES=false
                shift
                ;;
            --verify-only)
                VERIFY_ONLY=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                error "未知安装选项：$1"
                usage >&2
                return 1
                ;;
        esac
    done
}

detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' amd64 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        *) error "不支持的处理器架构：$(uname -m)"; return 1 ;;
    esac
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER=apt
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER=dnf
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER=yum
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER=pacman
    fi
}

prepare_privilege() {
    if [ "$(id -u)" -ne 0 ] && [ ${#SUDO[@]} -eq 0 ]; then
        command -v sudo >/dev/null 2>&1 || {
            error "安装需要 root 权限，当前系统也未找到 sudo"
            return 1
        }
        SUDO=(sudo)
    fi
}

install_packages() {
    [ "$INSTALL_DEPENDENCIES" = true ] || {
        error "缺少以下依赖，但已经指定 --no-deps：$*"
        return 1
    }
    prepare_privilege
    detect_package_manager
    case "$PACKAGE_MANAGER" in
        apt)
            "${SUDO[@]}" apt-get update -qq
            "${SUDO[@]}" apt-get install -y -qq "$@"
            ;;
        dnf|yum) "${SUDO[@]}" "$PACKAGE_MANAGER" install -y -q "$@" ;;
        pacman) "${SUDO[@]}" pacman -Sy --noconfirm --needed "$@" ;;
        *) error "未找到受支持的包管理器，无法安装依赖：$*"; return 1 ;;
    esac
}

ensure_verification_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
    [ ${#missing[@]} -eq 0 ] || install_packages "${missing[@]}"
    command -v curl >/dev/null 2>&1 || { error "缺少必需命令：curl"; return 1; }
    command -v openssl >/dev/null 2>&1 || { error "缺少必需命令：OpenSSL"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { error "缺少必需命令：sha256sum"; return 1; }
}

resolve_release() {
    local effective
    if [ "$RELEASE_REF" = latest ]; then
        [ -z "$LOCAL_SOURCE_DIR" ] || {
            error "使用本地发布文件验证时，必须显式设置 PMM_RELEASE_REF"
            return 1
        }
        if ! effective=$(curl --proto '=https' --tlsv1.2 --fail --location --silent \
            --connect-timeout 10 --max-time 60 --output /dev/null --write-out '%{url_effective}' \
            "$LATEST_URL"); then
            error "无法查询最新发布版本，请检查网络连接和 GitHub Release 是否存在"
            return 1
        fi
        RELEASE_REF=${effective##*/}
    fi
    [[ "$RELEASE_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || {
        error "版本必须是 latest 或不可变的语义化版本标签（例如 v6.0.1）"
        return 1
    }
    info "已选择发布版本：$RELEASE_REF"
}

fetch_file() {
    local name=$1 destination=$2
    if [ -n "$LOCAL_SOURCE_DIR" ]; then
        cp -- "$LOCAL_SOURCE_DIR/$name" "$destination" || {
            error "读取本地发布文件失败：$name"
            return 1
        }
    else
        curl --proto '=https' --tlsv1.2 --fail --location --silent \
            --connect-timeout 10 --max-time 120 \
            "$REMOTE_BASE/$RELEASE_REF/$name" -o "$destination" || {
                error "下载发布文件失败：$name（版本 $RELEASE_REF）"
                return 1
            }
    fi
}

write_public_key() {
    local destination=$1
    if [ -n "$LOCAL_PUBLIC_KEY" ]; then
        [ -n "$LOCAL_SOURCE_DIR" ] || {
            error "PMM_PUBLIC_KEY_FILE 只能与 PMM_LOCAL_SOURCE_DIR 同时使用"
            return 1
        }
        cp -- "$LOCAL_PUBLIC_KEY" "$destination"
        return
    fi
    cat >"$destination" <<'PMM_RELEASE_PUBLIC_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAoc8VOgD20wXNnrKsTw2h
BO556CErV52mHp/WpJMKE4nUNmTSJ13oHhBOaMIFh8Uhj2hhLMZemWfRDO3/nsDU
//tHAmZh+6eK764iH5C8GjVjiDDjAmP9n6LtWNPzon2oxYDtPDdfEgP68isgG3ho
aPMkDk752KzUtEKwDczLfyk+EAikLBEKc5oeTx0Ihb1ewkvTjo1BUHpPaj5DqbLb
RIM9aK5Rm4iTtbCYI6MiZXFjm1/q+B1/b+O36/eljmJ1UyhfGDY7/xxEV8IEjf5e
Uy+d9AdSTWui+5XcvA9Xgr+vn2Fue+VIBhvd9HgeB7++FRi/i9xhdrsEbzhG5rI1
SpTnBDojr/B/BxuT3LBi/VdGGTQCGOZGD25fV9qAXk/sU5vYWchdlhsomYKqBb4x
OsF3ONIi1STKLZAc62djLsyoOoJVni41XH4kO3XXHQ7S8xeQgazgtMPPBtifTkij
slcehrQYF9R64OUpdxfQ/UbBHvi1E7H1ecCmJX2w1wUfAgMBAAE=
-----END PUBLIC KEY-----
PMM_RELEASE_PUBLIC_KEY
}

manifest_hash_for() {
    local filename=$1 manifest=$2
    awk -v name="$filename" 'NF == 2 && $2 == name && $1 ~ /^[0-9a-fA-F]{64}$/ {print tolower($1)}' "$manifest"
}

require_maximum_size() {
    local path=$1 maximum=$2 description=$3 size
    size=$(wc -c < "$path")
    [ "$size" -le "$maximum" ] || {
        error "$description 超过允许的大小限制"
        return 1
    }
}

verify_release() {
    local binary_name=$1
    local manifest="$TMP_DIR/release-manifest.sha256"
    local signature="$TMP_DIR/release-manifest.sha256.sig"
    local public_key="$TMP_DIR/release-signing-public.pem"
    local actual_manifest expected_binary actual_binary count

    fetch_file release-manifest.sha256 "$manifest"
    fetch_file release-manifest.sha256.sig "$signature"
    require_maximum_size "$manifest" 1048576 "发布清单"
    require_maximum_size "$signature" 65536 "发布清单签名"
    write_public_key "$public_key"
    openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$manifest" >/dev/null 2>&1 || {
        error "发布清单签名无效，已拒绝安装"
        return 1
    }
    actual_manifest=$(sha256sum "$manifest" | awk '{print tolower($1)}')
    if [ -n "$EXPECTED_MANIFEST_SHA256" ]; then
        [[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
            error "PMM_MANIFEST_SHA256 必须是 64 位十六进制摘要"
            return 1
        }
        [ "$actual_manifest" = "${EXPECTED_MANIFEST_SHA256,,}" ] || {
            error "发布清单与额外固定的 SHA-256 摘要不匹配"
            return 1
        }
    fi

    count=$(awk -v name="$binary_name" 'NF == 2 && $2 == name {count++} END {print count+0}' "$manifest")
    [ "$count" -eq 1 ] || {
        error "已签名清单必须且只能包含一条 $binary_name 记录"
        return 1
    }
    expected_binary=$(manifest_hash_for "$binary_name" "$manifest")
    [ -n "$expected_binary" ] || { error "清单中的 $binary_name 记录无效"; return 1; }
    fetch_file "$binary_name" "$TMP_DIR/$binary_name"
    require_maximum_size "$TMP_DIR/$binary_name" 134217728 "$binary_name"
    actual_binary=$(sha256sum "$TMP_DIR/$binary_name" | awk '{print tolower($1)}')
    [ "$actual_binary" = "$expected_binary" ] || {
        error "$binary_name 的 SHA-256 与已签名清单不匹配"
        return 1
    }
    chmod 0755 "$TMP_DIR/$binary_name"
    "$TMP_DIR/$binary_name" version >/dev/null || {
        error "验证通过的程序无法在当前服务器上运行"
        return 1
    }
    openssl pkey -pubin -in "$public_key" -outform DER -out "$TMP_DIR/public-key.der" >/dev/null 2>&1 || {
        error "发布公钥格式无效，已拒绝安装"
        return 1
    }
    PUBLIC_KEY_SHA256=$(sha256sum "$TMP_DIR/public-key.der" | awk '{print tolower($1)}')
    VERIFIED_MANIFEST_SHA256=$actual_manifest
    info "发布签名和程序 SHA-256 校验通过"
}

ensure_runtime_dependencies() {
    local missing=()
    if ! command -v iptables >/dev/null 2>&1 || ! command -v ip6tables >/dev/null 2>&1; then
        missing+=(iptables)
    fi
    [ ${#missing[@]} -eq 0 ] || install_packages "${missing[@]}"
    command -v iptables >/dev/null 2>&1 || { error "缺少必需命令：iptables"; return 1; }
    command -v ip6tables >/dev/null 2>&1 || { error "缺少必需命令：ip6tables"; return 1; }
}

install_verified_binary() {
    local binary_name=$1 target="$INSTALL_DIR/pmm"
    local candidate rollback trust_candidate previous_trust
    candidate="$INSTALL_DIR/.pmm-candidate-$$"
    rollback="$INSTALL_DIR/.pmm-rollback-$$"
    trust_candidate="$CONFIG_DIR/.trusted-release-$$.json"
    previous_trust="$CONFIG_DIR/.trusted-release-rollback-$$.json"

    for directory in "$INSTALL_DIR" "$CONFIG_DIR"; do
        if "${SUDO[@]}" test -L "$directory"; then
            error "为避免路径劫持，拒绝使用符号链接目录：$directory"
            return 1
        fi
        if "${SUDO[@]}" test -e "$directory" && ! "${SUDO[@]}" test -d "$directory"; then
            error "安装路径存在但不是目录：$directory"
            return 1
        fi
    done
    "${SUDO[@]}" install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR"
    if "${SUDO[@]}" test -e "$candidate" || "${SUDO[@]}" test -e "$rollback" || \
       "${SUDO[@]}" test -e "$trust_candidate" || "${SUDO[@]}" test -e "$previous_trust"; then
        error "安装暂存路径已存在，为避免覆盖未知文件已停止安装"
        return 1
    fi
    if "${SUDO[@]}" test -e "$target" && ! "${SUDO[@]}" test -f "$target"; then
        error "目标 pmm 路径不是普通文件，拒绝替换"
        return 1
    fi
    "${SUDO[@]}" install -m 0755 "$TMP_DIR/$binary_name" "$candidate"
    printf '{\n  "release_ref": "%s",\n  "manifest_sha256": "%s",\n  "public_key_sha256": "%s"\n}\n' \
        "$RELEASE_REF" "$VERIFIED_MANIFEST_SHA256" "$PUBLIC_KEY_SHA256" > "$TMP_DIR/trusted-release.json"
    "${SUDO[@]}" install -m 0600 "$TMP_DIR/trusted-release.json" "$trust_candidate"

    if "${SUDO[@]}" test -e "$CONFIG_DIR/trusted-release.json"; then
        "${SUDO[@]}" mv -- "$CONFIG_DIR/trusted-release.json" "$previous_trust"
    fi
    if "${SUDO[@]}" test -e "$target"; then
        "${SUDO[@]}" mv -- "$target" "$rollback"
    fi
    if ! "${SUDO[@]}" mv -- "$candidate" "$target"; then
        "${SUDO[@]}" test ! -e "$rollback" || "${SUDO[@]}" mv -- "$rollback" "$target"
        "${SUDO[@]}" test ! -e "$previous_trust" || "${SUDO[@]}" mv -- "$previous_trust" "$CONFIG_DIR/trusted-release.json"
        error "替换 pmm 程序失败，已尝试恢复原版本"
        return 1
    fi
    if ! "${SUDO[@]}" mv -- "$trust_candidate" "$CONFIG_DIR/trusted-release.json"; then
        "${SUDO[@]}" rm -f -- "$target"
        "${SUDO[@]}" test ! -e "$rollback" || "${SUDO[@]}" mv -- "$rollback" "$target"
        "${SUDO[@]}" test ! -e "$previous_trust" || "${SUDO[@]}" mv -- "$previous_trust" "$CONFIG_DIR/trusted-release.json"
        error "保存发布信任记录失败，已尝试恢复原版本"
        return 1
    fi
    "${SUDO[@]}" rm -f -- "$rollback" "$previous_trust"
    info "端口映射管理器 $RELEASE_REF 安装完成"
    info "安装过程未修改防火墙规则、迁移数据或开机启动配置"
    info "运行 'pmm' 进入管理面板，运行 'pmm help' 查看命令帮助"
}

main() {
    local architecture binary_name
    parse_arguments "$@"
    architecture=$(detect_architecture)
    binary_name="pmm-linux-$architecture"
    ensure_verification_tools
    resolve_release
    verify_release "$binary_name"
    [ "$VERIFY_ONLY" = true ] && return 0
    prepare_privilege
    ensure_runtime_dependencies
    install_verified_binary "$binary_name"
}

main "$@"
