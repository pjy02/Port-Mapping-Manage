package listener

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
)

const procHeader = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

func TestInspectorKeepsFamilyAndProtocolSeparate(t *testing.T) {
	root := t.TempDir()
	writeProc(t, root, "tcp", socketLine("00000000", 8080, "0A"))
	writeProc(t, root, "udp", socketLine("00000000", 5353, "07"))
	writeProc(t, root, "tcp6", socketLine("00000000000000000000000000000001", 9090, "0A"))
	writeProc(t, root, "udp6", socketLine("00000000000000000000000000000001", 6000, "07"))
	writeValue(t, filepath.Join(root, "sys", "net", "ipv6", "bindv6only"), "1\n")
	inspector := Inspector{ProcRoot: root}
	tests := []struct {
		version  int
		protocol model.Protocol
		port     uint16
		want     Status
	}{
		{4, model.TCP, 8080, Up}, {6, model.TCP, 8080, Down},
		{4, model.UDP, 5353, Up}, {6, model.UDP, 5353, Down},
		{6, model.TCP, 9090, Up}, {4, model.TCP, 9090, Down},
		{6, model.UDP, 6000, Up}, {4, model.UDP, 6000, Down},
	}
	for _, test := range tests {
		got := inspector.Check(model.Rule{IPVersion: test.version, Protocol: test.protocol, TargetPort: test.port})
		if got.Status != test.want {
			t.Errorf("IPv%d/%s/%d: got %s, want %s (%s)", test.version, test.protocol, test.port, got.Status, test.want, got.Error)
		}
	}
}

func TestIPv6WildcardCanServeIPv4(t *testing.T) {
	root := t.TempDir()
	writeProc(t, root, "tcp", "")
	writeProc(t, root, "udp", "")
	writeProc(t, root, "tcp6", socketLine("00000000000000000000000000000000", 8443, "0A"))
	writeProc(t, root, "udp6", "")
	writeValue(t, filepath.Join(root, "sys", "net", "ipv6", "bindv6only"), "0\n")
	got := (Inspector{ProcRoot: root}).Check(model.Rule{IPVersion: 4, Protocol: model.TCP, TargetPort: 8443})
	if got.Status != Up {
		t.Fatalf("dual-stack wildcard was not detected: %+v", got)
	}
}

func socketLine(address string, port uint16, state string) string {
	return "   0: " + address + ":" + hexPort(port) + " 00000000:0000 " + state + " 00000000:00000000 00:00000000 00000000 0 0 0\n"
}

func hexPort(port uint16) string {
	const digits = "0123456789ABCDEF"
	result := []byte{'0', '0', '0', '0'}
	for index := 3; index >= 0; index-- {
		result[index] = digits[port&0xf]
		port >>= 4
	}
	return string(result)
}

func writeProc(t *testing.T, root, name, body string) {
	t.Helper()
	writeValue(t, filepath.Join(root, "net", name), procHeader+body)
}

func writeValue(t *testing.T, path, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}
