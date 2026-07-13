package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
)

type Config struct {
	SchemaVersion      int    `json:"schema_version"`
	Backend            string `json:"backend"`
	AutoBackup         bool   `json:"auto_backup"`
	MaxBackups         int    `json:"max_backups"`
	PublicIPLookup     string `json:"public_ip_lookup"`
	ReportRetention    int    `json:"report_retention"`
	LockTimeoutSeconds int    `json:"lock_timeout_seconds"`
	ConflictPolicy     string `json:"conflict_policy"`
	Verbose            bool   `json:"verbose"`
}

func Defaults() Config {
	return Config{
		SchemaVersion: 1, Backend: "iptables", AutoBackup: true, MaxBackups: 20,
		PublicIPLookup: "menu", ReportRetention: 20, LockTimeoutSeconds: 30,
		ConflictPolicy: "strict",
	}
}

func Load(path string) (Config, error) {
	config := Defaults()
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		if err := applyEnvironment(&config); err != nil {
			return Config{}, err
		}
		return config, config.Validate()
	}
	if err != nil {
		return Config{}, err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("decode config: %w", err)
	}
	if err := ensureEOF(decoder); err != nil {
		return Config{}, err
	}
	if err := applyEnvironment(&config); err != nil {
		return Config{}, err
	}
	return config, config.Validate()
}

func ensureEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("config contains multiple JSON values")
		}
		return err
	}
	return nil
}

func applyEnvironment(config *Config) error {
	if value := os.Getenv("PMM_BACKEND"); value != "" {
		config.Backend = value
	}
	if value := os.Getenv("PMM_AUTO_BACKUP"); value != "" {
		parsed, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("PMM_AUTO_BACKUP: %w", err)
		}
		config.AutoBackup = parsed
	}
	if value := os.Getenv("PMM_VERBOSE"); value != "" {
		parsed, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("PMM_VERBOSE: %w", err)
		}
		config.Verbose = parsed
	}
	return nil
}

func (c Config) Validate() error {
	if c.SchemaVersion != 1 {
		return fmt.Errorf("unsupported config schema %d", c.SchemaVersion)
	}
	if c.Backend != "iptables" && c.Backend != "auto" {
		return fmt.Errorf("invalid backend %q", c.Backend)
	}
	if c.MaxBackups < 1 || c.MaxBackups > 1000 {
		return errors.New("max_backups must be between 1 and 1000")
	}
	if c.ReportRetention < 1 || c.ReportRetention > 1000 {
		return errors.New("report_retention must be between 1 and 1000")
	}
	if c.LockTimeoutSeconds < 1 || c.LockTimeoutSeconds > 600 {
		return errors.New("lock_timeout_seconds must be between 1 and 600")
	}
	if c.PublicIPLookup != "menu" && c.PublicIPLookup != "on-demand" && c.PublicIPLookup != "off" {
		return fmt.Errorf("invalid public_ip_lookup %q", c.PublicIPLookup)
	}
	if c.ConflictPolicy != "strict" && c.ConflictPolicy != "warn" {
		return fmt.Errorf("invalid conflict_policy %q", c.ConflictPolicy)
	}
	return nil
}
