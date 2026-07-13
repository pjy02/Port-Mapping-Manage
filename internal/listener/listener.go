package listener

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
)

type Status string

const (
	Up    Status = "UP"
	Down  Status = "DOWN"
	Error Status = "ERROR"
)

// StatusText 返回适合终端和诊断报告显示的中文状态。
// Status 的原始值继续保持稳定，避免破坏 JSON 和外部集成兼容性。
func StatusText(status Status) string {
	switch status {
	case Up:
		return "正常监听"
	case Down:
		return "未监听"
	case Error:
		return "检查失败"
	default:
		return string(status)
	}
}

type Result struct {
	RuleID    string         `json:"rule_id"`
	IPVersion int            `json:"ip_version"`
	Protocol  model.Protocol `json:"protocol"`
	Port      uint16         `json:"port"`
	Status    Status         `json:"status"`
	Error     string         `json:"error,omitempty"`
}

type Inspector struct {
	ProcRoot string
}

func (i Inspector) Check(rule model.Rule) Result {
	result := Result{RuleID: rule.ID, IPVersion: rule.IPVersion, Protocol: rule.Protocol, Port: rule.TargetPort, Status: Down}
	path := i.socketPath(rule.IPVersion, rule.Protocol)
	file, err := os.Open(path)
	if err != nil {
		result.Status = Error
		result.Error = readErrorText(err)
		return result
	}
	defer file.Close()
	found, err := containsPort(file, rule.TargetPort, rule.Protocol)
	if err != nil {
		result.Status = Error
		result.Error = readErrorText(err)
		return result
	}
	if found {
		result.Status = Up
		return result
	}
	if rule.IPVersion == 4 && i.ipv6WildcardAcceptsIPv4(rule.Protocol, rule.TargetPort) {
		result.Status = Up
	}
	return result
}

func (i Inspector) socketPath(version int, protocol model.Protocol) string {
	name := string(protocol)
	if version == 6 {
		name += "6"
	}
	return filepath.Join(i.procRoot(), "net", name)
}

func (i Inspector) procRoot() string {
	if i.ProcRoot == "" {
		return "/proc"
	}
	return i.ProcRoot
}

func (i Inspector) ipv6WildcardAcceptsIPv4(protocol model.Protocol, port uint16) bool {
	value, err := os.ReadFile(filepath.Join(i.procRoot(), "sys", "net", "ipv6", "bindv6only"))
	if err != nil || strings.TrimSpace(string(value)) != "0" {
		return false
	}
	file, err := os.Open(i.socketPath(6, protocol))
	if err != nil {
		return false
	}
	defer file.Close()
	found, _ := containsWildcardPort(file, port, protocol)
	return found
}

func containsPort(r io.Reader, port uint16, protocol model.Protocol) (bool, error) {
	return scanSockets(r, port, protocol, false)
}

func containsWildcardPort(r io.Reader, port uint16, protocol model.Protocol) (bool, error) {
	return scanSockets(r, port, protocol, true)
}

func scanSockets(r io.Reader, port uint16, protocol model.Protocol, wildcardOnly bool) (bool, error) {
	scanner := bufio.NewScanner(r)
	first := true
	for scanner.Scan() {
		if first {
			first = false
			continue
		}
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 {
			continue
		}
		address := strings.Split(fields[1], ":")
		if len(address) != 2 {
			continue
		}
		parsed, err := strconv.ParseUint(address[1], 16, 16)
		if err != nil {
			return false, fmt.Errorf("解析套接字端口失败：%w", err)
		}
		if uint16(parsed) != port {
			continue
		}
		if protocol == model.TCP && fields[3] != "0A" {
			continue
		}
		if wildcardOnly && strings.Trim(address[0], "0") != "" {
			continue
		}
		return true, nil
	}
	if err := scanner.Err(); err != nil {
		return false, err
	}
	return false, nil
}

func ValidateProcRoot(root string) error {
	if root == "" {
		root = "/proc"
	}
	info, err := os.Stat(root)
	if err != nil {
		return fmt.Errorf("检查 proc 根路径失败：%w", err)
	}
	if !info.IsDir() {
		return errors.New("proc 根路径不是目录")
	}
	return nil
}

func readErrorText(err error) string {
	switch {
	case errors.Is(err, os.ErrNotExist):
		return "无法读取系统监听信息：文件或目录不存在"
	case errors.Is(err, os.ErrPermission):
		return "无法读取系统监听信息：权限不足"
	default:
		return "读取系统监听信息失败：" + err.Error()
	}
}
