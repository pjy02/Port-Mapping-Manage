package firewall

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
)

const (
	entryChain       = "PMM_PREROUTING"
	generationPrefix = "PMM_G_"
	anchorComment    = "pmm:anchor:v6"
	generationMark   = "pmm:generation:v6"
	rulePrefix       = "pmm:rule:"
)

type IPTables struct {
	Runner runner.Runner
	Wait   int
}

func NewIPTables(commandRunner runner.Runner) *IPTables {
	return &IPTables{Runner: commandRunner, Wait: 10}
}

func (b *IPTables) Probe(ctx context.Context) error {
	for _, family := range families() {
		if _, err := b.run(ctx, family.command, "-t", "nat", "-S"); err != nil {
			return fmt.Errorf("probe IPv%d: %w", family.version, err)
		}
	}
	return nil
}

func (b *IPTables) Snapshot(ctx context.Context) (Snapshot, error) {
	var snapshot Snapshot
	v4, err := b.snapshotFamily(ctx, family{version: 4, command: "iptables"})
	if err != nil {
		return Snapshot{}, err
	}
	v6, err := b.snapshotFamily(ctx, family{version: 6, command: "ip6tables"})
	if err != nil {
		return Snapshot{}, err
	}
	snapshot.IPv4, snapshot.IPv6 = v4, v6
	return snapshot, nil
}

func (b *IPTables) snapshotFamily(ctx context.Context, f family) (FamilySnapshot, error) {
	result, err := b.run(ctx, f.command, "-t", "nat", "-S")
	if err != nil {
		return FamilySnapshot{}, fmt.Errorf("read IPv%d NAT rules: %w", f.version, err)
	}
	lines := nonEmptyLines(result.Stdout)
	chains := declaredChains(lines)
	anchorCount := 0
	for _, line := range lines {
		if isAnchorRule(line) {
			anchorCount++
		}
	}
	_, entryExists := chains[entryChain]
	var generationChains []string
	for chain := range chains {
		if strings.HasPrefix(chain, generationPrefix) {
			generationChains = append(generationChains, chain)
		}
	}
	sort.Strings(generationChains)
	if anchorCount == 0 && !entryExists {
		for _, chain := range generationChains {
			if _, err := parseManagedRules(f.version, rulesForChain(lines, chain)); err != nil {
				return FamilySnapshot{}, fmt.Errorf("IPv%d orphan chain %s: %w", f.version, chain, err)
			}
		}
		return FamilySnapshot{IPVersion: f.version, Rules: []model.Rule{}, OrphanChains: generationChains}, nil
	}
	if anchorCount != 1 || !entryExists {
		return FamilySnapshot{}, fmt.Errorf("IPv%d: %w: anchor=%d entry=%t", f.version, ErrStateDrift, anchorCount, entryExists)
	}
	entryRules := rulesForChain(lines, entryChain)
	if len(entryRules) != 1 {
		return FamilySnapshot{}, fmt.Errorf("IPv%d: %w: entry chain has %d rules", f.version, ErrOwnershipConflict, len(entryRules))
	}
	active, ok := generationTarget(entryRules[0])
	if !ok {
		return FamilySnapshot{}, fmt.Errorf("IPv%d: %w: unexpected entry rule", f.version, ErrOwnershipConflict)
	}
	if _, exists := chains[active]; !exists {
		return FamilySnapshot{}, fmt.Errorf("IPv%d: %w: active generation chain is missing", f.version, ErrStateDrift)
	}
	rules, err := parseManagedRules(f.version, rulesForChain(lines, active))
	if err != nil {
		return FamilySnapshot{}, fmt.Errorf("IPv%d: %w", f.version, err)
	}
	var orphans []string
	for _, chain := range generationChains {
		if chain == active {
			continue
		}
		if _, err := parseManagedRules(f.version, rulesForChain(lines, chain)); err != nil {
			return FamilySnapshot{}, fmt.Errorf("IPv%d orphan chain %s: %w", f.version, chain, err)
		}
		orphans = append(orphans, chain)
	}
	return FamilySnapshot{IPVersion: f.version, Managed: true, ActiveChain: active, OrphanChains: orphans, Rules: rules}, nil
}

func (b *IPTables) Apply(ctx context.Context, desired []model.Rule) error {
	if err := validateDesired(desired); err != nil {
		return err
	}
	for _, f := range families() {
		familyRules := filterFamily(desired, f.version)
		if err := b.applyFamily(ctx, f, familyRules); err != nil {
			return fmt.Errorf("apply IPv%d: %w", f.version, err)
		}
	}
	return b.Verify(ctx, desired)
}

func (b *IPTables) applyFamily(ctx context.Context, f family, desired []model.Rule) error {
	before, err := b.snapshotFamily(ctx, f)
	if err != nil {
		return err
	}
	candidate := fmt.Sprintf("%s%X", generationPrefix, uint64(time.Now().UnixNano()))
	if len(candidate) > 28 {
		candidate = candidate[:28]
	}
	if _, err := b.run(ctx, f.command, "-t", "nat", "-N", candidate); err != nil {
		return fmt.Errorf("create candidate chain: %w", err)
	}
	candidateCreated := true
	entryCreated := false
	anchorCreated := false
	activated := false
	defer func() {
		if candidateCreated {
			_, _ = b.run(context.Background(), f.command, "-t", "nat", "-F", candidate)
			_, _ = b.run(context.Background(), f.command, "-t", "nat", "-X", candidate)
		}
		if !activated {
			if anchorCreated {
				_, _ = b.run(context.Background(), f.command, "-t", "nat", "-D", "PREROUTING", "-m", "comment", "--comment", anchorComment, "-j", entryChain)
			}
			if entryCreated {
				_, _ = b.run(context.Background(), f.command, "-t", "nat", "-F", entryChain)
				_, _ = b.run(context.Background(), f.command, "-t", "nat", "-X", entryChain)
			}
		}
	}()
	for _, rule := range desired {
		args := []string{"-t", "nat", "-A", candidate, "-p", string(rule.Protocol), "--dport", portRange(rule),
			"-m", "comment", "--comment", rulePrefix + rule.ID, "-j", "REDIRECT", "--to-ports", strconv.Itoa(int(rule.TargetPort))}
		if _, err := b.run(ctx, f.command, args...); err != nil {
			return fmt.Errorf("populate candidate chain for rule %s: %w", rule.ID, err)
		}
	}
	if !before.Managed {
		if _, err := b.run(ctx, f.command, "-t", "nat", "-N", entryChain); err != nil {
			return fmt.Errorf("create entry chain: %w", err)
		}
		entryCreated = true
		if _, err := b.run(ctx, f.command, "-t", "nat", "-A", "PREROUTING", "-m", "comment", "--comment", anchorComment, "-j", entryChain); err != nil {
			return fmt.Errorf("create anchor: %w", err)
		}
		anchorCreated = true
		if _, err := b.run(ctx, f.command, "-t", "nat", "-A", entryChain, "-m", "comment", "--comment", generationMark, "-j", candidate); err != nil {
			return fmt.Errorf("activate candidate: %w", err)
		}
	} else {
		if _, err := b.run(ctx, f.command, "-t", "nat", "-R", entryChain, "1", "-m", "comment", "--comment", generationMark, "-j", candidate); err != nil {
			return fmt.Errorf("switch active generation: %w", err)
		}
	}
	candidateCreated = false
	activated = true
	obsolete := append([]string(nil), before.OrphanChains...)
	if before.Managed {
		obsolete = append(obsolete, before.ActiveChain)
	}
	for _, chain := range uniqueStrings(obsolete) {
		if chain == candidate {
			continue
		}
		if _, err := b.run(ctx, f.command, "-t", "nat", "-F", chain); err != nil {
			return fmt.Errorf("flush obsolete generation %s: %w", chain, err)
		}
		if _, err := b.run(ctx, f.command, "-t", "nat", "-X", chain); err != nil {
			return fmt.Errorf("remove obsolete generation %s: %w", chain, err)
		}
	}
	return nil
}

func (b *IPTables) Verify(ctx context.Context, desired []model.Rule) error {
	snapshot, err := b.Snapshot(ctx)
	if err != nil {
		return err
	}
	actual := snapshot.Rules()
	actual = enabledRules(actual)
	expected := enabledRules(desired)
	if !sameRules(actual, expected) {
		return fmt.Errorf("%w: expected %v, got %v", ErrStateDrift, canonicalKeys(expected), canonicalKeys(actual))
	}
	return nil
}

func (b *IPTables) InspectExternal(ctx context.Context) ([]ExternalRange, error) {
	return b.inspectExternal(ctx, "")
}

// InspectExternalExceptComment is used only by explicit legacy migration. It
// ignores exact legacy-owned rules while retaining fail-closed parsing for all
// other PREROUTING rules.
func (b *IPTables) InspectExternalExceptComment(ctx context.Context, ignoredComment string) ([]ExternalRange, error) {
	return b.inspectExternal(ctx, ignoredComment)
}

func (b *IPTables) inspectExternal(ctx context.Context, ignoredComment string) ([]ExternalRange, error) {
	var ranges []ExternalRange
	for _, f := range families() {
		result, err := b.run(ctx, f.command, "-t", "nat", "-S")
		if err != nil {
			return nil, fmt.Errorf("inspect external IPv%d rules: %w", f.version, err)
		}
		lines := nonEmptyLines(result.Stdout)
		for _, line := range reachableRules(lines, "PREROUTING") {
			if isAnchorRule(line) {
				continue
			}
			fields := strings.Fields(line)
			comment, hasComment := fieldAfter(fields, "--comment")
			if ignoredComment != "" && hasComment && trimQuotes(comment) == ignoredComment {
				continue
			}
			protocol, hasProtocol := fieldAfter(fields, "-p")
			ports, hasPorts := fieldAfter(fields, "--dport")
			target, hasTarget := fieldAfter(fields, "-j")
			if strings.Contains(line, "! --dport") {
				return nil, fmt.Errorf("IPv%d negated destination-port rule cannot be safely analyzed: %s", f.version, line)
			}
			if !hasPorts {
				if strings.Contains(line, "--dports") {
					return nil, fmt.Errorf("IPv%d external multiport rule cannot be safely analyzed: %s", f.version, line)
				}
				if hasProtocol && (protocol == string(model.TCP) || protocol == string(model.UDP)) {
					if _, custom := declaredChains(lines)[target]; hasTarget && !custom {
						ranges = append(ranges, ExternalRange{IPVersion: f.version, Protocol: model.Protocol(protocol), StartPort: 1, EndPort: 65535, Raw: line})
					}
				}
				continue
			}
			if !hasProtocol || (protocol != string(model.TCP) && protocol != string(model.UDP)) {
				return nil, fmt.Errorf("IPv%d external destination-port rule has unknown protocol: %s", f.version, line)
			}
			start, end, err := parsePortRange(ports)
			if err != nil {
				return nil, fmt.Errorf("IPv%d external rule cannot be safely analyzed: %s", f.version, line)
			}
			ranges = append(ranges, ExternalRange{IPVersion: f.version, Protocol: model.Protocol(protocol), StartPort: start, EndPort: end, Raw: line})
		}
	}
	return ranges, nil
}

func reachableRules(lines []string, root string) []string {
	declared := declaredChains(lines)
	queue := []string{root}
	visited := make(map[string]struct{})
	var result []string
	for len(queue) > 0 {
		chain := queue[0]
		queue = queue[1:]
		if _, seen := visited[chain]; seen {
			continue
		}
		visited[chain] = struct{}{}
		for _, line := range rulesForChain(lines, chain) {
			result = append(result, line)
			fields := strings.Fields(line)
			target, hasTarget := fieldAfter(fields, "-j")
			if !hasTarget || target == entryChain {
				continue
			}
			if _, custom := declared[target]; custom {
				queue = append(queue, target)
			}
		}
	}
	return result
}

func (b *IPTables) Counters(ctx context.Context) ([]Counter, error) {
	var counters []Counter
	for _, f := range families() {
		command := "iptables-save"
		if f.version == 6 {
			command = "ip6tables-save"
		}
		result, err := b.Runner.Run(ctx, command, "-c", "-t", "nat")
		if err != nil {
			return nil, fmt.Errorf("read IPv%d counters: %w", f.version, err)
		}
		for _, line := range nonEmptyLines(result.Stdout) {
			fields := strings.Fields(line)
			if len(fields) < 2 || !strings.HasPrefix(fields[0], "[") {
				continue
			}
			comment, ok := fieldAfter(fields, "--comment")
			comment = trimQuotes(comment)
			if !ok || !strings.HasPrefix(comment, rulePrefix) {
				continue
			}
			values := strings.Split(strings.Trim(fields[0], "[]"), ":")
			if len(values) != 2 {
				return nil, fmt.Errorf("invalid IPv%d counter line: %s", f.version, line)
			}
			packets, packetErr := strconv.ParseUint(values[0], 10, 64)
			bytes, byteErr := strconv.ParseUint(values[1], 10, 64)
			if packetErr != nil || byteErr != nil {
				return nil, fmt.Errorf("invalid IPv%d counter values: %s", f.version, line)
			}
			counters = append(counters, Counter{RuleID: strings.TrimPrefix(comment, rulePrefix), IPVersion: f.version, Packets: packets, Bytes: bytes})
		}
	}
	return counters, nil
}

func (b *IPTables) DeleteManaged(ctx context.Context) error {
	for _, f := range families() {
		if err := b.deleteFamily(ctx, f); err != nil {
			return err
		}
	}
	return nil
}

// DiscoverLegacy reads only the exact legacy comment rules that were created by v5.
// Automatic migration is refused when those rules are interleaved with external rules,
// because replacing them with one anchor would otherwise change rule ordering.
func (b *IPTables) DiscoverLegacy(ctx context.Context, legacyComment string) ([]model.Rule, error) {
	var rules []model.Rule
	for _, f := range families() {
		result, err := b.run(ctx, f.command, "-t", "nat", "-S", "PREROUTING")
		if err != nil {
			return nil, fmt.Errorf("read legacy IPv%d rules: %w", f.version, err)
		}
		lines := nonEmptyLines(result.Stdout)
		seenLegacy := false
		for _, line := range lines {
			fields := strings.Fields(line)
			comment, hasComment := fieldAfter(fields, "--comment")
			owned := hasComment && trimQuotes(comment) == legacyComment
			if seenLegacy && !owned {
				return nil, fmt.Errorf("IPv%d legacy PMM rules are interleaved with external rules; automatic migration would change ordering", f.version)
			}
			if !owned {
				continue
			}
			seenLegacy = true
			protocol, okProtocol := fieldAfter(fields, "-p")
			ports, okPorts := fieldAfter(fields, "--dport")
			target, okTarget := fieldAfter(fields, "-j")
			toPorts, okToPorts := fieldAfter(fields, "--to-ports")
			if !okProtocol || !okPorts || !okTarget || !okToPorts || target != "REDIRECT" {
				return nil, fmt.Errorf("IPv%d legacy rule has an unsupported shape: %s", f.version, line)
			}
			start, end, err := parsePortRange(ports)
			if err != nil {
				return nil, err
			}
			targetPort, err := strconv.ParseUint(toPorts, 10, 16)
			if err != nil {
				return nil, err
			}
			rule := model.Rule{IPVersion: f.version, Protocol: model.Protocol(protocol), StartPort: start, EndPort: end, TargetPort: uint16(targetPort), Enabled: true}
			rule.EnsureID()
			if err := rule.Validate(); err != nil {
				return nil, err
			}
			rules = append(rules, rule)
		}
	}
	return rules, nil
}

func (b *IPTables) DeleteLegacy(ctx context.Context, legacyComment string, rules []model.Rule) error {
	for index := len(rules) - 1; index >= 0; index-- {
		rule := rules[index]
		command := "iptables"
		if rule.IPVersion == 6 {
			command = "ip6tables"
		}
		args := []string{"-t", "nat", "-D", "PREROUTING", "-p", string(rule.Protocol), "--dport", portRange(rule),
			"-m", "comment", "--comment", legacyComment, "-j", "REDIRECT", "--to-ports", strconv.Itoa(int(rule.TargetPort))}
		if _, err := b.run(ctx, command, args...); err != nil {
			return fmt.Errorf("delete legacy rule %s: %w", rule.ID, err)
		}
	}
	return nil
}

func (b *IPTables) RestoreLegacy(ctx context.Context, legacyComment string, rules []model.Rule) error {
	current, err := b.DiscoverLegacy(ctx, legacyComment)
	if err == nil && len(current) > 0 {
		if err := b.DeleteLegacy(ctx, legacyComment, current); err != nil {
			return err
		}
	}
	for _, rule := range rules {
		command := "iptables"
		if rule.IPVersion == 6 {
			command = "ip6tables"
		}
		args := []string{"-t", "nat", "-A", "PREROUTING", "-p", string(rule.Protocol), "--dport", portRange(rule),
			"-m", "comment", "--comment", legacyComment, "-j", "REDIRECT", "--to-ports", strconv.Itoa(int(rule.TargetPort))}
		if _, err := b.run(ctx, command, args...); err != nil {
			return fmt.Errorf("restore legacy rule %s: %w", rule.ID, err)
		}
	}
	return nil
}

func (b *IPTables) Restore(ctx context.Context, snapshot Snapshot) error {
	for _, item := range []struct {
		family   family
		snapshot FamilySnapshot
	}{{families()[0], snapshot.IPv4}, {families()[1], snapshot.IPv6}} {
		if item.snapshot.Managed {
			if err := b.applyFamily(ctx, item.family, item.snapshot.Rules); err != nil {
				return fmt.Errorf("restore IPv%d: %w", item.family.version, err)
			}
		} else if err := b.deleteFamily(ctx, item.family); err != nil {
			return err
		}
	}
	return nil
}

func (b *IPTables) deleteFamily(ctx context.Context, f family) error {
	snapshot, err := b.snapshotFamily(ctx, f)
	if err != nil {
		return err
	}
	if !snapshot.Managed {
		for _, chain := range snapshot.OrphanChains {
			if _, err := b.run(ctx, f.command, "-t", "nat", "-F", chain); err != nil {
				return err
			}
			if _, err := b.run(ctx, f.command, "-t", "nat", "-X", chain); err != nil {
				return err
			}
		}
		return nil
	}
	if _, err := b.run(ctx, f.command, "-t", "nat", "-D", "PREROUTING", "-m", "comment", "--comment", anchorComment, "-j", entryChain); err != nil {
		return fmt.Errorf("remove IPv%d anchor: %w", f.version, err)
	}
	if _, err := b.run(ctx, f.command, "-t", "nat", "-F", entryChain); err != nil {
		return err
	}
	for _, chain := range uniqueStrings(append(snapshot.OrphanChains, snapshot.ActiveChain)) {
		if _, err := b.run(ctx, f.command, "-t", "nat", "-F", chain); err != nil {
			return err
		}
		if _, err := b.run(ctx, f.command, "-t", "nat", "-X", chain); err != nil {
			return err
		}
	}
	if _, err := b.run(ctx, f.command, "-t", "nat", "-X", entryChain); err != nil {
		return err
	}
	return nil
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func (b *IPTables) run(ctx context.Context, command string, args ...string) (runner.Result, error) {
	withWait := append([]string{"--wait", strconv.Itoa(b.Wait)}, args...)
	return b.Runner.Run(ctx, command, withWait...)
}

type family struct {
	version int
	command string
}

func families() []family {
	return []family{{version: 4, command: "iptables"}, {version: 6, command: "ip6tables"}}
}

func nonEmptyLines(output string) []string {
	var lines []string
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

func declaredChains(lines []string) map[string]struct{} {
	chains := make(map[string]struct{})
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "-N" {
			chains[fields[1]] = struct{}{}
		}
	}
	return chains
}

func rulesForChain(lines []string, chain string) []string {
	prefix := "-A " + chain + " "
	var rules []string
	for _, line := range lines {
		if strings.HasPrefix(line, prefix) {
			rules = append(rules, line)
		}
	}
	return rules
}

func isAnchorRule(line string) bool {
	fields := strings.Fields(line)
	chain, okChain := fieldAfter(fields, "-A")
	comment, okComment := fieldAfter(fields, "--comment")
	target, okTarget := fieldAfter(fields, "-j")
	return okChain && okComment && okTarget && chain == "PREROUTING" && trimQuotes(comment) == anchorComment && target == entryChain
}

func generationTarget(line string) (string, bool) {
	fields := strings.Fields(line)
	chain, okChain := fieldAfter(fields, "-A")
	comment, okComment := fieldAfter(fields, "--comment")
	target, okTarget := fieldAfter(fields, "-j")
	if !okChain || !okComment || !okTarget || chain != entryChain || trimQuotes(comment) != generationMark || !strings.HasPrefix(target, generationPrefix) {
		return "", false
	}
	return target, true
}

func parseManagedRules(ipVersion int, lines []string) ([]model.Rule, error) {
	var rules []model.Rule
	for _, line := range lines {
		fields := strings.Fields(line)
		protocol, okProtocol := fieldAfter(fields, "-p")
		ports, okPorts := fieldAfter(fields, "--dport")
		comment, okComment := fieldAfter(fields, "--comment")
		target, okTarget := fieldAfter(fields, "-j")
		toPorts, okToPorts := fieldAfter(fields, "--to-ports")
		comment = trimQuotes(comment)
		if !okProtocol || !okPorts || !okComment || !okTarget || !okToPorts || target != "REDIRECT" || !strings.HasPrefix(comment, rulePrefix) {
			return nil, fmt.Errorf("%w: unexpected managed rule %q", ErrOwnershipConflict, line)
		}
		start, end, err := parsePortRange(ports)
		if err != nil {
			return nil, err
		}
		targetPort, err := strconv.ParseUint(toPorts, 10, 16)
		if err != nil {
			return nil, err
		}
		rule := model.Rule{ID: strings.TrimPrefix(comment, rulePrefix), IPVersion: ipVersion, Protocol: model.Protocol(protocol), StartPort: start, EndPort: end, TargetPort: uint16(targetPort), Enabled: true}
		if err := rule.Validate(); err != nil {
			return nil, err
		}
		rules = append(rules, rule)
	}
	return rules, nil
}

func parsePortRange(value string) (uint16, uint16, error) {
	parts := strings.Split(value, ":")
	if len(parts) == 1 {
		parts = append(parts, parts[0])
	}
	if len(parts) != 2 {
		return 0, 0, errors.New("invalid port range")
	}
	start, err := strconv.ParseUint(parts[0], 10, 16)
	if err != nil || start == 0 {
		return 0, 0, errors.New("invalid start port")
	}
	end, err := strconv.ParseUint(parts[1], 10, 16)
	if err != nil || end == 0 || start > end {
		return 0, 0, errors.New("invalid end port")
	}
	return uint16(start), uint16(end), nil
}

func fieldAfter(fields []string, key string) (string, bool) {
	for index := 0; index+1 < len(fields); index++ {
		if fields[index] == key {
			return fields[index+1], true
		}
	}
	return "", false
}

func trimQuotes(value string) string {
	return strings.Trim(value, "\"'")
}

func filterFamily(rules []model.Rule, ipVersion int) []model.Rule {
	var result []model.Rule
	for _, rule := range rules {
		if rule.Enabled && rule.IPVersion == ipVersion {
			result = append(result, rule)
		}
	}
	return result
}

func enabledRules(rules []model.Rule) []model.Rule {
	var result []model.Rule
	for _, rule := range rules {
		if rule.Enabled {
			result = append(result, rule)
		}
	}
	return result
}

func validateDesired(rules []model.Rule) error {
	set := model.NewRuleSet()
	set.Rules = append([]model.Rule(nil), rules...)
	return set.Normalize(time.Now())
}

func portRange(rule model.Rule) string {
	return fmt.Sprintf("%d:%d", rule.StartPort, rule.EndPort)
}

func sameRules(left, right []model.Rule) bool {
	l := canonicalKeys(left)
	r := canonicalKeys(right)
	if len(l) != len(r) {
		return false
	}
	for i := range l {
		if l[i] != r[i] {
			return false
		}
	}
	return true
}

func canonicalKeys(rules []model.Rule) []string {
	keys := make([]string, 0, len(rules))
	for _, rule := range rules {
		keys = append(keys, rule.ID+"|"+rule.CanonicalKey())
	}
	sort.Strings(keys)
	return keys
}
