#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

architecture=amd64
case "$(uname -m)" in
    aarch64|arm64) architecture=arm64 ;;
esac
binary_name="pmm-linux-$architecture"

(
    cd "$PROJECT_ROOT"
    CGO_ENABLED=0 go build -trimpath -o "$TEST_ROOT/$binary_name" ./cmd/pmm
)
(
    cd "$TEST_ROOT"
    sha256sum "$binary_name" > release-manifest.sha256
)
manifest_sha256=$(sha256sum "$TEST_ROOT/release-manifest.sha256" | awk '{print $1}')

PMM_LOCAL_SOURCE_DIR="$TEST_ROOT" \
PMM_RELEASE_REF=v6.0.0 \
PMM_MANIFEST_SHA256="$manifest_sha256" \
PMM_VERIFY_ONLY=true \
bash "$PROJECT_ROOT/install_pmm.sh" >/dev/null

printf '\ntampered\n' >> "$TEST_ROOT/$binary_name"
if PMM_LOCAL_SOURCE_DIR="$TEST_ROOT" \
   PMM_RELEASE_REF=v6.0.0 \
   PMM_MANIFEST_SHA256="$manifest_sha256" \
   PMM_VERIFY_ONLY=true \
   bash "$PROJECT_ROOT/install_pmm.sh" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: tampered binary was accepted" >&2
    exit 1
fi

wrong_manifest=$(printf '%064d' 0)
if [ "$wrong_manifest" = "$manifest_sha256" ]; then
    wrong_manifest=$(printf '%064d' 1)
fi
if PMM_LOCAL_SOURCE_DIR="$TEST_ROOT" \
   PMM_RELEASE_REF=v6.0.0 \
   PMM_MANIFEST_SHA256="$wrong_manifest" \
   PMM_VERIFY_ONLY=true \
   bash "$PROJECT_ROOT/install_pmm.sh" >/dev/null 2>&1; then
    printf '%s\n' "FAIL: untrusted manifest was accepted" >&2
    exit 1
fi

printf '%s\n' "PASS: v6 supply-chain verification fails closed"
