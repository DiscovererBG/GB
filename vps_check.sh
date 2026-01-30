#!/usr/bin/env bash
# =========================================================
# ✅ VPS 一键体检（只读）+ 流媒体解锁检测 + TCP真实链路测试（菜单版）
# - 菜单可选跑：System / IP / Ping / MTR / Disk / Streaming / TCP
# - 9：全跑（显示全过程）
# - R：后台静默全跑（不刷屏），只输出最终✅总结报告
# - 最后：美化总结报告（进度条/评分/结论/可打码）
#
# Usage:
#   bash <(curl -fsSL "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh")
#   或保存本地：
#   curl -fsSL -o vps_check.sh "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh"
#   chmod +x vps_check.sh && ./vps_check.sh
#
# Redact:
#   ./vps_check.sh --redact     # 自动打码 Host/IPv4
#
# NOTE:
# - 全部只读检测，不改系统配置（除非你选择安装 mtr-tiny）
# - 流媒体解锁为 best-effort（最终以登录播放为准）
# =========================================================

set -euo pipefail

# ---------- UI ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; GRAY="\033[90m"; NC="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
hr()   { echo -e "${BLUE}---------------------------------------------------------${NC}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }
title() { echo -e "${BLUE}====================== $* ======================${NC}"; }

# ---------- defaults ----------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=10
DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# TCP真实链路测试（更贴近代理体验）
TCP_TEST_URL="https://www.cloudflare.com/cdn-cgi/trace"     # 用于 TLS/TTFB（轻量）
TCP_SPEED_URL_DEFAULT="https://speed.hetzner.de/100MB.bin"  # 用于下载测速（Range小文件）
TCP_SPEED_RANGE_BYTES=$((8*1024*1024-1))                   # 8MB Range: 0-8388607
TCP_SPEED_MAXTIME=12
TCP_RETRY=1

# ---------- numeric helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

pause() { read -r -p "回车继续..." _ || true; }

# ---------- global state ----------
RUN_SYS=0 RUN_IP=0 RUN_PING=0 RUN_MTR=0 RUN_DISK=0 RUN_STREAM=0 RUN_TCP=0
HOSTNAME_=""; OS_=""; KERNEL_=""; UPTIME_=""; CPU_=""; CORES_=""; RAM_=""; SWAP_=""; LOAD_=""; VIRT_=""; DISKROOT_=""
IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"
TARGETS=("${DEFAULT_TARGETS[@]}")

# ping summary
PING_TOTAL_TARGETS=0
PING_GOOD=0
PING_WARN=0
PING_BAD=0
PING_WORST_LOSS=""
PING_WORST_AVG=""

# mtr summary
MTR_LASTLOSS=""
MTR_LASTAVG=""
MTR_RATING="unknown"

# disk summary
DISK_SPEED_RAW="unknown"
DISK_MBPS=""
DISK_RATING="unknown"

# stream summary
YT_CC="unknown"
YT_OK="unknown"
AG_STATUS="unknown"
NF_OK="unknown"
DP_OK="unknown"
TT_OK="unknown"
PV_OK="unknown"
MX_OK="unknown"

# TCP summary
TCP_TLS_MS=""
TCP_TTFB_MS=""
TCP_DL_Mbps=""
TCP_SRC="hetzner 100MB (range 8MB)"
TCP_RATING="unknown"
TCP_DL_CODE=""
TCP_DL_FAIL_REASON=""

# redact flag
REDACT=0
for a in "${@:-}"; do
  [[ "$a" == "--redact" ]] && REDACT=1
done

mask_ipv4() {
  local ip="${1:-}"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$ip" | awk -F. '{print $1"."$2".***.***"}'
  else
    echo "$ip"
  fi
}
mask_host() {
  local h="${1:-}"
  [[ -z "$h" ]] && { echo "$h"; return; }
  if [[ ${#h} -le 2 ]]; then echo "**"; else echo "${h:0:2}***"; fi
}

maybe_redact() {
  if [[ "$REDACT" -eq 1 ]]; then
    HOSTNAME_="$(mask_host "$HOSTNAME_")"
    IPV4_="$(mask_ipv4 "$IPV4_")"
  fi
}

# ---------- targets ----------
set_targets() {
  echo
  read -r -p "输入你要测试的目标（空格分隔，留空=默认 1.1.1.1 8.8.8.8 www.google.com）: " input || true
  if [[ -n "${input:-}" ]]; then
    read -r -a TARGETS <<< "$input"
  else
    TARGETS=("${DEFAULT_TARGETS[@]}")
  fi
  ok "Targets = ${TARGETS[*]}"
  echo
}

# ---------- System ----------
gather_system() {
  RUN_SYS=1
  HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
  UPTIME_="$(uptime -p 2>/dev/null || echo unknown)"
  OS_="$( (awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null) || echo unknown )"
  KERNEL_="$(uname -r 2>/dev/null || echo unknown)"
  CPU_="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || echo unknown)"
  CORES_="$(nproc 2>/dev/null || echo 1)"
  RAM_="$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  SWAP_="$(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  LOAD_="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || echo unknown)"
  VIRT_="unknown"
  if need_cmd systemd-detect-virt; then VIRT_="$(systemd-detect-virt 2>/dev/null || echo none)"; fi
  DISKROOT_="$(df -hP / 2>/dev/null | tail -n 1 | awk '{print $3"/"$2" ("$5")"}' || echo unknown)"

  maybe_redact

  echo -e "${BLUE}--- 基本信息 ---${NC}"
  echo "Host      : ${HOSTNAME_}"
  echo "OS        : ${OS_}"
  echo "Kernel    : ${KERNEL_}"
  echo "Uptime    : ${UPTIME_}"
  echo "CPU       : ${CPU_} (${CORES_} cores)"
  echo "RAM/Swap  : ${RAM_} / ${SWAP_}"
  echo "Load avg  : ${LOAD_}"
  echo "Virt      : ${VIRT_}"
  echo "Disk /    : ${DISKROOT_}"
  hr
}

# ---------- IP ----------
gather_ip() {
  RUN_IP=1
  IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"
  if ! need_cmd curl; then
    bad "缺少 curl，无法查询公网信息。"
    return 0
  fi
  local ip json
  ip="$(curl -4 -s --max-time 6 ifconfig.me 2>/dev/null || true)"
  [[ -n "${ip:-}" ]] && IPV4_="$ip"

  json="$(curl -4 -s --max-time 6 "http://ip-api.com/json/${IPV4_}?fields=status,country,regionName,city,isp,as,query" 2>/dev/null || true)"
  if echo "$json" | grep -q '"status":"success"'; then
    GEO_="$(echo "$json" | sed -n 's/.*"country":"\([^"]*\)".*"regionName":"\([^"]*\)".*"city":"\([^"]*\)".*/\1, \2, \3/p')"
    ASN_="$(echo "$json" | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')"
    ORG_="$(echo "$json" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')"
  fi

  maybe_redact

  echo -e "${BLUE}--- 公网信息 ---${NC}"
  echo "IPv4      : ${IPV4_}"
  echo "Geo       : ${GEO_}"
  echo "ASN       : ${ASN_}"
  echo "ISP/Org   : ${ORG_}"
  hr
}

# ---------- Ping ----------
ping_once() {
  local target="$1" interval="$2"
  ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null
}

ping_test_one() {
  local target="$1"
  echo -e "${BLUE}--- Ping：${target} (${PING_COUNT} packets) ---${NC}"

  if ! need_cmd ping; then
    warn "没有 ping 命令，跳过。"
    return 0
  fi

  local out loss avg min max mdev
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  avg="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')"
  min="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $1}' | awk '{print $1}')"
  max="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $3}' | awk '{print $1}')"
  mdev="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $4}' | awk '{print $1}')"

  loss="$(safe_num "$loss")"
  avg="$(safe_num "$avg")"; min="$(safe_num "$min")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  echo "Loss      : ${loss:-?}%"
  echo "RTT ms    : min=${min:-?} avg=${avg:-?} max=${max:-?} mdev=${mdev:-?}"

  local rating="WARN"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="GOOD"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="WARN"
  else rating="BAD"
  fi

  if [[ "$rating" == "GOOD" ]]; then ok "丢包：优秀（<=1%）"; ((PING_GOOD++)) || true
  elif [[ "$rating" == "WARN" ]]; then warn "丢包：一般（1%~5%）"; ((PING_WARN++)) || true
  else bad "丢包：偏高（>5%）"; ((PING_BAD++)) || true
  fi

  if [[ -n "${avg:-}" ]]; then
    if f_lt "$avg" "80"; then ok "延迟：优秀（<80ms）"
    elif f_lt "$avg" "150"; then warn "延迟：一般（80~150ms）"
    else warn "延迟：偏高（>=150ms）"
    fi
  fi

  if [[ -n "${loss:-}" ]]; then
    if [[ -z "${PING_WORST_LOSS:-}" ]]; then PING_WORST_LOSS="$loss"; else
      awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit (a>b)?0:1}' && PING_WORST_LOSS="$loss" || true
    fi
  fi
  if [[ -n "${avg:-}" ]]; then
    if [[ -z "${PING_WORST_AVG:-}" ]]; then PING_WORST_AVG="$avg"; else
      awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit (a>b)?0:1}' && PING_WORST_AVG="$avg" || true
    fi
  fi

  echo
}

run_ping_all() {
  RUN_PING=1
  PING_TOTAL_TARGETS="${#TARGETS[@]}"
  PING_GOOD=0; PING_WARN=0; PING_BAD=0
  PING_WORST_LOSS=""; PING_WORST_AVG=""
  for t in "${TARGETS[@]}"; do ping_test_one "$t"; done
  hr
  info "Ping 小结：Targets=${PING_TOTAL_TARGETS} | GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% worstAvg=${PING_WORST_AVG:-?}ms"
  hr
}

# ---------- MTR ----------
install_mtr() {
  if ! need_cmd apt; then
    warn "系统没有 apt（非 Debian/Ubuntu）或未找到 apt，跳过安装。"
    return 0
  fi
  info "将执行：apt update && apt install -y mtr-tiny"
  apt update && apt install -y mtr-tiny
  ok "mtr 安装完成。"
}

run_mtr() {
  RUN_MTR=1
  local target="${TARGETS[0]}"
  echo -e "${BLUE}--- MTR：${target} (${MTR_COUNT} cycles) ---${NC}"
  if ! need_cmd mtr; then
    warn "未安装 mtr。（可在菜单选择安装 mtr-tiny）"
    MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"
    hr
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
  last_loss="$(safe_num "$last_loss")"; last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

  echo
  echo "终点(最后一跳) : Loss=${last_loss:-?}%  Avg=${last_avg:-?} ms"
  info "提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。"

  if [[ -n "${last_loss:-}" ]]; then
    if f_le "$last_loss" "1.0"; then ok "路由质量：优秀"; MTR_RATING="GOOD"
    elif f_le "$last_loss" "5.0"; then warn "路由质量：一般"; MTR_RATING="WARN"
    else bad "路由质量：偏差"; MTR_RATING="BAD"
    fi
  else
    MTR_RATING="unknown"
  fi
  hr
}

# ---------- Disk ----------
run_disk() {
  RUN_DISK=1
  echo -e "${BLUE}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"
  if ! need_cmd dd; then
    warn "dd 不存在，跳过。"
    DISK_SPEED_RAW="unknown"; DISK_MBPS=""; DISK_RATING="unknown"
    hr
    return 0
  fi

  local tmp out speed mbps unit
  tmp="/tmp/vps_disk_test.$$"
  out="$(dd if=/dev/zero of="$tmp" bs=1M count="${DISK_TEST_MB}" conv=fdatasync 2>&1 || true)"
  rm -f "$tmp" >/dev/null 2>&1 || true

  speed="$(echo "$out" | tail -n 1 | awk -F', ' '{print $NF}' | sed 's/^[ \t]*//')"
  DISK_SPEED_RAW="${speed:-unknown}"
  echo "Result    : ${DISK_SPEED_RAW}"

  mbps="$(echo "$DISK_SPEED_RAW" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$DISK_SPEED_RAW" | awk '{print $2}' 2>/dev/null || true)"
  mbps="$(safe_num "$mbps")"
  if [[ -n "${mbps:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')" ; fi
    DISK_MBPS="$mbps"
    if f_ge "$mbps" "200"; then ok "磁盘：不错（>=200 MB/s）"; DISK_RATING="GOOD"
    elif f_ge "$mbps" "80"; then warn "磁盘：一般（80~200 MB/s）"; DISK_RATING="WARN"
    else warn "磁盘：偏低（<80 MB/s）"; DISK_RATING="BAD"
    fi
  else
    warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
    DISK_RATING="unknown"
  fi
  hr
}

# ---------- streaming helpers ----------
fetch()   { curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
head_req(){ curl -I -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
code_of() { curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }

run_streaming() {
  RUN_STREAM=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做流媒体检测。"
    return 0
  fi

  echo -e "${BLUE}--- 流媒体解锁检测（详细，best-effort）---${NC}"

  # YouTube
  local yt_code yt_html yt_cc
  yt_code="$(code_of "https://www.youtube.com/premium")"
  yt_html="$(fetch "https://www.youtube.com/premium")"
  yt_cc="$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d: -f2 | tr -d '"')"
  YT_CC="${yt_cc:-unknown}"
  echo "YouTube Premium HTTP : ${yt_code}  countryCode: ${YT_CC}"
  if [[ "$yt_code" == "200" || "$yt_code" == "302" ]]; then ok "YouTube：可访问（识别地区 ${YT_CC:-unknown}）"; YT_OK="OK"
  else bad "YouTube：可能不可用/被阻断（HTTP ${yt_code}）"; YT_OK="BAD"
  fi
  echo

  # AniGamer (动画疯)
  local ag_code ag_html
  ag_code="$(code_of "https://ani.gamer.com.tw/")"
  ag_html="$(fetch "https://ani.gamer.com.tw/")"
  echo "动画疯 HTTP         : ${ag_code}"
  if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
    bad "动画疯：检测到地区限制提示（非台湾通常会这样）"
    AG_STATUS="REGION_BLOCK"
  elif [[ "$ag_code" == "200" ]]; then
    ok "动画疯：页面可访问（是否可播放仍以实际播放为准）"
    AG_STATUS="OK"
  elif [[ "$ag_code" == "403" || "$ag_code" == "503" ]]; then
    warn "动画疯：可能被风控/CF 拦截（HTTP ${ag_code}）"
    AG_STATUS="WAF_OR_RISK"
  else
    warn "动画疯：状态不确定（HTTP ${ag_code}）"
    AG_STATUS="UNKNOWN"
  fi
  echo

  # Netflix
  local nf_code nf_head nf_redirect
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  nf_head="$(head_req "https://www.netflix.com/title/80018499")"
  nf_redirect="$(echo "$nf_head" | awk '/^location:/I{print $2}' | tr -d '\r' | head -n1)"
  echo "Netflix HTTP         : ${nf_code}"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then
    [[ -n "${nf_redirect:-}" ]] && ok "Netflix：可访问（有重定向，属正常地区跳转可能）" || ok "Netflix：可访问（需登录/播放验证片库）"
    NF_OK="OK"
  else
    warn "Netflix：可能不可访问/被阻断（HTTP ${nf_code}）"
    NF_OK="WARN"
  fi
  echo

  # Disney+
  local dp_code dp_head dp_loc
  dp_code="$(code_of "https://www.disneyplus.com/")"
  dp_head="$(head_req "https://www.disneyplus.com/")"
  dp_loc="$(echo "$dp_head" | awk '/^location:/I{print $2}' | tr -d '\r' | head -n1)"
  echo "Disney+ HTTP         : ${dp_code}"
  if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then
    echo "$dp_loc" | grep -qi "disneyplus.com/" && ok "Disney+：可访问（地区跳转属正常）" || ok "Disney+：可访问"
    DP_OK="OK"
  else
    warn "Disney+：可能不可访问/地区限制（HTTP ${dp_code}）"
    DP_OK="WARN"
  fi
  echo

  # TikTok
  local tt_code tt_head tt_region tt_cf
  tt_code="$(code_of "https://www.tiktok.com/")"
  tt_head="$(head_req "https://www.tiktok.com/")"
  tt_region="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="x-tt-region"{print $2}' | tr -d '\r' | head -n1)"
  tt_cf="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="cf-ray"{print $2}' | tr -d '\r' | head -n1)"
  echo "TikTok HTTP          : ${tt_code}  x-tt-region: ${tt_region:-unknown}"
  if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then
    [[ -n "${tt_region:-}" ]] && ok "TikTok：可访问（推测地区 ${tt_region}）" || warn "TikTok：可访问，但无法判断地区（可能 CF/风控隐藏，cf-ray=${tt_cf:-n/a}）"
    TT_OK="OK"
  elif [[ "$tt_code" == "403" ]]; then
    bad "TikTok：403（常见于地区限制/风控/CF 拦截）"
    TT_OK="BAD"
  else
    warn "TikTok：状态不确定（HTTP ${tt_code}）"
    TT_OK="WARN"
  fi
  echo

  # Prime Video
  local pv_code
  pv_code="$(code_of "https://www.primevideo.com/")"
  echo "PrimeVideo HTTP      : ${pv_code}"
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then
    ok "Prime Video：可访问（片库看账号地区）"
    PV_OK="OK"
  else
    warn "Prime Video：可能不可访问/风控（HTTP ${pv_code}）"
    PV_OK="WARN"
  fi
  echo

  # Max
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  echo "Max(HBO) HTTP         : ${mx_code}"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then
    ok "Max：可访问（是否可播放仍看地区与账号）"
    MX_OK="OK"
  else
    warn "Max：可能不可访问/地区限制（HTTP ${mx_code}）"
    MX_OK="WARN"
  fi
  echo

  hr
  info "提示：Netflix/Disney+/Max/Prime 仅能判断“可访问/疑似限制”，最终以登录播放为准。"
  info "TikTok 易受 Cloudflare/风控影响，建议多测几次综合判断。"
  hr
}

# ---------- TCP REAL TEST ----------
curl_timing_ms() {
  # output: tls_ms|ttfb_ms|http_code
  local url="$1"
  local out
  out="$(curl -L -s -o /dev/null \
    --connect-timeout 6 --max-time 12 \
    -A "Mozilla/5.0" \
    -w "%{time_appconnect}|%{time_starttransfer}|%{http_code}" \
    "$url" 2>/dev/null || echo "0|0|000")"
  echo "$out"
}

curl_speed() {
  # prints: speed_download(bytes/sec)|http_code
  local url="$1"
  local out="|000"

  # 先 IPv4（很多 VPS v6 不通或不稳）
  out="$(curl -4 -L -s -o /dev/null \
    --connect-timeout 6 --max-time "${TCP_SPEED_MAXTIME}" --retry "${TCP_RETRY}" \
    -r "0-${TCP_SPEED_RANGE_BYTES}" \
    -A "Mozilla/5.0" \
    -w "%{speed_download}|%{http_code}" \
    "$url" 2>/dev/null || echo "|000")"

  # IPv4 失败再尝试不限制协议
  local code="${out#*|}"
  if [[ "$code" == "000" || -z "$code" ]]; then
    out="$(curl -L -s -o /dev/null \
      --connect-timeout 6 --max-time "${TCP_SPEED_MAXTIME}" --retry "${TCP_RETRY}" \
      -r "0-${TCP_SPEED_RANGE_BYTES}" \
      -A "Mozilla/5.0" \
      -w "%{speed_download}|%{http_code}" \
      "$url" 2>/dev/null || echo "|000")"
  fi

  echo "$out"
}

run_tcp_real() {
  RUN_TCP=1
  echo -e "${BLUE}--- TCP 真实链路测试（更贴近代理体验）---${NC}"
  if ! need_cmd curl; then
    bad "缺少 curl，无法做 TCP 测试。"
    TCP_RATING="unknown"
    hr
    return 0
  fi

  # 1) TLS handshake + TTFB
  local t tls ttfb code
  t="$(curl_timing_ms "$TCP_TEST_URL")"
  tls="${t%%|*}"; t="${t#*|}"
  ttfb="${t%%|*}"; code="${t##*|}"

  # 转 ms
  TCP_TLS_MS="$(awk -v x="${tls:-0}" 'BEGIN{printf "%.0f", x*1000}')"
  TCP_TTFB_MS="$(awk -v x="${ttfb:-0}" 'BEGIN{printf "%.0f", x*1000}')"

  echo "Handshake(TLS) : ${TCP_TLS_MS} ms"
  echo "TTFB           : ${TCP_TTFB_MS} ms"

  # 2) Download speed (Range 8MB)
  local sp raw code2
  raw="$(curl_speed "$TCP_SPEED_URL_DEFAULT")"
  code2="${raw#*|}"
  sp="${raw%%|*}"
  TCP_DL_CODE="$code2"

  if [[ -n "$(safe_num "$sp")" && ( "$code2" == "200" || "$code2" == "206" || "$code2" == "302" ) ]]; then
    TCP_DL_Mbps="$(awk -v b="$sp" 'BEGIN{printf "%.1f", b*8/1000000}')"
    TCP_DL_FAIL_REASON=""
    echo "Download       : ${TCP_DL_Mbps} Mbps  (source=${TCP_SRC}, maxtime=${TCP_SPEED_MAXTIME}s)"
  else
    TCP_DL_Mbps=""
    # 常见：000=连接失败/超时/DNS/被阻断
    if [[ "$code2" == "000" ]]; then
      TCP_DL_FAIL_REASON="http_code=000(连接失败/超时/解析失败/被阻断)"
    else
      TCP_DL_FAIL_REASON="http_code=${code2}"
    fi
    echo "Download       : ? Mbps  (source=${TCP_SRC}, maxtime=${TCP_SPEED_MAXTIME}s, ${TCP_DL_FAIL_REASON})"
  fi

  # 3) rating（优先按 handshake+ttfb；download 作为加分项）
  # 基本阈值：TLS<=80ms & TTFB<=120ms 认为优秀；<=200/300 认为良好；否则一般/偏弱
  local score="WARN"
  if f_le "$TCP_TLS_MS" "80" && f_le "$TCP_TTFB_MS" "120"; then score="GOOD"
  elif f_le "$TCP_TLS_MS" "200" && f_le "$TCP_TTFB_MS" "300"; then score="WARN"
  else score="BAD"
  fi

  # download 加分：>50Mbps 直接抬到 GOOD（前提不是 BAD）
  if [[ "$score" != "BAD" && -n "${TCP_DL_Mbps:-}" ]]; then
    if f_ge "$TCP_DL_Mbps" "50"; then score="GOOD"; fi
  fi

  if [[ "$score" == "GOOD" ]]; then ok "TCP 体验：优秀"; TCP_RATING="GOOD"
  elif [[ "$score" == "WARN" ]]; then warn "TCP 体验：良好/一般（可用）"; TCP_RATING="WARN"
  else bad "TCP 体验：偏弱（建议换线路/换机房）"; TCP_RATING="BAD"
  fi

  hr
}

# ---------- Report helpers ----------
grade_cn() {
  local x="$1"
  if [[ "$x" -ge 85 ]]; then echo "优秀"
  elif [[ "$x" -ge 70 ]]; then echo "良好"
  elif [[ "$x" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}

grade_icon() {
  local x="$1"
  if [[ "$x" -ge 85 ]]; then echo "✅"
  elif [[ "$x" -ge 70 ]]; then echo "🟢"
  elif [[ "$x" -ge 55 ]]; then echo "🟠"
  else echo "❌"
  fi
}

bar() {
  # bar 0-100
  local p="${1:-0}"
  local w=20
  local fill=$((p*w/100))
  local empty=$((w-fill))
  printf "["
  for ((i=0;i<fill;i++)); do printf "█"; done
  for ((i=0;i<empty;i++)); do printf "░"; done
  printf "]"
}

# ---------- overall summary (beautified) ----------
overall_summary() {
  # scoring
  local net_score=0 disk_score=0 stream_score=0 tcp_score=0 total=0
  local net_grade disk_grade stream_grade tcp_grade overall
  local used=0

  # network score (ping as base)
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"
    [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  else
    net_score=0
  fi
  # MTR adjust
  if [[ "$RUN_MTR" -eq 1 ]]; then
    if [[ "$MTR_RATING" == "GOOD" ]]; then net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')" ; fi
    if [[ "$MTR_RATING" == "BAD" ]]; then  net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')" ; fi
  fi
  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"

  # disk score
  if [[ "$RUN_DISK" -eq 1 ]]; then
    if [[ "$DISK_RATING" == "GOOD" ]]; then disk_score=90
    elif [[ "$DISK_RATING" == "WARN" ]]; then disk_score=70
    elif [[ "$DISK_RATING" == "BAD" ]]; then disk_score=50
    else disk_score=0
    fi
  else
    disk_score=0
  fi

  # streaming score
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    local s=0
    [[ "$YT_OK" == "OK" ]] && ((s+=15)) || true
    [[ "$NF_OK" == "OK" ]] && ((s+=15)) || true
    [[ "$DP_OK" == "OK" ]] && ((s+=15)) || true
    [[ "$PV_OK" == "OK" ]] && ((s+=10)) || true
    [[ "$MX_OK" == "OK" ]] && ((s+=10)) || true
    [[ "$TT_OK" == "OK" ]] && ((s+=10)) || true
    [[ "$AG_STATUS" == "OK" ]] && ((s+=15)) || true
    stream_score="$(awk -v x="$s" 'BEGIN{printf "%.0f", x*100/90}')"
  else
    stream_score=0
  fi

  # tcp score
  if [[ "$RUN_TCP" -eq 1 ]]; then
    if [[ "$TCP_RATING" == "GOOD" ]]; then tcp_score=90
    elif [[ "$TCP_RATING" == "WARN" ]]; then tcp_score=70
    elif [[ "$TCP_RATING" == "BAD" ]]; then tcp_score=45
    else tcp_score=0
    fi
  else
    tcp_score=0
  fi

  net_grade="$(grade_cn "$net_score")"
  disk_grade="$(grade_cn "$disk_score")"
  stream_grade="$(grade_cn "$stream_score")"
  tcp_grade="$(grade_cn "$tcp_score")"

  # weights（网络50 / TCP20 / 磁盘10 / 流媒体20）
  local w_net=50 w_tcp=20 w_disk=10 w_stream=20

  total=0; used=0
  if [[ "$RUN_PING" -eq 1 || "$RUN_MTR" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$net_score" -v w="$w_net" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_net)) || true
  fi
  if [[ "$RUN_TCP" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$tcp_score" -v w="$w_tcp" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_tcp)) || true
  fi
  if [[ "$RUN_DISK" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$disk_score" -v w="$w_disk" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_disk)) || true
  fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$stream_score" -v w="$w_stream" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_stream)) || true
  fi
  if [[ "$used" -gt 0 ]]; then total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"; else total=0; fi
  overall="$(grade_cn "$total")"

  echo -e "${BLUE}====================== ✅ VPS 体检总结报告 ======================${NC}"
  echo -e "${BLUE}[基础信息]${NC}"
  if [[ "$RUN_SYS" -eq 1 ]]; then
    echo "  Host : ${HOSTNAME_}"
    echo "  OS   : ${OS_}"
    echo "  Kern : ${KERNEL_} | Virt=${VIRT_}"
    echo "  CPU  : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
    echo "  Disk : / ${DISKROOT_}"
  else
    echo "  （未执行）"
  fi
  if [[ "$RUN_IP" -eq 1 ]]; then
    echo "  IPv4 : ${IPV4_}"
    echo "  Geo  : ${GEO_}"
    echo "  ASN  : ${ASN_} | ISP=${ORG_}"
  else
    echo "  公网信息：未执行"
  fi
  hr

  echo -e "${BLUE}[网络] ${NC} $(grade_icon "$net_score")  ${net_score}/100（${net_grade}）  $(bar "$net_score")"
  if [[ "$RUN_PING" -eq 1 ]]; then
    echo "  Ping : GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% | worstAvg=${PING_WORST_AVG:-?}ms"
  else
    echo "  Ping : 未执行"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    echo "  MTR  : target=${TARGETS[0]} | lastLoss=${MTR_LASTLOSS:-?}% | lastAvg=${MTR_LASTAVG:-?}ms | rating=${MTR_RATING}"
  else
    echo "  MTR  : 未执行"
  fi
  hr

  echo -e "${BLUE}[TCP真实链路] ${NC} $(grade_icon "$tcp_score")  ${tcp_score}/100（${tcp_grade}）  $(bar "$tcp_score")"
  if [[ "$RUN_TCP" -eq 1 ]]; then
    echo "  TLS  : ${TCP_TLS_MS:-?} ms | TTFB=${TCP_TTFB_MS:-?} ms"
    if [[ -n "${TCP_DL_Mbps:-}" ]]; then
      echo "  DL   : ${TCP_DL_Mbps} Mbps (source=${TCP_SRC}, code=${TCP_DL_CODE})"
    else
      echo "  DL   : ? Mbps (source=${TCP_SRC}, ${TCP_DL_FAIL_REASON:-code=${TCP_DL_CODE}})"
    fi
    echo "  Eval : ${TCP_RATING}"
  else
    echo "  未执行"
  fi
  hr

  echo -e "${BLUE}[磁盘] ${NC} $(grade_icon "$disk_score")  ${disk_score}/100（${disk_grade}）  $(bar "$disk_score")"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    echo "  dd   : ${DISK_SPEED_RAW} | approx=${DISK_MBPS:-?} MB/s | rating=${DISK_RATING}"
  else
    echo "  未执行"
  fi
  hr

  echo -e "${BLUE}[流媒体] ${NC} $(grade_icon "$stream_score")  ${stream_score}/100（${stream_grade}）  $(bar "$stream_score")"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    echo "  YouTube=${YT_OK}(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  else
    echo "  未执行"
  fi
  hr

  echo -e "${BLUE}[总评] ${NC} $(grade_icon "$total")  ${total}/100（${overall}）  $(bar "$total")"
  if [[ "$total" -ge 85 ]]; then
    ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then
    ok "结论：整体不错，日常中转/落地够用，建议关注路由/邻居波动。"
  elif [[ "$total" -ge 55 ]]; then
    warn "结论：整体一般，建议换机房/换商家或降低用途预期。"
  else
    bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi

  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${BLUE}================================================================${NC}"
}

# ---------- run all ----------
run_all_verbose() {
  hr
  gather_system
  gather_ip
  run_ping_all
  run_mtr
  run_disk
  run_streaming
  run_tcp_real
  overall_summary
}

run_all_silent() {
  info "正在后台执行检测（2~8 + TCP），完成后输出最终✅总结..."
  {
    gather_system >/dev/null 2>&1 || true
    gather_ip >/dev/null 2>&1 || true
    run_ping_all >/dev/null 2>&1 || true
    run_mtr >/dev/null 2>&1 || true
    run_disk >/dev/null 2>&1 || true
    run_streaming >/dev/null 2>&1 || true
    run_tcp_real >/dev/null 2>&1 || true
  } || true
  overall_summary
}

# ---------- menu ----------
menu() {
  while true; do
    title "VPS 一键体检 菜单"
    echo "Targets: ${TARGETS[*]}  ${GRAY}(MTR 默认用第一个 Target)${NC}"
    echo
    echo "  1) 设置测试目标（Targets）"
    echo "  2) 基本信息（系统/CPU/RAM/磁盘占用/虚拟化）"
    echo "  3) 公网信息（IPv4 / Geo / ASN / ISP）"
    echo "  4) 网络 Ping 测试（所有 Targets）"
    echo "  5) 路由 MTR 测试（仅第一个 Target）"
    echo "  6) 安装 mtr-tiny（Debian/Ubuntu）"
    echo "  7) 磁盘 dd 测速（输出速度）"
    echo "  8) 流媒体检测（YouTube/动画疯/Netflix/Disney+/TikTok/Prime/Max）"
    echo "  T) TCP 真实链路测试（TLS/TTFB/下载 Mbps）"
    echo "  9) 一键全跑（2~8+T）并输出最终总结（会显示全过程）"
    echo "  R) 后台静默全跑（2~8+T），只输出最终✅总结报告（不刷屏）"
    echo "  0) 退出"
    hr
    read -r -p "选择 [0-9/R/T]: " c || true
    echo
    case "${c:-}" in
      1) set_targets; pause ;;
      2) gather_system; pause ;;
      3) gather_ip; pause ;;
      4) run_ping_all; pause ;;
      5) run_mtr; pause ;;
      6) install_mtr; pause ;;
      7) run_disk; pause ;;
      8) run_streaming; pause ;;
      T|t) run_tcp_real; pause ;;
      9) run_all_verbose; pause ;;
      R|r) run_all_silent; pause ;;
      0|q|Q) ok "Bye."; exit 0 ;;
      *) warn "无效选择：${c:-空}（请输入 0-9 / R / T）"; pause ;;
    esac
  done
}

# ---------- entry ----------
menu
