#!/bin/bash
# 一键安装脚本：下载 port_mapping_manager.sh 与 pmm 启动器并安装到 /usr/local/bin
# 使用方式（示例）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install_pmm.sh)
# 安装完成后可直接执行： pmm

set -euo pipefail

REMOTE_BASE="https://raw.githubusercontent.com/<USER>/<REPO>/main"  # TODO: 替换为真实仓库地址
INSTALL_DIR="/usr/local/bin"
TMP_DIR="$(mktemp -d)"

files=("port_mapping_manager.sh" "pmm")

echo "[PMM] 正在下载最新脚本..."
for f in "${files[@]}"; do
    echo "  - $f"
    curl -fsSL "$REMOTE_BASE/$f" -o "$TMP_DIR/$f"
    chmod +x "$TMP_DIR/$f"
done

echo "[PMM] 拷贝到 $INSTALL_DIR (需要sudo权限)"
sudo cp "$TMP_DIR/port_mapping_manager.sh" "$INSTALL_DIR/port_mapping_manager.sh"
sudo cp "$TMP_DIR/pmm" "$INSTALL_DIR/pmm"

rm -rf "$TMP_DIR"

echo "[PMM] 安装完成！现在可在任何目录直接运行： pmm"