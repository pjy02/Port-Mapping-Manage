package persistence

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
)

const ServiceName = "pmm-rules.service"

type Status struct {
	FileValid bool   `json:"file_valid"`
	Enabled   bool   `json:"enabled"`
	Active    bool   `json:"active"`
	Error     string `json:"error,omitempty"`
}

type Manager struct {
	Runner      runner.Runner
	ServicePath string
	BinaryPath  string
}

func (m Manager) Unit() string {
	binary := strings.ReplaceAll(m.BinaryPath, `\`, `\\`)
	binary = strings.ReplaceAll(binary, `"`, `\"`)
	return fmt.Sprintf(`[Unit]
Description=Port Mapping Manager owned rules
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart="%s" system restore --boot --non-interactive
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
`, binary)
}

func (m Manager) Check(ctx context.Context) Status {
	status := Status{}
	data, err := os.ReadFile(m.ServicePath)
	if err == nil {
		status.FileValid = string(data) == m.Unit()
	} else if !os.IsNotExist(err) {
		if os.IsPermission(err) {
			status.Error = "读取 systemd 服务文件失败：权限不足"
		} else {
			status.Error = "读取 systemd 服务文件失败：" + err.Error()
		}
	}
	if result, err := m.Runner.Run(ctx, "systemctl", "is-enabled", ServiceName); err == nil && strings.TrimSpace(result.Stdout) == "enabled" {
		status.Enabled = true
	}
	if result, err := m.Runner.Run(ctx, "systemctl", "is-active", ServiceName); err == nil && strings.TrimSpace(result.Stdout) == "active" {
		status.Active = true
	}
	return status
}

func (m Manager) Enable(ctx context.Context) error {
	before := m.Check(ctx)
	previous, readErr := os.ReadFile(m.ServicePath)
	previousExists := readErr == nil
	if readErr != nil && !os.IsNotExist(readErr) {
		return readErr
	}
	if previousExists && string(previous) != m.Unit() {
		return errors.New("同名 systemd 服务不属于 PMM，拒绝覆盖")
	}
	if err := storage.WriteFileAtomic(m.ServicePath, []byte(m.Unit()), 0o644); err != nil {
		return err
	}
	if _, err := m.Runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		return errors.Join(err, m.rollbackUnit(ctx, before, previous, previousExists))
	}
	if _, err := m.Runner.Run(ctx, "systemctl", "enable", ServiceName); err != nil {
		return errors.Join(err, m.rollbackUnit(ctx, before, previous, previousExists))
	}
	if _, err := m.Runner.Run(ctx, "systemctl", "start", ServiceName); err != nil {
		return errors.Join(err, m.rollbackUnit(ctx, before, previous, previousExists))
	}
	return nil
}

func (m Manager) Disable(ctx context.Context) error {
	status := m.Check(ctx)
	if !status.FileValid {
		return errors.New("同名 systemd 服务不属于 PMM，拒绝禁用或删除")
	}
	if _, err := m.Runner.Run(ctx, "systemctl", "disable", "--now", ServiceName); err != nil {
		return err
	}
	if err := os.Remove(m.ServicePath); err != nil && !os.IsNotExist(err) {
		return err
	}
	_, err := m.Runner.Run(ctx, "systemctl", "daemon-reload")
	return err
}

func (m Manager) rollbackUnit(ctx context.Context, before Status, previous []byte, previousExists bool) error {
	var rollbackErrors []error
	if previousExists {
		if err := storage.WriteFileAtomic(m.ServicePath, previous, 0o644); err != nil {
			rollbackErrors = append(rollbackErrors, fmt.Errorf("恢复原服务文件失败：%w", err))
		}
	} else if err := os.Remove(m.ServicePath); err != nil && !os.IsNotExist(err) {
		rollbackErrors = append(rollbackErrors, fmt.Errorf("删除候选服务文件失败：%w", err))
	}
	if _, err := m.Runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		rollbackErrors = append(rollbackErrors, fmt.Errorf("重新加载已恢复的服务失败：%w", err))
	}
	if !before.Enabled {
		if _, err := m.Runner.Run(ctx, "systemctl", "disable", ServiceName); err != nil {
			rollbackErrors = append(rollbackErrors, fmt.Errorf("恢复服务禁用状态失败：%w", err))
		}
	}
	if before.Active {
		if _, err := m.Runner.Run(ctx, "systemctl", "start", ServiceName); err != nil {
			rollbackErrors = append(rollbackErrors, fmt.Errorf("恢复服务运行状态失败：%w", err))
		}
	} else {
		if _, err := m.Runner.Run(ctx, "systemctl", "stop", ServiceName); err != nil {
			rollbackErrors = append(rollbackErrors, fmt.Errorf("恢复服务停止状态失败：%w", err))
		}
	}
	return errors.Join(rollbackErrors...)
}
