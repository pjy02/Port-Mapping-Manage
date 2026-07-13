package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/transaction"
)

type App struct {
	Backend firewall.Backend
	Store   storage.Store
	Tx      transaction.Manager
}

type State struct {
	Database model.RuleSet     `json:"database"`
	Kernel   firewall.Snapshot `json:"kernel"`
	Drift    bool              `json:"drift"`
}

func (a App) State(ctx context.Context) (State, error) {
	database, err := a.Store.Load()
	if err != nil {
		return State{}, err
	}
	kernel, err := a.Backend.Snapshot(ctx)
	if err != nil {
		return State{}, err
	}
	return State{Database: database, Kernel: kernel, Drift: !sameEnabledRules(database.Rules, kernel.Rules())}, nil
}

func (a App) Add(ctx context.Context, rule model.Rule) (transaction.Result, error) {
	rule.Enabled = true
	rule.EnsureID()
	if err := rule.Validate(); err != nil {
		return transaction.Result{}, err
	}
	set, err := a.Store.Load()
	if err != nil {
		return transaction.Result{}, err
	}
	for _, existing := range set.Rules {
		if existing.CanonicalKey() == rule.CanonicalKey() {
			return transaction.Result{}, fmt.Errorf("rule already exists as %s", existing.ID)
		}
	}
	if err := ensureUniqueID(&rule, set.Rules); err != nil {
		return transaction.Result{}, err
	}
	set.Rules = append(set.Rules, rule)
	return a.Tx.Apply(ctx, "rule-add", set)
}

func (a App) Delete(ctx context.Context, id string) (transaction.Result, error) {
	return a.mutate(ctx, "rule-delete", id, func(_ *model.Rule, set *model.RuleSet, index int) {
		set.Rules = append(set.Rules[:index], set.Rules[index+1:]...)
	})
}

func (a App) Clear(ctx context.Context) (transaction.Result, error) {
	set, err := a.Store.Load()
	if err != nil {
		return transaction.Result{}, err
	}
	set.Rules = []model.Rule{}
	return a.Tx.Apply(ctx, "rule-clear", set)
}

func (a App) Toggle(ctx context.Context, id string, enabled bool) (transaction.Result, error) {
	return a.mutate(ctx, "rule-toggle", id, func(rule *model.Rule, _ *model.RuleSet, _ int) {
		rule.Enabled = enabled
		rule.UpdatedAt = time.Now().UTC()
	})
}

func (a App) Edit(ctx context.Context, id string, update model.Rule) (transaction.Result, error) {
	return a.mutate(ctx, "rule-edit", id, func(rule *model.Rule, _ *model.RuleSet, _ int) {
		rule.IPVersion = update.IPVersion
		rule.Protocol = update.Protocol
		rule.StartPort = update.StartPort
		rule.EndPort = update.EndPort
		rule.TargetPort = update.TargetPort
		rule.Label = update.Label
		rule.UpdatedAt = time.Now().UTC()
	})
}

func (a App) mutate(ctx context.Context, operation, id string, fn func(*model.Rule, *model.RuleSet, int)) (transaction.Result, error) {
	set, err := a.Store.Load()
	if err != nil {
		return transaction.Result{}, err
	}
	for index := range set.Rules {
		if set.Rules[index].ID == id {
			fn(&set.Rules[index], &set, index)
			return a.Tx.Apply(ctx, operation, set)
		}
	}
	return transaction.Result{}, fmt.Errorf("rule %s not found", id)
}

func (a App) Import(ctx context.Context, r io.Reader, legacyIPVersion int, replace bool) (transaction.Result, int, error) {
	imported, err := model.ParsePipe(r, legacyIPVersion)
	if err != nil {
		return transaction.Result{}, 0, err
	}
	set, err := a.Store.Load()
	if err != nil {
		return transaction.Result{}, 0, err
	}
	if replace {
		set.Rules = imported
	} else {
		existing := make(map[string]struct{}, len(set.Rules))
		for _, rule := range set.Rules {
			existing[rule.CanonicalKey()] = struct{}{}
		}
		for _, rule := range imported {
			if _, duplicate := existing[rule.CanonicalKey()]; duplicate {
				continue
			}
			if err := ensureUniqueID(&rule, set.Rules); err != nil {
				return transaction.Result{}, 0, err
			}
			set.Rules = append(set.Rules, rule)
			existing[rule.CanonicalKey()] = struct{}{}
		}
	}
	result, err := a.Tx.Apply(ctx, "batch-import", set)
	return result, len(imported), err
}

func ensureUniqueID(rule *model.Rule, existing []model.Rule) error {
	used := func(id string) bool {
		for _, candidate := range existing {
			if candidate.ID == id {
				return true
			}
		}
		return false
	}
	if !used(rule.ID) {
		return nil
	}
	for attempt := 0; attempt < 8; attempt++ {
		bytes := make([]byte, 8)
		if _, err := rand.Read(bytes); err != nil {
			return fmt.Errorf("generate rule ID: %w", err)
		}
		rule.ID = hex.EncodeToString(bytes)
		if !used(rule.ID) {
			return nil
		}
	}
	return errors.New("could not allocate a unique rule ID")
}

func (a App) Export(ctx context.Context, w io.Writer, format string) error {
	state, err := a.State(ctx)
	if err != nil {
		return err
	}
	if state.Drift {
		return errors.New("database and kernel state differ; refusing to export an ambiguous state")
	}
	switch format {
	case "pipe":
		return model.WritePipe(w, state.Database.Rules)
	case "json":
		encoder := json.NewEncoder(w)
		encoder.SetIndent("", "  ")
		return encoder.Encode(state.Database)
	default:
		return fmt.Errorf("unknown export format %q", format)
	}
}

func (a App) Backup(ctx context.Context) (string, error) {
	state, err := a.State(ctx)
	if err != nil {
		return "", err
	}
	if state.Drift {
		return "", errors.New("database and kernel state differ; refusing to create a misleading backup")
	}
	return a.Store.Backup(state.Database)
}

func (a App) Restore(ctx context.Context, path string) (transaction.Result, error) {
	file, err := os.Open(path)
	if err != nil {
		return transaction.Result{}, err
	}
	defer file.Close()
	set, err := model.Decode(file)
	if err != nil {
		return transaction.Result{}, err
	}
	return a.Tx.Apply(ctx, "backup-restore", set)
}

func (a App) ListBackups() ([]string, error) {
	return a.Store.ListBackups()
}

func (a App) Doctor(ctx context.Context) (State, []string, error) {
	state, err := a.State(ctx)
	if err != nil {
		return State{}, nil, err
	}
	var issues []string
	if state.Drift {
		issues = append(issues, "规则数据库与内核专属链不一致")
	}
	if !state.Kernel.IPv4.Managed {
		issues = append(issues, "IPv4 项目专属链尚未创建")
	}
	if !state.Kernel.IPv6.Managed {
		issues = append(issues, "IPv6 项目专属链尚未创建")
	}
	if len(state.Kernel.IPv4.OrphanChains) > 0 {
		issues = append(issues, fmt.Sprintf("IPv4 存在未激活候选链: %s", strings.Join(state.Kernel.IPv4.OrphanChains, ", ")))
	}
	if len(state.Kernel.IPv6.OrphanChains) > 0 {
		issues = append(issues, fmt.Sprintf("IPv6 存在未激活候选链: %s", strings.Join(state.Kernel.IPv6.OrphanChains, ", ")))
	}
	return state, issues, nil
}

func sameEnabledRules(left, right []model.Rule) bool {
	keys := func(rules []model.Rule) []string {
		var result []string
		for _, rule := range rules {
			if rule.Enabled {
				result = append(result, rule.ID+"|"+rule.CanonicalKey())
			}
		}
		sort.Strings(result)
		return result
	}
	return strings.Join(keys(left), "\n") == strings.Join(keys(right), "\n")
}
