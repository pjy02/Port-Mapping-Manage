package address

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
)

type Result struct {
	IP        string    `json:"ip"`
	IPVersion int       `json:"ip_version"`
	Source    string    `json:"source"`
	CheckedAt time.Time `json:"checked_at"`
	Cached    bool      `json:"cached"`
}

type Resolver struct {
	Client    *http.Client
	CacheV4   string
	CacheV6   string
	TTL       time.Duration
	Endpoints map[int][]string
	Now       func() time.Time
	// DisableLocalFallback is intended for deterministic tests and locked-down
	// deployments that never want interface addresses returned as a fallback.
	DisableLocalFallback bool
}

func (r Resolver) Resolve(ctx context.Context, version int, refresh bool) (Result, error) {
	if version != 4 && version != 6 {
		return Result{}, errors.New("IP 版本只能是 4 或 6")
	}
	if r.Now == nil {
		r.Now = time.Now
	}
	if r.TTL <= 0 {
		r.TTL = 10 * time.Minute
	}
	cachePath := r.CacheV4
	if version == 6 {
		cachePath = r.CacheV6
	}
	if !refresh {
		if cached, err := r.loadCache(cachePath, version); err == nil && r.Now().Sub(cached.CheckedAt) <= r.TTL {
			cached.Cached = true
			return cached, nil
		}
	}
	client := r.Client
	if client == nil {
		client = &http.Client{Timeout: 4 * time.Second}
	}
	endpoints := r.Endpoints[version]
	if len(endpoints) == 0 {
		if version == 4 {
			endpoints = []string{"https://api.ipify.org", "https://ipv4.icanhazip.com"}
		} else {
			endpoints = []string{"https://api6.ipify.org", "https://ipv6.icanhazip.com"}
		}
	}
	var failures []error
	for _, endpoint := range endpoints {
		result, err := fetch(ctx, client, endpoint, version, r.Now().UTC())
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", endpoint, err))
			continue
		}
		if err := storage.WriteJSONAtomic(cachePath, result, 0o600); err != nil {
			return Result{}, fmt.Errorf("保存 IPv%d 公网地址缓存失败：%w", version, err)
		}
		return result, nil
	}
	if !r.DisableLocalFallback {
		if local, err := localGlobalAddress(version); err == nil {
			result := Result{IP: local.String(), IPVersion: version, Source: "local-interface", CheckedAt: r.Now().UTC()}
			if err := storage.WriteJSONAtomic(cachePath, result, 0o600); err != nil {
				return Result{}, err
			}
			return result, nil
		}
	}
	return Result{}, fmt.Errorf("查询 IPv%d 公网地址失败：%w", version, errors.Join(failures...))
}

func (r Resolver) loadCache(path string, version int) (Result, error) {
	file, err := os.Open(path)
	if err != nil {
		return Result{}, err
	}
	defer file.Close()
	var result Result
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return Result{}, err
	}
	if result.IPVersion != version || !validFamily(net.ParseIP(result.IP), version) || result.CheckedAt.IsZero() {
		return Result{}, errors.New("缓存中的 IP 版本或地址无效")
	}
	return result, nil
}

func fetch(ctx context.Context, client *http.Client, endpoint string, version int, now time.Time) (Result, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return Result{}, err
	}
	request.Header.Set("User-Agent", "Port-Mapping-Manager/6")
	response, err := client.Do(request)
	if err != nil {
		return Result{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return Result{}, fmt.Errorf("HTTP 返回状态码 %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 256))
	if err != nil {
		return Result{}, err
	}
	value := strings.TrimSpace(string(body))
	if !validFamily(net.ParseIP(value), version) {
		return Result{}, fmt.Errorf("响应内容不是有效的 IPv%d 地址", version)
	}
	return Result{IP: value, IPVersion: version, Source: endpoint, CheckedAt: now}, nil
}

func validFamily(ip net.IP, version int) bool {
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	if version == 4 {
		return ip.To4() != nil
	}
	return ip.To4() == nil && ip.To16() != nil
}

func localGlobalAddress(version int) (net.IP, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	for _, item := range interfaces {
		if item.Flags&net.FlagUp == 0 || item.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := item.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err == nil && validFamily(ip, version) {
				return ip, nil
			}
		}
	}
	return nil, fmt.Errorf("没有找到全局 IPv%d 网卡地址", version)
}
