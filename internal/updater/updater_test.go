package updater

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestInstallRejectsUntrustedManifest(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("self-update is Linux-only")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("tampered"))
	}))
	defer server.Close()
	manager := Manager{Client: server.Client(), BaseURL: server.URL, BinaryPath: filepath.Join(t.TempDir(), "pmm"), TrustPath: filepath.Join(t.TempDir(), "trust.json")}
	if err := manager.Install(context.Background(), "v6.0.0", fmt.Sprintf("%064d", 1)); err == nil {
		t.Fatal("untrusted manifest was accepted")
	}
}

func TestInstallVerifiedReplacesBinaryAndWritesTrust(t *testing.T) {
	root := t.TempDir()
	binaryPath := filepath.Join(root, "bin", "pmm")
	trustPath := filepath.Join(root, "etc", "trust.json")
	if err := os.MkdirAll(filepath.Dir(binaryPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binaryPath, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	manager := Manager{BinaryPath: binaryPath, TrustPath: trustPath}
	if err := manager.installVerified([]byte("new"), Trust{ReleaseRef: "v6.0.0", ManifestSHA256: fmt.Sprintf("%064d", 1)}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(binaryPath)
	if err != nil || string(got) != "new" {
		t.Fatalf("binary not replaced: %q %v", got, err)
	}
	if _, err := os.Stat(trustPath); err != nil {
		t.Fatalf("trust anchor missing: %v", err)
	}
}

func TestManifestRequiresOneExactEntry(t *testing.T) {
	sum := sha256.Sum256([]byte("binary"))
	line := fmt.Sprintf("%x  pmm-linux-amd64\n", sum)
	if got, err := manifestEntry([]byte(line), "pmm-linux-amd64"); err != nil || got != fmt.Sprintf("%x", sum) {
		t.Fatalf("valid manifest rejected: %q %v", got, err)
	}
	if _, err := manifestEntry([]byte(line+line), "pmm-linux-amd64"); err == nil {
		t.Fatal("duplicate manifest entry accepted")
	}
}
