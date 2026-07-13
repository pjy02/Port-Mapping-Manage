package main

import (
	"bytes"
	"errors"
	"flag"
	"io"
	"strings"
	"testing"
)

func TestLegacyGlobalAliases(t *testing.T) {
	tests := []struct {
		args      []string
		command   string
		defaultIP int
	}{
		{[]string{"--version"}, "version", 4},
		{[]string{"--help"}, "help", 4},
		{[]string{"--uninstall", "--yes"}, "uninstall", 4},
		{[]string{"--ip-version", "6", "menu"}, "menu", 6},
	}
	for _, test := range tests {
		options, err := parseGlobal(test.args)
		if err != nil {
			t.Fatalf("%v: %v", test.args, err)
		}
		if len(options.remaining) == 0 || options.remaining[0] != test.command || options.defaultIP != test.defaultIP {
			t.Fatalf("%v parsed incorrectly: %+v", test.args, options)
		}
	}
}

func TestUnknownGlobalOptionFails(t *testing.T) {
	if _, err := parseGlobal([]string{"--does-not-exist"}); err == nil {
		t.Fatal("unknown global option was accepted")
	}
}

func TestCommandFlagErrorsAreChinese(t *testing.T) {
	flags := flag.NewFlagSet("测试命令", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.Int("count", 1, "执行次数")
	err := parseCommandFlags(flags, []string{"--does-not-exist"}, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "未知选项") || strings.Contains(err.Error(), "flag provided") {
		t.Fatalf("参数错误未正确中文化：%v", err)
	}
}

func TestCommandFlagHelpUsesChineseDefaults(t *testing.T) {
	flags := flag.NewFlagSet("测试命令", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.Int("count", 1, "执行次数")
	var output bytes.Buffer
	err := parseCommandFlags(flags, []string{"--help"}, &output)
	if !errors.Is(err, errFlagHelpShown) {
		t.Fatalf("帮助请求返回了意外错误：%v", err)
	}
	text := output.String()
	if !strings.Contains(text, "可用选项") || !strings.Contains(text, "默认值：1") || strings.Contains(text, "default") {
		t.Fatalf("参数帮助未完全中文化：%q", text)
	}
}

func TestRuleTableChineseHeaderAlignment(t *testing.T) {
	var output bytes.Buffer
	renderRuleTableHeader(&output)
	renderRuleTableRow(&output, "85b2f9822f0a89cc", "IPv4", "udp", "6000-7000", "3000", "启用")
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("规则表行数异常：%q", output.String())
	}
	columns := [][2]string{
		{"ID", "85b2f9822f0a89cc"},
		{"IP", "IPv4"},
		{"协议", "udp"},
		{"来源端口", "6000-7000"},
		{"目标", "3000"},
		{"状态", "启用"},
	}
	for _, column := range columns {
		headerStart := displayStart(lines[0], column[0])
		valueStart := displayStart(lines[1], column[1])
		if headerStart < 0 || valueStart < 0 || headerStart != valueStart {
			t.Fatalf("列 %q 未对齐：表头=%d，数据=%d\n%s", column[0], headerStart, valueStart, output.String())
		}
	}
}

func displayStart(line, value string) int {
	index := strings.Index(line, value)
	if index < 0 {
		return -1
	}
	return displayWidth(line[:index])
}
