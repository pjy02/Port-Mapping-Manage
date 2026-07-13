#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export PATH="/usr/bin:$PATH"

manifest_sha256=$(sha256sum "$PROJECT_ROOT/release-manifest.sha256" | awk '{print $1}')
(cd "$PROJECT_ROOT" && sha256sum -c install_pmm.sh.sha256 >/dev/null)

PMM_LOCAL_SOURCE_DIR="$PROJECT_ROOT" \
PMM_MANIFEST_SHA256="$manifest_sha256" \
PMM_VERIFY_ONLY=true \
bash "$PROJECT_ROOT/install_pmm.sh" >/dev/null

cp "$PROJECT_ROOT/release-manifest.sha256" "$TEST_ROOT/release-manifest.sha256"
cp "$PROJECT_ROOT/port_mapping_manager.sh" "$TEST_ROOT/port_mapping_manager.sh"
cp "$PROJECT_ROOT/pmm" "$TEST_ROOT/pmm"
printf '\n# tampered payload\n' >> "$TEST_ROOT/port_mapping_manager.sh"

if PMM_LOCAL_SOURCE_DIR="$TEST_ROOT" \
   PMM_MANIFEST_SHA256="$manifest_sha256" \
   PMM_VERIFY_ONLY=true \
   bash "$PROJECT_ROOT/install_pmm.sh" >/dev/null 2>&1; then
    echo "FAIL: tampered payload was accepted" >&2
    exit 1
fi

if PMM_LOCAL_SOURCE_DIR="$PROJECT_ROOT" \
   PMM_MANIFEST_SHA256="${manifest_sha256%?}0" \
   PMM_VERIFY_ONLY=true \
   bash "$PROJECT_ROOT/install_pmm.sh" >/dev/null 2>&1; then
    echo "FAIL: untrusted manifest digest was accepted" >&2
    exit 1
fi

echo "PASS: supply-chain verification fails closed"
