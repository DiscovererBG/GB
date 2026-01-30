#!/usr/bin/env bash
# =========================================================
# VPS Health + Streaming Check (Read-only)
# - System info, IP/ASN/Geo (best-effort)
# - Ping loss/latency/jitter
# - MTR route quality (optional, if installed)
# - Disk quick benchmark (dd)
# - Streaming checks: YouTube, AniGamer(动画疯), Netflix, Disney+, TikTok, Prime Video, HBO Max
#
# NOTE:
# - This script does NOT change system settings.
# - Streaming "unlock" is best-effort. Some services require login/account checks.
# =========================================================

set -euo pipefail

# ---------- UI ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; GRAY="\033[90m"; NC="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- config ----------
PING_COUNT=50
PING_INTERVAL=0.2
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=10

# float compare without bc
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

hr() { echo -e "${BLUE}---------------------------------------------------------${NC}"; }

# ---------- input ----------
echo -e "${BLUE}=========================================================${NC}"
echo -e "${BLUE} VPS 一键体检（只读）+ 流媒体解锁检测（详细）${NC}"
echo -e "${BLUE}=========================================================${NC}"
echo
read -r -p "输入你要测试的目标（留空=默认 1.1.1.1 + 8.8.8.8 + www.google.com）: " TARGET_CUSTOM || true
echo

DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")
TARGETS=()
if [[ -n "${TARGET_CUSTOM}" ]]; then
  # support space separated
  read -r -a TARGETS <<< "${TARGET_CUSTOM}"
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

# ---------- gather system ----------
HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
UPTIME="$(uptime -p 2>/dev/null || true)"
OS="$( (cat /etc/os-release 2>/dev/null | awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}') || echo unknown )"
KERNEL="$(uname -r 2>/dev/null || echo unknown)"
CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || echo unknown)"
CPU_CORES="$(nproc 2>/dev/null || echo 1)"
RAM_MB="$(awk '/MemTotal/{printf "%.0f\n",$2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
SWAP_MB="$(awk '/SwapTotal/{printf "%.0f\n",$2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
LOAD="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || true)"
VIRT="unknown"
if need_cmd systemd-detect-virt; then VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"; fi

DISK_LINE="$(df -hP / 2>/dev/null | tail -n 1 || true)"
DISK_TOTAL="$(echo "$DISK_LINE" | awk '{print $2}')"
DISK_USED="$(echo "$DISK_LINE" | awk '{print $3}')"
DISK_USEP="$(echo "$DISK_LINE" | awk '{print $5}')"

PUBLIC_IPv4="unknown"
GEO="unknown"
ASN="unknown"
ORG="unknown"

if need_cmd curl; then
  PUBLIC_IPv4="$(curl -4 -s --max-time 6 ifconfig.me 2>/dev/null || true)"
  [[ -z "${PUBLIC_IPv4}" ]] && PUBLIC_IPv4="unknown"

  # best-effort Geo/ASN (may be rate-limited sometimes)
  JSON="$(curl -4 -s --max-time 6 "http://ip-api.com/json/${PUBLIC_IPv4}?fields=status,country,regionName,city,isp,as,query" 2>/dev/null || true)"
  if echo "$JSON" | grep -q '"status":"success"'; then
    GEO="$(echo "$JSON" | sed -n 's/.*"country":"\([^"]*\)".*"regionName":"\([^"]*\)".*"city":"\([^"]*\)".*/\1, \2, \3/p')"
    ASN="$(echo "$JSON" | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')"
    ORG="$(echo "$JSON" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')"
  fi
fi

# ---------- print base ----------
echo -e "${BLUE}--- 1) 基本信息 ---${NC}"
echo "Host      : ${HOSTNAME}"
echo "OS        : ${OS}"
echo "Kernel    : ${KERNEL}"
echo "Uptime    : ${UPTIME:-unknown}"
echo "CPU       : ${CPU_MODEL} (${CPU_CORES} cores)"
echo "RAM/Swap  : ${RAM_MB} MB / ${SWAP_MB} MB"
echo "Load avg  : ${LOAD:-unknown}"
echo "Virt      : ${VIRT}"
echo "Disk /    : ${DISK_USED}/${DISK_TOTAL} (${DISK_USEP})"
echo
echo -e "${BLUE}--- 2) 公网信息 ---${NC}"
echo "IPv4      : ${PUBLIC_IPv4}"
echo "Geo       : ${GEO}"
echo "ASN       : ${ASN}"
echo "ISP/Org   : ${ORG}"
hr

# ---------- ping ----------
ping_test() {
  local target="$1"
  echo -e "${BLUE}--- 3) Ping：${target} (${PING_COUNT} packets) ---${NC}"

  if ! need_cmd ping; then
    warn "没有 ping 命令，跳过。"
    return 0
  fi

  local out loss avg min max mdev
  out="$(ping -c "${PING_COUNT}" -i "${PING_INTERVAL}" -n "$target" 2>/dev/null || true)"
  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  [[ -z "${loss}" ]] && loss="100"

  avg="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')"
  min="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $1}' | awk '{print $1}')"
  max="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $3}' | awk '{print $1}')"
  mdev="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $4}' | awk '{print $1}')"

  echo "Loss      : ${loss}%"
  echo "RTT ms    : min=${min:-?} avg=${avg:-?} max=${max:-?} mdev=${mdev:-?}"

  # rating
  if f_le "$loss" "1.0"; then ok "网络丢包：优秀（<=1%）"
  elif f_le "$loss" "5.0"; then warn "网络丢包：一般（1%~5%）"
  else bad "网络丢包：偏高（>5%）"
  fi

  if [[ -n "${avg:-}" ]]; then
    if f_lt "$avg" "80"; then ok "延迟：优秀（<80ms）"
    elif f_lt "$avg" "150"; then warn "延迟：一般（80~150ms）"
    else warn "延迟：偏高（>=150ms，跨洲/绕路常见）"
    fi
  fi
  echo
}

for t in "${TARGETS[@]}"; do ping_test "$t"; done
hr

# ---------- mtr ----------
mtr_test() {
  local target="$1"
  echo -e "${BLUE}--- 4) MTR：${target} (${MTR_COUNT} cycles) ---${NC}"
  if ! need_cmd mtr; then
    warn "未安装 mtr，跳过。（Debian/Ubuntu：apt -y install mtr-tiny）"
    echo
    return 0
  fi
  local out last_line last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"
  echo "$out" | head -n 3
  echo -e "${GRAY}...（中间省略）...${NC}"
  echo "$out" | tail -n 5
  last_line="$(echo "$out" | tail -n 1)"
  last_loss="$(echo "$last_line" | awk '{print $3}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $6}')"
  echo
  echo "终点(最后一跳) : Loss=${last_loss:-?}%  Avg=${last_avg:-?} ms"
  info "提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。"
  if [[ -n "${last_loss:-}" ]]; then
    if f_le "$last_loss" "1.0"; then ok "路由质量：优秀（终点丢包<=1%）"
    elif f_le "$last_loss" "5.0"; then warn "路由质量：一般（终点丢包1%~5%）"
    else bad "路由质量：偏差（终点丢包>5%）"
    fi
  fi
  echo
}

# run mtr only for first target by default
mtr_test "${TARGETS[0]}"
hr

# ---------- disk dd ----------
echo -e "${BLUE}--- 5) 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"
if need_cmd dd; then
  tmp="/tmp/vps_disk_test.$$"
  out="$( (dd if=/dev/zero of="$tmp" bs=1M count="${DISK_TEST_MB}" conv=fdatasync status=none 2>&1) || true )"
  rm -f "$tmp" >/dev/null 2>&1 || true
  # dd output like: "268435456 bytes (268 MB, 256 MiB) copied, 0.123 s, 2.1 GB/s"
  speed="$(echo "$out" | awk -F', ' '{print $NF}' | sed 's/^[ \t]*//')"
  echo "Result    : ${speed:-unknown}"

  mbps=""; unit=""
  mbps="$(echo "$speed" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$speed" | awk '{print $2}' 2>/dev/null || true)"
  if [[ -n "${mbps}" && -n "${unit}" ]]; then
    # normalize to MB/s
    if [[ "$unit" == "GB/s" ]]; then mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')" ; fi
    if f_ge "$mbps" "200"; then ok "磁盘：不错（>=200 MB/s）"
    elif f_ge "$mbps" "80"; then warn "磁盘：一般（80~200 MB/s）"
    else warn "磁盘：偏低（<80 MB/s，可能限速/邻居影响）"
    fi
  fi
else
  warn "dd 不存在，跳过。"
fi
hr

# ---------- streaming checks ----------
if ! need_cmd curl; then
  bad "缺少 curl，无法做流媒体检测。"
  exit 0
fi

fetch() {
  # curl body
  local url="$1"
  curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$url" 2>/dev/null || true
}
head_req() {
  local url="$1"
  curl -I -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$url" 2>/dev/null || true
}
code_of() {
  local url="$1"
  curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$url" 2>/dev/null || true
}

echo -e "${BLUE}--- 6) 流媒体解锁检测（详细，best-effort）---${NC}"

# ---- YouTube Premium + countryCode ----
yt_code="$(code_of "https://www.youtube.com/premium")"
yt_html="$(fetch "https://www.youtube.com/premium")"
yt_cc="$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d: -f2 | tr -d '"')"
echo "YouTube Premium HTTP : ${yt_code}  countryCode: ${yt_cc:-unknown}"
if [[ "$yt_code" == "200" || "$yt_code" == "302" ]]; then
  if [[ -n "${yt_cc:-}" ]]; then ok "YouTube：可访问（识别地区 ${yt_cc}）"
  else warn "YouTube：可访问，但未取到地区码（页面结构可能变化）"
  fi
else
  bad "YouTube：可能不可用/被阻断（HTTP ${yt_code}）"
fi
echo

# ---- AniGamer (动画疯) ----
ag_code="$(code_of "https://ani.gamer.com.tw/")"
ag_html="$(fetch "https://ani.gamer.com.tw/")"
# common block hints
if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
  echo "动画疯 HTTP         : ${ag_code}"
  bad "动画疯：检测到地区限制提示（非台湾通常会这样）"
elif [[ "$ag_code" == "200" ]]; then
  echo "动画疯 HTTP         : ${ag_code}"
  ok "动画疯：页面可正常访问（大概率台湾可用，仍以实际播放为准）"
else
  echo "动画疯 HTTP         : ${ag_code}"
  warn "动画疯：状态不确定（HTTP ${ag_code}，可能被重定向或风控）"
fi
echo

# ---- Netflix (best-effort) ----
nf_code="$(code_of "https://www.netflix.com/title/80018499")"
nf_head="$(head_req "https://www.netflix.com/title/80018499")"
# netflix sometimes redirects and sets country in headers/cookies; best-effort signals:
nf_redirect="$(echo "$nf_head" | awk '/^location:/I{print $2}' | tr -d '\r' | head -n1)"
echo "Netflix HTTP         : ${nf_code}"
if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then
  if [[ -n "${nf_redirect:-}" ]]; then
    ok "Netflix：可访问（有重定向，可能为正常地区跳转）"
  else
    ok "Netflix：可访问（进一步解锁需登录验证/播放验证）"
  fi
else
  warn "Netflix：可能不可访问/被阻断（HTTP ${nf_code}）"
fi
echo

# ---- Disney+ (best-effort) ----
dp_code="$(code_of "https://www.disneyplus.com/")"
dp_head="$(head_req "https://www.disneyplus.com/")"
dp_loc="$(echo "$dp_head" | awk '/^location:/I{print $2}' | tr -d '\r' | head -n1)"
echo "Disney+ HTTP         : ${dp_code}"
if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then
  if echo "$dp_loc" | grep -qi "disneyplus.com/"; then
    ok "Disney+：可访问（存在地区跳转也属正常）"
  else
    ok "Disney+：可访问"
  fi
else
  warn "Disney+：可能不可访问/地区限制（HTTP ${dp_code}）"
fi
echo

# ---- TikTok (best-effort) ----
tt_code="$(code_of "https://www.tiktok.com/")"
tt_head="$(head_req "https://www.tiktok.com/")"
tt_region="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="x-tt-region"{print $2}' | tr -d '\r' | head -n1)"
tt_cf="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="cf-ray"{print $2}' | tr -d '\r' | head -n1)"
echo "TikTok HTTP          : ${tt_code}  x-tt-region: ${tt_region:-unknown}"
if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then
  if [[ -n "${tt_region:-}" ]]; then ok "TikTok：可访问（推测地区 ${tt_region}）"
  else warn "TikTok：可访问，但未取到地区头（可能被 Cloudflare 隐藏/页面变化，cf-ray=${tt_cf:-n/a}）"
  fi
elif [[ "$tt_code" == "403" ]]; then
  bad "TikTok：403（常见于地区限制/风控/CF拦截）"
else
  warn "TikTok：状态不确定（HTTP ${tt_code}）"
fi
echo

# ---- Prime Video (optional signal) ----
pv_code="$(code_of "https://www.primevideo.com/")"
echo "PrimeVideo HTTP      : ${pv_code}"
if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then
  ok "Prime Video：可访问（具体片库仍看账号地区）"
else
  warn "Prime Video：可能不可访问/风控（HTTP ${pv_code}）"
fi
echo

# ---- HBO Max / Max (optional signal) ----
mx_code="$(code_of "https://play.max.com/")"
echo "Max(HBO) HTTP         : ${mx_code}"
if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then
  ok "Max：可访问（是否可播放仍看地区与账号）"
else
  warn "Max：可能不可访问/地区限制（HTTP ${mx_code}）"
fi
echo

hr

echo -e "${BLUE}总结建议：${NC}"
info "1) 动画疯：看是否出现“地区限制”提示，基本最可靠。"
info "2) Netflix/Disney+/Max/Prime：仅能判断“可访问/疑似限制”，最终以登录播放为准。"
info "3) TikTok：受 Cloudflare/风控影响大，偶尔会误判；多测几次更准。"
echo
ok "检测完成。"