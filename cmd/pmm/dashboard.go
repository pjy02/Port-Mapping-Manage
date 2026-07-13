package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/persistence"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/version"
)

const dashboardWidth = 72

type dashboardStatus struct {
	Version     string
	Health      string
	Backend     string
	Persistence string
	Total       int
	Enabled     int
	IPv4        int
	IPv6        int
	TCP         int
	UDP         int
}

type dashboardTheme struct {
	color bool
}

func (c cli) dashboardStatus(ctx context.Context) dashboardStatus {
	status := dashboardStatus{Version: version.Version, Health: "正常", Backend: "iptables", Persistence: "未启用"}
	set, err := c.app.Store.Load()
	if err != nil {
		status.Health = "数据异常"
	} else {
		for _, rule := range set.Rules {
			status.Total++
			if rule.Enabled {
				status.Enabled++
			}
			switch rule.IPVersion {
			case 4:
				status.IPv4++
			case 6:
				status.IPv6++
			}
			switch rule.Protocol {
			case model.TCP:
				status.TCP++
			case model.UDP:
				status.UDP++
			}
		}
	}
	if state, stateErr := c.app.State(ctx); stateErr != nil {
		if status.Health == "正常" {
			status.Health = "检查失败"
		}
	} else if state.Drift {
		status.Health = "状态漂移"
	}
	persistenceStatus := (persistence.Manager{Runner: c.runner, ServicePath: c.paths.Service, BinaryPath: c.paths.Binary}).Check(ctx)
	switch {
	case persistenceStatus.Error != "":
		status.Persistence = "检查异常"
	case persistenceStatus.FileValid && persistenceStatus.Enabled && persistenceStatus.Active:
		status.Persistence = "已启用"
	case persistenceStatus.FileValid && persistenceStatus.Enabled:
		status.Persistence = "未运行"
	case persistenceStatus.FileValid:
		status.Persistence = "已禁用"
	}
	return status
}

func newDashboardTheme(w io.Writer) dashboardTheme {
	return dashboardTheme{color: isTerminalFile(w) && os.Getenv("NO_COLOR") == "" && os.Getenv("TERM") != "dumb"}
}

func (t dashboardTheme) paint(code, value string) string {
	if !t.color {
		return value
	}
	return "\x1b[" + code + "m" + value + "\x1b[0m"
}

func renderDashboard(w io.Writer, status dashboardStatus, theme dashboardTheme) {
	top := "╭" + strings.Repeat("─", dashboardWidth-2) + "╮"
	middle := "├" + strings.Repeat("─", dashboardWidth-2) + "┤"
	bottom := "╰" + strings.Repeat("─", dashboardWidth-2) + "╯"
	line := func(value string) {
		fmt.Fprintf(w, "│ %s │\n", padDisplay(value, dashboardWidth-4))
	}
	section := func(title string) {
		fmt.Fprintln(w, theme.paint("36", middle))
		line(theme.paint("1;36", title))
	}
	row := func(left, right string) {
		columnWidth := (dashboardWidth - 4) / 2
		line(padDisplay(left, columnWidth) + padDisplay(right, columnWidth))
	}

	fmt.Fprintln(w, theme.paint("1;36", top))
	line(theme.paint("1", "Port Mapping Manager v"+status.Version))
	section("运行状态")
	row("状态："+status.Health, "后端："+status.Backend)
	row("持久化："+status.Persistence, fmt.Sprintf("规则：%d（启用 %d）", status.Total, status.Enabled))
	row(fmt.Sprintf("IPv4：%d    IPv6：%d", status.IPv4, status.IPv6), fmt.Sprintf("TCP：%d    UDP：%d", status.TCP, status.UDP))
	section("常用操作")
	row("[1] 规则列表", "[2] 添加规则")
	row("[3] 管理规则", "[4] 流量监控")
	row("[5] 系统诊断", "[6] 批量导入导出")
	section("系统管理")
	row("[7] 备份与恢复", "[8] 持久化管理")
	row("[9] 公网地址", "[10] 旧版迁移")
	section("维护操作")
	row("[U] 检查更新", "[X] 安全卸载")
	row("[Q] 退出", "")
	fmt.Fprintln(w, theme.paint("1;36", bottom))
}

func padDisplay(value string, width int) string {
	visible := displayWidth(value)
	if visible >= width {
		return value
	}
	return value + strings.Repeat(" ", width-visible)
}

func displayWidth(value string) int {
	width := 0
	escape := false
	for _, r := range value {
		if escape {
			if unicode.IsLetter(r) {
				escape = false
			}
			continue
		}
		if r == '\x1b' {
			escape = true
			continue
		}
		if unicode.IsControl(r) || unicode.Is(unicode.Mn, r) {
			continue
		}
		if isWideRune(r) {
			width += 2
		} else {
			width++
		}
	}
	return width
}

func isWideRune(r rune) bool {
	return r >= 0x1100 && (r <= 0x115f || r == 0x2329 || r == 0x232a ||
		(r >= 0x2e80 && r <= 0xa4cf && r != 0x303f) ||
		(r >= 0xac00 && r <= 0xd7a3) || (r >= 0xf900 && r <= 0xfaff) ||
		(r >= 0xfe10 && r <= 0xfe19) || (r >= 0xfe30 && r <= 0xfe6f) ||
		(r >= 0xff00 && r <= 0xff60) || (r >= 0xffe0 && r <= 0xffe6) ||
		(r >= 0x20000 && r <= 0x3fffd))
}

func isTerminalFile(value any) bool {
	file, ok := value.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
