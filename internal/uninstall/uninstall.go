package uninstall

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/lock"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/paths"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/persistence"
)

type Plan struct {
	ManagedIPv4 bool     `json:"managed_ipv4"`
	ManagedIPv6 bool     `json:"managed_ipv6"`
	OrphanIPv4  []string `json:"orphan_ipv4,omitempty"`
	OrphanIPv6  []string `json:"orphan_ipv6,omitempty"`
	Paths       []string `json:"paths"`
}

type Manager struct {
	Backend     firewall.Backend
	Persistence persistence.Manager
	Paths       paths.Paths
	LockTimeout time.Duration
	// ExecutablePath is the running PMM executable. It is injected in tests;
	// production callers should pass os.Executable().
	ExecutablePath string
}

func (m Manager) Plan(ctx context.Context) (Plan, error) {
	snapshot, err := m.Backend.Snapshot(ctx)
	if err != nil {
		return Plan{}, err
	}
	return Plan{
		ManagedIPv4: snapshot.IPv4.Managed, ManagedIPv6: snapshot.IPv6.Managed,
		OrphanIPv4: snapshot.IPv4.OrphanChains, OrphanIPv6: snapshot.IPv6.OrphanChains,
		Paths: []string{m.Paths.Config, filepath.Dir(m.Paths.State), filepath.Dir(m.Paths.Log), filepath.Dir(m.Paths.PublicIPv4), m.Paths.Service, m.Paths.Binary},
	}, nil
}

func (m Manager) Execute(ctx context.Context, keepData bool) error {
	handle, err := lock.Acquire(ctx, m.Paths.Lock, m.LockTimeout)
	if err != nil {
		return err
	}
	defer handle.Release()
	before, err := m.Backend.Snapshot(ctx)
	if err != nil {
		return fmt.Errorf("uninstall preflight failed: %w", err)
	}
	if err := m.Backend.DeleteManaged(ctx); err != nil {
		return m.restoreFirewall(ctx, before, fmt.Errorf("remove managed firewall rules: %w", err))
	}
	verified, err := m.Backend.Snapshot(ctx)
	if err != nil {
		return m.restoreFirewall(ctx, before, fmt.Errorf("verify firewall cleanup: %w", err))
	}
	if verified.IPv4.Managed || verified.IPv6.Managed || len(verified.IPv4.OrphanChains) > 0 || len(verified.IPv6.OrphanChains) > 0 {
		return m.restoreFirewall(ctx, before, errors.New("managed firewall objects remain; state files were preserved"))
	}
	status := m.Persistence.Check(ctx)
	if (status.Enabled || status.Active) && !status.FileValid {
		return m.restoreFirewall(ctx, before, errors.New("pmm-rules.service is active or enabled but its contents are not owned by PMM; refusing uninstall"))
	}
	if status.FileValid {
		if err := m.Persistence.Disable(ctx); err != nil {
			return m.restoreFirewall(ctx, before, fmt.Errorf("disable persistence: %w", err))
		}
	}
	if !keepData {
		for _, path := range []string{filepath.Dir(m.Paths.State), filepath.Dir(m.Paths.Log), filepath.Dir(m.Paths.PublicIPv4), filepath.Dir(m.Paths.Config)} {
			if err := removeVerifiedDirectory(path); err != nil {
				return err
			}
		}
	}
	if err := removeRunningBinary(m.Paths.Binary, m.ExecutablePath); err != nil {
		return err
	}
	return nil
}

func removeRunningBinary(path, executablePath string) error {
	target, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !target.Mode().IsRegular() || target.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to remove non-regular or symlink binary %s", path)
	}
	if executablePath == "" {
		return errors.New("cannot prove ownership of installed binary without the running executable path")
	}
	running, err := os.Stat(executablePath)
	if err != nil {
		return fmt.Errorf("stat running executable: %w", err)
	}
	installed, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !os.SameFile(running, installed) {
		return fmt.Errorf("refusing to remove %s because it is not the running PMM executable", path)
	}
	return os.Remove(path)
}

func (m Manager) restoreFirewall(ctx context.Context, before firewall.Snapshot, cause error) error {
	if err := m.Backend.Restore(ctx, before); err != nil {
		return fmt.Errorf("%w; firewall rollback failed: %v", cause, err)
	}
	return cause
}

func removeVerifiedDirectory(path string) error {
	clean := filepath.Clean(path)
	base := filepath.Base(clean)
	if base != "port-mapping-manager" {
		return fmt.Errorf("refusing to remove unexpected directory %s", path)
	}
	info, err := os.Lstat(clean)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to remove non-directory or symlink %s", path)
	}
	return os.RemoveAll(clean)
}
