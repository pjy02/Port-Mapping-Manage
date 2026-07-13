package model

import (
	"strings"
	"testing"
	"time"
)

func TestParsePipeAllFamiliesAndProtocols(t *testing.T) {
	input := "4|tcp|1000|1001|2000\n4|udp|3000|3001|4000\n6|tcp|5000|5001|6000\n6|udp|7000|7001|8000\n"
	rules, err := ParsePipe(strings.NewReader(input), 4)
	if err != nil {
		t.Fatal(err)
	}
	if len(rules) != 4 {
		t.Fatalf("expected 4 rules, got %d", len(rules))
	}
	for _, rule := range rules {
		if rule.ID == "" || !rule.Enabled {
			t.Fatalf("rule was not normalized: %+v", rule)
		}
	}
}

func TestParseLegacy(t *testing.T) {
	rules, err := ParsePipe(strings.NewReader("6000:7000:3000\n"), 6)
	if err != nil {
		t.Fatal(err)
	}
	if rules[0].IPVersion != 6 || rules[0].Protocol != UDP {
		t.Fatalf("legacy defaults were not preserved: %+v", rules[0])
	}
}

func TestRuleSetRejectsOverlap(t *testing.T) {
	set := NewRuleSet()
	set.Rules = []Rule{
		{IPVersion: 4, Protocol: TCP, StartPort: 1000, EndPort: 2000, TargetPort: 9000, Enabled: true},
		{IPVersion: 4, Protocol: TCP, StartPort: 1500, EndPort: 2500, TargetPort: 9001, Enabled: true},
	}
	if err := set.Normalize(time.Now()); err == nil {
		t.Fatal("overlapping rules were accepted")
	}
}

func TestDisabledOverlapIsAllowed(t *testing.T) {
	set := NewRuleSet()
	set.Rules = []Rule{
		{IPVersion: 6, Protocol: UDP, StartPort: 1000, EndPort: 2000, TargetPort: 9000, Enabled: true},
		{IPVersion: 6, Protocol: UDP, StartPort: 1500, EndPort: 2500, TargetPort: 9001, Enabled: false},
	}
	if err := set.Normalize(time.Now()); err != nil {
		t.Fatal(err)
	}
}

func TestTargetInsideRangeRejectedEverywhere(t *testing.T) {
	rule := Rule{IPVersion: 4, Protocol: UDP, StartPort: 1000, EndPort: 2000, TargetPort: 1500, Enabled: true}
	if err := rule.Validate(); err == nil {
		t.Fatal("target inside source range was accepted")
	}
}

func TestDecodeRejectsTrailingJSON(t *testing.T) {
	input := `{"schema_version":2,"generation":0,"backend":"iptables","rules":[],"updated_at":"0001-01-01T00:00:00Z"} {}`
	if _, err := Decode(strings.NewReader(input)); err == nil {
		t.Fatal("trailing JSON was accepted")
	}
}

func TestDuplicateCanonicalTupleRejectedWhenDisabled(t *testing.T) {
	set := NewRuleSet()
	set.Rules = []Rule{
		{ID: "one", IPVersion: 4, Protocol: TCP, StartPort: 1000, EndPort: 1001, TargetPort: 2000, Enabled: true},
		{ID: "two", IPVersion: 4, Protocol: TCP, StartPort: 1000, EndPort: 1001, TargetPort: 2000, Enabled: false},
	}
	if err := set.Normalize(time.Now()); err == nil {
		t.Fatal("duplicate canonical tuple was accepted")
	}
}
