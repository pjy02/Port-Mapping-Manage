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

openssl genpkey -quiet -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$TEST_ROOT/private.pem"
openssl pkey -in "$TEST_ROOT/private.pem" -pubout -out "$TEST_ROOT/public.pem" >/dev/null 2>&1

(
    cd "$PROJECT_ROOT"
    CGO_ENABLED=0 go build -trimpath -o "$TEST_ROOT/$binary_name" ./cmd/pmm
)
(
    cd "$TEST_ROOT"
    sha256sum "$binary_name" | sed 's/ \*/  /' > release-manifest.sha256
    openssl dgst -sha256 -sign private.pem -out release-manifest.sha256.sig release-manifest.sha256
)
manifest_sha256=$(sha256sum "$TEST_ROOT/release-manifest.sha256" | awk '{print $1}')

verify_local() {
    PMM_LOCAL_SOURCE_DIR="$TEST_ROOT" \
    PMM_PUBLIC_KEY_FILE="$TEST_ROOT/public.pem" \
    PMM_RELEASE_REF=v6.0.0 \
    PMM_MANIFEST_SHA256="${PMM_MANIFEST_SHA256:-}" \
    PMM_VERIFY_ONLY=true \
    "${BASH:-bash}" "$PROJECT_ROOT/install_pmm.sh"
}

verify_local >/dev/null
PMM_MANIFEST_SHA256="$manifest_sha256" verify_local >/dev/null

cp "$TEST_ROOT/$binary_name" "$TEST_ROOT/$binary_name.good"
printf '\ntampered\n' >> "$TEST_ROOT/$binary_name"
if verify_local >/dev/null 2>&1; then
    printf '%s\n' "FAIL: tampered binary was accepted" >&2
    exit 1
fi
mv "$TEST_ROOT/$binary_name.good" "$TEST_ROOT/$binary_name"

cp "$TEST_ROOT/release-manifest.sha256" "$TEST_ROOT/release-manifest.sha256.good"
printf '0%.0s' {1..64} > "$TEST_ROOT/release-manifest.sha256"
printf '  %s\n' "$binary_name" >> "$TEST_ROOT/release-manifest.sha256"
if verify_local >/dev/null 2>&1; then
    printf '%s\n' "FAIL: unsigned manifest change was accepted" >&2
    exit 1
fi
mv "$TEST_ROOT/release-manifest.sha256.good" "$TEST_ROOT/release-manifest.sha256"

cp "$TEST_ROOT/release-manifest.sha256.sig" "$TEST_ROOT/release-manifest.sha256.sig.good"
printf 'invalid-signature' > "$TEST_ROOT/release-manifest.sha256.sig"
if verify_local >/dev/null 2>&1; then
    printf '%s\n' "FAIL: invalid manifest signature was accepted" >&2
    exit 1
fi
mv "$TEST_ROOT/release-manifest.sha256.sig.good" "$TEST_ROOT/release-manifest.sha256.sig"

wrong_manifest=$(printf '%064d' 0)
if PMM_MANIFEST_SHA256="$wrong_manifest" verify_local >/dev/null 2>&1; then
    printf '%s\n' "FAIL: wrong optional manifest pin was accepted" >&2
    exit 1
fi

awk '/^-----BEGIN PUBLIC KEY-----$/{copy=1} copy{print} /^-----END PUBLIC KEY-----$/{exit}' \
    "$PROJECT_ROOT/install_pmm.sh" > "$TEST_ROOT/embedded-public.pem"
openssl pkey -pubin -in "$PROJECT_ROOT/release-signing-public.pem" -outform DER \
    -out "$TEST_ROOT/repository-public.der"
openssl pkey -pubin -in "$TEST_ROOT/embedded-public.pem" -outform DER \
    -out "$TEST_ROOT/embedded-public.der"
openssl pkey -pubin -in "$PROJECT_ROOT/internal/updater/release-signing-public.pem" -outform DER \
    -out "$TEST_ROOT/updater-public.der"
cmp "$TEST_ROOT/repository-public.der" "$TEST_ROOT/embedded-public.der"
cmp "$TEST_ROOT/repository-public.der" "$TEST_ROOT/updater-public.der"

printf '%s\n' "PASS: v6 signed supply-chain verification fails closed"
