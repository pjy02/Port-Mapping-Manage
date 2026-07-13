package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/pjy02/Port-Mapping-Manage/v6/internal/model"
)

type menuInput struct {
	reader *bufio.Reader
	out    io.Writer
}

func (c cli) menu(ctx context.Context) error {
	in := menuInput{reader: bufio.NewReader(c.stdin), out: c.stdout}
	interactive := isTerminalFile(c.stdin) && isTerminalFile(c.stdout) && os.Getenv("TERM") != "dumb"
	theme := newDashboardTheme(c.stdout)
	for {
		if interactive {
			fmt.Fprint(c.stdout, "\x1b[2J\x1b[H")
		} else {
			fmt.Fprintln(c.stdout)
		}
		renderDashboard(c.stdout, c.dashboardStatus(ctx), theme)
		choice, err := in.prompt("请选择", "")
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		choice = strings.ToLower(choice)
		if choice == "0" || choice == "q" {
			return nil
		}
		var actionErr error
		switch choice {
		case "1":
			actionErr = c.rule(ctx, []string{"list"})
		case "2":
			actionErr = c.menuAddRule(ctx, in)
		case "3":
			actionErr = c.menuManageRule(ctx, in)
		case "4":
			actionErr = c.menuMonitor(ctx, in)
		case "5":
			actionErr = c.menuDoctor(ctx, in)
		case "6":
			actionErr = c.menuBatch(ctx, in)
		case "7":
			actionErr = c.menuBackup(ctx, in)
		case "8":
			actionErr = c.menuPersistence(ctx, in)
		case "9":
			actionErr = c.menuAddress(ctx, in)
		case "10":
			actionErr = c.menuMigration(ctx, in)
		case "u", "11":
			actionErr = c.update(ctx, []string{"check"})
		case "x", "12":
			actionErr = c.menuUninstall(ctx, in)
		default:
			fmt.Fprintln(c.stderr, "无效选择")
		}
		if actionErr != nil {
			fmt.Fprintln(c.stderr, "错误："+localizedErrorText(actionErr))
		}
		if interactive {
			if err := in.pause(); err != nil {
				return err
			}
		}
	}
}

func (c cli) menuAddress(ctx context.Context, in menuInput) error {
	version, err := in.prompt("IP 版本 4/6", "4")
	if err != nil {
		return err
	}
	refresh, err := in.prompt("忽略缓存重新查询？y/N", "n")
	if err != nil {
		return err
	}
	args := []string{"--ip", version}
	if isYes(refresh) {
		args = append(args, "--refresh")
	}
	return c.address(ctx, args)
}

func (c cli) menuAddRule(ctx context.Context, in menuInput) error {
	mode, err := in.prompt("1=自定义，2=6000-7000→3000，3=8000-9000→4000，4=10000-12000→5000", "1")
	if err != nil {
		return err
	}
	start, end, target := 0, 0, 0
	switch mode {
	case "2":
		start, end, target = 6000, 7000, 3000
	case "3":
		start, end, target = 8000, 9000, 4000
	case "4":
		start, end, target = 10000, 12000, 5000
	case "1":
	default:
		return errors.New("无效预设")
	}
	rule, err := in.rule(model.Rule{IPVersion: c.defaultIP, Protocol: model.UDP, StartPort: uint16(start), EndPort: uint16(end), TargetPort: uint16(target), Enabled: true})
	if err != nil {
		return err
	}
	result, err := c.app.Add(ctx, rule)
	return c.transactionResult(result, err)
}

func (c cli) menuManageRule(ctx context.Context, in menuInput) error {
	state, err := c.app.State(ctx)
	if err != nil {
		return err
	}
	if len(state.Database.Rules) == 0 {
		return errors.New("当前没有规则")
	}
	if err := c.rule(ctx, []string{"list"}); err != nil {
		return err
	}
	id, err := in.prompt("规则 ID（可输入唯一前缀）", "")
	if err != nil {
		return err
	}
	rule, err := resolveRule(state.Database.Rules, id)
	if err != nil {
		return err
	}
	action, err := in.prompt("1=编辑，2=启用，3=禁用，4=删除，5=清空全部", "1")
	if err != nil {
		return err
	}
	switch action {
	case "1":
		update, err := in.rule(rule)
		if err != nil {
			return err
		}
		result, err := c.app.Edit(ctx, rule.ID, update)
		return c.transactionResult(result, err)
	case "2", "3":
		result, err := c.app.Toggle(ctx, rule.ID, action == "2")
		return c.transactionResult(result, err)
	case "4":
		confirm, err := in.prompt("输入 DELETE 确认删除", "")
		if err != nil {
			return err
		}
		if confirm != "DELETE" {
			fmt.Fprintln(c.stdout, "已取消")
			return nil
		}
		result, err := c.app.Delete(ctx, rule.ID)
		return c.transactionResult(result, err)
	case "5":
		confirm, err := in.prompt("输入 CLEAR-ALL 确认清空全部 PMM 规则", "")
		if err != nil {
			return err
		}
		if confirm != "CLEAR-ALL" {
			fmt.Fprintln(c.stdout, "已取消")
			return nil
		}
		return c.rule(ctx, []string{"clear", "--yes"})
	default:
		return errors.New("无效操作")
	}
}

func (c cli) menuBatch(ctx context.Context, in menuInput) error {
	action, err := in.prompt("1=导入合并，2=导入替换，3=导出 pipe，4=导出 JSON，5=生成样例", "1")
	if err != nil {
		return err
	}
	path, err := in.prompt("文件路径", "")
	if err != nil {
		return err
	}
	if path == "" {
		return errors.New("文件路径不能为空")
	}
	switch action {
	case "5":
		return c.sample([]string{path})
	case "1", "2":
		legacyIP, err := in.prompt("旧三字段格式使用的 IP 版本", "4")
		if err != nil {
			return err
		}
		args := []string{"--legacy-ip", legacyIP}
		if action == "2" {
			confirm, err := in.prompt("替换全部现有规则，输入 REPLACE 确认", "")
			if err != nil {
				return err
			}
			if confirm != "REPLACE" {
				fmt.Fprintln(c.stdout, "已取消")
				return nil
			}
			args = append(args, "--replace")
		}
		return c.importRules(ctx, append(args, path))
	case "3":
		return c.exportRules(ctx, []string{"--format", "pipe", path})
	case "4":
		return c.exportRules(ctx, []string{"--format", "json", path})
	default:
		return errors.New("无效操作")
	}
}

func (c cli) menuBackup(ctx context.Context, in menuInput) error {
	action, err := in.prompt("1=创建，2=恢复，3=删除", "1")
	if err != nil {
		return err
	}
	if action == "1" {
		return c.backup(ctx, []string{"create"})
	}
	backups, err := c.app.ListBackups()
	if err != nil {
		return err
	}
	if len(backups) == 0 {
		return errors.New("没有可用备份")
	}
	for index, path := range backups {
		fmt.Fprintf(c.stdout, "%d. %s\n", index+1, path)
	}
	selected, err := in.promptInt("备份序号", 1, 1, len(backups))
	if err != nil {
		return err
	}
	path := backups[selected-1]
	switch action {
	case "2":
		return c.backup(ctx, []string{"restore", path})
	case "3":
		confirm, err := in.prompt("输入 DELETE 确认删除备份", "")
		if err != nil {
			return err
		}
		if confirm != "DELETE" {
			fmt.Fprintln(c.stdout, "已取消")
			return nil
		}
		return c.backup(ctx, []string{"delete", path})
	default:
		return errors.New("无效操作")
	}
}

func (c cli) menuDoctor(ctx context.Context, in menuInput) error {
	save, err := in.prompt("持久保存诊断报告？y/N", "n")
	if err != nil {
		return err
	}
	if isYes(save) {
		return c.doctor(ctx, []string{"--save"})
	}
	return c.doctor(ctx, nil)
}

func (c cli) menuMonitor(ctx context.Context, in menuInput) error {
	mode, err := in.prompt("模式 rules/summary/connections/system", "rules")
	if err != nil {
		return err
	}
	interval, err := in.prompt("采样间隔", "1s")
	if err != nil {
		return err
	}
	count, err := in.prompt("采样次数（0 表示 Ctrl+C 前持续运行）", "10")
	if err != nil {
		return err
	}
	return c.monitor(ctx, []string{"--mode", mode, "--interval", interval, "--count", count})
}

func (c cli) menuPersistence(ctx context.Context, in menuInput) error {
	action, err := in.prompt("1=只读检查，2=启用/修复，3=禁用，4=幂等恢复测试，5=按数据库显式重对账", "1")
	if err != nil {
		return err
	}
	if action == "5" {
		if err := c.repair(ctx, []string{"plan"}); err != nil {
			return err
		}
		confirm, err := in.prompt("输入 RECONCILE 确认将已提交数据库应用到 PMM 链", "")
		if err != nil {
			return err
		}
		if confirm != "RECONCILE" {
			fmt.Fprintln(c.stdout, "已取消")
			return nil
		}
		return c.repair(ctx, []string{"reconcile", "--yes"})
	}
	commands := map[string]string{"1": "check", "2": "repair", "3": "disable", "4": "test"}
	command, exists := commands[action]
	if !exists {
		return errors.New("无效操作")
	}
	if action == "2" || action == "3" {
		confirm, err := in.prompt("该操作会修改 systemd，输入 APPLY 确认", "")
		if err != nil {
			return err
		}
		if confirm != "APPLY" {
			fmt.Fprintln(c.stdout, "已取消")
			return nil
		}
	}
	return c.persistence(ctx, []string{command})
}

func (c cli) menuMigration(ctx context.Context, in menuInput) error {
	source, err := in.prompt("迁移来源 auto/kernel/database", "auto")
	if err != nil {
		return err
	}
	if err := c.migrate(ctx, []string{"--source", source}); err != nil {
		return err
	}
	confirm, err := in.prompt("执行上述迁移计划？输入 MIGRATE 确认", "")
	if err != nil {
		return err
	}
	if confirm != "MIGRATE" {
		fmt.Fprintln(c.stdout, "已取消")
		return nil
	}
	return c.migrate(ctx, []string{"--source", source, "--execute"})
}

func (c cli) menuUninstall(ctx context.Context, in menuInput) error {
	if err := c.uninstall(ctx, nil); err != nil {
		return err
	}
	confirm, err := in.prompt("输入 UNINSTALL 执行卸载，其他输入取消", "")
	if err != nil {
		return err
	}
	if confirm != "UNINSTALL" {
		fmt.Fprintln(c.stdout, "已取消")
		return nil
	}
	keep, err := in.prompt("保留配置、备份和报告？Y/n", "y")
	if err != nil {
		return err
	}
	args := []string{"--yes"}
	if isYes(keep) {
		args = append(args, "--keep-data")
	}
	return c.uninstall(ctx, args)
}

func (in menuInput) rule(defaults model.Rule) (model.Rule, error) {
	ip, err := in.promptInt("IP 版本", defaultInt(defaults.IPVersion, 4), 4, 6)
	if err != nil {
		return model.Rule{}, err
	}
	if ip != 4 && ip != 6 {
		return model.Rule{}, errors.New("IP 版本只能是 4 或 6")
	}
	protocolDefault := string(defaults.Protocol)
	if protocolDefault == "" {
		protocolDefault = "udp"
	}
	protocol, err := in.prompt("协议 tcp/udp", protocolDefault)
	if err != nil {
		return model.Rule{}, err
	}
	start, err := in.promptInt("起始端口", int(defaults.StartPort), 1, 65535)
	if err != nil {
		return model.Rule{}, err
	}
	endDefault := int(defaults.EndPort)
	if endDefault == 0 {
		endDefault = start
	}
	end, err := in.promptInt("结束端口", endDefault, 1, 65535)
	if err != nil {
		return model.Rule{}, err
	}
	target, err := in.promptInt("目标端口", int(defaults.TargetPort), 1, 65535)
	if err != nil {
		return model.Rule{}, err
	}
	label, err := in.prompt("标签", defaults.Label)
	if err != nil {
		return model.Rule{}, err
	}
	rule, err := makeRule(ip, protocol, start, end, target, label)
	if err != nil {
		return model.Rule{}, err
	}
	rule.Enabled = defaults.Enabled
	return rule, nil
}

func (in menuInput) prompt(label, defaultValue string) (string, error) {
	if defaultValue == "" {
		fmt.Fprintf(in.out, "%s: ", label)
	} else {
		fmt.Fprintf(in.out, "%s [%s]: ", label, defaultValue)
	}
	value, err := in.reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	value = strings.TrimSpace(value)
	if value == "" {
		value = defaultValue
	}
	if errors.Is(err, io.EOF) && value == "" {
		return "", io.EOF
	}
	return value, nil
}

func (in menuInput) promptInt(label string, defaultValue, minimum, maximum int) (int, error) {
	defaultText := ""
	if defaultValue != 0 {
		defaultText = strconv.Itoa(defaultValue)
	}
	value, err := in.prompt(label, defaultText)
	if err != nil {
		return 0, err
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < minimum || parsed > maximum {
		return 0, fmt.Errorf("%s 必须在 %d-%d 之间", label, minimum, maximum)
	}
	return parsed, nil
}

func (in menuInput) pause() error {
	fmt.Fprint(in.out, "\n按回车键返回主菜单...")
	_, err := in.reader.ReadString('\n')
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func resolveRule(rules []model.Rule, input string) (model.Rule, error) {
	var match *model.Rule
	for index := range rules {
		if rules[index].ID == input {
			return rules[index], nil
		}
		if strings.HasPrefix(rules[index].ID, input) {
			if match != nil {
				return model.Rule{}, errors.New("规则 ID 前缀不唯一")
			}
			candidate := rules[index]
			match = &candidate
		}
	}
	if match == nil {
		return model.Rule{}, fmt.Errorf("找不到规则 %s", input)
	}
	return *match, nil
}

func defaultInt(value, fallback int) int {
	if value == 0 {
		return fallback
	}
	return value
}

func isYes(value string) bool {
	value = strings.ToLower(strings.TrimSpace(value))
	return value == "y" || value == "yes" || value == "是"
}
