package firewall

import (
	"context"
	"errors"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
)

var (
	ErrOwnershipConflict = errors.New("firewall object exists but is not owned by PMM")
	ErrStateDrift        = errors.New("firewall state is incomplete or inconsistent")
)

type FamilySnapshot struct {
	IPVersion    int          `json:"ip_version"`
	Managed      bool         `json:"managed"`
	ActiveChain  string       `json:"active_chain,omitempty"`
	OrphanChains []string     `json:"orphan_chains,omitempty"`
	Rules        []model.Rule `json:"rules"`
}

type Snapshot struct {
	IPv4 FamilySnapshot `json:"ipv4"`
	IPv6 FamilySnapshot `json:"ipv6"`
}

func (s Snapshot) Rules() []model.Rule {
	rules := make([]model.Rule, 0, len(s.IPv4.Rules)+len(s.IPv6.Rules))
	rules = append(rules, s.IPv4.Rules...)
	rules = append(rules, s.IPv6.Rules...)
	return rules
}

type ExternalRange struct {
	IPVersion int
	Protocol  model.Protocol
	StartPort uint16
	EndPort   uint16
	Raw       string
}

type Counter struct {
	RuleID    string `json:"rule_id"`
	IPVersion int    `json:"ip_version"`
	Packets   uint64 `json:"packets"`
	Bytes     uint64 `json:"bytes"`
}

type Backend interface {
	Probe(context.Context) error
	Snapshot(context.Context) (Snapshot, error)
	InspectExternal(context.Context) ([]ExternalRange, error)
	Counters(context.Context) ([]Counter, error)
	Apply(context.Context, []model.Rule) error
	Verify(context.Context, []model.Rule) error
	Restore(context.Context, Snapshot) error
	DeleteManaged(context.Context) error
}
