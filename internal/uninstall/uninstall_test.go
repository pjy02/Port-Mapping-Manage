package uninstall

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/paths"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/persistence"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
)

func TestDeleteFailureRestoresFirewall(t *testing.T) {
	root := t.TempDir()
	backend := &uninstallBackend{state: managedSnapshot(), failDelete: true}
	manager := Manager{Backend: backend, Paths: paths.ForRoot(root), LockTimeout: time.Second}
	if err := manager.Execute(context.Background(), true); err == nil {
		t.Fatal("delete failure was ignored")
	}
	if backend.restoreCalls != 1 || !backend.state.IPv4.Managed {
		t.Fatalf("firewall was not restored: calls=%d state=%+v", backend.restoreCalls, backend.state)
	}
}

func TestKeepDataStillRemovesBinary(t *testing.T) {
	root := t.TempDir()
	pathSet := paths.ForRoot(root)
	backend := &uninstallBackend{state: managedSnapshot()}
	fakeRunner := quietRunner{}
	persistenceManager := persistence.Manager{Runner: fakeRunner, ServicePath: pathSet.Service, BinaryPath: pathSet.Binary}
	writeFile(t, pathSet.Service, persistenceManager.Unit())
	writeFile(t, pathSet.Binary, "binary")
	writeFile(t, pathSet.State, "preserved")
	manager := Manager{Backend: backend, Persistence: persistenceManager, Paths: pathSet, LockTimeout: time.Second, ExecutablePath: pathSet.Binary}
	if err := manager.Execute(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(pathSet.Binary); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("binary remains after uninstall: %v", err)
	}
	if _, err := os.Stat(pathSet.State); err != nil {
		t.Fatalf("keep-data removed state: %v", err)
	}
}

type uninstallBackend struct {
	state        firewall.Snapshot
	failDelete   bool
	restoreCalls int
}

func (b *uninstallBackend) Probe(context.Context) error { return nil }
func (b *uninstallBackend) Snapshot(context.Context) (firewall.Snapshot, error) {
	return b.state, nil
}
func (b *uninstallBackend) InspectExternal(context.Context) ([]firewall.ExternalRange, error) {
	return nil, nil
}
func (b *uninstallBackend) Counters(context.Context) ([]firewall.Counter, error) { return nil, nil }
func (b *uninstallBackend) Apply(context.Context, []model.Rule) error            { return nil }
func (b *uninstallBackend) Verify(context.Context, []model.Rule) error           { return nil }
func (b *uninstallBackend) Restore(_ context.Context, snapshot firewall.Snapshot) error {
	b.restoreCalls++
	b.state = snapshot
	return nil
}
func (b *uninstallBackend) DeleteManaged(context.Context) error {
	b.state = firewall.Snapshot{}
	if b.failDelete {
		return errors.New("injected delete failure")
	}
	return nil
}

func managedSnapshot() firewall.Snapshot {
	return firewall.Snapshot{
		IPv4: firewall.FamilySnapshot{IPVersion: 4, Managed: true, ActiveChain: "PMM_G_1"},
		IPv6: firewall.FamilySnapshot{IPVersion: 6, Managed: true, ActiveChain: "PMM_G_2"},
	}
}

type quietRunner struct{}

func (quietRunner) Run(_ context.Context, name string, args ...string) (runner.Result, error) {
	call := name + " " + strings.Join(args, " ")
	if strings.Contains(call, "is-enabled") {
		return runner.Result{Stdout: "disabled\n"}, nil
	}
	if strings.Contains(call, "is-active") {
		return runner.Result{Stdout: "inactive\n"}, nil
	}
	return runner.Result{}, nil
}

func writeFile(t *testing.T, path, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0o755); err != nil {
		t.Fatal(err)
	}
}
