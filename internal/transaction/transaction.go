package transaction

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/lock"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
)

type Phase string

const (
	Prepared       Phase = "PREPARED"
	Applying       Phase = "APPLYING"
	Applied        Phase = "APPLIED"
	Verifying      Phase = "VERIFYING"
	Committed      Phase = "COMMITTED"
	RollingBack    Phase = "ROLLING_BACK"
	RolledBack     Phase = "ROLLED_BACK"
	RollbackFailed Phase = "ROLLBACK_FAILED"
)

var ErrRollbackFailed = errors.New("操作失败，并且回滚未能恢复原状态")

type Journal struct {
	ID        string            `json:"id"`
	Operation string            `json:"operation"`
	Phase     Phase             `json:"phase"`
	StartedAt time.Time         `json:"started_at"`
	UpdatedAt time.Time         `json:"updated_at"`
	Before    firewall.Snapshot `json:"before"`
	Desired   []model.Rule      `json:"desired"`
	Error     string            `json:"error,omitempty"`
}

type Result struct {
	TransactionID string `json:"transaction_id"`
	BackupPath    string `json:"backup_path,omitempty"`
	Phase         Phase  `json:"phase"`
}

type Manager struct {
	Backend        firewall.Backend
	Store          storage.Store
	LockPath       string
	TransactionDir string
	LockTimeout    time.Duration
	AutoBackup     bool
	Now            func() time.Time
}

func (m Manager) Apply(ctx context.Context, operation string, desired model.RuleSet) (Result, error) {
	return m.apply(ctx, operation, desired, true, m.AutoBackup, true, true)
}

// Reconcile applies an already committed database state, for example during boot.
// It journals and rolls back kernel changes but does not rewrite the database or create a routine backup.
func (m Manager) Reconcile(ctx context.Context, operation string, desired model.RuleSet) (Result, error) {
	return m.apply(ctx, operation, desired, false, false, true, true)
}

// ReconcileMigration is restricted to an explicit migration plan that already
// identified the legacy PMM rules. It bypasses only the ordinary external-rule
// overlap check; model validation, locking, journaling, verification and rollback remain mandatory.
func (m Manager) ReconcileMigration(ctx context.Context, operation string, desired model.RuleSet) (Result, error) {
	return m.apply(ctx, operation, desired, false, false, false, true)
}

// ReconcileMigrationLocked is used by the migration coordinator while it owns
// Manager.LockPath for the entire new-chain/legacy-delete/database-commit flow.
func (m Manager) ReconcileMigrationLocked(ctx context.Context, operation string, desired model.RuleSet) (Result, error) {
	return m.apply(ctx, operation, desired, false, false, false, false)
}

func (m Manager) apply(ctx context.Context, operation string, desired model.RuleSet, commitDatabase, autoBackup, inspectExternal, acquireLock bool) (Result, error) {
	if m.Now == nil {
		m.Now = time.Now
	}
	if err := desired.Normalize(m.Now()); err != nil {
		return Result{}, err
	}
	var handle lock.Handle
	var err error
	if acquireLock {
		handle, err = lock.Acquire(ctx, m.LockPath, m.LockTimeout)
		if err != nil {
			return Result{}, err
		}
		defer handle.Release()
	}

	before, err := m.Backend.Snapshot(ctx)
	if err != nil {
		return Result{}, fmt.Errorf("获取内核规则快照失败：%w", err)
	}
	if inspectExternal {
		if err := m.checkExternalConflicts(ctx, desired.Rules); err != nil {
			return Result{}, err
		}
	}
	current, err := m.Store.Load()
	if err != nil {
		return Result{}, err
	}
	if commitDatabase && !sameEnabledRules(current.Rules, before.Rules()) {
		return Result{}, errors.New("数据库与受管防火墙状态不一致；请先运行 doctor，再显式执行 repair reconcile --yes")
	}
	desired.Generation = current.Generation

	id := fmt.Sprintf("%s-%d", m.Now().UTC().Format("20060102T150405.000000000Z"), os.Getpid())
	journal := Journal{ID: id, Operation: operation, Phase: Prepared, StartedAt: m.Now().UTC(), UpdatedAt: m.Now().UTC(), Before: before, Desired: desired.Rules}
	journalPath := filepath.Join(m.TransactionDir, id, "journal.json")
	if err := m.writeJournal(journalPath, &journal); err != nil {
		return Result{}, err
	}

	result := Result{TransactionID: id, Phase: Prepared}
	if autoBackup {
		// Back up the committed model, not only the enabled kernel rules. This
		// preserves disabled rules and their metadata across rollback/restore.
		result.BackupPath, err = m.Store.Backup(current)
		if err != nil {
			journal.Error = "备份失败：" + err.Error()
			_ = m.writeJournal(journalPath, &journal)
			return result, err
		}
	}

	journal.Phase = Applying
	if err := m.writeJournal(journalPath, &journal); err != nil {
		return result, err
	}
	if err := m.Backend.Apply(ctx, desired.Rules); err != nil {
		return m.rollback(ctx, journalPath, &journal, result, fmt.Errorf("应用防火墙状态失败：%w", err))
	}
	journal.Phase = Applied
	if err := m.writeJournal(journalPath, &journal); err != nil {
		return m.rollback(ctx, journalPath, &journal, result, err)
	}
	journal.Phase = Verifying
	if err := m.writeJournal(journalPath, &journal); err != nil {
		return m.rollback(ctx, journalPath, &journal, result, err)
	}
	if err := m.Backend.Verify(ctx, desired.Rules); err != nil {
		return m.rollback(ctx, journalPath, &journal, result, fmt.Errorf("验证防火墙状态失败：%w", err))
	}
	if commitDatabase {
		if err := m.Store.Save(desired); err != nil {
			return m.rollback(ctx, journalPath, &journal, result, fmt.Errorf("提交规则数据库失败：%w", err))
		}
	}
	journal.Phase = Committed
	journal.Error = ""
	if err := m.writeJournal(journalPath, &journal); err != nil {
		return result, fmt.Errorf("防火墙和数据库已提交，但更新事务日志失败：%w", err)
	}
	result.Phase = Committed
	return result, nil
}

func sameEnabledRules(database, kernel []model.Rule) bool {
	keys := func(rules []model.Rule) map[string]struct{} {
		result := make(map[string]struct{}, len(rules))
		for _, rule := range rules {
			if rule.Enabled {
				result[rule.ID+"|"+rule.CanonicalKey()] = struct{}{}
			}
		}
		return result
	}
	left, right := keys(database), keys(kernel)
	if len(left) != len(right) {
		return false
	}
	for key := range left {
		if _, exists := right[key]; !exists {
			return false
		}
	}
	return true
}

func (m Manager) rollback(ctx context.Context, path string, journal *Journal, result Result, cause error) (Result, error) {
	journal.Phase = RollingBack
	journal.Error = cause.Error()
	_ = m.writeJournal(path, journal)
	if err := m.Backend.Restore(ctx, journal.Before); err != nil {
		journal.Phase = RollbackFailed
		journal.Error = cause.Error() + "；回滚失败：" + err.Error()
		_ = m.writeJournal(path, journal)
		result.Phase = RollbackFailed
		return result, fmt.Errorf("%w：%v；回滚错误：%v", ErrRollbackFailed, cause, err)
	}
	if err := m.verifySnapshot(ctx, journal.Before); err != nil {
		journal.Phase = RollbackFailed
		journal.Error = cause.Error() + "；回滚验证失败：" + err.Error()
		_ = m.writeJournal(path, journal)
		result.Phase = RollbackFailed
		return result, fmt.Errorf("%w：%v；回滚验证错误：%v", ErrRollbackFailed, cause, err)
	}
	journal.Phase = RolledBack
	_ = m.writeJournal(path, journal)
	result.Phase = RolledBack
	return result, cause
}

func (m Manager) verifySnapshot(ctx context.Context, expected firewall.Snapshot) error {
	actual, err := m.Backend.Snapshot(ctx)
	if err != nil {
		return err
	}
	if actual.IPv4.Managed != expected.IPv4.Managed || actual.IPv6.Managed != expected.IPv6.Managed {
		return errors.New("受管链的存在状态与事务前不一致")
	}
	if expected.IPv4.Managed || expected.IPv6.Managed {
		return m.Backend.Verify(ctx, expected.Rules())
	}
	return nil
}

func (m Manager) checkExternalConflicts(ctx context.Context, desired []model.Rule) error {
	external, err := m.Backend.InspectExternal(ctx)
	if err != nil {
		return fmt.Errorf("检查外部规则冲突失败：%w", err)
	}
	for _, rule := range desired {
		if !rule.Enabled {
			continue
		}
		for _, other := range external {
			if rule.IPVersion == other.IPVersion && rule.Protocol == other.Protocol && rule.StartPort <= other.EndPort && rule.EndPort >= other.StartPort {
				return fmt.Errorf("规则 %s 与外部规则冲突：%s", rule.ID, other.Raw)
			}
		}
	}
	return nil
}

func (m Manager) writeJournal(path string, journal *Journal) error {
	journal.UpdatedAt = m.Now().UTC()
	return storage.WriteJSONAtomic(path, journal, 0o600)
}
