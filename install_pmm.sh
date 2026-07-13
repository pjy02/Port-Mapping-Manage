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

info() { printf '\033[0;32m[INFO]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Install Port Mapping Manager from a signed GitHub release.

Usage: install_pmm.sh [options]
  --version vX.Y.Z  install an exact release (default: latest stable)
  --no-deps         do not install missing curl/OpenSSL/iptables packages
  --verify-only     verify the release without installing it
  --help            show this help

The installer never creates firewall rules, migrates old data, or enables
persistence. PMM_MANIFEST_SHA256 may pin an independently obtained manifest
digest in addition to the mandatory release signature.
EOF
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)
                [ "$#" -ge 2 ] || { error "--version requires vX.Y.Z"; return 1; }
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
                error "unknown option: $1"
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
        *) error "unsupported architecture: $(uname -m)"; return 1 ;;
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
            error "installation requires root or sudo"
            return 1
        }
        SUDO=(sudo)
    fi
}

install_packages() {
    [ "$INSTALL_DEPENDENCIES" = true ] || {
        error "missing dependencies and --no-deps was selected: $*"
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
        *) error "cannot install missing dependencies: $*"; return 1 ;;
    esac
}

ensure_verification_tools() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
    [ ${#missing[@]} -eq 0 ] || install_packages "${missing[@]}"
    command -v curl >/dev/null 2>&1 || { error "curl is required"; return 1; }
    command -v openssl >/dev/null 2>&1 || { error "OpenSSL is required"; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { error "sha256sum is required"; return 1; }
}

resolve_release() {
    local effective
    if [ "$RELEASE_REF" = latest ]; then
        [ -z "$LOCAL_SOURCE_DIR" ] || {
            error "local verification requires an explicit PMM_RELEASE_REF"
            return 1
        }
        effective=$(curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 60 --output /dev/null --write-out '%{url_effective}' \
            "$LATEST_URL")
        RELEASE_REF=${effective##*/}
    fi
    [[ "$RELEASE_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || {
        error "release reference must be latest or an immutable semantic-version tag"
        return 1
    }
    info "selected release $RELEASE_REF"
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

write_public_key() {
    local destination=$1
    if [ -n "$LOCAL_PUBLIC_KEY" ]; then
        [ -n "$LOCAL_SOURCE_DIR" ] || {
            error "PMM_PUBLIC_KEY_FILE is accepted only with PMM_LOCAL_SOURCE_DIR"
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
        error "$description exceeds the size limit"
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
    require_maximum_size "$manifest" 1048576 "release manifest"
    require_maximum_size "$signature" 65536 "release manifest signature"
    write_public_key "$public_key"
    openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$manifest" >/dev/null 2>&1 || {
        error "release manifest signature is invalid"
        return 1
    }
    actual_manifest=$(sha256sum "$manifest" | awk '{print tolower($1)}')
    if [ -n "$EXPECTED_MANIFEST_SHA256" ]; then
        [[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
            error "PMM_MANIFEST_SHA256 must be a 64-character digest"
            return 1
        }
        [ "$actual_manifest" = "${EXPECTED_MANIFEST_SHA256,,}" ] || {
            error "release manifest does not match the additionally pinned SHA-256"
            return 1
        }
    fi

    count=$(awk -v name="$binary_name" 'NF == 2 && $2 == name {count++} END {print count+0}' "$manifest")
    [ "$count" -eq 1 ] || {
        error "signed manifest must contain exactly one $binary_name entry"
        return 1
    }
    expected_binary=$(manifest_hash_for "$binary_name" "$manifest")
    [ -n "$expected_binary" ] || { error "manifest entry for $binary_name is invalid"; return 1; }
    fetch_file "$binary_name" "$TMP_DIR/$binary_name"
    require_maximum_size "$TMP_DIR/$binary_name" 134217728 "$binary_name"
    actual_binary=$(sha256sum "$TMP_DIR/$binary_name" | awk '{print tolower($1)}')
    [ "$actual_binary" = "$expected_binary" ] || {
        error "$binary_name does not match the signed manifest"
        return 1
    }
    chmod 0755 "$TMP_DIR/$binary_name"
    "$TMP_DIR/$binary_name" version >/dev/null || {
        error "verified payload cannot execute on this host"
        return 1
    }
    openssl pkey -pubin -in "$public_key" -outform DER -out "$TMP_DIR/public-key.der"
    PUBLIC_KEY_SHA256=$(sha256sum "$TMP_DIR/public-key.der" | awk '{print tolower($1)}')
    VERIFIED_MANIFEST_SHA256=$actual_manifest
    info "manifest signature and binary SHA-256 verification passed"
}

ensure_runtime_dependencies() {
    local missing=()
    if ! command -v iptables >/dev/null 2>&1 || ! command -v ip6tables >/dev/null 2>&1; then
        missing+=(iptables)
    fi
    [ ${#missing[@]} -eq 0 ] || install_packages "${missing[@]}"
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
    info "no firewall, migration, or startup configuration was changed"
    info "run 'pmm' for the menu or 'pmm help' for commands"
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
