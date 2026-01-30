#!/usr/bin/env bash
# =========================================================
# VPS Health + Streaming + TCP Real Link Check (Read-only)
# - 菜单交互：系统 / 公网 / Ping / MTR / Disk / Streaming / TCP
# - R：后台静默全跑（2~8+10），只输出最终✅总结报告
# - 修复：进度条乱码、asort 依赖、MTR/Ping/TCP 解析不稳
# - 美化：总结报告配色统一（优秀/良好/一般/偏弱）
#
# Usage:
#   bash <(curl -fsSL "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh")
#   或保存到本地：chmod +x vps_check.sh && ./vps_check.sh
#
# NOTE:
# - 只读检测，不改系统配置（除非你选择安装 mtr-tiny）
# =========================================================

set -euo pipefail

# ---------- UI ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"; GRAY="\033[90m"; NC="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
hr()   { echo -e "${MAGENTA}---------------------------------------------------------${NC}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }
pause() { read -r -p "回车继续..." _ || true; }

# ---------- defaults ----------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=12
DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# TCP test
TCP_RANGE_MB=16
TCP_SOURCES=("cloudflare" "hetzner" "ovh" "cachefly")
# 可用源（尽量用 CDN/镜像，多数能 206/200）
TCP_URL_cloudflare="https://speed.cloudflare.com/__down?bytes=16777216"       # 16MB
TCP_URL_hetzner="https://speed.hetzner.de/100MB.bin"                         # 用 range 抽 16MB
TCP_URL_ovh="https://proof.ovh.net/files/100Mb.dat"                          # range 抽 16MB
TCP_URL_cachefly="https://cachefly.cachefly.net/100mb.test"                  # range 抽 16MB

# ---------- numeric helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

# ---------- global state for summary ----------
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

# tcp summary
TCP_TLS_MS=""
TCP_TTFB_MS=""
TCP_DL_MBPS=""
TCP_EVAL="unknown"
TCP_SCORE=0
TCP_VALID_SAMPLES=0
TCP_BEST_NAME=""
TCP_BEST_MBPS=""

# ---------- progress bar (ASCII to avoid乱码) ----------
# bar: [====........]  (color by grade)
bar_color_by_grade() {
  local grade="$1"
  case "$grade" in
    "优秀") echo -e "$GREEN" ;;
    "良好") echo -e "$CYAN" ;;
    "一般") echo -e "$YELLOW" ;;
    *)      echo -e "$RED" ;;
  esac
}
progress_bar() {
  local score="${1:-0}"
  local grade="${2:-偏弱}"
  local width=28
  local filled=$(( score*width/100 ))
  (( filled<0 )) && filled=0
  (( filled>width )) && filled=$width
  local empty=$(( width-filled ))

  local c; c="$(bar_color_by_grade "$grade")"
  printf "%b[%s%s]%b" "$c" "$(printf '%*s' "$filled" '' | tr ' ' '=')" "$(printf '%*s' "$empty" '' | tr ' ' '.')" "$NC"
}

grade_of() {
  local x="${1:-0}"
  if [[ "$x" -ge 85 ]]; then echo "优秀"
  elif [[ "$x" -ge 70 ]]; then echo "良好"
  elif [[ "$x" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}

grade_word_colored() {
  local grade="$1"
  case "$grade" in
    "优秀") echo -e "${GREEN}${grade}${NC}" ;;
    "良好") echo -e "${CYAN}${grade}${NC}" ;;
    "一般") echo -e "${YELLOW}${grade}${NC}" ;;
    *)      echo -e "${RED}${grade}${NC}" ;;
  esac
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

# ---------- system ----------
gather_system() {
  RUN_SYS=1
  HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
  UPTIME_="$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/^up //g' || echo unknown)"
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

  echo -e "${MAGENTA}--- 基本信息 ---${NC}"
  echo "Host     : ${HOSTNAME_}"
  echo "OS       : ${OS_}"
  echo "Kernel   : ${KERNEL_}"
  echo "Uptime   : ${UPTIME_}"
  echo "CPU      : ${CPU_} (${CORES_} cores)"
  echo "RAM/Swap : ${RAM_} / ${SWAP_}"
  echo "Load avg : ${LOAD_}"
  echo "Virt     : ${VIRT_}"
  echo "Disk /   : ${DISKROOT_}"
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
  echo -e "${MAGENTA}--- 公网信息 ---${NC}"
  echo "IPv4   : ${IPV4_}"
  echo "Geo    : ${GEO_}"
  echo "ASN    : ${ASN_}"
  echo "ISP    : ${ORG_}"
  hr
}

# ---------- ping ----------
ping_once() { local target="$1" interval="$2"; ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null; }

ping_test_one() {
  local target="$1"
  echo -e "${MAGENTA}--- Ping: ${target} (${PING_COUNT} packets) ---${NC}"

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
  # 兼容 rtt / round-trip
  local rttline
  rttline="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | head -n1)"
  min="$(echo "$rttline" | awk -F'/' '{print $1}' | awk '{print $1}')"
  avg="$(echo "$rttline" | awk -F'/' '{print $2}' | awk '{print $1}')"
  max="$(echo "$rttline" | awk -F'/' '{print $3}' | awk '{print $1}')"
  mdev="$(echo "$rttline" | awk -F'/' '{print $4}' | awk '{print $1}')"

  loss="$(safe_num "$loss")"
  avg="$(safe_num "$avg")"; min="$(safe_num "$min")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  echo "Loss   : ${loss:-?}%"
  echo "RTT ms : min=${min:-?} avg=${avg:-?} max=${max:-?} mdev=${mdev:-?}"

  local rating="一般"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="优秀"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="一般"
  else rating="偏弱"
  fi

  if [[ "$rating" == "优秀" ]]; then ok "丢包：优秀（<=1%）"; ((PING_GOOD++)) || true
  elif [[ "$rating" == "一般" ]]; then warn "丢包：一般（1%~5%）"; ((PING_WARN++)) || true
  else bad "丢包：偏弱（>5%）"; ((PING_BAD++)) || true
  fi

  if [[ -n "${avg:-}" ]]; then
    if f_lt "$avg" "80"; then ok "延迟：优秀（<80ms）"
    elif f_lt "$avg" "150"; then warn "延迟：一般（80~150ms）"
    else warn "延迟：偏高（>=150ms）"
    fi
  fi

  # track worst
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
  info "Ping 小结：目标数=${PING_TOTAL_TARGETS} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-?}% 最差平均延迟=${PING_WORST_AVG:-?}ms"
  hr
}

# ---------- mtr ----------
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
  echo -e "${MAGENTA}--- MTR: ${target} (${MTR_COUNT} cycles) ---${NC}"
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
  echo "$out" | tail -n 6

  # 最后一跳通常长这样： "7.|-- one.one.one.one  0.0%  100  1.3  1.3  1.2  1.8  0.1"
  last_line="$(echo "$out" | awk 'NF>=7 {line=$0} END{print line}')"
  last_loss="$(echo "$last_line" | awk '{print $(NF-6)}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $(NF-4)}')"

  last_loss="$(safe_num "$last_loss")"; last_avg="$(safe_num "$last_avg")"
  MTR_LASTLOSS="${last_loss:-}"; MTR_LASTAVG="${last_avg:-}"

  echo
  echo "终点(最后一跳) : Loss=${last_loss:-?}%  Avg=${last_avg:-?} ms"
  info "提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。"

  if [[ -n "${last_loss:-}" ]]; then
    if f_le "$last_loss" "1.0"; then ok "路由质量：优秀"; MTR_RATING="GOOD"
    elif f_le "$last_loss" "5.0"; then warn "路由质量：一般"; MTR_RATING="WARN"
    else bad "路由质量：偏弱"; MTR_RATING="BAD"
    fi
  else
    MTR_RATING="unknown"
  fi
  hr
}

# ---------- disk ----------
run_disk() {
  RUN_DISK=1
  echo -e "${MAGENTA}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"
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
  echo "Result : ${DISK_SPEED_RAW}"

  mbps="$(echo "$DISK_SPEED_RAW" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$DISK_SPEED_RAW" | awk '{print $2}' 2>/dev/null || true)"
  mbps="$(safe_num "$mbps")"

  if [[ -n "${mbps:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')" ; fi
    DISK_MBPS="$mbps"
    if f_ge "$mbps" "200"; then ok "磁盘：优秀（>=200 MB/s）"; DISK_RATING="GOOD"
    elif f_ge "$mbps" "80"; then warn "磁盘：一般（80~200 MB/s）"; DISK_RATING="WARN"
    else warn "磁盘：偏弱（<80 MB/s）"; DISK_RATING="BAD"
    fi
  else
    warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
    DISK_RATING="unknown"
  fi
  hr
}

# ---------- streaming ----------
fetch()   { curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
head_req(){ curl -I -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
code_of() { curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }

run_streaming() {
  RUN_STREAM=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做流媒体检测。"
    return 0
  fi

  echo -e "${MAGENTA}--- 流媒体解锁检测（best-effort）---${NC}"

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

  # AniGamer
  local ag_code ag_html
  ag_code="$(code_of "https://ani.gamer.com.tw/")"
  ag_html="$(fetch "https://ani.gamer.com.tw/")"
  echo "动画疯 HTTP         : ${ag_code}"
  if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
    bad "动画疯：检测到地区限制提示"
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
  local nf_code
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  echo "Netflix HTTP         : ${nf_code}"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then ok "Netflix：可访问（最终以登录播放为准）"; NF_OK="OK"
  else warn "Netflix：可能不可访问/被阻断（HTTP ${nf_code}）"; NF_OK="WARN"
  fi
  echo

  # Disney+
  local dp_code
  dp_code="$(code_of "https://www.disneyplus.com/")"
  echo "Disney+ HTTP         : ${dp_code}"
  if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then ok "Disney+：可访问（最终以登录播放为准）"; DP_OK="OK"
  else warn "Disney+：可能不可访问/地区限制（HTTP ${dp_code}）"; DP_OK="WARN"
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
    [[ -n "${tt_region:-}" ]] && ok "TikTok：可访问（推测地区 ${tt_region}）" || warn "TikTok：可访问但无法判断地区（易受风控/CF 影响，cf-ray=${tt_cf:-n/a}）"
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
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then ok "Prime Video：可访问（片库看账号地区）"; PV_OK="OK"
  else warn "Prime Video：可能不可访问/风控（HTTP ${pv_code}）"; PV_OK="WARN"
  fi
  echo

  # Max
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  echo "Max(HBO) HTTP        : ${mx_code}"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then ok "Max：可访问（最终以登录播放为准）"; MX_OK="OK"
  else warn "Max：可能不可访问/地区限制（HTTP ${mx_code}）"; MX_OK="WARN"
  fi

  hr
  info "提示：Netflix/Disney+/Max/Prime 仅能判断“可访问/疑似限制”，最终以登录播放为准。"
  info "TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。"
  hr
}

# ---------- TCP real link ----------
# 返回：TLS(ms), TTFB(ms), DL(Mbps), HTTP_CODE
tcp_one() {
  local name="$1"
  local url_var="TCP_URL_${name}"
  local url="${!url_var:-}"

  [[ -z "${url:-}" ]] && echo "0|0|0|000" && return 0

  # range：除 cloudflare 外尽量用 range 抽 16MB，避免长时间下载
  local extra=()
  if [[ "$name" != "cloudflare" ]]; then
    local bytes=$((TCP_RANGE_MB*1024*1024))
    extra=(-r "0-$((bytes-1))")
  fi

  # curl -w 获取握手/TTFB/速度/状态码
  # time_appconnect: TLS握手完成时间（秒）
  # time_starttransfer: TTFB（秒）
  # speed_download: 字节/秒
  local out
  out="$(curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" \
    "${extra[@]}" \
    -w "%{http_code}|%{time_appconnect}|%{time_starttransfer}|%{speed_download}" \
    "$url" 2>/dev/null || true)"

  local code tls_s ttfb_s bps
  code="$(echo "$out" | awk -F'|' '{print $1}')"
  tls_s="$(echo "$out" | awk -F'|' '{print $2}')"
  ttfb_s="$(echo "$out" | awk -F'|' '{print $3}')"
  bps="$(echo "$out" | awk -F'|' '{print $4}')"

  code="${code:-000}"
  tls_s="$(safe_num "$tls_s")"
  ttfb_s="$(safe_num "$ttfb_s")"
  bps="$(safe_num "$bps")"

  local tls_ms ttfb_ms mbps
  tls_ms=""
  ttfb_ms=""
  mbps=""

  if [[ -n "${tls_s:-}" ]]; then tls_ms="$(awk -v x="$tls_s" 'BEGIN{printf "%.0f", x*1000}')" ; fi
  if [[ -n "${ttfb_s:-}" ]]; then ttfb_ms="$(awk -v x="$ttfb_s" 'BEGIN{printf "%.0f", x*1000}')" ; fi
  if [[ -n "${bps:-}" ]]; then mbps="$(awk -v x="$bps" 'BEGIN{printf "%.2f", x*8/1000000}')" ; fi

  echo "${tls_ms:-0}|${ttfb_ms:-0}|${mbps:-0}|${code}"
}

median_from_list() {
  # 输入：若干行数字 -> 输出中位数（保留2位）
  # 只用 sort，不依赖 gawk asort
  local n
  n="$(wc -l | awk '{print $1}')"
  [[ -z "${n:-}" || "$n" -lt 1 ]] && echo "" && return 0

  if (( n % 2 == 1 )); then
    local k=$(( (n+1)/2 ))
    sort -n | awk -v k="$k" 'NR==k{printf "%.2f",$1}'
  else
    local k1=$(( n/2 ))
    local k2=$(( k1+1 ))
    sort -n | awk -v k1="$k1" -v k2="$k2" 'NR==k1{a=$1} NR==k2{printf "%.2f",(a+$1)/2}'
  fi
}

run_tcp() {
  RUN_TCP=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做 TCP 测试。"
    TCP_EVAL="unknown"; TCP_SCORE=0
    return 0
  fi

  echo -e "${MAGENTA}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${NC}"
  info "范围：${TCP_RANGE_MB}MB | maxTime=${CURL_TIMEOUT}s | sources=${TCP_SOURCES[*]}（能测几个算几个）"

  local tls_list="" ttfb_list="" dl_list=""
  TCP_VALID_SAMPLES=0
  TCP_BEST_MBPS=""; TCP_BEST_NAME=""

  for s in "${TCP_SOURCES[@]}"; do
    local r tls ttfb dl code
    r="$(tcp_one "$s")"
    tls="$(echo "$r" | awk -F'|' '{print $1}')"
    ttfb="$(echo "$r" | awk -F'|' '{print $2}')"
    dl="$(echo "$r" | awk -F'|' '{print $3}')"
    code="$(echo "$r" | awk -F'|' '{print $4}')"

    # 有效判定：code 200/206 且 dl>0
    local ok_one=0
    if [[ "$code" == "200" || "$code" == "206" ]]; then
      if [[ -n "$(safe_num "$dl")" ]] && f_gt0="$(awk -v x="$dl" 'BEGIN{exit (x>0)?0:1}')" ; then :; fi
      if awk -v x="$dl" 'BEGIN{exit (x>0)?0:1}'; then ok_one=1; fi
    fi

    if [[ "$ok_one" -eq 1 ]]; then
      ((TCP_VALID_SAMPLES++)) || true
      tls_list+="${tls}\n"
      ttfb_list+="${ttfb}\n"
      dl_list+="${dl}\n"
      # best
      if [[ -z "${TCP_BEST_MBPS:-}" ]]; then TCP_BEST_MBPS="$dl"; TCP_BEST_NAME="$s"; else
        awk -v a="$dl" -v b="$TCP_BEST_MBPS" 'BEGIN{exit (a>b)?0:1}' && TCP_BEST_MBPS="$dl" && TCP_BEST_NAME="$s" || true
      fi
      echo -e " • ${GREEN}${s}${NC}: TLS=${tls}ms  TTFB=${ttfb}ms  DL=${dl}Mbps  code=${code}"
    else
      echo -e " • ${GRAY}${s}${NC}: DL=?Mbps  code=${code}（跳过）"
    fi
  done

  if [[ "$TCP_VALID_SAMPLES" -lt 2 ]]; then
    warn "TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。"
    TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
    TCP_EVAL="unknown"
    TCP_SCORE=0
    hr
    return 0
  fi

  # 计算中位数
  TCP_TLS_MS="$(printf "%b" "$tls_list" | awk 'NF>0{print $1}' | median_from_list || true)"
  TCP_TTFB_MS="$(printf "%b" "$ttfb_list" | awk 'NF>0{print $1}' | median_from_list || true)"
  TCP_DL_MBPS="$(printf "%b" "$dl_list" | awk 'NF>0{print $1}' | median_from_list || true)"

  echo
  echo -e "${GRAY}Median:${NC} TLS=${TCP_TLS_MS:-?}ms | TTFB=${TCP_TTFB_MS:-?}ms | DL=${TCP_DL_MBPS:-?}Mbps  (best=${TCP_BEST_NAME} ${TCP_BEST_MBPS}Mbps)"

  # 评分（偏“代理体验”）：TTFB + DL 影响更大
  # 简单规则：
  # - DL >= 100Mbps 且 TTFB <= 300ms -> 优秀
  # - DL >= 20Mbps  且 TTFB <= 800ms -> 良好
  # - DL >= 5Mbps   -> 一般
  # - else -> 偏弱
  local dl="${TCP_DL_MBPS:-0}" ttfb="${TCP_TTFB_MS:-99999}"
  dl="$(safe_num "$dl")"; ttfb="$(safe_num "$ttfb")"
  local grade="偏弱"

  if [[ -n "${dl:-}" && -n "${ttfb:-}" ]]; then
    if f_ge "$dl" "100" && f_le "$ttfb" "300"; then grade="优秀"; TCP_SCORE=90; TCP_EVAL="GOOD"
    elif f_ge "$dl" "20" && f_le "$ttfb" "800"; then grade="良好"; TCP_SCORE=80; TCP_EVAL="WARN"
    elif f_ge "$dl" "5"; then grade="一般"; TCP_SCORE=65; TCP_EVAL="WARN"
    else grade="偏弱"; TCP_SCORE=40; TCP_EVAL="BAD"
    fi
  else
    TCP_SCORE=0; TCP_EVAL="unknown"
  fi

  if [[ "$grade" == "优秀" ]]; then ok "TCP 体验：优秀（median）"
  elif [[ "$grade" == "良好" ]]; then warn "TCP 体验：良好（median）"
  elif [[ "$grade" == "一般" ]]; then warn "TCP 体验：一般（median）"
  else bad "TCP 体验：偏弱（median）"
  fi
  hr
}

# ---------- overall summary ----------
overall_summary() {
  echo -e "${MAGENTA}====================== ✅ VPS 体检总结报告 ======================${NC}"

  # net score based on ping + mtr
  local net_score=0 disk_score=0 stream_score=0 tcp_score=0 total=0
  local net_grade="未知" disk_grade="未知" stream_grade="未知" tcp_grade="未知" overall=""

  # Ping contribution
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

  # Disk score
  if [[ "$RUN_DISK" -eq 1 ]]; then
    if [[ "$DISK_RATING" == "GOOD" ]]; then disk_score=90
    elif [[ "$DISK_RATING" == "WARN" ]]; then disk_score=70
    elif [[ "$DISK_RATING" == "BAD" ]]; then disk_score=50
    else disk_score=0
    fi
  else disk_score=0; fi

  # Streaming score
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
  else stream_score=0; fi

  # TCP score
  if [[ "$RUN_TCP" -eq 1 ]]; then
    tcp_score="${TCP_SCORE:-0}"
  else
    tcp_score=0
  fi

  net_grade="$(grade_of "$net_score")"
  disk_grade="$(grade_of "$disk_score")"
  stream_grade="$(grade_of "$stream_score")"
  tcp_grade="$(grade_of "$tcp_score")"

  # total weights: net 40 / tcp 25 / stream 20 / disk 15
  local w_net=40 w_tcp=25 w_stream=20 w_disk=15
  local used=0
  total=0
  if [[ "$RUN_PING" -eq 1 || "$RUN_MTR" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$net_score" -v w="$w_net" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_net)) || true; fi
  if [[ "$RUN_TCP" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$tcp_score" -v w="$w_tcp" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_tcp)) || true; fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$stream_score" -v w="$w_stream" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_stream)) || true; fi
  if [[ "$RUN_DISK" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$disk_score" -v w="$w_disk" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_disk)) || true; fi
  if [[ "$used" -gt 0 ]]; then total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"; else total=0; fi

  overall="$(grade_of "$total")"

  echo -e "${MAGENTA}[基础信息]${NC}"
  if [[ "$RUN_SYS" -eq 1 ]]; then
    echo "Host : ${HOSTNAME_}"
    echo "OS   : ${OS_}"
    echo "Kern : ${KERNEL_} | Virt=${VIRT_}"
    echo "CPU  : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
    echo "Disk : / ${DISKROOT_}"
  else
    echo "（未执行）"
  fi
  if [[ "$RUN_IP" -eq 1 ]]; then
    echo "IPv4 : ${IPV4_}"
    echo "Geo  : ${GEO_}"
    echo "ASN  : ${ASN_}"
    echo "ISP  : ${ORG_}"
  else
    echo "公网信息：未执行"
  fi
  hr

  echo -e "${MAGENTA}[网络]  ${net_score}/100 ($(grade_word_colored "$net_grade"))  $(progress_bar "$net_score" "$net_grade")${NC}"
  if [[ "$RUN_PING" -eq 1 ]]; then
    echo "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-?}% | 最差平均延迟=${PING_WORST_AVG:-?}ms"
  else
    echo "Ping : 未执行"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    echo "MTR  : target=${TARGETS[0]} | 终点丢包=${MTR_LASTLOSS:-?}% | 终点平均=${MTR_LASTAVG:-?}ms | 评级=${MTR_RATING}"
  else
    echo "MTR  : 未执行"
  fi
  hr

  echo -e "${MAGENTA}[TCP真实链路]  ${tcp_score}/100 ($(grade_word_colored "$tcp_grade"))  $(progress_bar "$tcp_score" "$tcp_grade")${NC}"
  if [[ "$RUN_TCP" -eq 1 ]]; then
    echo "TLS  : ${TCP_TLS_MS:-?} ms | TTFB=${TCP_TTFB_MS:-?} ms"
    echo "DL   : ${TCP_DL_MBPS:-?} Mbps (median, range=${TCP_RANGE_MB}MB, maxTime=${CURL_TIMEOUT}s)"
    echo "Eval : ${TCP_EVAL}"
    [[ "${TCP_VALID_SAMPLES:-0}" -lt 2 ]] && warn "TCP：有效样本不足，建议换时间多测几次"
  else
    echo "未执行"
  fi
  hr

  echo -e "${MAGENTA}[磁盘]  ${disk_score}/100 ($(grade_word_colored "$disk_grade"))  $(progress_bar "$disk_score" "$disk_grade")${NC}"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    echo "dd   : ${DISK_SPEED_RAW} | approx=${DISK_MBPS:-?} MB/s | rating=${DISK_RATING}"
  else
    echo "未执行"
  fi
  hr

  echo -e "${MAGENTA}[流媒体]  ${stream_score}/100 ($(grade_word_colored "$stream_grade"))  $(progress_bar "$stream_score" "$stream_grade")${NC}"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    echo "YouTube=OK(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  else
    echo "未执行"
  fi
  hr

  echo -e "${MAGENTA}[总评]  ${total}/100 ($(grade_word_colored "$overall"))  $(progress_bar "$total" "$overall")${NC}"
  if [[ "$total" -ge 85 ]]; then ok "结论：整体素质很强，适合中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then ok "结论：整体不错，日常中转/落地够用，关注路由与邻居波动。"
  elif [[ "$total" -ge 55 ]]; then warn "结论：整体一般，建议降低用途预期或换机房/换商家。"
  else bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi

  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${MAGENTA}================================================================${NC}"
}

# ---------- run all (verbose) ----------
run_all_verbose() {
  hr
  gather_system
  gather_ip
  run_ping_all
  run_mtr
  run_disk
  run_streaming
  run_tcp
  overall_summary
}

# ---------- run all (silent) ----------
run_all_silent() {
  info "正在后台执行检测（2~8+10），完成后输出最终✅总结..."
  # 静默执行：把过程输出丢弃，但不影响变量结果
  { gather_system; } >/dev/null 2>&1 || true
  { gather_ip; } >/dev/null 2>&1 || true
  { run_ping_all; } >/dev/null 2>&1 || true
  { run_mtr; } >/dev/null 2>&1 || true
  { run_disk; } >/dev/null 2>&1 || true
  { run_streaming; } >/dev/null 2>&1 || true
  { run_tcp; } >/dev/null 2>&1 || true
  overall_summary
}

# ---------- menu ----------
menu() {
  while true; do
    echo -e "${MAGENTA}====================== VPS 一键体检 菜单 ======================${NC}"
    echo -e "Targets: ${TARGETS[*]}  ${GRAY}(MTR 默认用第一个 Target)${NC}"
    echo
    echo "  1) 设置测试目标（Targets）"
    echo "  2) 基本信息（系统/CPU/RAM/磁盘占用/虚拟化）"
    echo "  3) 公网信息（IPv4 / Geo / ASN / ISP）"
    echo "  4) 网络 Ping 测试（所有 Targets）"
    echo "  5) 路由 MTR 测试（仅第一个 Target）"
    echo "  6) 安装 mtr-tiny（Debian/Ubuntu）"
    echo "  7) 磁盘 dd 测速（输出速度）"
    echo "  8) 流媒体检测（YouTube/动画疯/Netflix/Disney+/TikTok/Prime/Max）"
    echo "  9) 一键全跑（2~8+10）并输出最终总结（会显示全过程）"
    echo " 10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
    echo "  R) 后台静默全跑（2~8+10），只输出最终✅总结报告（不刷屏）"
    echo "  0) 退出"
    hr

    read -r -p "选择 [0-10/R]: " c || true
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
      9) run_all_verbose; pause ;;
      10) run_tcp; pause ;;
      r|R) run_all_silent; pause ;;
      0|q|Q) ok "Bye."; exit 0 ;;
      *) warn "无效选择：${c:-空}"; pause ;;
    esac
  done
}

# ---------- entry ----------
menu
