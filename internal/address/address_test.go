package address

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestFamilyCachesAreIndependent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/v4" {
			_, _ = w.Write([]byte("203.0.113.10\n"))
			return
		}
		_, _ = w.Write([]byte("2001:db8::10\n"))
	}))
	defer server.Close()
	root := t.TempDir()
	now := time.Unix(1000, 0)
	resolver := Resolver{
		Client: server.Client(), CacheV4: filepath.Join(root, "v4.json"), CacheV6: filepath.Join(root, "v6.json"),
		Endpoints: map[int][]string{4: {server.URL + "/v4"}, 6: {server.URL + "/v6"}}, Now: func() time.Time { return now },
	}
	v4, err := resolver.Resolve(context.Background(), 4, false)
	if err != nil {
		t.Fatal(err)
	}
	v6, err := resolver.Resolve(context.Background(), 6, false)
	if err != nil {
		t.Fatal(err)
	}
	if v4.IP != "203.0.113.10" || v6.IP != "2001:db8::10" {
		t.Fatalf("family data leaked: v4=%+v v6=%+v", v4, v6)
	}
	server.Close()
	cached4, err := resolver.Resolve(context.Background(), 4, false)
	if err != nil || !cached4.Cached || cached4.IP != v4.IP {
		t.Fatalf("IPv4 cache unavailable or contaminated: %+v %v", cached4, err)
	}
	cached6, err := resolver.Resolve(context.Background(), 6, false)
	if err != nil || !cached6.Cached || cached6.IP != v6.IP {
		t.Fatalf("IPv6 cache unavailable or contaminated: %+v %v", cached6, err)
	}
}

func TestRejectsWrongFamilyResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("2001:db8::1"))
	}))
	defer server.Close()
	resolver := Resolver{Client: server.Client(), CacheV4: filepath.Join(t.TempDir(), "v4.json"), Endpoints: map[int][]string{4: {server.URL}}, DisableLocalFallback: true}
	if _, err := resolver.Resolve(context.Background(), 4, true); err == nil {
		t.Fatal("IPv6 response entered IPv4 cache")
	}
}
