package paths

import (
	"path/filepath"
	"strings"
)

type Paths struct {
	Config       string
	State        string
	Backups      string
	Transactions string
	Reports      string
	PublicIPv4   string
	PublicIPv6   string
	Log          string
	Lock         string
	LegacyDir    string
	Service      string
	Binary       string
	Trust        string
}

func ForRoot(root string) Paths {
	join := func(path string) string {
		if root == "" {
			return filepath.FromSlash(path)
		}
		return filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(path, "/")))
	}
	return Paths{
		Config:       join("/etc/port-mapping-manager/config.json"),
		State:        join("/var/lib/port-mapping-manager/rules.json"),
		Backups:      join("/var/lib/port-mapping-manager/backups"),
		Transactions: join("/var/lib/port-mapping-manager/transactions"),
		Reports:      join("/var/log/port-mapping-manager/reports"),
		PublicIPv4:   join("/var/cache/port-mapping-manager/public-ip-v4.json"),
		PublicIPv6:   join("/var/cache/port-mapping-manager/public-ip-v6.json"),
		Log:          join("/var/log/port-mapping-manager/pmm.log"),
		Lock:         join("/run/lock/port-mapping-manager.lock"),
		LegacyDir:    join("/etc/port_mapping_manager"),
		Service:      join("/etc/systemd/system/pmm-rules.service"),
		Binary:       join("/usr/local/bin/pmm"),
		Trust:        join("/etc/port-mapping-manager/trusted-release.json"),
	}
}
