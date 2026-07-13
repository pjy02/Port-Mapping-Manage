#!/usr/bin/env bash
# Port Mapping Manager v6 verified binary installer.

set -euo pipefail

RELEASE_REF="${PMM_RELEASE_REF:-v6.0.0}"
EXPECTED_MANIFEST_SHA256="${PMM_MANIFEST_SHA256:-}"
LOCAL_SOURCE_DIR="${PMM_LOCAL_SOURCE_DIR:-}"
VERIFY_ONLY="${PMM_VERIFY_ONLY:-false}"
INSTALL_DEPENDENCIES="${PMM_INSTALL_DEPENDENCIES:-true}"
INSTALL_DIR="${PMM_INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${PMM_CONFIG_DIR:-/etc/port-mapping-manager}"
REMOTE_BASE="${PMM_REMOTE_BASE:-https://github.com/pjy02/Port-Mapping-Manage/releases/download}"
TMP_DIR=$(mktemp -d)
SUDO=()
PACKAGE_MANAGER=""

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT INT TERM

info() { printf '\033[0;32m[INFO]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

detect_architecture() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' amd64 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        *) error "unsupported architecture: $(uname -m)"; return 1 ;;
    esac
}

detect_privilege_and_package_manager() {
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || {
            error "installation requires root or sudo"
            return 1
        }
        SUDO=(sudo)
    fi
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

install_packages() {
    [ "$INSTALL_DEPENDENCIES" = true ] || return 0
    case "$PACKAGE_MANAGER" in
        apt)
            "${SUDO[@]}" apt-get update -qq
            "${SUDO[@]}" apt-get install -y -qq "$@"
            ;;
        dnf|yum) "${SUDO[@]}" "$PACKAGE_MANAGER" install -y -q "$@" ;;
        pacman) "${SUDO[@]}" pacman -Sy --noconfirm --needed "$@" ;;
        *) error "cannot install missing dependencies: $*"; return 1 ;;
    esac
}

ensure_verification_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
    if [ ${#missing[@]} -gt 0 ]; then
        [ "$VERIFY_ONLY" = false ] || {
            error "verification tools are missing: ${missing[*]}"
            return 1
        }
        detect_privilege_and_package_manager
        install_packages "${missing[@]}"
    fi
    command -v curl >/dev/null 2>&1 || { error "curl is required"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { error "sha256sum is required"; return 1; }
}

fetch_file() {
    local name=$1 destination=$2
    if [ -n "$LOCAL_SOURCE_DIR" ]; then
        cp -- "$LOCAL_SOURCE_DIR/$name" "$destination"
    else
        curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 120 \
            "$REMOTE_BASE/$RELEASE_REF/$name" -o "$destination"
    fi
}

manifest_hash_for() {
    local filename=$1 manifest=$2
    awk -v name="$filename" '$2 == name && $1 ~ /^[0-9a-fA-F]{64}$/ {print tolower($1)}' "$manifest"
}

verify_release() {
    local binary_name=$1
    local manifest="$TMP_DIR/release-manifest.sha256"
    local actual_manifest expected_binary actual_binary count

    [[ "$RELEASE_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || {
        error "release reference must be an immutable semantic-version tag"
        return 1
    }
    [[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
        error "PMM_MANIFEST_SHA256 must contain an independently verified 64-character digest"
        return 1
    }

    fetch_file release-manifest.sha256 "$manifest"
    actual_manifest=$(sha256sum "$manifest" | awk '{print tolower($1)}')
    [ "$actual_manifest" = "${EXPECTED_MANIFEST_SHA256,,}" ] || {
        error "release manifest does not match the trusted SHA-256"
        return 1
    }

    count=$(awk -v name="$binary_name" '$2 == name {count++} END {print count+0}' "$manifest")
    [ "$count" -eq 1 ] || {
        error "verified manifest must contain exactly one $binary_name entry"
        return 1
    }
    expected_binary=$(manifest_hash_for "$binary_name" "$manifest")
    [ -n "$expected_binary" ] || { error "manifest entry for $binary_name is invalid"; return 1; }
    fetch_file "$binary_name" "$TMP_DIR/$binary_name"
    actual_binary=$(sha256sum "$TMP_DIR/$binary_name" | awk '{print tolower($1)}')
    [ "$actual_binary" = "$expected_binary" ] || {
        error "$binary_name does not match the verified manifest"
        return 1
    }
    chmod 0755 "$TMP_DIR/$binary_name"
    "$TMP_DIR/$binary_name" version >/dev/null || {
        error "verified payload cannot execute on this host"
        return 1
    }
    info "release reference, manifest and binary verification passed"
}

ensure_runtime_dependencies() {
    local missing=()
    command -v iptables >/dev/null 2>&1 || missing+=(iptables)
    command -v ip6tables >/dev/null 2>&1 || missing+=(iptables)
    if [ ${#missing[@]} -gt 0 ]; then
        install_packages "${missing[@]}"
    fi
    command -v iptables >/dev/null 2>&1 || { error "iptables is required"; return 1; }
    command -v ip6tables >/dev/null 2>&1 || { error "ip6tables is required"; return 1; }
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
            error "refusing to use symlink directory: $directory"
            return 1
        fi
        if "${SUDO[@]}" test -e "$directory" && ! "${SUDO[@]}" test -d "$directory"; then
            error "refusing to use non-directory path: $directory"
            return 1
        fi
    done
    "${SUDO[@]}" install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR"
    if "${SUDO[@]}" test -e "$candidate" || "${SUDO[@]}" test -e "$rollback" || \
       "${SUDO[@]}" test -e "$trust_candidate" || "${SUDO[@]}" test -e "$previous_trust"; then
        error "installer staging path already exists"
        return 1
    fi
    if "${SUDO[@]}" test -e "$target" && ! "${SUDO[@]}" test -f "$target"; then
        error "refusing to replace a non-regular pmm path"
        return 1
    fi
    "${SUDO[@]}" install -m 0755 "$TMP_DIR/$binary_name" "$candidate"
    printf '{\n  "release_ref": "%s",\n  "manifest_sha256": "%s"\n}\n' \
        "$RELEASE_REF" "${EXPECTED_MANIFEST_SHA256,,}" > "$TMP_DIR/trusted-release.json"
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
        return 1
    fi
    if ! "${SUDO[@]}" mv -- "$trust_candidate" "$CONFIG_DIR/trusted-release.json"; then
        "${SUDO[@]}" rm -f -- "$target"
        "${SUDO[@]}" test ! -e "$rollback" || "${SUDO[@]}" mv -- "$rollback" "$target"
        "${SUDO[@]}" test ! -e "$previous_trust" || "${SUDO[@]}" mv -- "$previous_trust" "$CONFIG_DIR/trusted-release.json"
        return 1
    fi
    "${SUDO[@]}" rm -f -- "$rollback" "$previous_trust"
    info "installed Port Mapping Manager $RELEASE_REF"
    info "no firewall or startup configuration was changed; run 'pmm migrate' or 'pmm persistence enable' explicitly"
}

main() {
    local architecture binary_name
    architecture=$(detect_architecture)
    binary_name="pmm-linux-$architecture"
    ensure_verification_tools
    verify_release "$binary_name"
    [ "$VERIFY_ONLY" = true ] && return 0
    detect_privilege_and_package_manager
    ensure_runtime_dependencies
    install_verified_binary "$binary_name"
}

main "$@"
