package firewall

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
)

func TestParseManagedRulesAllFamiliesAndProtocols(t *testing.T) {
	tests := []struct {
		version  int
		protocol model.Protocol
	}{
		{4, model.TCP}, {4, model.UDP}, {6, model.TCP}, {6, model.UDP},
	}
	for _, test := range tests {
		line := "-A PMM_G_1 -p " + string(test.protocol) + " --dport 6000:7000 -m comment --comment pmm:rule:abc -j REDIRECT --to-ports 3000"
		rules, err := parseManagedRules(test.version, []string{line})
		if err != nil {
			t.Fatalf("IPv%d/%s: %v", test.version, test.protocol, err)
		}
		if len(rules) != 1 || rules[0].IPVersion != test.version || rules[0].Protocol != test.protocol {
			t.Fatalf("IPv%d/%s parsed incorrectly: %+v", test.version, test.protocol, rules)
		}
	}
}

func TestSnapshotFailsClosedOnQueryError(t *testing.T) {
	backend := NewIPTables(staticRunner{err: errors.New("query failed")})
	if _, err := backend.Snapshot(context.Background()); err == nil {
		t.Fatal("snapshot query error was ignored")
	}
}

func TestInspectExternalRejectsAmbiguousMultiport(t *testing.T) {
	backend := NewIPTables(staticRunner{stdout: "-A PREROUTING -p tcp -m multiport --dports 80,443 -j ACCEPT\n"})
	if _, err := backend.InspectExternal(context.Background()); err == nil || !strings.Contains(err.Error(), "multiport") {
		t.Fatalf("ambiguous external rule was accepted: %v", err)
	}
}

func TestParseManagedRuleRejectsForeignShape(t *testing.T) {
	line := "-A PMM_G_1 -p tcp --dport 443 -j REDIRECT --to-ports 8443"
	if _, err := parseManagedRules(4, []string{line}); !errors.Is(err, ErrOwnershipConflict) {
		t.Fatalf("foreign managed-chain rule was accepted: %v", err)
	}
}

func TestInspectExternalFollowsReachableCustomChains(t *testing.T) {
	output := strings.Join([]string{
		"-N DOCKER",
		"-A PREROUTING -j DOCKER",
		"-A DOCKER -p tcp --dport 8080 -j REDIRECT --to-ports 80",
	}, "\n")
	backend := NewIPTables(staticRunner{stdout: output})
	ranges, err := backend.InspectExternal(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(ranges) != 2 || ranges[0].StartPort != 8080 || ranges[1].StartPort != 8080 {
		// The static runner returns the same table for IPv4 and IPv6; both
		// families must discover the reachable rule.
		t.Fatalf("reachable custom-chain rule was missed: %+v", ranges)
	}
}

func TestSnapshotReportsSafeOrphanGeneration(t *testing.T) {
	output := "-N PMM_G_ORPHAN\n-A PMM_G_ORPHAN -p udp --dport 6000:6001 -m comment --comment pmm:rule:abc -j REDIRECT --to-ports 3000\n"
	backend := NewIPTables(staticRunner{stdout: output})
	snapshot, err := backend.snapshotFamily(context.Background(), family{version: 4, command: "iptables"})
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Managed || len(snapshot.OrphanChains) != 1 || snapshot.OrphanChains[0] != "PMM_G_ORPHAN" {
		t.Fatalf("orphan generation was ignored: %+v", snapshot)
	}
}

type staticRunner struct {
	stdout string
	err    error
}

func (r staticRunner) Run(context.Context, string, ...string) (runner.Result, error) {
	return runner.Result{Stdout: r.stdout}, r.err
}
