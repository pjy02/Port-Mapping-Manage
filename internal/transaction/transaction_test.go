package transaction

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
)

type fakeBackend struct {
	state        firewall.Snapshot
	failSnapshot bool
	failApply    bool
	failRestore  bool
	external     []firewall.ExternalRange
}

func (f *fakeBackend) Probe(context.Context) error { return nil }
func (f *fakeBackend) Snapshot(context.Context) (firewall.Snapshot, error) {
	if f.failSnapshot {
		return firewall.Snapshot{}, errors.New("query failed")
	}
	return f.state, nil
}
func (f *fakeBackend) InspectExternal(context.Context) ([]firewall.ExternalRange, error) {
	return f.external, nil
}
func (f *fakeBackend) Counters(context.Context) ([]firewall.Counter, error) { return nil, nil }
func (f *fakeBackend) Apply(_ context.Context, rules []model.Rule) error {
	f.state = snapshotFor(rules)
	if f.failApply {
		return errors.New("injected apply failure")
	}
	return nil
}
func (f *fakeBackend) Verify(_ context.Context, rules []model.Rule) error {
	if len(f.state.Rules()) != enabledCount(rules) {
		return errors.New("verification mismatch")
	}
	return nil
}
func (f *fakeBackend) Restore(_ context.Context, snapshot firewall.Snapshot) error {
	if f.failRestore {
		return errors.New("injected rollback failure")
	}
	f.state = snapshot
	return nil
}
func (f *fakeBackend) DeleteManaged(context.Context) error {
	f.state = firewall.Snapshot{}
	return nil
}

func TestApplyFailureRollsBackAndDoesNotCommitDatabase(t *testing.T) {
	root := t.TempDir()
	oldRule := testRule("old", 4, 1000)
	backend := &fakeBackend{state: snapshotFor([]model.Rule{oldRule}), failApply: true}
	manager, store := testManager(root, backend)
	initial := model.NewRuleSet()
	initial.Rules = []model.Rule{oldRule}
	if err := store.Save(initial); err != nil {
		t.Fatal(err)
	}
	desired := model.NewRuleSet()
	desired.Rules = []model.Rule{testRule("new", 6, 3000)}
	result, err := manager.Apply(context.Background(), "test", desired)
	if err == nil || result.Phase != RolledBack {
		t.Fatalf("expected rolled back error, result=%+v err=%v", result, err)
	}
	if got := backend.state.Rules(); len(got) != 1 || got[0].ID != "old" {
		t.Fatalf("kernel state was not restored: %+v", got)
	}
	stored, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(stored.Rules) != 1 || stored.Rules[0].ID != "old" {
		t.Fatalf("database changed on failed transaction: %+v", stored.Rules)
	}
}

func TestSnapshotFailureStopsBeforeMutation(t *testing.T) {
	root := t.TempDir()
	backend := &fakeBackend{failSnapshot: true}
	manager, _ := testManager(root, backend)
	desired := model.NewRuleSet()
	desired.Rules = []model.Rule{testRule("new", 4, 1000)}
	if _, err := manager.Apply(context.Background(), "test", desired); err == nil {
		t.Fatal("snapshot failure was ignored")
	}
}

func TestRollbackFailureIsDistinguishable(t *testing.T) {
	root := t.TempDir()
	backend := &fakeBackend{state: snapshotFor(nil), failApply: true, failRestore: true}
	manager, _ := testManager(root, backend)
	desired := model.NewRuleSet()
	desired.Rules = []model.Rule{testRule("new", 4, 1000)}
	result, err := manager.Apply(context.Background(), "test", desired)
	if !errors.Is(err, ErrRollbackFailed) || result.Phase != RollbackFailed {
		t.Fatalf("rollback failure was masked: result=%+v err=%v", result, err)
	}
}

func TestExternalConflictStopsBeforeApply(t *testing.T) {
	root := t.TempDir()
	backend := &fakeBackend{external: []firewall.ExternalRange{{IPVersion: 4, Protocol: model.TCP, StartPort: 1500, EndPort: 1600, Raw: "external"}}}
	manager, _ := testManager(root, backend)
	desired := model.NewRuleSet()
	desired.Rules = []model.Rule{{ID: "new", IPVersion: 4, Protocol: model.TCP, StartPort: 1000, EndPort: 2000, TargetPort: 9000, Enabled: true}}
	if _, err := manager.Apply(context.Background(), "test", desired); err == nil {
		t.Fatal("external conflict was accepted")
	}
	if backend.state.IPv4.Managed || backend.state.IPv6.Managed {
		t.Fatal("backend was mutated after conflict")
	}
}

func TestDriftStopsOrdinaryMutation(t *testing.T) {
	root := t.TempDir()
	kernelRule := testRule("kernel", 4, 1000)
	backend := &fakeBackend{state: snapshotFor([]model.Rule{kernelRule})}
	manager, store := testManager(root, backend)
	database := model.NewRuleSet()
	database.Rules = []model.Rule{testRule("database", 4, 2000)}
	if err := store.Save(database); err != nil {
		t.Fatal(err)
	}
	desired := database
	desired.Rules = append(desired.Rules, testRule("new", 6, 3000))
	if _, err := manager.Apply(context.Background(), "test", desired); err == nil {
		t.Fatal("drifted pre-state was overwritten")
	}
	if got := backend.state.Rules(); len(got) != 1 || got[0].ID != "kernel" {
		t.Fatalf("kernel mutated despite drift: %+v", got)
	}
}

func TestAutomaticBackupPreservesDisabledRules(t *testing.T) {
	root := t.TempDir()
	enabled := testRule("enabled", 4, 1000)
	disabled := testRule("disabled", 6, 2000)
	disabled.Enabled = false
	backend := &fakeBackend{state: snapshotFor([]model.Rule{enabled})}
	manager, store := testManager(root, backend)
	current := model.NewRuleSet()
	current.Rules = []model.Rule{enabled, disabled}
	if err := store.Save(current); err != nil {
		t.Fatal(err)
	}
	desired := current
	desired.Rules = append(desired.Rules, testRule("new", 4, 3000))
	result, err := manager.Apply(context.Background(), "test", desired)
	if err != nil {
		t.Fatal(err)
	}
	backupStore := storage.Store{StatePath: result.BackupPath}
	backup, err := backupStore.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(backup.Rules) != 2 || backup.Rules[1].Enabled {
		t.Fatalf("disabled rule missing from backup: %+v", backup.Rules)
	}
}

func testManager(root string, backend firewall.Backend) (Manager, storage.Store) {
	store := storage.Store{StatePath: filepath.Join(root, "rules.json"), BackupDir: filepath.Join(root, "backups")}
	manager := Manager{
		Backend: backend, Store: store, LockPath: filepath.Join(root, "pmm.lock"),
		TransactionDir: filepath.Join(root, "transactions"), LockTimeout: time.Second,
		AutoBackup: true, Now: time.Now,
	}
	return manager, store
}

func testRule(id string, version int, start uint16) model.Rule {
	return model.Rule{ID: id, IPVersion: version, Protocol: model.UDP, StartPort: start, EndPort: start + 10, TargetPort: start + 100, Enabled: true}
}

func snapshotFor(rules []model.Rule) firewall.Snapshot {
	snapshot := firewall.Snapshot{
		IPv4: firewall.FamilySnapshot{IPVersion: 4, Managed: true, ActiveChain: "PMM_G_1"},
		IPv6: firewall.FamilySnapshot{IPVersion: 6, Managed: true, ActiveChain: "PMM_G_1"},
	}
	for _, rule := range rules {
		if !rule.Enabled {
			continue
		}
		if rule.IPVersion == 4 {
			snapshot.IPv4.Rules = append(snapshot.IPv4.Rules, rule)
		} else {
			snapshot.IPv6.Rules = append(snapshot.IPv6.Rules, rule)
		}
	}
	return snapshot
}

func enabledCount(rules []model.Rule) int {
	count := 0
	for _, rule := range rules {
		if rule.Enabled {
			count++
		}
	}
	return count
}
