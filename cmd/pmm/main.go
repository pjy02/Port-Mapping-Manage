package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"time"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/address"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/app"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/config"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/diagnostics"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/firewall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/listener"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/migration"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/monitor"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/paths"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/persistence"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/runner"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/storage"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/transaction"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/uninstall"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/updater"
	"github.com/pjy02/Port-Mapping-Manage/v6/internal/version"
)

type cli struct {
	app       app.App
	config    config.Config
	json      bool
	stdin     io.Reader
	stdout    io.Writer
	stderr    io.Writer
	paths     paths.Paths
	runner    runner.Runner
	backend   *firewall.IPTables
	defaultIP int
}

type globalOptions struct {
	root      string
	json      bool
	noBackup  bool
	verbose   bool
	defaultIP int
	remaining []string
}

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "错误:", err)
		os.Exit(1)
	}
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	options, err := parseGlobal(args)
	if err != nil {
		return err
	}
	pathSet := paths.ForRoot(options.root)
	loadedConfig, err := config.Load(pathSet.Config)
	if err != nil {
		return err
	}
	if options.noBackup {
		loadedConfig.AutoBackup = false
	}
	if options.verbose {
		loadedConfig.Verbose = true
	}
	commandRunner := runner.ExecRunner{}
	backend := firewall.NewIPTables(commandRunner)
	store := storage.Store{StatePath: pathSet.State, BackupDir: pathSet.Backups, MaxBackups: loadedConfig.MaxBackups}
	manager := transaction.Manager{
		Backend: backend, Store: store, LockPath: pathSet.Lock, TransactionDir: pathSet.Transactions,
		LockTimeout: time.Duration(loadedConfig.LockTimeoutSeconds) * time.Second, AutoBackup: loadedConfig.AutoBackup,
	}
	command := cli{app: app.App{Backend: backend, Store: store, Tx: manager}, config: loadedConfig, json: options.json, stdin: stdin, stdout: stdout, stderr: stderr, paths: pathSet, runner: commandRunner, backend: backend, defaultIP: options.defaultIP}
	if len(options.remaining) == 0 {
		return command.menu(ctx)
	}
	return command.execute(ctx, options.remaining)
}

func parseGlobal(args []string) (globalOptions, error) {
	options := globalOptions{root: os.Getenv("PMM_ROOT"), defaultIP: 4}
	for index := 0; index < len(args); index++ {
		switch args[index] {
		case "--root":
			index++
			if index >= len(args) || args[index] == "" {
				return globalOptions{}, errors.New("--root requires a path")
			}
			options.root = args[index]
		case "--json":
			options.json = true
		case "--no-backup":
			options.noBackup = true
		case "--verbose", "-v":
			options.verbose = true
		case "--ip-version":
			index++
			if index >= len(args) || (args[index] != "4" && args[index] != "6") {
				return globalOptions{}, errors.New("--ip-version must be 4 or 6")
			}
			options.defaultIP, _ = strconv.Atoi(args[index])
		case "--help", "-h":
			options.remaining = []string{"help"}
			return options, nil
		case "--version":
			options.remaining = []string{"version"}
			return options, nil
		case "--uninstall":
			options.remaining = append([]string{"uninstall"}, args[index+1:]...)
			return options, nil
		default:
			if strings.HasPrefix(args[index], "-") {
				return globalOptions{}, fmt.Errorf("unknown global option %q", args[index])
			}
			options.remaining = args[index:]
			return options, nil
		}
	}
	return options, nil
}

func (c cli) execute(ctx context.Context, args []string) error {
	switch args[0] {
	case "version", "--version":
		fmt.Fprintf(c.stdout, "pmm %s (%s, %s)\n", version.Version, version.Commit, version.Date)
		return nil
	case "help", "--help", "-h":
		c.help()
		return nil
	case "menu":
		return c.menu(ctx)
	case "rule":
		return c.rule(ctx, args[1:])
	case "import":
		return c.importRules(ctx, args[1:])
	case "sample":
		return c.sample(args[1:])
	case "export":
		return c.exportRules(ctx, args[1:])
	case "backup":
		return c.backup(ctx, args[1:])
	case "doctor":
		return c.doctor(ctx, args[1:])
	case "persistence":
		return c.persistence(ctx, args[1:])
	case "monitor":
		return c.monitor(ctx, args[1:])
	case "address":
		return c.address(ctx, args[1:])
	case "system":
		return c.system(ctx, args[1:])
	case "migrate":
		return c.migrate(ctx, args[1:])
	case "uninstall":
		return c.uninstall(ctx, args[1:])
	case "update":
		return c.update(ctx, args[1:])
	case "repair":
		return c.repair(ctx, args[1:])
	default:
		return fmt.Errorf("unknown command %q; use pmm help", args[0])
	}
}

func (c cli) repair(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] == "plan" {
		state, err := c.app.State(ctx)
		if err != nil {
			return err
		}
		if c.json {
			return writeJSON(c.stdout, state)
		}
		fmt.Fprintf(c.stdout, "只读修复计划：数据库规则=%d，内核规则=%d，漂移=%t。执行需使用 repair reconcile --yes。\n", len(state.Database.Rules), len(state.Kernel.Rules()), state.Drift)
		return nil
	}
	if args[0] != "reconcile" {
		return errors.New("repair requires plan or reconcile --yes")
	}
	flags := flag.NewFlagSet("repair reconcile", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	yes := flags.Bool("yes", false, "explicitly apply the committed database to PMM chains")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if !*yes {
		return errors.New("repair reconcile requires --yes")
	}
	return c.restoreCommittedState(ctx, "explicit-reconcile")
}

func (c cli) sample(args []string) error {
	if len(args) > 1 {
		return errors.New("sample accepts at most one output file")
	}
	content := "# PMM-RULES-V2\n# IP版本|协议|起始端口|结束端口|目标端口\n4|udp|6000|7000|3000\n4|tcp|8000|9000|4000\n6|udp|10000|12000|5000\n6|tcp|13000|14000|6000\n"
	if len(args) == 0 {
		_, err := io.WriteString(c.stdout, content)
		return err
	}
	file, err := os.OpenFile(args[0], os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.WriteString(file, content); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func (c cli) update(ctx context.Context, args []string) error {
	manager := updater.Manager{BinaryPath: c.paths.Binary, TrustPath: c.paths.Trust}
	if len(args) == 0 {
		if err := manager.Install(ctx, "latest", ""); err != nil {
			return err
		}
		fmt.Fprintln(c.stdout, "已安装签名验证通过的最新稳定版本。")
		return nil
	}
	switch args[0] {
	case "check":
		latest, err := manager.Check(ctx, version.Version)
		if err != nil {
			return err
		}
		if c.json {
			return writeJSON(c.stdout, latest)
		}
		fmt.Fprintf(c.stdout, "当前版本: %s，最新版本: %s\n", latest.Current, latest.Latest)
		if latest.Available {
			fmt.Fprintln(c.stdout, "发现新版本；运行 sudo pmm update 安装签名验证通过的版本。")
		}
		return nil
	case "install":
		flags := flag.NewFlagSet("update install", flag.ContinueOnError)
		flags.SetOutput(c.stderr)
		ref := flags.String("ref", "latest", "latest or immutable release tag")
		manifestSHA := flags.String("manifest-sha256", "", "optional independently pinned manifest SHA-256")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		if err := manager.Install(ctx, *ref, *manifestSHA); err != nil {
			return err
		}
		fmt.Fprintln(c.stdout, "更新完成；已验证发布签名和二进制摘要。")
		return nil
	default:
		return fmt.Errorf("unknown update command %q", args[0])
	}
}

func (c cli) address(ctx context.Context, args []string) error {
	if c.config.PublicIPLookup == "off" {
		return errors.New("public IP lookup is disabled by configuration")
	}
	flags := flag.NewFlagSet("address", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	ip := flags.Int("ip", 4, "IP version")
	refresh := flags.Bool("refresh", false, "ignore the family-specific cache")
	if err := flags.Parse(args); err != nil {
		return err
	}
	resolver := address.Resolver{CacheV4: c.paths.PublicIPv4, CacheV6: c.paths.PublicIPv6}
	result, err := resolver.Resolve(ctx, *ip, *refresh)
	if err != nil {
		return err
	}
	if c.json {
		return writeJSON(c.stdout, result)
	}
	cache := ""
	if result.Cached {
		cache = "（缓存）"
	}
	fmt.Fprintf(c.stdout, "IPv%d 公网地址: %s %s\n", result.IPVersion, result.IP, cache)
	return nil
}

func (c cli) rule(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("rule requires list, add, edit, delete, enable or disable")
	}
	switch args[0] {
	case "list":
		state, err := c.app.State(ctx)
		if err != nil {
			return err
		}
		if c.json {
			return writeJSON(c.stdout, state)
		}
		fmt.Fprintf(c.stdout, "%-18s %-5s %-5s %-13s %-8s %-8s\n", "ID", "IP", "协议", "来源端口", "目标", "状态")
		for _, rule := range state.Database.Rules {
			status := "启用"
			if !rule.Enabled {
				status = "禁用"
			}
			fmt.Fprintf(c.stdout, "%-18s IPv%-3d %-5s %-13s %-8d %-8s\n", rule.ID, rule.IPVersion, rule.Protocol, fmt.Sprintf("%d-%d", rule.StartPort, rule.EndPort), rule.TargetPort, status)
		}
		if state.Drift {
			fmt.Fprintln(c.stdout, "警告: 数据库与内核状态不一致")
		}
		return nil
	case "add", "edit":
		flags := flag.NewFlagSet("rule "+args[0], flag.ContinueOnError)
		flags.SetOutput(c.stderr)
		id := flags.String("id", "", "rule ID for edit")
		ip := flags.Int("ip", c.defaultIP, "IP version")
		protocol := flags.String("protocol", "udp", "tcp or udp")
		start := flags.Int("start", 0, "start port")
		end := flags.Int("end", 0, "end port")
		target := flags.Int("target", 0, "target port")
		label := flags.String("label", "", "label")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		rule, err := makeRule(*ip, *protocol, *start, *end, *target, *label)
		if err != nil {
			return err
		}
		var result transaction.Result
		if args[0] == "add" {
			result, err = c.app.Add(ctx, rule)
		} else {
			if *id == "" {
				return errors.New("edit requires --id")
			}
			labelProvided := false
			flags.Visit(func(item *flag.Flag) {
				if item.Name == "label" {
					labelProvided = true
				}
			})
			if !labelProvided {
				set, loadErr := c.app.Store.Load()
				if loadErr != nil {
					return loadErr
				}
				found := false
				for _, existing := range set.Rules {
					if existing.ID == *id {
						rule.Label = existing.Label
						found = true
						break
					}
				}
				if !found {
					return fmt.Errorf("rule %s not found", *id)
				}
			}
			result, err = c.app.Edit(ctx, *id, rule)
		}
		return c.transactionResult(result, err)
	case "delete", "enable", "disable":
		if len(args) != 2 {
			return fmt.Errorf("rule %s requires one rule ID", args[0])
		}
		var result transaction.Result
		var err error
		if args[0] == "delete" {
			result, err = c.app.Delete(ctx, args[1])
		} else {
			result, err = c.app.Toggle(ctx, args[1], args[0] == "enable")
		}
		return c.transactionResult(result, err)
	case "clear":
		flags := flag.NewFlagSet("rule clear", flag.ContinueOnError)
		flags.SetOutput(c.stderr)
		yes := flags.Bool("yes", false, "confirm removal of every PMM rule")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		if !*yes {
			return errors.New("rule clear requires --yes")
		}
		result, err := c.app.Clear(ctx)
		return c.transactionResult(result, err)
	default:
		return fmt.Errorf("unknown rule command %q", args[0])
	}
}

func (c cli) importRules(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("import", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	legacyIP := flags.Int("legacy-ip", c.defaultIP, "IP version for legacy records")
	replace := flags.Bool("replace", false, "replace instead of merge")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 {
		return errors.New("import requires a file")
	}
	file, err := os.Open(flags.Arg(0))
	if err != nil {
		return err
	}
	defer file.Close()
	result, count, err := c.app.Import(ctx, file, *legacyIP, *replace)
	if err != nil {
		return c.transactionResult(result, err)
	}
	fmt.Fprintf(c.stdout, "已验证并导入 %d 条记录，事务 %s\n", count, result.TransactionID)
	return nil
}

func (c cli) exportRules(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("export", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	format := flags.String("format", "pipe", "pipe or json")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() > 1 {
		return errors.New("export accepts at most one output file")
	}
	writer := c.stdout
	var file *os.File
	if flags.NArg() == 1 {
		var err error
		file, err = os.OpenFile(flags.Arg(0), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		defer file.Close()
		writer = file
	}
	return c.app.Export(ctx, writer, *format)
}

func (c cli) backup(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("backup requires create, list or restore")
	}
	switch args[0] {
	case "create":
		path, err := c.app.Backup(ctx)
		if err == nil {
			fmt.Fprintln(c.stdout, path)
		}
		return err
	case "list":
		backups, err := c.app.ListBackups()
		if err != nil {
			return err
		}
		for _, path := range backups {
			fmt.Fprintln(c.stdout, path)
		}
		return nil
	case "restore":
		if len(args) != 2 {
			return errors.New("backup restore requires a backup file")
		}
		result, err := c.app.Restore(ctx, args[1])
		return c.transactionResult(result, err)
	case "delete":
		if len(args) < 2 {
			return errors.New("backup delete requires one or more backup files")
		}
		for _, path := range args[1:] {
			if err := c.app.Store.DeleteBackup(path); err != nil {
				return err
			}
		}
		return nil
	case "purge":
		if len(args) != 2 || args[1] != "--yes" {
			return errors.New("backup purge requires --yes")
		}
		backups, err := c.app.ListBackups()
		if err != nil {
			return err
		}
		for _, path := range backups {
			if err := c.app.Store.DeleteBackup(path); err != nil {
				return err
			}
		}
		return nil
	default:
		return fmt.Errorf("unknown backup command %q", args[0])
	}
}

func (c cli) doctor(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("doctor", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	save := flags.Bool("save", false, "persist a diagnostic report")
	if err := flags.Parse(args); err != nil {
		return err
	}
	persistenceManager := persistence.Manager{Runner: c.runner, ServicePath: c.paths.Service, BinaryPath: c.paths.Binary}
	service := diagnostics.Service{App: c.app, Inspector: listener.Inspector{}, ReportDir: c.paths.Reports, Retention: c.config.ReportRetention, Persistence: &persistenceManager}
	report, err := service.Collect(ctx)
	if err != nil {
		return err
	}
	if c.json {
		if err := writeJSON(c.stdout, report); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(c.stdout, "数据库规则: %d，内核规则: %d\n", len(report.State.Database.Rules), len(report.State.Kernel.Rules()))
		for _, item := range report.Listeners {
			fmt.Fprintf(c.stdout, "IPv%d %-3s %5d: %s", item.IPVersion, item.Protocol, item.Port, item.Status)
			if item.Error != "" {
				fmt.Fprintf(c.stdout, " (%s)", item.Error)
			}
			fmt.Fprintln(c.stdout)
		}
		if len(report.Issues) == 0 {
			fmt.Fprintln(c.stdout, "检查通过")
		} else {
			for _, issue := range report.Issues {
				fmt.Fprintln(c.stdout, "-", issue)
			}
		}
	}
	if *save {
		path, err := service.Save(report)
		if err != nil {
			return err
		}
		fmt.Fprintln(c.stdout, "诊断报告:", path)
	}
	return nil
}

func (c cli) persistence(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("persistence requires check, enable, disable or test")
	}
	manager := persistence.Manager{Runner: c.runner, ServicePath: c.paths.Service, BinaryPath: c.paths.Binary}
	switch args[0] {
	case "check":
		status := manager.Check(ctx)
		if c.json {
			return writeJSON(c.stdout, status)
		}
		fmt.Fprintf(c.stdout, "服务文件=%t 已启用=%t 活跃=%t\n", status.FileValid, status.Enabled, status.Active)
		if status.Error != "" {
			return errors.New(status.Error)
		}
		return nil
	case "enable", "repair":
		return manager.Enable(ctx)
	case "disable":
		return manager.Disable(ctx)
	case "test":
		return c.restoreCommittedState(ctx, "persistence-test")
	default:
		return fmt.Errorf("unknown persistence command %q", args[0])
	}
}

func (c cli) monitor(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("monitor", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	interval := flags.Duration("interval", time.Second, "sampling interval")
	count := flags.Int("count", 0, "number of samples; zero means until interrupted")
	mode := flags.String("mode", "rules", "rules, summary, connections or system")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *interval < 100*time.Millisecond {
		return errors.New("monitor interval must be at least 100ms")
	}
	if *mode != "rules" && *mode != "summary" && *mode != "connections" && *mode != "system" {
		return errors.New("monitor mode must be rules, summary, connections or system")
	}
	sampler := monitor.Sampler{Backend: c.app.Backend}
	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for sample := 0; *count == 0 || sample < *count; sample++ {
		if *mode == "connections" {
			connections, err := c.connectionSnapshot(ctx)
			if err != nil {
				return err
			}
			if c.json {
				if err := writeJSON(c.stdout, connections); err != nil {
					return err
				}
			} else {
				fmt.Fprintln(c.stdout, time.Now().Format(time.RFC3339))
				for _, item := range connections {
					fmt.Fprintf(c.stdout, "[%s]\n%s", item.Name, item.Output)
				}
			}
			if !waitMonitor(ctx, ticker, *count, sample) {
				break
			}
			continue
		}
		if *mode == "system" {
			persistenceManager := persistence.Manager{Runner: c.runner, ServicePath: c.paths.Service, BinaryPath: c.paths.Binary}
			service := diagnostics.Service{App: c.app, Inspector: listener.Inspector{}, Persistence: &persistenceManager}
			report, err := service.Collect(ctx)
			if err != nil {
				return err
			}
			if c.json {
				if err := writeJSON(c.stdout, report.System); err != nil {
					return err
				}
			} else {
				fmt.Fprintf(c.stdout, "%s load=%s memory=%d/%d KiB uptime=%ds IPv4-rules=%d IPv6-rules=%d\n", time.Now().Format(time.RFC3339), report.System.LoadAverage, report.System.MemoryAvailableKB, report.System.MemoryTotalKB, report.System.UptimeSeconds, len(report.State.Kernel.IPv4.Rules), len(report.State.Kernel.IPv6.Rules))
			}
			if !waitMonitor(ctx, ticker, *count, sample) {
				break
			}
			continue
		}
		rates, err := sampler.Sample(ctx, time.Now())
		if err != nil {
			return err
		}
		if c.json {
			if err := writeJSON(c.stdout, rates); err != nil {
				return err
			}
		} else if *mode == "summary" {
			var packets, bytes uint64
			var packetsRate, bytesRate float64
			for _, rate := range rates {
				packets += rate.Counter.Packets
				bytes += rate.Counter.Bytes
				packetsRate += rate.PacketsRate
				bytesRate += rate.BytesRate
			}
			state, err := c.app.State(ctx)
			if err != nil {
				return err
			}
			up := 0
			for _, rule := range state.Database.Rules {
				if rule.Enabled && (listener.Inspector{}).Check(rule).Status == listener.Up {
					up++
				}
			}
			fmt.Fprintf(c.stdout, "%s packets=%d bytes=%d rate=%.1fpps/%.1fBps listeners=%d\n", time.Now().Format(time.RFC3339), packets, bytes, packetsRate, bytesRate, up)
		} else {
			fmt.Fprintln(c.stdout, time.Now().Format(time.RFC3339))
			for _, rate := range rates {
				if rate.Baseline {
					fmt.Fprintf(c.stdout, "  IPv%d %-18s packets=%d bytes=%d rate=N/A\n", rate.Counter.IPVersion, rate.Counter.RuleID, rate.Counter.Packets, rate.Counter.Bytes)
				} else if rate.Reset {
					fmt.Fprintf(c.stdout, "  IPv%d %-18s counter reset\n", rate.Counter.IPVersion, rate.Counter.RuleID)
				} else {
					fmt.Fprintf(c.stdout, "  IPv%d %-18s %.1f pps %.1f B/s\n", rate.Counter.IPVersion, rate.Counter.RuleID, rate.PacketsRate, rate.BytesRate)
				}
			}
		}
		if !waitMonitor(ctx, ticker, *count, sample) {
			break
		}
	}
	return nil
}

type connectionView struct {
	Name   string `json:"name"`
	Output string `json:"output"`
}

func (c cli) connectionSnapshot(ctx context.Context) ([]connectionView, error) {
	commands := []struct {
		name string
		args []string
	}{
		{"IPv4 TCP listening", []string{"-H", "-4", "-lntp"}},
		{"IPv4 TCP established", []string{"-H", "-4", "-ntp", "state", "established"}},
		{"IPv4 UDP listening", []string{"-H", "-4", "-lnup"}},
		{"IPv6 TCP listening", []string{"-H", "-6", "-lntp"}},
		{"IPv6 TCP established", []string{"-H", "-6", "-ntp", "state", "established"}},
		{"IPv6 UDP listening", []string{"-H", "-6", "-lnup"}},
	}
	views := make([]connectionView, 0, len(commands))
	for _, command := range commands {
		result, err := c.runner.Run(ctx, "ss", command.args...)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", command.name, err)
		}
		views = append(views, connectionView{Name: command.name, Output: result.Stdout})
	}
	return views, nil
}

func waitMonitor(ctx context.Context, ticker *time.Ticker, count, sample int) bool {
	if count != 0 && sample+1 >= count {
		return false
	}
	select {
	case <-ctx.Done():
		return false
	case <-ticker.C:
		return true
	}
}

func (c cli) system(ctx context.Context, args []string) error {
	if len(args) == 0 || args[0] != "restore" {
		return errors.New("unknown system command")
	}
	return c.restoreCommittedState(ctx, "boot-restore")
}

func (c cli) restoreCommittedState(ctx context.Context, operation string) error {
	set, err := c.app.Store.Load()
	if err != nil {
		return err
	}
	result, err := c.app.Tx.Reconcile(ctx, operation, set)
	return c.transactionResult(result, err)
}

func (c cli) migrate(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("migrate", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	source := flags.String("source", "auto", "auto, kernel or database")
	execute := flags.Bool("execute", false, "execute the migration plan")
	if err := flags.Parse(args); err != nil {
		return err
	}
	manager := migration.Manager{
		Backend: c.backend, Store: c.app.Store, Tx: c.app.Tx, LegacyDir: c.paths.LegacyDir,
		MigrationDir: c.paths.Transactions, ServicePath: c.paths.Service, Runner: c.runner,
	}
	plan, err := manager.Plan(ctx, migration.Source(*source))
	if err != nil {
		if c.json {
			_ = writeJSON(c.stdout, plan)
		}
		return err
	}
	if c.json || !*execute {
		if err := writeJSON(c.stdout, plan); err != nil {
			return err
		}
	}
	if !*execute {
		fmt.Fprintln(c.stdout, "这是只读迁移计划；确认后使用 --execute。")
		return nil
	}
	result, err := manager.Execute(ctx, plan)
	return c.transactionResult(result, err)
}

func (c cli) uninstall(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("uninstall", flag.ContinueOnError)
	flags.SetOutput(c.stderr)
	yes := flags.Bool("yes", false, "execute uninstall")
	keepData := flags.Bool("keep-data", false, "keep configuration, backups and reports")
	if err := flags.Parse(args); err != nil {
		return err
	}
	persistenceManager := persistence.Manager{Runner: c.runner, ServicePath: c.paths.Service, BinaryPath: c.paths.Binary}
	manager := uninstall.Manager{
		Backend: c.app.Backend, Persistence: persistenceManager, Paths: c.paths,
		LockTimeout: time.Duration(c.config.LockTimeoutSeconds) * time.Second,
	}
	manager.ExecutablePath, _ = os.Executable()
	plan, err := manager.Plan(ctx)
	if err != nil {
		return err
	}
	if c.json || !*yes {
		if err := writeJSON(c.stdout, plan); err != nil {
			return err
		}
	}
	if !*yes {
		fmt.Fprintln(c.stdout, "这是只读卸载计划；确认后使用 --yes。")
		return nil
	}
	return manager.Execute(ctx, *keepData)
}

func (c cli) transactionResult(result transaction.Result, err error) error {
	if c.json {
		_ = writeJSON(c.stdout, struct {
			Result transaction.Result `json:"result"`
			Error  string             `json:"error,omitempty"`
		}{result, errorString(err)})
	}
	if err != nil {
		return fmt.Errorf("transaction %s ended in %s: %w", result.TransactionID, result.Phase, err)
	}
	if !c.json {
		fmt.Fprintf(c.stdout, "事务 %s 已提交", result.TransactionID)
		if result.BackupPath != "" {
			fmt.Fprintf(c.stdout, "，备份: %s", result.BackupPath)
		}
		fmt.Fprintln(c.stdout)
	}
	return nil
}

func (c cli) help() {
	fmt.Fprintln(c.stdout, `Port Mapping Manager v6

用法:
  pmm [--json] [--no-backup] [--verbose] [--ip-version 4|6] <command>

命令:
  rule list
  rule add --ip 4 --protocol udp --start 6000 --end 7000 --target 3000
  rule edit --id ID --ip 6 --protocol tcp --start 8000 --end 9000 --target 4000
  rule delete|enable|disable ID
  rule clear --yes
  import [--legacy-ip 4|6] [--replace] FILE
  sample [FILE]
  export [--format pipe|json] [FILE]
  backup create|list|restore|delete|purge
  doctor [--save]
  monitor [--mode rules|summary|connections|system] [--interval 1s] [--count N]
  address [--ip 4|6] [--refresh]
  persistence check|enable|repair|disable|test
  migrate [--source auto|kernel|database] [--execute]
  update [check|install [--ref latest|vX.Y.Z] [--manifest-sha256 SHA256]]
  repair plan|reconcile --yes
  uninstall [--keep-data] [--yes]
  menu
  version`)
}

func makeRule(ip int, protocol string, start, end, target int, label string) (model.Rule, error) {
	if start < 1 || start > 65535 || end < 1 || end > 65535 || target < 1 || target > 65535 {
		return model.Rule{}, errors.New("ports must be between 1 and 65535")
	}
	rule := model.Rule{IPVersion: ip, Protocol: model.Protocol(strings.ToLower(protocol)), StartPort: uint16(start), EndPort: uint16(end), TargetPort: uint16(target), Enabled: true, Label: label}
	rule.EnsureID()
	return rule, rule.Validate()
}

func writeJSON(w io.Writer, value any) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func errorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
