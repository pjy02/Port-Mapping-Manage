package diagnostics

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/app"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/listener"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/persistence"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/version"
)

type Report struct {
	ID            string              `json:"id"`
	CreatedAt     time.Time           `json:"created_at"`
	Version       string              `json:"version"`
	GOOS          string              `json:"goos"`
	GOARCH        string              `json:"goarch"`
	State         app.State           `json:"state"`
	Issues        []string            `json:"issues"`
	Listeners     []listener.Result   `json:"listeners"`
	ExternalRules int                 `json:"external_rules"`
	System        SystemInfo          `json:"system"`
	Persistence   *persistence.Status `json:"persistence,omitempty"`
}

type SystemInfo struct {
	KernelRelease     string `json:"kernel_release,omitempty"`
	LoadAverage       string `json:"load_average,omitempty"`
	UptimeSeconds     uint64 `json:"uptime_seconds,omitempty"`
	MemoryTotalKB     uint64 `json:"memory_total_kb,omitempty"`
	MemoryAvailableKB uint64 `json:"memory_available_kb,omitempty"`
	IPv4Forwarding    string `json:"ipv4_forwarding,omitempty"`
	IPv6Forwarding    string `json:"ipv6_forwarding,omitempty"`
}

type Service struct {
	App         app.App
	Inspector   listener.Inspector
	ReportDir   string
	Retention   int
	Now         func() time.Time
	ProcRoot    string
	Persistence *persistence.Manager
}

func (s Service) Collect(ctx context.Context) (Report, error) {
	if s.Now == nil {
		s.Now = time.Now
	}
	state, issues, err := s.App.Doctor(ctx)
	if err != nil {
		return Report{}, err
	}
	report := Report{
		ID: s.Now().UTC().Format("20060102T150405.000000000Z"), CreatedAt: s.Now().UTC(),
		Version: version.Version, GOOS: runtime.GOOS, GOARCH: runtime.GOARCH,
		State: state, Issues: issues,
	}
	report.System = collectSystemInfo(s.ProcRoot)
	if external, inspectErr := s.App.Backend.InspectExternal(ctx); inspectErr != nil {
		report.Issues = append(report.Issues, "外部规则检查失败："+inspectErr.Error())
	} else {
		report.ExternalRules = len(external)
		for _, rule := range state.Database.Rules {
			if !rule.Enabled {
				continue
			}
			for _, other := range external {
				if rule.IPVersion == other.IPVersion && rule.Protocol == other.Protocol && rule.StartPort <= other.EndPort && rule.EndPort >= other.StartPort {
					report.Issues = append(report.Issues, fmt.Sprintf("规则 %s 与外部规则冲突：%s", rule.ID, other.Raw))
				}
			}
		}
	}
	if s.Persistence != nil {
		status := s.Persistence.Check(ctx)
		report.Persistence = &status
		if status.Error != "" {
			report.Issues = append(report.Issues, "持久化检查失败："+status.Error)
		}
	}
	for _, rule := range state.Database.Rules {
		if rule.Enabled {
			result := s.Inspector.Check(rule)
			report.Listeners = append(report.Listeners, result)
			if result.Status != listener.Up {
				report.Issues = append(report.Issues, fmt.Sprintf("IPv%d/%s 目标端口 %d 监听状态为%s", result.IPVersion, result.Protocol, result.Port, listener.StatusText(result.Status)))
			}
		}
	}
	return report, nil
}

func collectSystemInfo(procRoot string) SystemInfo {
	if procRoot == "" {
		procRoot = "/proc"
	}
	read := func(relative string) string {
		data, err := os.ReadFile(filepath.Join(procRoot, filepath.FromSlash(relative)))
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(data))
	}
	info := SystemInfo{
		KernelRelease: read("sys/kernel/osrelease"), LoadAverage: read("loadavg"),
		IPv4Forwarding: read("sys/net/ipv4/ip_forward"), IPv6Forwarding: read("sys/net/ipv6/conf/all/forwarding"),
	}
	if fields := strings.Fields(read("uptime")); len(fields) > 0 {
		if value, err := strconv.ParseFloat(fields[0], 64); err == nil && value >= 0 {
			info.UptimeSeconds = uint64(value)
		}
	}
	for _, line := range strings.Split(read("meminfo"), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		switch strings.TrimSuffix(fields[0], ":") {
		case "MemTotal":
			info.MemoryTotalKB = value
		case "MemAvailable":
			info.MemoryAvailableKB = value
		}
	}
	return info
}

func (s Service) Save(report Report) (string, error) {
	path := filepath.Join(s.ReportDir, fmt.Sprintf("diagnostic-%s-%d.json", report.ID, os.Getpid()))
	if err := storage.WriteJSONAtomic(path, report, 0o600); err != nil {
		return "", err
	}
	if err := s.cleanup(); err != nil {
		return path, err
	}
	return path, nil
}

func (s Service) cleanup() error {
	entries, err := os.ReadDir(s.ReportDir)
	if err != nil {
		return err
	}
	var names []string
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "diagnostic-") || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr != nil {
			return infoErr
		}
		if info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 {
			names = append(names, entry.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	for _, name := range names[safeMin(s.Retention, len(names)):] {
		if err := os.Remove(filepath.Join(s.ReportDir, name)); err != nil {
			return err
		}
	}
	return nil
}

func safeMin(left, right int) int {
	if left < right {
		return left
	}
	return right
}
