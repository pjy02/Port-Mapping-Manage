package updater

import (
	"bufio"
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
)

const repository = "pjy02/Port-Mapping-Manage"

//go:embed release-signing-public.pem
var releasePublicKeyPEM []byte

var releaseRefPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$`)

type Trust struct {
	ReleaseRef      string    `json:"release_ref"`
	ManifestSHA256  string    `json:"manifest_sha256"`
	PublicKeySHA256 string    `json:"public_key_sha256"`
	InstalledAt     time.Time `json:"installed_at"`
}

type Latest struct {
	Current   string `json:"current"`
	Latest    string `json:"latest"`
	Available bool   `json:"available"`
	URL       string `json:"url"`
}

type Manager struct {
	Client         *http.Client
	BinaryPath     string
	TrustPath      string
	BaseURL        string
	APIURL         string
	PublicKeyPEM   []byte
	ValidateBinary func(string) error
	Now            func() time.Time
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
		return Latest{}, fmt.Errorf("发布接口返回 HTTP 状态码 %d", response.StatusCode)
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
		return Latest{}, errors.New("发布接口返回了无效的版本标签")
	}
	return Latest{Current: current, Latest: payload.TagName, Available: payload.TagName != "v"+strings.TrimPrefix(current, "v"), URL: payload.HTMLURL}, nil
}

func (m Manager) Install(ctx context.Context, releaseRef, manifestDigest string) error {
	if runtime.GOOS != "linux" {
		return errors.New("自动更新仅支持 Linux")
	}
	if releaseRef == "" || releaseRef == "latest" {
		latest, err := m.Check(ctx, "")
		if err != nil {
			return err
		}
		releaseRef = latest.Latest
	}
	if !releaseRefPattern.MatchString(releaseRef) {
		return errors.New("发布版本必须是不可变的语义化版本标签")
	}
	manifestDigest = strings.ToLower(manifestDigest)
	if manifestDigest != "" {
		if len(manifestDigest) != 64 {
			return errors.New("固定的清单 SHA-256 必须包含 64 个十六进制字符")
		}
		if _, err := hex.DecodeString(manifestDigest); err != nil {
			return errors.New("固定的清单 SHA-256 无效")
		}
	}
	arch := runtime.GOARCH
	if arch != "amd64" && arch != "arm64" {
		return fmt.Errorf("不支持的处理器架构 %s", arch)
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
	signature, err := m.download(ctx, base+"/"+releaseRef+"/release-manifest.sha256.sig", 64<<10)
	if err != nil {
		return err
	}
	publicKey, publicKeyDigest, err := m.releasePublicKey()
	if err != nil {
		return err
	}
	if err := verifyManifestSignature(publicKey, manifest, signature); err != nil {
		return err
	}
	manifestActual := digest(manifest)
	if manifestDigest != "" && manifestActual != manifestDigest {
		return errors.New("发布清单与额外固定的 SHA-256 不匹配")
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
		return errors.New("下载程序的 SHA-256 与已验证清单不匹配")
	}
	return m.installVerified(binary, Trust{ReleaseRef: releaseRef, ManifestSHA256: manifestActual, PublicKeySHA256: publicKeyDigest, InstalledAt: m.now().UTC()})
}

func (m Manager) releasePublicKey() (*rsa.PublicKey, string, error) {
	keyPEM := m.PublicKeyPEM
	if len(keyPEM) == 0 {
		keyPEM = releasePublicKeyPEM
	}
	block, rest := pem.Decode(keyPEM)
	if block == nil || len(strings.TrimSpace(string(rest))) != 0 || block.Type != "PUBLIC KEY" {
		return nil, "", errors.New("发布公钥无效")
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, "", fmt.Errorf("解析发布公钥失败：%w", err)
	}
	key, ok := parsed.(*rsa.PublicKey)
	if !ok || key.N.BitLen() < 3072 {
		return nil, "", errors.New("发布公钥必须是至少 3072 位的 RSA 密钥")
	}
	return key, digest(block.Bytes), nil
}

func verifyManifestSignature(key *rsa.PublicKey, manifest, signature []byte) error {
	sum := sha256.Sum256(manifest)
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, sum[:], signature); err != nil {
		return errors.New("发布清单签名无效")
	}
	return nil
}

func (m Manager) installVerified(binary []byte, trust Trust) error {
	if m.BinaryPath == "" || m.TrustPath == "" {
		return errors.New("程序路径和信任记录路径不能为空")
	}
	for _, directory := range []string{filepath.Dir(m.BinaryPath), filepath.Dir(m.TrustPath)} {
		if err := verifySafeDirectory(directory); err != nil {
			return err
		}
	}
	if info, err := os.Lstat(m.BinaryPath); err == nil {
		if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("目标程序不是普通文件或是符号链接，拒绝替换")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	candidate := m.BinaryPath + fmt.Sprintf(".candidate-%d", os.Getpid())
	rollback := m.BinaryPath + fmt.Sprintf(".rollback-%d", os.Getpid())
	defer os.Remove(candidate)
	defer os.Remove(rollback)
	if _, err := os.Lstat(candidate); !os.IsNotExist(err) {
		return errors.New("更新候选路径已存在，拒绝覆盖")
	}
	if _, err := os.Lstat(rollback); !os.IsNotExist(err) {
		return errors.New("更新回滚路径已存在，拒绝覆盖")
	}
	if err := storage.WriteFileAtomic(candidate, binary, 0o755); err != nil {
		return err
	}
	if err := m.validateBinary(candidate); err != nil {
		return fmt.Errorf("验证通过的更新程序无法执行：%w", err)
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
		return fmt.Errorf("保存发布信任记录失败，程序已回滚：%w", err)
	}
	return nil
}

func (m Manager) validateBinary(path string) error {
	if m.ValidateBinary != nil {
		return m.ValidateBinary(path)
	}
	command := exec.Command(path, "version")
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	return command.Run()
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
		return fmt.Errorf("更新目录不安全或是符号链接，拒绝使用：%s", path)
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
		return nil, fmt.Errorf("下载请求返回 HTTP 状态码 %d", response.StatusCode)
	}
	if response.ContentLength > maximum {
		return nil, errors.New("下载内容超过大小限制")
	}
	limited := io.LimitReader(response.Body, maximum+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maximum {
		return nil, errors.New("下载内容超过大小限制")
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
		return "", fmt.Errorf("已验证清单必须且只能包含一条 %s 记录", filename)
	}
	return matches[0], nil
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
