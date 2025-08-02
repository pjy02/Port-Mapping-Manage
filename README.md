# Enhanced Port Mapping Manager

一个功能强大的UDP端口映射管理脚本，特别适用于Hysteria2机场端口跳跃配置。

## 功能特点

- **智能端口管理**：自动检测端口冲突和占用情况
- **安全性增强**：输入验证、安全日志记录和错误处理
- **批量操作**：支持批量导入/导出端口映射规则
- **实时监控**：监控端口映射流量和状态
- **系统诊断**：提供全面的系统诊断功能
- **持久化支持**：多种规则持久化方案
- **备份恢复**：自动备份和恢复iptables规则
- **用户友好**：交互式菜单和彩色输出

## 系统要求

- Linux系统
- root权限
- iptables
- 常用网络工具(ss, grep, awk, sed)

## 安装与使用

1. 下载脚本：
   ```bash
   wget https://raw.githubusercontent.com/yourusername/Enhanced-Port-Mapping-Manager/main/Enhanced\ Port\ Mapping\ Manager.txt
