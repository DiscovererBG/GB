#!/usr/bin/env bash
# VPS 使用 resolvconf 的 DNS 切换脚本（含实时 DNS 显示）

set -e

RESOLV_BASE="/etc/resolvconf/resolv.conf.d/base"

# 获取当前系统 DNS（第一条 nameserver）
CURRENT_DNS=$(grep -m1 "^nameserver" /etc/resolv.conf | awk '{print $2}')

if [ "$EUID" -ne 0 ]; then
  echo "⚠ 请用 root 权限运行：sudo bash $0"
  exit 1
fi

echo "================ 流媒体解锁 DNS 地区选择 ================"
echo "（当前生效 DNS：$CURRENT_DNS）"
echo
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
  1) REGION="Default"; DNS_IP="154.83.83.83" ;;
  2) REGION="Hong Kong"; DNS_IP="154.83.83.84" ;;
  3) REGION="Japan"; DNS_IP="154.83.83.85" ;;
  4) REGION="Taiwan"; DNS_IP="154.83.83.86" ;;
  5) REGION="Singapore"; DNS_IP="154.83.83.87" ;;
  6) REGION="United States"; DNS_IP="154.83.83.88" ;;
  7) REGION="United Kingdom"; DNS_IP="154.83.83.89" ;;
  8) REGION="Germany"; DNS_IP="154.83.83.90" ;;
  0)
    read -rp "请输入自定义 DNS: " DNS_IP
    REGION="Custom"
    ;;
  *)
    echo "❌ 无效选择，退出。"
    exit 1
    ;;
esac

echo
echo "➡ 写入 DNS：$DNS_IP （地区：$REGION）"
echo "➡ 修改文件：$RESOLV_BASE"

# 覆盖 resolvconf base 配置
echo "nameserver $DNS_IP" > "$RESOLV_BASE"
echo "nameserver 8.8.8.8" >> "$RESOLV_BASE"

echo "➡ 更新 resolvconf..."
resolvconf -u

echo
echo "➡ 生效后的 /etc/resolv.conf："
cat /etc/resolv.conf

echo
echo "🎉 DNS 切换完成！当前地区：$REGION（$DNS_IP）"
