#!/usr/bin/env bash
# VPS 使用 resolvconf 的 DNS 切换脚本
# 功能：
#  - 菜单选择流媒体 DNS（中文+国旗）
#  - 实时显示当前 DNS
#  - 修改 /etc/resolvconf/resolv.conf.d/base 并更新
#  - 强制把新 DNS 放到 /etc/resolv.conf 第一位
#  - 根据地区选择专属测试域名
#  - 自动测试 DNS 是否正常工作

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
echo " 1) 🇨🇳 默认          154.83.83.83"
echo " 2) 🇭🇰 香港          154.83.83.84"
echo " 3) 🇯🇵 日本          154.83.83.85"
echo " 4) 🇼🇸 台湾          154.83.83.86"
echo " 5) 🇸🇬 新加坡        154.83.83.87"
echo " 6) 🇺🇸 美国          154.83.83.88"
echo " 7) 🇬🇧 英国          154.83.83.89"
echo " 8) 🇩🇪 德国          154.83.83.90"
echo "----------------------------------------------------------"
echo " 0) ✏️ 自定义手动输入 DNS"
echo "=========================================================="
read -rp "请输入要使用的编号(0-8): " CHOICE

REGION=""
DNS_IP=""

case "$CHOICE" in
  1) REGION="🇨🇳 默认";      DNS_IP="154.83.83.83" ;;
  2) REGION="🇭🇰 香港";      DNS_IP="154.83.83.84" ;;
  3) REGION="🇯🇵 日本";      DNS_IP="154.83.83.85" ;;
  4) REGION="🇼🇸 台湾";      DNS_IP="154.83.83.86" ;;
  5) REGION="🇸🇬 新加坡";    DNS_IP="154.83.83.87" ;;
  6) REGION="🇺🇸 美国";      DNS_IP="154.83.83.88" ;;
  7) REGION="🇬🇧 英国";      DNS_IP="154.83.83.89" ;;
  8) REGION="🇩🇪 德国";      DNS_IP="154.83.83.90" ;;
  0)
    read -rp "请输入自定义 DNS: " DNS_IP
    REGION="✏️ 自定义"
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

# ==============================
#   根据地区选择测试域名
# ==============================
TEST_DOMAIN="www.google.com"
TEST_DESC="通用测试域名"

case "$CHOICE" in
  2) TEST_DOMAIN="viu.com";               TEST_DESC="香港 ViuTV";;
  3) TEST_DOMAIN="dmm.com";               TEST_DESC="日本 DMM";;
  4) TEST_DOMAIN="ani.gamer.com.tw";      TEST_DESC="台湾 动画疯";;
  5) TEST_DOMAIN="mewatch.sg";            TEST_DESC="新加坡 meWATCH";;
  6) TEST_DOMAIN="netflix.com";           TEST_DESC="美国 Netflix";;
  7) TEST_DOMAIN="bbc.co.uk";             TEST_DESC="英国 BBC";;
  8) TEST_DOMAIN="dw.com";                TEST_DESC="德国之声 DW";;
  1) TEST_DOMAIN="www.google.com";        TEST_DESC="通用测试域名";;
  0) TEST_DOMAIN="www.google.com";        TEST_DESC="通用测试域名";;
esac

echo "➡ 正在测试 DNS 是否正常工作（地区测试域名：$TEST_DOMAIN，$TEST_DESC）..."

if command -v getent >/dev/null 2>&1; then
  if getent hosts "$TEST_DOMAIN" >/dev/null 2>&1; then
    echo "✅ DNS 解析正常：$TEST_DOMAIN 可以被解析"
  else
    echo "❌ DNS 解析失败：无法解析 $TEST_DOMAIN"
  fi
else
  # 没有 getent 时，用 ping 做兜底测试
  if ping -c 3 -W 2 "$TEST_DOMAIN" >/dev/null 2>&1; then
    echo "✅ DNS / 网络测试正常：可以访问 $TEST_DOMAIN"
  else
    echo "❌ DNS / 网络测试失败：无法访问 $TEST_DOMAIN"
  fi
fi

echo
echo "🎉 DNS 切换完成！当前地区：$REGION（$DNS_IP）"
