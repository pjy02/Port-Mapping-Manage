package model

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"
)

const SchemaVersion = 2

type Protocol string

const (
	TCP Protocol = "tcp"
	UDP Protocol = "udp"
)

type Rule struct {
	ID         string    `json:"id"`
	IPVersion  int       `json:"ip_version"`
	Protocol   Protocol  `json:"protocol"`
	StartPort  uint16    `json:"start_port"`
	EndPort    uint16    `json:"end_port"`
	TargetPort uint16    `json:"target_port"`
	Enabled    bool      `json:"enabled"`
	Label      string    `json:"label,omitempty"`
	CreatedAt  time.Time `json:"created_at,omitempty"`
	UpdatedAt  time.Time `json:"updated_at,omitempty"`
}

type RuleSet struct {
	SchemaVersion int       `json:"schema_version"`
	Generation    uint64    `json:"generation"`
	Backend       string    `json:"backend"`
	Rules         []Rule    `json:"rules"`
	UpdatedAt     time.Time `json:"updated_at"`
}

func NewRuleSet() RuleSet {
	return RuleSet{SchemaVersion: SchemaVersion, Backend: "iptables", Rules: []Rule{}}
}

func (r Rule) CanonicalKey() string {
	return fmt.Sprintf("%d|%s|%d|%d|%d", r.IPVersion, r.Protocol, r.StartPort, r.EndPort, r.TargetPort)
}

func (r *Rule) EnsureID() {
	if r.ID != "" {
		return
	}
	sum := sha256.Sum256([]byte(r.CanonicalKey()))
	r.ID = hex.EncodeToString(sum[:8])
}

func (r Rule) Validate() error {
	if r.IPVersion != 4 && r.IPVersion != 6 {
		return fmt.Errorf("invalid IP version %d", r.IPVersion)
	}
	if r.Protocol != TCP && r.Protocol != UDP {
		return fmt.Errorf("invalid protocol %q", r.Protocol)
	}
	if r.StartPort == 0 || r.EndPort == 0 || r.TargetPort == 0 {
		return errors.New("ports must be between 1 and 65535")
	}
	if r.StartPort > r.EndPort {
		return errors.New("start port must not exceed end port")
	}
	if r.TargetPort >= r.StartPort && r.TargetPort <= r.EndPort {
		return errors.New("target port must not be inside the source range")
	}
	if len(r.Label) > 128 {
		return errors.New("label exceeds 128 characters")
	}
	return nil
}

func (s *RuleSet) Normalize(now time.Time) error {
	if s.SchemaVersion == 0 {
		s.SchemaVersion = SchemaVersion
	}
	if s.SchemaVersion != SchemaVersion {
		return fmt.Errorf("unsupported schema version %d", s.SchemaVersion)
	}
	if s.Backend == "" {
		s.Backend = "iptables"
	}
	seenIDs := make(map[string]struct{}, len(s.Rules))
	seenCanonical := make(map[string]string, len(s.Rules))
	for i := range s.Rules {
		r := &s.Rules[i]
		r.Protocol = Protocol(strings.ToLower(string(r.Protocol)))
		r.EnsureID()
		if err := r.Validate(); err != nil {
			return fmt.Errorf("rule %s: %w", r.ID, err)
		}
		if _, exists := seenIDs[r.ID]; exists {
			return fmt.Errorf("duplicate rule ID %s", r.ID)
		}
		seenIDs[r.ID] = struct{}{}
		if existingID, exists := seenCanonical[r.CanonicalKey()]; exists {
			return fmt.Errorf("rules %s and %s have the same canonical tuple", existingID, r.ID)
		}
		seenCanonical[r.CanonicalKey()] = r.ID
		if r.CreatedAt.IsZero() {
			r.CreatedAt = now.UTC()
		}
		r.UpdatedAt = now.UTC()
	}
	sort.Slice(s.Rules, func(i, j int) bool {
		if s.Rules[i].IPVersion != s.Rules[j].IPVersion {
			return s.Rules[i].IPVersion < s.Rules[j].IPVersion
		}
		if s.Rules[i].Protocol != s.Rules[j].Protocol {
			return s.Rules[i].Protocol < s.Rules[j].Protocol
		}
		if s.Rules[i].StartPort != s.Rules[j].StartPort {
			return s.Rules[i].StartPort < s.Rules[j].StartPort
		}
		return s.Rules[i].ID < s.Rules[j].ID
	})
	for i := 0; i < len(s.Rules); i++ {
		if !s.Rules[i].Enabled {
			continue
		}
		for j := i + 1; j < len(s.Rules); j++ {
			if !s.Rules[j].Enabled || s.Rules[i].IPVersion != s.Rules[j].IPVersion || s.Rules[i].Protocol != s.Rules[j].Protocol {
				continue
			}
			if s.Rules[j].StartPort <= s.Rules[i].EndPort && s.Rules[j].EndPort >= s.Rules[i].StartPort {
				return fmt.Errorf("rules %s and %s overlap", s.Rules[i].ID, s.Rules[j].ID)
			}
		}
	}
	s.UpdatedAt = now.UTC()
	return nil
}

func Decode(r io.Reader) (RuleSet, error) {
	var set RuleSet
	decoder := json.NewDecoder(r)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&set); err != nil {
		return RuleSet{}, err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return RuleSet{}, errors.New("rule database contains multiple JSON values")
		}
		return RuleSet{}, err
	}
	if err := set.Normalize(time.Now()); err != nil {
		return RuleSet{}, err
	}
	return set, nil
}

func ParsePipe(r io.Reader, legacyIPVersion int) ([]Rule, error) {
	scanner := bufio.NewScanner(r)
	var rules []Rule
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(strings.TrimSuffix(scanner.Text(), "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		var fields []string
		if strings.Contains(line, "|") {
			fields = strings.Split(line, "|")
			if len(fields) != 5 {
				return nil, fmt.Errorf("line %d: expected five fields", lineNo)
			}
		} else {
			legacy := strings.Split(line, ":")
			if len(legacy) != 3 {
				return nil, fmt.Errorf("line %d: invalid legacy record", lineNo)
			}
			fields = []string{strconv.Itoa(legacyIPVersion), string(UDP), legacy[0], legacy[1], legacy[2]}
		}
		values := make([]int, 4)
		indexes := []int{0, 2, 3, 4}
		for i, index := range indexes {
			value, err := strconv.Atoi(strings.TrimSpace(fields[index]))
			if err != nil || value < 0 || value > 65535 {
				return nil, fmt.Errorf("line %d: invalid numeric field", lineNo)
			}
			values[i] = value
		}
		rule := Rule{
			IPVersion: values[0], Protocol: Protocol(strings.ToLower(strings.TrimSpace(fields[1]))),
			StartPort: uint16(values[1]), EndPort: uint16(values[2]), TargetPort: uint16(values[3]), Enabled: true,
		}
		rule.EnsureID()
		if err := rule.Validate(); err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNo, err)
		}
		rules = append(rules, rule)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return rules, nil
}

func WritePipe(w io.Writer, rules []Rule) error {
	if _, err := fmt.Fprintln(w, "# PMM-RULES-V2"); err != nil {
		return err
	}
	if _, err := fmt.Fprintln(w, "# IP版本|协议|起始端口|结束端口|目标端口"); err != nil {
		return err
	}
	for _, r := range rules {
		if !r.Enabled {
			continue
		}
		if _, err := fmt.Fprintln(w, r.CanonicalKey()); err != nil {
			return err
		}
	}
	return nil
}
