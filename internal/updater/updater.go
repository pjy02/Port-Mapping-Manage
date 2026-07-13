package updater

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
)

const repository = "pjy02/Port-Mapping-Manage"

var releaseRefPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$`)

type Trust struct {
	ReleaseRef     string    `json:"release_ref"`
	ManifestSHA256 string    `json:"manifest_sha256"`
	InstalledAt    time.Time `json:"installed_at"`
}

type Latest struct {
	Current   string `json:"current"`
	Latest    string `json:"latest"`
	Available bool   `json:"available"`
	URL       string `json:"url"`
}

type Manager struct {
	Client     *http.Client
	BinaryPath string
	TrustPath  string
	BaseURL    string
	APIURL     string
	Now        func() time.Time
}

func (m Manager) Check(ctx context.Context, current string) (Latest, error) {
	apiURL := m.APIURL
	if apiURL == "" {
		apiURL = "https://api.github.com/repos/" + repository + "/releases/latest"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return Latest{}, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "Port-Mapping-Manager/6")
	response, err := m.client().Do(request)
	if err != nil {
		return Latest{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return Latest{}, fmt.Errorf("release API returned HTTP %d", response.StatusCode)
	}
	var payload struct {
		TagName string `json:"tag_name"`
		HTMLURL string `json:"html_url"`
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	if err := decoder.Decode(&payload); err != nil {
		return Latest{}, err
	}
	if !releaseRefPattern.MatchString(payload.TagName) {
		return Latest{}, errors.New("release API returned an invalid tag")
	}
	return Latest{Current: current, Latest: payload.TagName, Available: payload.TagName != "v"+strings.TrimPrefix(current, "v"), URL: payload.HTMLURL}, nil
}

func (m Manager) Install(ctx context.Context, releaseRef, manifestDigest string) error {
	if runtime.GOOS != "linux" {
		return errors.New("self-update is supported only on Linux")
	}
	if !releaseRefPattern.MatchString(releaseRef) {
		return errors.New("release ref must be an immutable semantic-version tag")
	}
	manifestDigest = strings.ToLower(manifestDigest)
	if len(manifestDigest) != 64 {
		return errors.New("a 64-character trusted manifest SHA-256 is required")
	}
	if _, err := hex.DecodeString(manifestDigest); err != nil {
		return errors.New("trusted manifest SHA-256 is invalid")
	}
	arch := runtime.GOARCH
	if arch != "amd64" && arch != "arm64" {
		return fmt.Errorf("unsupported architecture %s", arch)
	}
	filename := "pmm-linux-" + arch
	base := strings.TrimSuffix(m.BaseURL, "/")
	if base == "" {
		base = "https://github.com/" + repository + "/releases/download"
	}
	manifest, err := m.download(ctx, base+"/"+releaseRef+"/release-manifest.sha256", 1<<20)
	if err != nil {
		return err
	}
	if digest(manifest) != manifestDigest {
		return errors.New("release manifest does not match the trusted SHA-256")
	}
	expected, err := manifestEntry(manifest, filename)
	if err != nil {
		return err
	}
	binary, err := m.download(ctx, base+"/"+releaseRef+"/"+filename, 128<<20)
	if err != nil {
		return err
	}
	if digest(binary) != expected {
		return errors.New("downloaded binary SHA-256 does not match the verified manifest")
	}
	return m.installVerified(binary, Trust{ReleaseRef: releaseRef, ManifestSHA256: manifestDigest, InstalledAt: m.now().UTC()})
}

func (m Manager) installVerified(binary []byte, trust Trust) error {
	if m.BinaryPath == "" || m.TrustPath == "" {
		return errors.New("binary and trust paths are required")
	}
	for _, directory := range []string{filepath.Dir(m.BinaryPath), filepath.Dir(m.TrustPath)} {
		if err := verifySafeDirectory(directory); err != nil {
			return err
		}
	}
	if info, err := os.Lstat(m.BinaryPath); err == nil {
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("refusing to replace a non-regular or symlink binary")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	candidate := m.BinaryPath + fmt.Sprintf(".candidate-%d", os.Getpid())
	rollback := m.BinaryPath + fmt.Sprintf(".rollback-%d", os.Getpid())
	defer os.Remove(candidate)
	defer os.Remove(rollback)
	if _, err := os.Lstat(candidate); !os.IsNotExist(err) {
		return errors.New("candidate update path already exists")
	}
	if _, err := os.Lstat(rollback); !os.IsNotExist(err) {
		return errors.New("rollback update path already exists")
	}
	if err := storage.WriteFileAtomic(candidate, binary, 0o755); err != nil {
		return err
	}
	hadPrevious := false
	if _, err := os.Stat(m.BinaryPath); err == nil {
		if err := os.Rename(m.BinaryPath, rollback); err != nil {
			return err
		}
		hadPrevious = true
	}
	if err := os.Rename(candidate, m.BinaryPath); err != nil {
		if hadPrevious {
			_ = os.Rename(rollback, m.BinaryPath)
		}
		return err
	}
	if err := storage.WriteJSONAtomic(m.TrustPath, trust, 0o600); err != nil {
		_ = os.Remove(m.BinaryPath)
		if hadPrevious {
			_ = os.Rename(rollback, m.BinaryPath)
		}
		return fmt.Errorf("save trust anchor and rolled back binary: %w", err)
	}
	return nil
}

func verifySafeDirectory(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing unsafe update directory %s", path)
	}
	return nil
}

func (m Manager) download(ctx context.Context, url string, maximum int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "Port-Mapping-Manager/6")
	response, err := m.client().Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download returned HTTP %d", response.StatusCode)
	}
	if response.ContentLength > maximum {
		return nil, errors.New("download exceeds size limit")
	}
	limited := io.LimitReader(response.Body, maximum+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maximum {
		return nil, errors.New("download exceeds size limit")
	}
	return data, nil
}

func (m Manager) client() *http.Client {
	if m.Client != nil {
		return m.Client
	}
	return &http.Client{Timeout: 30 * time.Second}
}

func (m Manager) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func manifestEntry(manifest []byte, filename string) (string, error) {
	scanner := bufio.NewScanner(strings.NewReader(string(manifest)))
	var matches []string
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 2 && filepath.Base(fields[1]) == fields[1] && fields[1] == filename && len(fields[0]) == 64 {
			if _, err := hex.DecodeString(fields[0]); err == nil {
				matches = append(matches, strings.ToLower(fields[0]))
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if len(matches) != 1 {
		return "", fmt.Errorf("verified manifest must contain exactly one %s entry", filename)
	}
	return matches[0], nil
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
