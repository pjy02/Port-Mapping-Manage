#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if [ "${1:-}" != "--inside" ]; then
    if [ "$(uname -s)" != "Linux" ]; then
        echo "SKIP: network namespace integration test requires Linux"
        exit 0
    fi
    [ "$EUID" -eq 0 ] || fail "run this test as root"
    for cmd in ip iptables ip6tables; do
        command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
    done

    namespace="pmm-test-$$"
    test_root=$(mktemp -d)
    cleanup() {
        ip netns del "$namespace" >/dev/null 2>&1 || true
        rm -rf "$test_root"
    }
    trap cleanup EXIT

    ip netns add "$namespace"
    ip -n "$namespace" link set lo up
    ip netns exec "$namespace" sysctl -qw net.ipv6.conf.all.disable_ipv6=0 || true
    ip netns exec "$namespace" env PMM_NETNS_ROOT="$test_root" \
        bash "$PROJECT_ROOT/tests/test_netns_integration.sh" --inside
    exit $?
fi

[ -n "${PMM_NETNS_ROOT:-}" ] || fail "PMM_NETNS_ROOT is not set"
export PMM_SOURCE_ONLY=true
# shellcheck source=../port_mapping_manager.sh
source "$PROJECT_ROOT/port_mapping_manager.sh"

CONFIG_DIR="$PMM_NETNS_ROOT/etc/port_mapping_manager"
BACKUP_DIR="$CONFIG_DIR/backups"
CONFIG_FILE="$CONFIG_DIR/config.conf"
RULES_DB="$CONFIG_DIR/rules.db"
RESTORE_SCRIPT="$CONFIG_DIR/restore-owned-rules.sh"
LOG_FILE="$PMM_NETNS_ROOT/pmm.log"
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"

iptables -t nat -F
ip6tables -t nat -F

# 外部规则用于验证同步、恢复和删除都不会越过项目边界。
iptables -t nat -A PREROUTING -p udp --dport 5555 \
    -m comment --comment external-owner -j REDIRECT --to-port 5556
ip6tables -t nat -A PREROUTING -p tcp --dport 5557 \
    -m comment --comment external-owner -j REDIRECT --to-port 5558

cat > "$PMM_NETNS_ROOT/import.conf" <<'EOF'
4|udp|6100|6101|6102
4|tcp|6200|6201|6202
6|udp|7100|7101|7102
6|tcp|7200|7201|7202
EOF

import_rules_from_file "$PMM_NETNS_ROOT/import.conf" || fail "dual-stack batch import failed"
[ "${IMPORT_SUCCESS_COUNT:-0}" -eq 4 ] || fail "expected four imported rules"

python3 - <<'PY' &
import socket, time
sockets = []
for family, kind, address in (
    (socket.AF_INET, socket.SOCK_DGRAM, ("0.0.0.0", 6102)),
    (socket.AF_INET, socket.SOCK_STREAM, ("0.0.0.0", 6202)),
    (socket.AF_INET6, socket.SOCK_DGRAM, ("::", 7102)),
    (socket.AF_INET6, socket.SOCK_STREAM, ("::", 7202)),
):
    sock = socket.socket(family, kind)
    sock.bind(address)
    if kind == socket.SOCK_STREAM:
        sock.listen(1)
    sockets.append(sock)
time.sleep(300)
PY
listener_pid=$!
trap 'kill "$listener_pid" >/dev/null 2>&1 || true' EXIT
sleep 1

is_service_listening 4 udp 6102 || fail "IPv4 UDP listener not detected"
is_service_listening 4 tcp 6202 || fail "IPv4 TCP listener not detected"
is_service_listening 6 udp 7102 || fail "IPv6 UDP listener not detected"
is_service_listening 6 tcp 7202 || fail "IPv6 TCP listener not detected"
! is_service_listening 6 udp 6102 || fail "IPv4 UDP listener leaked into IPv6 check"
! is_service_listening 4 tcp 7202 || fail "IPv6 TCP listener leaked into IPv4 check"

iptables -t nat -C PREROUTING -p udp --dport 6100:6101 \
    -m comment --comment "$RULE_COMMENT" -j REDIRECT --to-port 6102
iptables -t nat -C PREROUTING -p tcp --dport 6200:6201 \
    -m comment --comment "$RULE_COMMENT" -j REDIRECT --to-port 6202
ip6tables -t nat -C PREROUTING -p udp --dport 7100:7101 \
    -m comment --comment "$RULE_COMMENT" -j REDIRECT --to-port 7102
ip6tables -t nat -C PREROUTING -p tcp --dport 7200:7201 \
    -m comment --comment "$RULE_COMMENT" -j REDIRECT --to-port 7202

# 验证 IPv4/IPv6 缓存完全分离。
clear_iptables_cache
cache_iptables_rules 4 > "$PMM_NETNS_ROOT/cache-v4"
cache_iptables_rules 6 > "$PMM_NETNS_ROOT/cache-v6"
grep -Fq '6100:6101' "$PMM_NETNS_ROOT/cache-v4" || fail "IPv4 cache missing IPv4 rule"
! grep -Fq '7100:7101' "$PMM_NETNS_ROOT/cache-v4" || fail "IPv6 rule leaked into IPv4 cache"
grep -Fq '7100:7101' "$PMM_NETNS_ROOT/cache-v6" || fail "IPv6 cache missing IPv6 rule"
! grep -Fq '6100:6101' "$PMM_NETNS_ROOT/cache-v6" || fail "IPv4 rule leaked into IPv6 cache"

export_rules_to_file "$PMM_NETNS_ROOT/export.conf" || fail "dual-stack export failed"
[ "${EXPORT_RULE_COUNT:-0}" -eq 4 ] || fail "expected four exported rules"
for record in \
    '4|udp|6100|6101|6102' \
    '4|tcp|6200|6201|6202' \
    '6|udp|7100|7101|7102' \
    '6|tcp|7200|7201|7202'; do
    grep -Fxq "$record" "$PMM_NETNS_ROOT/export.conf" || fail "missing exported record: $record"
done
! grep -Fq '5555' "$PMM_NETNS_ROOT/export.conf" || fail "external IPv4 rule was exported"
! grep -Fq '5557' "$PMM_NETNS_ROOT/export.conf" || fail "external IPv6 rule was exported"

generate_diagnostic_report >/dev/null
report_file=$(find "$REPORT_DIR" -maxdepth 1 -type f -name 'diagnostic_report_*.txt' | head -n1)
[ -n "$report_file" ] || fail "diagnostic report was not persisted"
grep -Fq 'IPv4|udp|6100|6101|6102|listening' "$report_file" || fail "report missing IPv4 UDP state"
grep -Fq 'IPv4|tcp|6200|6201|6202|listening' "$report_file" || fail "report missing IPv4 TCP state"
grep -Fq 'IPv6|udp|7100|7101|7102|listening' "$report_file" || fail "report missing IPv6 UDP state"
grep -Fq 'IPv6|tcp|7200|7201|7202|listening' "$report_file" || fail "report missing IPv6 TCP state"

backup_rules >/dev/null || fail "dual-stack backup failed"
backup_file=$LAST_BACKUP_FILE
[ -n "$backup_file" ] || fail "backup file missing"
[ "$(grep -cve '^[[:space:]]*$' "$backup_file")" -eq 4 ] || fail "backup did not preserve all four rules"

# 增加一条备份之外的规则，再从备份恢复，验证精确替换项目规则。
apply_rule_record 4 udp 6300 6301 6302
restore_rules_from_backup_file "$backup_file" || fail "dual-stack backup restore failed"
! iptables -t nat -C PREROUTING -p udp --dport 6300:6301 \
    -m comment --comment "$RULE_COMMENT" -j REDIRECT --to-port 6302 2>/dev/null || \
    fail "restore retained a rule not present in backup"

# 外部规则必须始终保留。
iptables -t nat -C PREROUTING -p udp --dport 5555 \
    -m comment --comment external-owner -j REDIRECT --to-port 5556
ip6tables -t nat -C PREROUTING -p tcp --dport 5557 \
    -m comment --comment external-owner -j REDIRECT --to-port 5558

delete_all_owned_rules >/dev/null || fail "owned-rule deletion failed"
! iptables -t nat -S PREROUTING | grep -Fq "$RULE_COMMENT" || fail "IPv4 owned rules remain"
! ip6tables -t nat -S PREROUTING | grep -Fq "$RULE_COMMENT" || fail "IPv6 owned rules remain"
iptables -t nat -S PREROUTING | grep -Fq external-owner || fail "external IPv4 rule was deleted"
ip6tables -t nat -S PREROUTING | grep -Fq external-owner || fail "external IPv6 rule was deleted"

create_restore_script
"$RESTORE_SCRIPT" || fail "owned-rule restore script failed"
count_before=$(iptables -t nat -S PREROUTING | grep -Fc "$RULE_COMMENT")
count_before=$((count_before + $(ip6tables -t nat -S PREROUTING | grep -Fc "$RULE_COMMENT")))
[ "$count_before" -eq 4 ] || fail "restore did not recreate all four rules"

# 第二次恢复必须幂等。
"$RESTORE_SCRIPT" || fail "second owned-rule restore failed"
count_after=$(iptables -t nat -S PREROUTING | grep -Fc "$RULE_COMMENT")
count_after=$((count_after + $(ip6tables -t nat -S PREROUTING | grep -Fc "$RULE_COMMENT")))
[ "$count_after" -eq "$count_before" ] || fail "restore script created duplicate rules"

echo "PASS: network namespace dual-stack integration"
