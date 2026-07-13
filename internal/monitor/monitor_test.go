package monitor

import (
	"context"
	"testing"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
)

func TestSamplerBaselineRateAndReset(t *testing.T) {
	backend := &counterBackend{}
	sampler := Sampler{Backend: backend}
	start := time.Unix(100, 0)
	backend.counters = []firewall.Counter{{RuleID: "same", IPVersion: 4, Packets: 10, Bytes: 100}, {RuleID: "same", IPVersion: 6, Packets: 20, Bytes: 200}}
	first, err := sampler.Sample(context.Background(), start)
	if err != nil || len(first) != 2 || !first[0].Baseline || !first[1].Baseline {
		t.Fatalf("invalid baseline: %+v %v", first, err)
	}
	backend.counters = []firewall.Counter{{RuleID: "same", IPVersion: 4, Packets: 14, Bytes: 140}, {RuleID: "same", IPVersion: 6, Packets: 25, Bytes: 260}}
	second, err := sampler.Sample(context.Background(), start.Add(2*time.Second))
	if err != nil || second[0].PacketsRate != 2 || second[1].PacketsRate != 2.5 {
		t.Fatalf("family counters leaked or rate incorrect: %+v %v", second, err)
	}
	backend.counters[0].Packets, backend.counters[0].Bytes = 1, 1
	third, err := sampler.Sample(context.Background(), start.Add(3*time.Second))
	if err != nil || !third[0].Reset || third[0].PacketsRate < 0 || third[0].BytesRate < 0 {
		t.Fatalf("counter reset produced invalid rate: %+v %v", third, err)
	}
}

type counterBackend struct {
	firewall.Backend
	counters []firewall.Counter
}

func (b *counterBackend) Counters(context.Context) ([]firewall.Counter, error) {
	return append([]firewall.Counter(nil), b.counters...), nil
}
