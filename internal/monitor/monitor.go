package monitor

import (
	"context"
	"strconv"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
)

type Rate struct {
	Counter     firewall.Counter `json:"counter"`
	PacketsRate float64          `json:"packets_per_second"`
	BytesRate   float64          `json:"bytes_per_second"`
	Baseline    bool             `json:"baseline"`
	Reset       bool             `json:"reset"`
}

type Sampler struct {
	Backend firewall.Backend
	last    map[string]firewall.Counter
	lastAt  time.Time
}

func (s *Sampler) Sample(ctx context.Context, now time.Time) ([]Rate, error) {
	counters, err := s.Backend.Counters(ctx)
	if err != nil {
		return nil, err
	}
	if s.last == nil {
		s.last = make(map[string]firewall.Counter)
	}
	elapsed := now.Sub(s.lastAt).Seconds()
	baseline := s.lastAt.IsZero() || elapsed <= 0
	rates := make([]Rate, 0, len(counters))
	next := make(map[string]firewall.Counter, len(counters))
	for _, counter := range counters {
		key := counterKey(counter)
		rate := Rate{Counter: counter, Baseline: baseline}
		if previous, exists := s.last[key]; !baseline && exists {
			if counter.Packets < previous.Packets || counter.Bytes < previous.Bytes {
				rate.Reset = true
			} else {
				rate.PacketsRate = float64(counter.Packets-previous.Packets) / elapsed
				rate.BytesRate = float64(counter.Bytes-previous.Bytes) / elapsed
			}
		} else {
			rate.Baseline = true
		}
		rates = append(rates, rate)
		next[key] = counter
	}
	s.last, s.lastAt = next, now
	return rates, nil
}

func counterKey(counter firewall.Counter) string {
	return strconv.Itoa(counter.IPVersion) + "|" + counter.RuleID
}
