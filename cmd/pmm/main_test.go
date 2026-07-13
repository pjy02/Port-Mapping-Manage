package main

import "testing"

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
