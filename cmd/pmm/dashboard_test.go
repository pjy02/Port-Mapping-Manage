package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestRenderDashboardGroupsActionsWithoutHint(t *testing.T) {
	var output bytes.Buffer
	renderDashboard(&output, dashboardStatus{Version: "6.0.0", Health: "正常", Backend: "iptables", Persistence: "已启用", Total: 4, Enabled: 3, IPv4: 2, IPv6: 2, TCP: 1, UDP: 3}, dashboardTheme{})
	text := output.String()
	for _, expected := range []string{"Port Mapping Manager v6.0.0", "运行状态", "常用操作", "系统管理", "维护操作", "[U] 检查更新", "[Q] 退出"} {
		if !strings.Contains(text, expected) {
			t.Fatalf("dashboard missing %q:\n%s", expected, text)
		}
	}
	if strings.Contains(text, "提示") {
		t.Fatalf("dashboard unexpectedly contains a hint section:\n%s", text)
	}
	if strings.Contains(text, "\x1b[") {
		t.Fatal("plain dashboard contains ANSI escapes")
	}
}

func TestDisplayWidthHandlesChineseAndANSI(t *testing.T) {
	if got := displayWidth("规则 IPv6"); got != 9 {
		t.Fatalf("display width = %d, want 9", got)
	}
	if got := displayWidth("\x1b[36m状态\x1b[0m"); got != 4 {
		t.Fatalf("ANSI display width = %d, want 4", got)
	}
}
