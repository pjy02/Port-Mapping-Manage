package migration

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
)

func TestPlanSelectsMatchingLegacyDatabaseAndKernel(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "rules.db"), []byte("4|udp|6000|7000|3000\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	backend := firewall.NewIPTables(legacyRunner{ipv4: legacyLine()})
	manager := Manager{Backend: backend, LegacyDir: root}
	plan, err := manager.Plan(context.Background(), Auto)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.SelectedRules) != 1 || plan.SelectedRules[0].IPVersion != 4 {
		t.Fatalf("matching migration sources not selected: %+v", plan)
	}
}

func TestPlanRejectsExternalConflict(t *testing.T) {
	root := t.TempDir()
	output := strings.Join([]string{
		"-A PREROUTING -p udp --dport 6500:6600 -m comment --comment external -j REDIRECT --to-ports 9000",
		legacyLine(),
	}, "\n")
	manager := Manager{Backend: firewall.NewIPTables(legacyRunner{ipv4: output}), LegacyDir: root}
	if _, err := manager.Plan(context.Background(), Auto); err == nil || !strings.Contains(err.Error(), "与外部规则冲突") {
		t.Fatalf("external migration conflict was accepted: %v", err)
	}
}

func TestPlanRejectsMissingLegacyState(t *testing.T) {
	manager := Manager{Backend: firewall.NewIPTables(legacyRunner{}), LegacyDir: t.TempDir()}
	if _, err := manager.Plan(context.Background(), Auto); err == nil {
		t.Fatal("empty migration was accepted")
	}
}

func TestPlanRejectsForeignSameNameService(t *testing.T) {
	root := t.TempDir()
	servicePath := filepath.Join(root, "pmm-rules.service")
	if err := os.WriteFile(servicePath, []byte("[Service]\nExecStart=/bin/foreign\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	manager := Manager{Backend: firewall.NewIPTables(legacyRunner{ipv4: legacyLine()}), LegacyDir: root, ServicePath: servicePath, Runner: legacyRunner{}}
	if _, err := manager.Plan(context.Background(), Auto); err == nil || !strings.Contains(err.Error(), "不完全匹配") {
		t.Fatalf("foreign same-name service was accepted: %v", err)
	}
}

func legacyLine() string {
	return "-A PREROUTING -p udp --dport 6000:7000 -m comment --comment " + LegacyComment + " -j REDIRECT --to-ports 3000"
}

type legacyRunner struct {
	ipv4 string
}

func (r legacyRunner) Run(_ context.Context, name string, _ ...string) (runner.Result, error) {
	if name == "iptables" {
		return runner.Result{Stdout: r.ipv4}, nil
	}
	return runner.Result{}, nil
}
