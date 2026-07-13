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
cat > "$PMM_TEST_RULES_V4" <<'EOF'
-A PREROUTING -p udp -m udp --dport 6000:7000 -m comment --comment udp-port-mapping-script-v4 -j REDIRECT --to-ports 3000
-A PREROUTING -p tcp -m tcp --dport 9999 -j REDIRECT --to-ports 9998
EOF
cat > "$PMM_TEST_RULES_V6" <<'EOF'
-A PREROUTING -p tcp -m tcp --dport 443 -m comment --comment udp-port-mapping-script-v4 -j REDIRECT --to-ports 8443
EOF
export PATH="$TEST_ROOT/bin:$PATH"

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

echo "PASS: unified rule model and owned-rule restore"
