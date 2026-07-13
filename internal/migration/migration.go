package migration

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/lock"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/persistence"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/transaction"
)

const LegacyComment = "udp-port-mapping-script-v4"

type Source string

const (
	Auto     Source = "auto"
	Kernel   Source = "kernel"
	Database Source = "database"
)

type Plan struct {
	LegacyDatabase       string       `json:"legacy_database"`
	DatabaseRules        []model.Rule `json:"database_rules"`
	KernelRules          []model.Rule `json:"kernel_rules"`
	SelectedRules        []model.Rule `json:"selected_rules"`
	Source               Source       `json:"source"`
	Ambiguous            bool         `json:"ambiguous"`
	LegacyServiceOwned   bool         `json:"legacy_service_owned"`
	LegacyServiceEnabled bool         `json:"legacy_service_enabled"`
	LegacyServiceActive  bool         `json:"legacy_service_active"`
}

type Journal struct {
	Phase     string    `json:"phase"`
	UpdatedAt time.Time `json:"updated_at"`
	Plan      Plan      `json:"plan"`
	Error     string    `json:"error,omitempty"`
}

type Manager struct {
	Backend      *firewall.IPTables
	Store        storage.Store
	Tx           transaction.Manager
	LegacyDir    string
	MigrationDir string
	ServicePath  string
	Runner       runner.Runner
}

func (m Manager) Plan(ctx context.Context, source Source) (Plan, error) {
	legacyPath := filepath.Join(m.LegacyDir, "rules.db")
	databaseRules, databaseErr := readLegacyDatabase(legacyPath)
	if databaseErr != nil && !errors.Is(databaseErr, os.ErrNotExist) {
		return Plan{}, databaseErr
	}
	kernelRules, err := m.Backend.DiscoverLegacy(ctx, LegacyComment)
	if err != nil {
		return Plan{}, err
	}
	plan := Plan{LegacyDatabase: legacyPath, DatabaseRules: databaseRules, KernelRules: kernelRules, Source: source}
	if err := m.inspectLegacyService(ctx, &plan); err != nil {
		return plan, err
	}
	switch source {
	case Kernel:
		plan.SelectedRules = kernelRules
	case Database:
		plan.SelectedRules = databaseRules
	case Auto:
		if len(databaseRules) > 0 && len(kernelRules) > 0 && !sameRules(databaseRules, kernelRules) {
			plan.Ambiguous = true
			return plan, errors.New("旧版数据库与内核规则不一致；请明确选择 --source kernel 或 --source database")
		}
		if len(kernelRules) > 0 {
			plan.SelectedRules = kernelRules
		} else {
			plan.SelectedRules = databaseRules
		}
	default:
		return Plan{}, fmt.Errorf("无效的迁移来源 %q", source)
	}
	set := model.NewRuleSet()
	set.Rules = append([]model.Rule(nil), plan.SelectedRules...)
	if err := set.Normalize(time.Now()); err != nil {
		return Plan{}, err
	}
	plan.SelectedRules = set.Rules
	if len(plan.SelectedRules) == 0 && len(plan.KernelRules) == 0 {
		return plan, errors.New("没有找到旧版 PMM 规则或数据库记录")
	}
	external, err := m.Backend.InspectExternalExceptComment(ctx, LegacyComment)
	if err != nil {
		return plan, fmt.Errorf("检查非旧版规则失败：%w", err)
	}
	for _, rule := range plan.SelectedRules {
		for _, other := range external {
			if rule.IPVersion == other.IPVersion && rule.Protocol == other.Protocol && rule.StartPort <= other.EndPort && rule.EndPort >= other.StartPort {
				return plan, fmt.Errorf("旧版规则 %s 与外部规则冲突：%s", rule.ID, other.Raw)
			}
		}
	}
	return plan, nil
}

func (m Manager) Execute(ctx context.Context, plan Plan) (transaction.Result, error) {
	if plan.Ambiguous {
		return transaction.Result{}, errors.New("迁移计划存在歧义，无法安全执行")
	}
	set := model.NewRuleSet()
	set.Rules = append([]model.Rule(nil), plan.SelectedRules...)
	if err := set.Normalize(time.Now()); err != nil {
		return transaction.Result{}, err
	}
	handle, err := lock.Acquire(ctx, m.Tx.LockPath, m.Tx.LockTimeout)
	if err != nil {
		return transaction.Result{}, err
	}
	defer handle.Release()
	if err := os.MkdirAll(m.MigrationDir, 0o700); err != nil {
		return transaction.Result{}, err
	}
	bundle := filepath.Join(m.MigrationDir, time.Now().UTC().Format("20060102T150405.000000000Z"))
	if err := os.MkdirAll(bundle, 0o700); err != nil {
		return transaction.Result{}, err
	}
	journalPath := filepath.Join(bundle, "migration.json")
	journal := Journal{Phase: "PLANNED", UpdatedAt: time.Now().UTC(), Plan: plan}
	if err := storage.WriteJSONAtomic(journalPath, journal, 0o600); err != nil {
		return transaction.Result{}, err
	}
	if err := m.disableLegacyService(ctx, plan); err != nil {
		journal.Phase, journal.Error, journal.UpdatedAt = "LEGACY_SERVICE_DISABLE_FAILED", err.Error(), time.Now().UTC()
		_ = storage.WriteJSONAtomic(journalPath, journal, 0o600)
		return transaction.Result{}, err
	}
	result, err := m.Tx.ReconcileMigrationLocked(ctx, "v5-migration-prepare", set)
	if err != nil {
		err = errors.Join(err, m.restoreLegacyService(ctx, plan))
		journal.Phase, journal.Error, journal.UpdatedAt = "PREPARE_FAILED", err.Error(), time.Now().UTC()
		_ = storage.WriteJSONAtomic(journalPath, journal, 0o600)
		return result, err
	}
	journal.Phase, journal.UpdatedAt = "NEW_CHAIN_VERIFIED", time.Now().UTC()
	_ = storage.WriteJSONAtomic(journalPath, journal, 0o600)
	if err := m.Backend.DeleteLegacy(ctx, LegacyComment, plan.KernelRules); err != nil {
		failure := m.restoreLegacyAfterFailure(ctx, plan, fmt.Errorf("删除旧版规则失败：%w", err))
		journal.Phase, journal.Error, journal.UpdatedAt = "ROLLED_BACK", failure.Error(), time.Now().UTC()
		_ = storage.WriteJSONAtomic(journalPath, journal, 0o600)
		return result, failure
	}
	journal.Phase, journal.UpdatedAt = "LEGACY_DELETED", time.Now().UTC()
	_ = storage.WriteJSONAtomic(journalPath, journal, 0o600)
	if err := m.Store.Save(set); err != nil {
		failure := m.restoreLegacyAfterFailure(ctx, plan, fmt.Errorf("提交迁移后的数据库失败：%w", err))
		journal.Phase, journal.Error, journal.UpdatedAt = "ROLLED_BACK", failure.Error(), time.Now().UTC()
		_ = storage.WriteJSONAtomic(journalPath, journal, 0o600)
		return result, failure
	}
	journal.Phase, journal.Error, journal.UpdatedAt = "COMMITTED", "", time.Now().UTC()
	if err := storage.WriteJSONAtomic(journalPath, journal, 0o600); err != nil {
		return result, fmt.Errorf("迁移已提交，但更新迁移日志失败：%w", err)
	}
	return result, nil
}

func (m Manager) restoreLegacyAfterFailure(ctx context.Context, plan Plan, cause error) error {
	managedErr := m.Backend.DeleteManaged(ctx)
	legacyErr := m.Backend.RestoreLegacy(ctx, LegacyComment, plan.KernelRules)
	serviceErr := m.restoreLegacyService(ctx, plan)
	if managedErr != nil || legacyErr != nil || serviceErr != nil {
		return fmt.Errorf("迁移失败：%v；清理新规则错误：%v；恢复旧规则错误：%v；恢复服务错误：%v", cause, managedErr, legacyErr, serviceErr)
	}
	return cause
}

func (m Manager) legacyUnit() string {
	return fmt.Sprintf(`[Unit]
Description=Port Mapping Manager owned rules
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=%s
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
`, filepath.Join(m.LegacyDir, "restore-owned-rules.sh"))
}

func (m Manager) inspectLegacyService(ctx context.Context, plan *Plan) error {
	if m.ServicePath == "" {
		return nil
	}
	data, err := os.ReadFile(m.ServicePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if string(data) != m.legacyUnit() {
		return errors.New("pmm-rules.service 已存在，但内容与旧版 PMM 服务不完全匹配，拒绝迁移")
	}
	plan.LegacyServiceOwned = true
	if m.Runner == nil {
		return errors.New("缺少命令执行器，无法检查旧版持久化服务")
	}
	if result, err := m.Runner.Run(ctx, "systemctl", "is-enabled", persistence.ServiceName); err == nil && strings.TrimSpace(result.Stdout) == "enabled" {
		plan.LegacyServiceEnabled = true
	}
	if result, err := m.Runner.Run(ctx, "systemctl", "is-active", persistence.ServiceName); err == nil && strings.TrimSpace(result.Stdout) == "active" {
		plan.LegacyServiceActive = true
	}
	return nil
}

func (m Manager) disableLegacyService(ctx context.Context, plan Plan) error {
	if !plan.LegacyServiceOwned {
		return nil
	}
	if m.Runner == nil {
		return errors.New("缺少命令执行器，无法禁用旧版持久化服务")
	}
	if plan.LegacyServiceEnabled || plan.LegacyServiceActive {
		if _, err := m.Runner.Run(ctx, "systemctl", "disable", "--now", persistence.ServiceName); err != nil {
			return errors.Join(err, m.restoreLegacyService(ctx, plan))
		}
	}
	if err := os.Remove(m.ServicePath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errors.Join(err, m.restoreLegacyService(ctx, plan))
	}
	if _, err := m.Runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		return errors.Join(err, m.restoreLegacyService(ctx, plan))
	}
	return nil
}

func (m Manager) restoreLegacyService(ctx context.Context, plan Plan) error {
	if !plan.LegacyServiceOwned {
		return nil
	}
	if m.Runner == nil {
		return errors.New("缺少命令执行器，无法恢复旧版持久化服务")
	}
	if err := storage.WriteFileAtomic(m.ServicePath, []byte(m.legacyUnit()), 0o644); err != nil {
		return err
	}
	var restoreErrors []error
	if _, err := m.Runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		restoreErrors = append(restoreErrors, err)
	}
	if plan.LegacyServiceEnabled {
		if _, err := m.Runner.Run(ctx, "systemctl", "enable", persistence.ServiceName); err != nil {
			restoreErrors = append(restoreErrors, err)
		}
	}
	if plan.LegacyServiceActive {
		if _, err := m.Runner.Run(ctx, "systemctl", "start", persistence.ServiceName); err != nil {
			restoreErrors = append(restoreErrors, err)
		}
	}
	return errors.Join(restoreErrors...)
}

func readLegacyDatabase(path string) ([]model.Rule, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return model.ParsePipe(file, 4)
}

func sameRules(left, right []model.Rule) bool {
	keys := func(rules []model.Rule) []string {
		result := make([]string, 0, len(rules))
		for _, rule := range rules {
			result = append(result, rule.CanonicalKey())
		}
		sort.Strings(result)
		return result
	}
	return strings.Join(keys(left), "\n") == strings.Join(keys(right), "\n")
}
