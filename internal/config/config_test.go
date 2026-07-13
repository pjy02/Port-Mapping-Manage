package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadRejectsUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	data := `{"schema_version":1,"backend":"auto","auto_backup":true,"max_backups":20,"public_ip_lookup":"on-demand","report_retention":20,"lock_timeout_seconds":30,"conflict_policy":"strict","verbose":false,"unexpected":true}`
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("unknown config field was accepted")
	}
}

func TestNftablesIsNotAdvertisedBeforeImplementation(t *testing.T) {
	config := Defaults()
	config.Backend = "nftables"
	if err := config.Validate(); err == nil {
		t.Fatal("unimplemented nftables backend was accepted")
	}
}

func TestInvalidBooleanEnvironmentFails(t *testing.T) {
	t.Setenv("PMM_AUTO_BACKUP", "sometimes")
	if _, err := Load(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("invalid environment override was silently ignored")
	}
}
