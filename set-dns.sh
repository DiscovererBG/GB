#!/usr/bin/env bash
# Ubuntu / Debian systemd-resolved 多地区流媒体 DNS 一键切换脚本

set -e

CONF="/etc/systemd/resolved.conf"

if [ "$EUID" -ne 0 ]; then
  echo "⚠ 请用 root 权限运行：sudo bash $0"
  exit 1
fi

echo "================ 流媒体解锁 DNS 地区选择 ================"
echo " 1) Default  默认         154.83.83.83"
echo " 2) HK       香港         154.83.83.84"
echo " 3) JP       日本         154.83.83.85"
echo " 4) TW       台湾         154.83.83.86"
echo " 5) SG       新加坡       154.83.83.87"
echo " 6) US       美国         154.83.83.88"
echo " 7) UK       英国         154.83.83.89"
echo " 8) DE       德国         154.83.83.90"
echo "----------------------------------------------------------"
echo " 0) 自定义手动输入 DNS"
echo "=========================================================="
read -rp "请输入要使用的编号(0-8): " CHOICE

REGION=""
DNS_IP=""

case "$CHOICE" in
  1) REGION="Default 默认"; DNS_IP="154.83.83.83" ;;
  2) REGION="Hong Kong 香港"; DNS_IP="154.83.83.84" ;;
  3) REGION="Japan 日本"; DNS_IP="154.83.83.85" ;;
  4) REGION="Taiwan 台湾"; DNS_IP="154.83.83.86" ;;
  5) REGION="Singapore 新加坡"; DNS_IP="154.83.83.87" ;;
  6) REGION="United States 美国"; DNS_IP="154.83.83.88" ;;
  7) REGION="United Kingdom 英国"; DNS_IP="154.83.83.89" ;;
  8) REGION="Germany 德国"; DNS_IP="154.83.83.90" ;;
  0)
    read -rp "请输入自定义 DNS IP: " DNS_IP
    REGION="自定义"
    ;;
  *)
    echo "❌ 无效选择，退出。"
    exit 1
    ;;
esac

if [[ -z "$DNS_IP" ]]; then
  echo "❌ DNS IP 为空，退出。"
  exit 1
fi

echo "➡ 将 DNS 修改为：$DNS_IP （地区：$REGION）"
echo "➡ 修改文件：$CONF"

# 备份原文件
BACKUP="/etc/systemd/resolved.conf.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONF" "$BACKUP" 2>/dev/null || touch "$CONF"
echo "✅ 已备份原文件到：$BACKUP"

# 更新 DNS= 行
if grep -qE '^[# ]*DNS=' "$CONF"; then
  sed -i "s/^[# ]*DNS=.*/DNS=$DNS_IP/" "$CONF"
else
  echo "DNS=$DNS_IP" >> "$CONF"
fi

# 确保 DNSStubListener=yes
if grep -qE '^[# ]*DNSStubListener=' "$CONF"; then
  sed -i "s/^[# ]*DNSStubListener=.*/DNSStubListener=yes/" "$CONF"
else
  echo "DNSStubListener=yes" >> "$CONF"
fi

echo "➡ 正在重启 systemd-resolved 服务..."
systemctl restart systemd-resolved

echo "➡ 当前 DNS（截取）:"
systemd-resolve --status | grep -A2 'DNS Servers'

echo "🎉 完成！当前 DNS：$DNS_IP（地区：$REGION）"
