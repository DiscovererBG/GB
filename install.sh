#!/usr/bin/env bash
# 自动下载主脚本、赋权并运行

URL="https://raw.githubusercontent.com/DiscovererBG/GB/main/set-dns.sh"

echo "➡ 正在下载 DNS 切换脚本..."
curl -o set-dns.sh -sL "$URL"

echo "➡ 赋予执行权限..."
chmod +x set-dns.sh

echo "➡ 启动脚本..."
sudo ./set-dns.sh