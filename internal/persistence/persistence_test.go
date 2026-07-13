package persistence

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
)

func TestDisableRefusesForeignUnit(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, ServiceName)
	if err := os.WriteFile(path, []byte("[Service]\nExecStart=/bin/foreign\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	fake := &recordingRunner{}
	manager := Manager{Runner: fake, ServicePath: path, BinaryPath: "/usr/local/bin/pmm"}
	if err := manager.Disable(context.Background()); err == nil {
		t.Fatal("foreign unit was removed")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("foreign unit changed: %v", err)
	}
	for _, call := range fake.calls {
		if strings.Contains(call, "disable --now") {
			t.Fatalf("systemctl mutated foreign unit: %v", fake.calls)
		}
	}
}

func TestEnableFailureRestoresPreviousUnit(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, ServiceName)
	manager := Manager{ServicePath: path, BinaryPath: "/usr/local/bin/pmm"}
	previous := []byte(manager.Unit())
	if err := os.WriteFile(path, previous, 0o644); err != nil {
		t.Fatal(err)
	}
	fake := &recordingRunner{failOnce: "systemctl enable " + ServiceName}
	manager.Runner = fake
	if err := manager.Enable(context.Background()); err == nil {
		t.Fatal("injected enable failure was ignored")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(previous) {
		t.Fatalf("previous unit was not restored: %q", got)
	}
}

func TestEnableRefusesForeignUnit(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, ServiceName)
	foreign := []byte("[Service]\nExecStart=/bin/foreign\n")
	if err := os.WriteFile(path, foreign, 0o644); err != nil {
		t.Fatal(err)
	}
	fake := &recordingRunner{}
	manager := Manager{Runner: fake, ServicePath: path, BinaryPath: "/usr/local/bin/pmm"}
	if err := manager.Enable(context.Background()); err == nil {
		t.Fatal("foreign unit was overwritten")
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != string(foreign) {
		t.Fatalf("foreign unit changed: %q %v", got, err)
	}
}

func TestUnitQuotesBinaryPath(t *testing.T) {
	unit := (Manager{BinaryPath: `/path with space/pmm`}).Unit()
	if !strings.Contains(unit, `ExecStart="/path with space/pmm" system restore`) {
		t.Fatalf("binary path is not quoted: %s", unit)
	}
}

type recordingRunner struct {
	calls    []string
	failOnce string
}

func (r *recordingRunner) Run(_ context.Context, name string, args ...string) (runner.Result, error) {
	call := name + " " + strings.Join(args, " ")
	r.calls = append(r.calls, call)
	if call == r.failOnce {
		r.failOnce = ""
		return runner.Result{ExitCode: 1}, errors.New("injected failure")
	}
	return runner.Result{}, nil
}
