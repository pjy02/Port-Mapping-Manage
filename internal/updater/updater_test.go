package updater

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestEmbeddedReleasePublicKey(t *testing.T) {
	key, fingerprint, err := (Manager{}).releasePublicKey()
	if err != nil {
		t.Fatal(err)
	}
	if key.N.BitLen() != 3072 {
		t.Fatalf("unexpected release key strength: %d", key.N.BitLen())
	}
	const expected = "5e4c8fba36596ef61c3e0beaf4d44c5ce93dcf529e0b97cf645d9c4f8807f38c"
	if fingerprint != expected {
		t.Fatalf("release key fingerprint = %s, want %s", fingerprint, expected)
	}
}

func TestInstallAcceptsSignedManifest(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("self-update is Linux-only")
	}
	privateKey, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	publicDER, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	publicPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: publicDER})
	binary := []byte("signed-binary")
	binaryName := "pmm-linux-" + runtime.GOARCH
	manifest := []byte(fmt.Sprintf("%s  %s\n", digest(binary), binaryName))
	manifestSum := sha256.Sum256(manifest)
	signature, err := rsa.SignPKCS1v15(rand.Reader, privateKey, crypto.SHA256, manifestSum[:])
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch {
		case strings.HasSuffix(request.URL.Path, "/release-manifest.sha256"):
			_, _ = w.Write(manifest)
		case strings.HasSuffix(request.URL.Path, "/release-manifest.sha256.sig"):
			_, _ = w.Write(signature)
		case strings.HasSuffix(request.URL.Path, "/"+binaryName):
			_, _ = w.Write(binary)
		default:
			http.NotFound(w, request)
		}
	}))
	defer server.Close()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	manager := Manager{
		Client: server.Client(), BaseURL: server.URL, PublicKeyPEM: publicPEM,
		BinaryPath: filepath.Join(root, "bin", "pmm"), TrustPath: filepath.Join(root, "etc", "trust.json"),
		ValidateBinary: func(string) error { return nil },
	}
	if err := manager.Install(context.Background(), "v6.0.0", ""); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(manager.BinaryPath)
	if err != nil || string(got) != string(binary) {
		t.Fatalf("signed binary not installed: %q %v", got, err)
	}
}

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
	manager := Manager{BinaryPath: binaryPath, TrustPath: trustPath, ValidateBinary: func(string) error { return nil }}
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
