# Port Mapping Manager v6

Port Mapping Manager（PMM）是面向 Linux 的 TCP/UDP 端口重定向管理器。v6 已从单体 Shell 脚本重写为 Go 程序：规则、事务、防火墙、持久化、诊断和卸载均有明确边界，启动程序本身不会隐式修改系统。

> 当前代码版本为 `6.0.0-dev`。生产发布由 `vX.Y.Z` 标签工作流构建 Linux amd64/arm64 二进制及校验清单。

## 核心保证

- 统一规则模型：`IP 版本 + 协议 + 起始端口 + 结束端口 + 目标端口`。
- IPv4/IPv6、TCP/UDP 四种组合使用同一套验证、诊断和监控逻辑。
- 防火墙只管理 `PMM_PREROUTING`、`PMM_G_*` 链及 `pmm:*` comment，不保存、覆盖或清空完整防火墙。
- 所有写操作使用进程锁、事务日志、变更前备份、应用后验证和失败回滚。
- 批量导入严格执行“全部预验证 → 单次备份 → 整批应用 → 失败回滚”。
- 数据库与内核状态漂移时，普通增删改失败关闭，不会覆盖不明确的现场。
- 检查与修复分离：`doctor`、`persistence check`、迁移计划和卸载计划均为只读；修改必须显式确认。
- IPv4/IPv6 公网地址使用不同缓存文件，仅在显式执行 `address` 时访问网络。
- 安装和更新要求不可变版本标签、受信任清单 SHA-256 和清单内二进制 SHA-256 三项同时匹配。

## 运行架构

```text
CLI / 交互菜单
       │
       ├── 只读：状态、诊断、监听、计数器、计划
       │
       └── 写操作事务
             ├── 全局锁
             ├── 内核快照 + 外部规则冲突检查
             ├── 完整模型备份 + 事务日志
             ├── 构建新一代 PMM_G_* 链
             ├── 原子切换 PMM_PREROUTING
             ├── 内核复核
             └── 原子提交 rules.json；失败恢复快照
```

## 系统要求

- Linux，root 权限（查看帮助和版本除外）
- `iptables`、`ip6tables`，含 NAT/REDIRECT 支持
- systemd 仅在启用持久化服务时需要
- 支持 amd64、arm64

后端目前是 iptables。配置中的 `backend` 只接受 `auto` 或 `iptables`；不会宣称尚未实现的 nftables 支持。

## 安全安装

不要使用未经校验的 `curl | bash`。从同一版本发布页下载安装器和安装器摘要，并通过可信渠道确认发布清单摘要：

```bash
VERSION=v6.0.0
BASE="https://github.com/pjy02/Port-Mapping-Manage/releases/download/$VERSION"

curl --proto '=https' --tlsv1.2 -fLO "$BASE/install_pmm.sh"
curl --proto '=https' --tlsv1.2 -fLO "$BASE/install_pmm.sh.sha256"
sha256sum -c install_pmm.sh.sha256

# 必须与发布说明、签名公告或另一独立可信渠道公布的值比对。
TRUSTED_MANIFEST_SHA256="<64 位 SHA-256>"
sudo env PMM_RELEASE_REF="$VERSION" \
  PMM_MANIFEST_SHA256="$TRUSTED_MANIFEST_SHA256" \
  bash install_pmm.sh
```

安装器会拒绝可变分支、缺失的信任摘要、重复清单条目、错误架构和摘要不匹配的载荷。安装完成后不会自动创建防火墙规则、迁移旧数据或启用开机服务。

## 命令

无参数运行 `pmm` 会进入完整交互菜单；所有功能也可脚本化调用。

```bash
# 规则
pmm rule list
pmm rule add --ip 4 --protocol udp --start 6000 --end 7000 --target 3000
pmm rule edit --id RULE_ID --ip 6 --protocol tcp --start 8000 --end 9000 --target 4000
pmm rule enable RULE_ID
pmm rule disable RULE_ID
pmm rule delete RULE_ID

# 批量导入导出
pmm import rules.conf                  # 合并
pmm import --replace rules.conf        # 完整替换
pmm import --legacy-ip 6 old.conf      # 三字段旧格式按 IPv6/UDP 解释
pmm sample sample-rules.conf
pmm export --format pipe rules.conf
pmm export --format json rules.json

# 备份
pmm backup create
pmm backup list
pmm backup restore /var/lib/port-mapping-manager/backups/rules-....json
pmm backup delete /var/lib/port-mapping-manager/backups/rules-....json

# 只读诊断与监控
pmm doctor
pmm doctor --save
pmm monitor --mode rules --interval 1s --count 10
pmm monitor --mode summary --interval 1s --count 10
pmm monitor --mode connections --interval 3s --count 10
pmm monitor --mode system --interval 2s --count 10
pmm address --ip 4
pmm address --ip 6 --refresh

# 持久化（检查不修复；启用/修复必须显式执行）
pmm persistence check
pmm persistence enable
pmm persistence repair
pmm persistence test
pmm persistence disable

# 崩溃或人工改动后的重对账：先看计划，再显式应用已提交数据库
pmm repair plan
pmm repair reconcile --yes

# v5 迁移：先看计划，再执行
pmm migrate --source auto
pmm migrate --source auto --execute
# 数据库与内核不一致时必须人工选择：--source kernel 或 --source database
# 精确匹配的 v5 pmm-rules.service 会一并停用；失败时恢复。

# 更新：检查是只读的；安装必须提供新版本清单的可信摘要
pmm update check
pmm update install --ref v6.1.0 --manifest-sha256 '<64 位 SHA-256>'

# 卸载：先看计划，再明确执行
pmm uninstall
pmm uninstall --keep-data --yes
pmm uninstall --yes
```

全局选项必须写在子命令前：

```text
--json        JSON 输出
--no-backup   仅对本次写操作关闭自动备份
--root PATH   测试用文件系统根目录
```

## 批量文件格式

```text
# IP版本|协议|起始端口|结束端口|目标端口
4|udp|6000|7000|3000
4|tcp|8000|9000|4000
6|udp|10000|12000|5000
6|tcp|13000|14000|6000
```

兼容旧三字段格式 `start:end:target`。导入会先解析完整文件、验证端口和内部重叠，再检查外部 PREROUTING 冲突；任何一步失败都不会留下部分规则。

## 文件与所有权

| 路径 | 用途 |
| --- | --- |
| `/etc/port-mapping-manager/config.json` | 可选 JSON 配置 |
| `/etc/port-mapping-manager/trusted-release.json` | 已安装版本信任锚 |
| `/var/lib/port-mapping-manager/rules.json` | 唯一已提交规则模型 |
| `/var/lib/port-mapping-manager/backups/` | 完整模型备份，包括禁用规则 |
| `/var/lib/port-mapping-manager/transactions/` | 事务及迁移日志 |
| `/var/log/port-mapping-manager/reports/` | 持久诊断报告 |
| `/var/cache/port-mapping-manager/public-ip-v4.json` | IPv4 独立缓存 |
| `/var/cache/port-mapping-manager/public-ip-v6.json` | IPv6 独立缓存 |
| `/etc/systemd/system/pmm-rules.service` | 可选、内容精确校验的持久化单元 |

卸载只会删除上述 PMM 目录、精确匹配的 systemd 单元、PMM 专属链和 `/usr/local/bin/pmm`。同名但内容不匹配的服务文件、符号链接、外部防火墙规则和系统依赖均不会删除。

## 配置示例

```json
{
  "schema_version": 1,
  "backend": "auto",
  "auto_backup": true,
  "max_backups": 20,
  "public_ip_lookup": "on-demand",
  "report_retention": 20,
  "lock_timeout_seconds": 30,
  "conflict_policy": "strict",
  "verbose": false
}
```

配置是严格 JSON：未知字段和非法值会直接报错，绝不会作为 Shell 代码执行。当前冲突策略固定为失败关闭；`warn` 仅保留配置兼容，不会绕过安全检查。

## 开发和验证

```bash
gofmt -w cmd internal
go test -race ./...
go vet ./...
bash -n install_pmm.sh tests/test_supply_chain.sh tests/test_netns_integration.sh
shellcheck install_pmm.sh tests/test_supply_chain.sh tests/test_netns_integration.sh
bash tests/test_supply_chain.sh
sudo bash tests/test_netns_integration.sh
```

network namespace 集成测试会创建隔离网络空间，验证四种 IP/协议组合、外部规则边界、批量失败无部分提交、备份恢复、持久诊断、幂等恢复、监控和安全卸载。

## License

[MIT](LICENSE)
