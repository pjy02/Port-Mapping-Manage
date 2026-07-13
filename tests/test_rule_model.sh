#!/bin/bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export PMM_SOURCE_ONLY=true
# shellcheck source=../port_mapping_manager.sh
source "$PROJECT_ROOT/port_mapping_manager.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT

# 在 Git Bash/Windows 中优先使用 POSIX 工具，避免命中 Windows sort/find。
export PATH="/usr/bin:$PATH"

CONFIG_DIR="$TEST_ROOT/etc/port_mapping_manager"
BACKUP_DIR="$CONFIG_DIR/backups"
CONFIG_FILE="$CONFIG_DIR/config.conf"
RULES_DB="$CONFIG_DIR/rules.db"
RESTORE_SCRIPT="$CONFIG_DIR/restore-owned-rules.sh"
LOG_FILE="$TEST_ROOT/pmm.log"
PERSISTENCE_SERVICE="pmm-rules.service"
PERSISTENCE_SERVICE_FILE="$TEST_ROOT/$PERSISTENCE_SERVICE"
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$TEST_ROOT/bin"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "expected '$1' to equal '$2'"
}

validate_rule_record 4 udp 6000 7000 3000 || fail "valid IPv4 UDP record rejected"
validate_rule_record 6 tcp 443 443 8443 || fail "valid IPv6 TCP record rejected"
! validate_rule_record 5 udp 1 2 3 || fail "invalid IP version accepted"
! validate_rule_record 4 sctp 1 2 3 || fail "invalid protocol accepted"
! validate_rule_record 4 tcp 200 100 300 || fail "reversed range accepted"

rule_model_add 4 udp 6000 7000 3000
rule_model_add 4 udp 6000 7000 3000
rule_model_add 6 tcp 443 443 8443
assert_eq "$(wc -l < "$RULES_DB" | tr -d ' ')" "2"
validate_rule_model_file || fail "generated model is invalid"

rule_model_remove 4 udp 6000 7000 3000
assert_eq "$(wc -l < "$RULES_DB" | tr -d ' ')" "1"
rule_model_add 4 udp 6000 7000 3000

cat > "$TEST_ROOT/bin/iptables" <<'MOCK'
#!/bin/bash
set -u
state=${PMM_TEST_STATE:?}
args="$*"
if [[ " $args " == *" -L PREROUTING "* ]]; then
    if [ "$(basename "$0")" = ip6tables ]; then
        cat "${PMM_TEST_CACHE_V6:?}"
    else
        cat "${PMM_TEST_CACHE_V4:?}"
    fi
    exit 0
fi
if [[ " $args " == *" -S PREROUTING "* ]]; then
    if [ "$(basename "$0")" = ip6tables ]; then
        cat "${PMM_TEST_RULES_V6:?}"
    else
        cat "${PMM_TEST_RULES_V4:?}"
    fi
    exit 0
fi
if [[ " $args " == *" -C "* ]]; then
    protocol=""
    dport=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -p) protocol=$2; shift 2 ;;
            --dport) dport=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    grep -Fq -- "-p $protocol --dport $dport " "$state" 2>/dev/null
    exit $?
fi
if [[ " $args " == *" -A "* ]]; then
    printf '%s\n' "$args" >> "$state"
    exit 0
fi
exit 0
MOCK
cp "$TEST_ROOT/bin/iptables" "$TEST_ROOT/bin/ip6tables"
chmod +x "$TEST_ROOT/bin/iptables" "$TEST_ROOT/bin/ip6tables"

export PMM_TEST_STATE="$TEST_ROOT/kernel-state"
touch "$PMM_TEST_STATE"
export PMM_TEST_RULES_V4="$TEST_ROOT/rules-v4"
export PMM_TEST_RULES_V6="$TEST_ROOT/rules-v6"
export PMM_TEST_CACHE_V4="$TEST_ROOT/cache-v4"
export PMM_TEST_CACHE_V6="$TEST_ROOT/cache-v6"
cat > "$PMM_TEST_RULES_V4" <<'EOF'
-A PREROUTING -p udp -m udp --dport 6000:7000 -m comment --comment udp-port-mapping-script-v4 -j REDIRECT --to-ports 3000
-A PREROUTING -p tcp -m tcp --dport 9999 -j REDIRECT --to-ports 9998
EOF
cat > "$PMM_TEST_RULES_V6" <<'EOF'
-A PREROUTING -p tcp -m tcp --dport 443 -m comment --comment udp-port-mapping-script-v4 -j REDIRECT --to-ports 8443
EOF
printf 'Chain PREROUTING\nnum target prot source destination\n1 REDIRECT udp 0.0.0.0/0 0.0.0.0/0 udp dpts:6000:7000 /* udp-port-mapping-script-v4 */ redir ports 3000\n' > "$PMM_TEST_CACHE_V4"
printf 'Chain PREROUTING\nnum target prot source destination\n1 REDIRECT tcp ::/0 ::/0 tcp dpt:443 /* udp-port-mapping-script-v4 */ redir ports 8443\n' > "$PMM_TEST_CACHE_V6"
export PATH="$TEST_ROOT/bin:$PATH"

clear_iptables_cache
cache_iptables_rules 4 > "$TEST_ROOT/cache-out-v4"
cache_iptables_rules 6 > "$TEST_ROOT/cache-out-v6"
grep -Fq 'dpts:6000:7000' "$TEST_ROOT/cache-out-v4" || fail "IPv4 cache content missing"
! grep -Fq 'dpt:443' "$TEST_ROOT/cache-out-v4" || fail "IPv6 data leaked into IPv4 cache"
grep -Fq 'dpt:443' "$TEST_ROOT/cache-out-v6" || fail "IPv6 cache content missing"
! grep -Fq 'dpts:6000:7000' "$TEST_ROOT/cache-out-v6" || fail "IPv4 data leaked into IPv6 cache"

sync_rule_model_from_kernel
assert_eq "$(wc -l < "$RULES_DB" | tr -d ' ')" "2"
grep -Fxq '4|udp|6000|7000|3000' "$RULES_DB" || fail "IPv4 migration record missing"
grep -Fxq '6|tcp|443|443|8443' "$RULES_DB" || fail "IPv6 migration record missing"

backup_rules >/dev/null
backup_file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'owned_rules_*.db' | head -n1)
[ -n "$backup_file" ] || fail "owned-rule backup was not created"
validate_rule_model_file "$backup_file" || fail "owned-rule backup is invalid"

create_restore_script
bash -n "$RESTORE_SCRIPT" || fail "generated restore script has invalid syntax"
bash "$RESTORE_SCRIPT" || fail "restore script failed"
assert_eq "$(wc -l < "$PMM_TEST_STATE" | tr -d ' ')" "2"

# 第二次执行必须幂等，不能重复添加规则。
bash "$RESTORE_SCRIPT" || fail "second restore failed"
assert_eq "$(wc -l < "$PMM_TEST_STATE" | tr -d ' ')" "2"

grep -Fq -- '--comment udp-port-mapping-script-v4' "$PMM_TEST_STATE" || fail "owned comment missing"
grep -Fq -- '-p udp --dport 6000:7000' "$PMM_TEST_STATE" || fail "IPv4 UDP rule missing"
grep -Fq -- '-p tcp --dport 443:443' "$PMM_TEST_STATE" || fail "IPv6 TCP rule missing"

cat > "$TEST_ROOT/import.conf" <<'EOF'
4|tcp|8000|8001|8080
6|udp|9000|9001|9090
EOF
import_rules_from_file "$TEST_ROOT/import.conf"
assert_eq "${IMPORT_SUCCESS_COUNT:-0}" "2"
assert_eq "${IMPORT_ERROR_COUNT:-0}" "0"
grep -Fq -- '-p tcp --dport 8000:8001' "$PMM_TEST_STATE" || fail "batch IPv4 TCP rule missing"
grep -Fq -- '-p udp --dport 9000:9001' "$PMM_TEST_STATE" || fail "batch IPv6 UDP rule missing"

export_rules_to_file "$TEST_ROOT/export.conf"
grep -Fxq '4|udp|6000|7000|3000' "$TEST_ROOT/export.conf" || fail "exported IPv4 record missing"
grep -Fxq '6|tcp|443|443|8443' "$TEST_ROOT/export.conf" || fail "exported IPv6 record missing"

cat > "$TEST_ROOT/bin/ss" <<'MOCK'
#!/bin/bash
args=" $* "
if [[ "$args" == *" -4 "* && "$args" == *" -t "* ]]; then
    echo 'LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("svc4",pid=1,fd=3))'
elif [[ "$args" == *" -6 "* && "$args" == *" -u "* ]]; then
    echo 'UNCONN 0 0 [::]:9090 [::]:* users:(("svc6",pid=2,fd=4))'
fi
MOCK
chmod +x "$TEST_ROOT/bin/ss"
is_service_listening 4 tcp 8080 || fail "IPv4 TCP listener not detected"
! is_service_listening 6 tcp 8080 || fail "IPv4 listener leaked into IPv6 TCP check"
is_service_listening 6 udp 9090 || fail "IPv6 UDP listener not detected"
! is_service_listening 4 udp 9090 || fail "IPv6 listener leaked into IPv4 UDP check"

# 冲突检查必须同时匹配地址族、协议和完整范围。
! check_port_conflicts 6500 6600 8080 udp 4 || fail "overlapping owned IPv4 UDP range not detected"
check_port_conflicts 6500 6600 8080 tcp 4 || fail "UDP range leaked into IPv4 TCP conflict check"
! check_port_conflicts 9999 9999 8080 tcp 4 || fail "external IPv4 TCP conflict not detected"
check_port_conflicts 9999 9999 8080 udp 4 || fail "external TCP range leaked into UDP conflict check"
! check_port_conflicts 443 443 8080 tcp 6 || fail "owned IPv6 TCP conflict not detected"
check_port_conflicts 443 443 8080 tcp 4 || fail "IPv6 range leaked into IPv4 conflict check"

# 事务型批量导入：只备份一次，第二条失败后必须回滚整个批次。
BACKUP_CALLS=0
APPLY_CALLS=0
ROLLBACK_CALLS=0
extract_owned_rules() { return 0; }
backup_rules() {
    BACKUP_CALLS=$((BACKUP_CALLS + 1))
    LAST_BACKUP_FILE="$TEST_ROOT/transaction-backup.db"
    : > "$LAST_BACKUP_FILE"
}
apply_rule_record() {
    APPLY_CALLS=$((APPLY_CALLS + 1))
    [ "$5" != 9999 ]
}
restore_rules_from_backup_file() {
    [ "$1" = "$LAST_BACKUP_FILE" ] || return 1
    ROLLBACK_CALLS=$((ROLLBACK_CALLS + 1))
}
cat > "$TEST_ROOT/invalid-transaction.conf" <<'EOF'
4|tcp|8200|8201|8080
6|udp|not-a-port|9201|9090
EOF
if import_rules_from_file "$TEST_ROOT/invalid-transaction.conf"; then
    fail "invalid transaction unexpectedly succeeded"
fi
assert_eq "$BACKUP_CALLS" "0"
assert_eq "$APPLY_CALLS" "0"
assert_eq "$ROLLBACK_CALLS" "0"

cat > "$TEST_ROOT/transaction.conf" <<'EOF'
4|tcp|8100|8101|8080
6|udp|9100|9101|9999
EOF
if import_rules_from_file "$TEST_ROOT/transaction.conf"; then
    fail "transactional import unexpectedly succeeded"
fi
assert_eq "$BACKUP_CALLS" "1"
assert_eq "$APPLY_CALLS" "2"
assert_eq "$ROLLBACK_CALLS" "1"
assert_eq "$IMPORT_SUCCESS_COUNT" "0"

echo "PASS: rule model, dual-stack cache, batch I/O, backup and restore"
