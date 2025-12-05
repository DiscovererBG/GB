#!/usr/bin/env bash
# VPS 使用 resolvconf 的 DNS 切换脚本（含实时 DNS 显示 + 强制把新 DNS 放第一位）

set -e

RESOLV_BASE="/etc/resolvconf/resolv.conf.d/base"
RESOLV_CONF="/etc/resolv.conf"

# 获取当前系统 DNS（第一条 nameserver）
CURRENT_DNS=$(grep -m1 "^nameserver" "$RESOLV_CONF" | awk '{print $2}')

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
  1) REGION="Default";        DNS_IP="154.83.83.83" ;;
  2) REGION="Hong Kong";      DNS_IP="154.83.83.84" ;;
  3) REGION="Japan";          DNS_IP="154.83.83.85" ;;
  4) REGION="Taiwan";         DNS_IP="154.83.83.86" ;;
  5) REGION="Singapore";      DNS_IP="154.83.83.87" ;;
  6) REGION="United States";  DNS_IP="154.83.83.88" ;;
  7) REGION="United Kingdom"; DNS_IP="154.83.83.89" ;;
  8) REGION="Germany";        DNS_IP="154.83.83.90" ;;
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

# 覆盖 resolvconf base 配置（主 DNS + 备用 8.8.8.8）
echo "nameserver $DNS_IP" > "$RESOLV_BASE"
echo "nameserver 8.8.8.8" >> "$RESOLV_BASE"

echo "➡ 更新 resolvconf..."
resolvconf -u

echo "➡ 调整 /etc/resolv.conf 中的 nameserver 顺序（把新 DNS 放第一位）..."

TMP_FILE=$(mktemp)

# 1. 保留所有非 nameserver 行（注释、search 等）
grep -v '^nameserver' "$RESOLV_CONF" > "$TMP_FILE"

# 2. 把新 DNS 和 8.8.8.8 作为前两条
echo "nameserver $DNS_IP" >> "$TMP_FILE"
echo "nameserver 8.8.8.8" >> "$TMP_FILE"

# 3. 把原来其他 nameserver（排除重复的）追加在后面
grep '^nameserver' "$RESOLV_CONF" | awk '{print $2}' | while read -r ns; do
  if [ "$ns" != "$DNS_IP" ] && [ "$ns" != "8.8.8.8" ]; then
    echo "nameserver $ns" >> "$TMP_FILE"
  fi
done

# 覆盖原 resolv.conf
cp "$TMP_FILE" "$RESOLV_CONF"
rm -f "$TMP_FILE"

echo
echo "➡ 最终生效的 /etc/resolv.conf："
cat "$RESOLV_CONF"

echo
echo "🎉 DNS 切换完成！当前地区：$REGION（$DNS_IP）"
