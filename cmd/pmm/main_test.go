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
