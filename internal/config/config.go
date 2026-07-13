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
		return Config{}, fmt.Errorf("解析配置文件失败：%w", err)
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
			return errors.New("配置文件包含多个 JSON 值")
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
			return fmt.Errorf("PMM_AUTO_BACKUP 的值 %q 无效，只能使用 true 或 false", value)
		}
		config.AutoBackup = parsed
	}
	if value := os.Getenv("PMM_VERBOSE"); value != "" {
		parsed, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("PMM_VERBOSE 的值 %q 无效，只能使用 true 或 false", value)
		}
		config.Verbose = parsed
	}
	return nil
}

func (c Config) Validate() error {
	if c.SchemaVersion != 1 {
		return fmt.Errorf("不支持的配置结构版本 %d", c.SchemaVersion)
	}
	if c.Backend != "iptables" && c.Backend != "auto" {
		return fmt.Errorf("无效的防火墙后端 %q", c.Backend)
	}
	if c.MaxBackups < 1 || c.MaxBackups > 1000 {
		return errors.New("max_backups 必须在 1 到 1000 之间")
	}
	if c.ReportRetention < 1 || c.ReportRetention > 1000 {
		return errors.New("report_retention 必须在 1 到 1000 之间")
	}
	if c.LockTimeoutSeconds < 1 || c.LockTimeoutSeconds > 600 {
		return errors.New("lock_timeout_seconds 必须在 1 到 600 之间")
	}
	if c.PublicIPLookup != "menu" && c.PublicIPLookup != "on-demand" && c.PublicIPLookup != "off" {
		return fmt.Errorf("无效的 public_ip_lookup 配置 %q", c.PublicIPLookup)
	}
	if c.ConflictPolicy != "strict" && c.ConflictPolicy != "warn" {
		return fmt.Errorf("无效的 conflict_policy 配置 %q", c.ConflictPolicy)
	}
	return nil
}
