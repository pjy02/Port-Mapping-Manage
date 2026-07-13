#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
STATE_ROOT="$TEST_ROOT/root"
PMM_BINARY="$TEST_ROOT/pmm"
NAMESPACE="pmm-v6-$$"
LISTENER_PID=""

cleanup() {
    if [ -n "$LISTENER_PID" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    fi
    ip netns del "$NAMESPACE" 2>/dev/null || true
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
    printf '%s\n' "失败：$*" >&2
    exit 1
}

pmm() {
    ip netns exec "$NAMESPACE" "$PMM_BINARY" --root "$STATE_ROOT" "$@"
}

(
    cd "$PROJECT_ROOT"
    CGO_ENABLED=0 go build -trimpath -o "$PMM_BINARY" ./cmd/pmm
)
ip netns add "$NAMESPACE"
ip -n "$NAMESPACE" link set lo up

# Unmanaged rules prove that every mutation, restore and uninstall remains
# inside the PMM-owned anchor and generation chains.
ip netns exec "$NAMESPACE" iptables -t nat -A PREROUTING -p tcp --dport 5500:5501 \
    -m comment --comment external-owner -j REDIRECT --to-ports 5502
ip netns exec "$NAMESPACE" ip6tables -t nat -A PREROUTING -p udp --dport 7500:7501 \
    -m comment --comment external-owner -j REDIRECT --to-ports 7502

pmm rule add --ip 4 --protocol udp --start 6100 --end 6101 --target 6102 >/dev/null
pmm rule add --ip 4 --protocol tcp --start 6200 --end 6201 --target 6202 >/dev/null
pmm rule add --ip 6 --protocol udp --start 7100 --end 7101 --target 7102 >/dev/null
pmm rule add --ip 6 --protocol tcp --start 7200 --end 7201 --target 7202 >/dev/null

ip netns exec "$NAMESPACE" iptables-save -t nat | grep -Fq 'pmm:rule:' || fail "缺少 IPv4 受管规则"
ip netns exec "$NAMESPACE" ip6tables-save -t nat | grep -Fq 'pmm:rule:' || fail "缺少 IPv6 受管规则"
ip netns exec "$NAMESPACE" iptables -t nat -S PREROUTING | grep -Fq external-owner || fail "外部 IPv4 规则被修改"
ip netns exec "$NAMESPACE" ip6tables -t nat -S PREROUTING | grep -Fq external-owner || fail "外部 IPv6 规则被修改"

# Batch import must prevalidate the entire file. The second record conflicts
# with an unmanaged rule, so the first record must never be committed.
cat > "$TEST_ROOT/conflicting-import.conf" <<'EOF'
4|udp|6300|6301|6302
4|tcp|5500|5501|6500
EOF
if pmm import "$TEST_ROOT/conflicting-import.conf" >/dev/null 2>&1; then
    fail "存在冲突的批量导入错误地执行成功"
fi
pmm export "$TEST_ROOT/after-failed-import.conf"
! grep -Fq '6300' "$TEST_ROOT/after-failed-import.conf" || fail "失败的批量导入残留了部分规则"

backup_path=$(pmm backup create)
pmm rule add --ip 4 --protocol udp --start 6400 --end 6401 --target 6402 >/dev/null
pmm backup restore "$backup_path" >/dev/null
pmm export "$TEST_ROOT/restored.conf"
! grep -Fq '6400' "$TEST_ROOT/restored.conf" || fail "恢复备份后仍保留了后续规则"
grep -Fq '6|tcp|7200|7201|7202' "$TEST_ROOT/restored.conf" || fail "恢复备份后缺少 IPv6 TCP 规则"

# One process exposes exact IPv4/IPv6 and TCP/UDP listeners. /proc/net is
# namespace-aware, so doctor must report all four independently.
ip netns exec "$NAMESPACE" python3 -c '
import socket, time
s=[]
for family, kind, port in [
    (socket.AF_INET, socket.SOCK_DGRAM, 6102),
    (socket.AF_INET, socket.SOCK_STREAM, 6202),
    (socket.AF_INET6, socket.SOCK_DGRAM, 7102),
    (socket.AF_INET6, socket.SOCK_STREAM, 7202),
]:
    sock=socket.socket(family, kind)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        address=("::1", port)
    else:
        address=("127.0.0.1", port)
    sock.bind(address)
    if kind == socket.SOCK_STREAM:
        sock.listen(1)
    s.append(sock)
time.sleep(120)
' &
LISTENER_PID=$!
sleep 1
pmm doctor --save >/dev/null
report_file=$(find "$STATE_ROOT/var/log/port-mapping-manager/reports" -type f -name 'diagnostic-*.json' | head -n 1)
[ -n "$report_file" ] || fail "诊断报告未持久保存"
python3 - "$report_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report=json.load(handle)
actual={(item["ip_version"], item["protocol"], item["port"], item["status"]) for item in report["listeners"]}
expected={(4,"udp",6102,"UP"),(4,"tcp",6202,"UP"),(6,"udp",7102,"UP"),(6,"tcp",7202,"UP")}
missing=expected-actual
if missing:
    raise SystemExit(f"缺少监听状态：{missing}；实际结果={actual}")
PY

# Persistence restore is idempotent and monitoring sees both families.
pmm system restore >/dev/null
pmm system restore >/dev/null
pmm monitor --interval 100ms --count 2 > "$TEST_ROOT/monitor.txt"
grep -Fq 'IPv4' "$TEST_ROOT/monitor.txt" || fail "监控输出缺少 IPv4"
grep -Fq 'IPv6' "$TEST_ROOT/monitor.txt" || fail "监控输出缺少 IPv6"

pmm uninstall --keep-data --yes >/dev/null
! ip netns exec "$NAMESPACE" iptables-save -t nat | grep -Fq 'pmm:anchor:v6' || fail "IPv4 受管锚点仍然残留"
! ip netns exec "$NAMESPACE" ip6tables-save -t nat | grep -Fq 'pmm:anchor:v6' || fail "IPv6 受管锚点仍然残留"
ip netns exec "$NAMESPACE" iptables -t nat -S PREROUTING | grep -Fq external-owner || fail "卸载操作删除了外部 IPv4 规则"
ip netns exec "$NAMESPACE" ip6tables -t nat -S PREROUTING | grep -Fq external-owner || fail "卸载操作删除了外部 IPv6 规则"
[ -f "$STATE_ROOT/var/lib/port-mapping-manager/rules.json" ] || fail "--keep-data 删除了规则数据库"

printf '%s\n' "通过：v6 网络命名空间集成测试"
