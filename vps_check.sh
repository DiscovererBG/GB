#!/usr/bin/env bash
# =========================================================
# VPS 一键体检（只读）+ 流媒体解锁检测（菜单版 + TCP真实链路）
# - 交互菜单：System / IP / Ping / MTR / Disk / Streaming / TCP真实链路
# - R：静默后台全跑（2~8 + 10）只输出最终✅总结报告（不刷屏）
# - 美化：最终总结报告卡片化/对齐/进度条
# - 可选：--redact 自动打码（IPv4/Host）
#
# Usage:
#   bash <(curl -fsSL "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh")
#   或：chmod +x vps_check.sh && ./vps_check.sh
#   打码：./vps_check.sh --redact
# =========================================================

set -euo pipefail

# ---------- args ----------
REDACT=0
SILENT=0
for arg in "${@:-}"; do
  case "$arg" in
    --redact) REDACT=1 ;;
    --silent) SILENT=1 ;;
  esac
done

# ---------- UI ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; PURPLE="\033[35m"; GRAY="\033[90m"; NC="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
hr()   { echo -e "${PURPLE}---------------------------------------------------------${NC}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() { [[ "${SILENT}" -eq 1 ]] && return 0; read -r -p "回车继续..." _ || true; }

# ---------- defaults ----------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=12
DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# TCP tests (HTTPS real path)
TCP_URLS_DEFAULT=("https://www.cloudflare.com/cdn-cgi/trace" "https://www.google.com/generate_204")
TCP_SPEED_URL_DEFAULT="https://speed.hetzner.de/100MB.bin"  # 真实下载测速源
TCP_SPEED_MAXTIME=12        # 秒：避免测速太久
TCP_RETRY=1                 # curl 重试次数（网络抖动时有用）

# ---------- numeric helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

# ---------- redact helpers ----------
mask_ipv4() {
  local ip="${1:-unknown}"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$ip" | awk -F. '{printf "%s.%s.*.*",$1,$2}'
  else
    echo "$ip"
  fi
}
mask_host() {
  local h="${1:-unknown}"
  [[ -z "$h" || "$h" == "unknown" ]] && { echo "$h"; return; }
  echo "${h:0:2}***"
}

# ---------- progress bar ----------
bar() {
  # bar <score 0-100> [width]
  local s="${1:-0}" w="${2:-24}"
  s=$(( s<0?0 : s>100?100 : s ))
  local filled=$(( s*w/100 ))
  local empty=$(( w-filled ))
  printf "["
  printf "%0.s█" $(seq 1 $filled 2>/dev/null || true)
  printf "%0.s░" $(seq 1 $empty 2>/dev/null || true)
  printf "]"
}

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
TCP_HANDSHAKE_MS=""
TCP_TTFB_MS=""
TCP_DL_Mbps=""
TCP_RATING="unknown"

# ---------- input ----------
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
  UPTIME_="$(uptime -p 2>/dev/null || echo unknown)"
  OS_="$( (awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null) || echo unknown )"
  KERNEL_="$(uname -r 2>/dev/null || echo unknown)"
  CPU_="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || echo unknown)"
  CORES_="$(nproc 2>/dev/null || echo 1)"
  RAM_="$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  SWAP_="$(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  LOAD_="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || echo unknown)"
  VIRT_="unknown"
  need_cmd systemd-detect-virt && VIRT_="$(systemd-detect-virt 2>/dev/null || echo none)"
  DISKROOT_="$(df -hP / 2>/dev/null | tail -n 1 | awk '{print $3"/"$2" ("$5")"}' || echo unknown)"

  [[ "${SILENT}" -eq 1 ]] && return 0
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

# ---------- public ip ----------
gather_ip() {
  RUN_IP=1
  IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"
  if ! need_cmd curl; then
    [[ "${SILENT}" -eq 1 ]] || bad "缺少 curl，无法查询公网信息。"
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

  [[ "${SILENT}" -eq 1 ]] && return 0
  echo -e "${BLUE}--- 公网信息 ---${NC}"
  echo "IPv4      : ${IPV4_}"
  echo "Geo       : ${GEO_}"
  echo "ASN       : ${ASN_}"
  echo "ISP/Org   : ${ORG_}"
  hr
}

# ---------- ping ----------
ping_once() { local target="$1" interval="$2"; ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null; }

ping_test_one() {
  local target="$1"
  [[ "${SILENT}" -eq 1 ]] || echo -e "${BLUE}--- Ping：${target} (${PING_COUNT} packets) ---${NC}"

  if ! need_cmd ping; then
    [[ "${SILENT}" -eq 1 ]] || warn "没有 ping 命令，跳过。"
    return 0
  fi

  local out loss avg min max mdev
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    [[ "${SILENT}" -eq 1 ]] || warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  avg="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')"
  min="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $1}' | awk '{print $1}')"
  max="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $3}' | awk '{print $1}')"
  mdev="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $4}' | awk '{print $1}')"

  loss="$(safe_num "$loss")"
  avg="$(safe_num "$avg")"; min="$(safe_num "$min")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  [[ "${SILENT}" -eq 1 ]] || {
    echo "Loss      : ${loss:-?}%"
    echo "RTT ms    : min=${min:-?} avg=${avg:-?} max=${max:-?} mdev=${mdev:-?}"
  }

  local rating="WARN"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="GOOD"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="WARN"
  else rating="BAD"
  fi

  if [[ "$rating" == "GOOD" ]]; then ((PING_GOOD++)) || true
  elif [[ "$rating" == "WARN" ]]; then ((PING_WARN++)) || true
  else ((PING_BAD++)) || true
  fi

  # track worst
  if [[ -n "${loss:-}" ]]; then
    if [[ -z "${PING_WORST_LOSS:-}" ]]; then PING_WORST_LOSS="$loss"
    else awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit (a>b)?0:1}' && PING_WORST_LOSS="$loss" || true
    fi
  fi
  if [[ -n "${avg:-}" ]]; then
    if [[ -z "${PING_WORST_AVG:-}" ]]; then PING_WORST_AVG="$avg"
    else awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit (a>b)?0:1}' && PING_WORST_AVG="$avg" || true
    fi
  fi

  [[ "${SILENT}" -eq 1 ]] || echo
}

run_ping_all() {
  RUN_PING=1
  PING_TOTAL_TARGETS="${#TARGETS[@]}"
  PING_GOOD=0; PING_WARN=0; PING_BAD=0
  PING_WORST_LOSS=""; PING_WORST_AVG=""
  for t in "${TARGETS[@]}"; do ping_test_one "$t"; done

  [[ "${SILENT}" -eq 1 ]] && return 0
  hr
  info "Ping 小结：Targets=${PING_TOTAL_TARGETS} | GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% worstAvg=${PING_WORST_AVG:-?}ms"
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

  if ! need_cmd mtr; then
    MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"
    [[ "${SILENT}" -eq 1 ]] || warn "未安装 mtr。（可在菜单选择安装 mtr-tiny）"
    [[ "${SILENT}" -eq 1 ]] || hr
    return 0
  fi

  local out last_line last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"

  last_line="$(echo "$out" | tail -n 1)"
  last_loss="$(echo "$last_line" | awk '{print $3}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $6}')"
  last_loss="$(safe_num "$last_loss")"; last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

  if [[ -n "${last_loss:-}" ]]; then
    if f_le "$last_loss" "1.0"; then MTR_RATING="GOOD"
    elif f_le "$last_loss" "5.0"; then MTR_RATING="WARN"
    else MTR_RATING="BAD"
    fi
  else
    MTR_RATING="unknown"
  fi

  [[ "${SILENT}" -eq 1 ]] && return 0

  echo -e "${BLUE}--- MTR：${target} (${MTR_COUNT} cycles) ---${NC}"
  echo "$out" | head -n 3
  echo -e "${GRAY}...（中间省略）...${NC}"
  echo "$out" | tail -n 5
  echo
  echo "终点(最后一跳) : Loss=${last_loss:-?}%  Avg=${last_avg:-?} ms"
  info "提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。"
  hr
}

# ---------- disk dd ----------
run_disk() {
  RUN_DISK=1
  if ! need_cmd dd; then
    DISK_SPEED_RAW="unknown"; DISK_MBPS=""; DISK_RATING="unknown"
    [[ "${SILENT}" -eq 1 ]] || warn "dd 不存在，跳过。"
    [[ "${SILENT}" -eq 1 ]] || hr
    return 0
  fi

  local tmp out speed mbps unit
  tmp="/tmp/vps_disk_test.$$"
  out="$(dd if=/dev/zero of="$tmp" bs=1M count="${DISK_TEST_MB}" conv=fdatasync 2>&1 || true)"
  rm -f "$tmp" >/dev/null 2>&1 || true

  speed="$(echo "$out" | tail -n 1 | awk -F', ' '{print $NF}' | sed 's/^[ \t]*//')"
  DISK_SPEED_RAW="${speed:-unknown}"

  mbps="$(echo "$DISK_SPEED_RAW" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$DISK_SPEED_RAW" | awk '{print $2}' 2>/dev/null || true)"
  mbps="$(safe_num "$mbps")"

  if [[ -n "${mbps:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')" ; fi
    DISK_MBPS="$mbps"
    if f_ge "$mbps" "200"; then DISK_RATING="GOOD"
    elif f_ge "$mbps" "80"; then DISK_RATING="WARN"
    else DISK_RATING="BAD"
    fi
  else
    DISK_RATING="unknown"
  fi

  [[ "${SILENT}" -eq 1 ]] && return 0
  echo -e "${BLUE}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"
  echo "Result    : ${DISK_SPEED_RAW}"
  if [[ "$DISK_RATING" == "GOOD" ]]; then ok "磁盘：不错（>=200 MB/s）"
  elif [[ "$DISK_RATING" == "WARN" ]]; then warn "磁盘：一般（80~200 MB/s）"
  elif [[ "$DISK_RATING" == "BAD" ]]; then warn "磁盘：偏低（<80 MB/s）"
  else warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
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
    [[ "${SILENT}" -eq 1 ]] || bad "缺少 curl，无法做流媒体检测。"
    return 0
  fi

  # YouTube
  local yt_code yt_html yt_cc
  yt_code="$(code_of "https://www.youtube.com/premium")"
  yt_html="$(fetch "https://www.youtube.com/premium")"
  yt_cc="$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d: -f2 | tr -d '"')"
  YT_CC="${yt_cc:-unknown}"
  if [[ "$yt_code" == "200" || "$yt_code" == "302" ]]; then YT_OK="OK"; else YT_OK="BAD"; fi

  # AniGamer
  local ag_code ag_html
  ag_code="$(code_of "https://ani.gamer.com.tw/")"
  ag_html="$(fetch "https://ani.gamer.com.tw/")"
  if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
    AG_STATUS="REGION_BLOCK"
  elif [[ "$ag_code" == "200" ]]; then
    AG_STATUS="OK"
  elif [[ "$ag_code" == "403" || "$ag_code" == "503" ]]; then
    AG_STATUS="WAF_OR_RISK"
  else
    AG_STATUS="UNKNOWN"
  fi

  # Netflix
  local nf_code
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then NF_OK="OK"; else NF_OK="WARN"; fi

  # Disney+
  local dp_code
  dp_code="$(code_of "https://www.disneyplus.com/")"
  if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then DP_OK="OK"; else DP_OK="WARN"; fi

  # TikTok
  local tt_code
  tt_code="$(code_of "https://www.tiktok.com/")"
  if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then TT_OK="OK"
  elif [[ "$tt_code" == "403" ]]; then TT_OK="BAD"
  else TT_OK="WARN"
  fi

  # Prime
  local pv_code
  pv_code="$(code_of "https://www.primevideo.com/")"
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then PV_OK="OK"; else PV_OK="WARN"; fi

  # Max
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then MX_OK="OK"; else MX_OK="WARN"; fi

  [[ "${SILENT}" -eq 1 ]] && return 0

  echo -e "${BLUE}--- 流媒体解锁检测（best-effort）---${NC}"
  echo "YouTube : ${YT_OK} (CC=${YT_CC})"
  echo "动画疯 : ${AG_STATUS}"
  echo "Netflix : ${NF_OK}"
  echo "Disney+: ${DP_OK}"
  echo "TikTok  : ${TT_OK}"
  echo "Prime   : ${PV_OK}"
  echo "Max     : ${MX_OK}"
  hr
  info "提示：最终以登录播放为准；TikTok/动画疯易受风控影响。"
  hr
}

# ---------- TCP REAL LINK TEST ----------
# What we measure:
# - handshake_ms : time_appconnect (TLS握手完成)
# - ttfb_ms      : time_starttransfer (首字节)
# - dl_mbps      : 下载速率（curl speed_download）
curl_time_metrics() {
  # prints: appconnect|starttransfer|http_code
  local url="$1"
  curl -L -s -o /dev/null \
    --connect-timeout 6 --max-time "${CURL_TIMEOUT}" --retry "${TCP_RETRY}" \
    -A "Mozilla/5.0" \
    -w "%{time_appconnect}|%{time_starttransfer}|%{http_code}" \
    "$url" 2>/dev/null || echo "||"
}

curl_speed() {
  # prints: speed_download(bytes/sec)|http_code
  local url="$1"
  curl -L -s -o /dev/null \
    --connect-timeout 6 --max-time "${TCP_SPEED_MAXTIME}" --retry "${TCP_RETRY}" \
    -A "Mozilla/5.0" \
    -w "%{speed_download}|%{http_code}" \
    "$url" 2>/dev/null || echo "|"
}

run_tcp_real() {
  RUN_TCP=1
  TCP_HANDSHAKE_MS=""
  TCP_TTFB_MS=""
  TCP_DL_Mbps=""
  TCP_RATING="unknown"

  if ! need_cmd curl; then
    [[ "${SILENT}" -eq 1 ]] || bad "缺少 curl，无法做 TCP 真实链路测试。"
    return 0
  fi

  # 1) handshake/ttfb: take best (min) among default urls
  local best_h="" best_t="" any_ok=0
  for u in "${TCP_URLS_DEFAULT[@]}"; do
    local m app tt code
    m="$(curl_time_metrics "$u")"
    app="${m%%|*}"; m="${m#*|}"
    tt="${m%%|*}"; m="${m#*|}"
    code="${m:-}"

    # app/tt in seconds, convert to ms
    if [[ -n "$(safe_num "$app")" && -n "$(safe_num "$tt")" && "$code" =~ ^2|3 ]]; then
      any_ok=1
      local app_ms tt_ms
      app_ms="$(awk -v x="$app" 'BEGIN{printf "%.0f", x*1000}')"
      tt_ms="$(awk -v x="$tt" 'BEGIN{printf "%.0f", x*1000}')"

      if [[ -z "$best_h" ]] || awk -v a="$app_ms" -v b="$best_h" 'BEGIN{exit (a<b)?0:1}'; then best_h="$app_ms"; fi
      if [[ -z "$best_t" ]] || awk -v a="$tt_ms" -v b="$best_t" 'BEGIN{exit (a<b)?0:1}'; then best_t="$tt_ms"; fi
    fi
  done

  TCP_HANDSHAKE_MS="${best_h:-}"
  TCP_TTFB_MS="${best_t:-}"

  # 2) download speed: convert bytes/sec -> Mbps
  local sp code
  sp="$(curl_speed "$TCP_SPEED_URL_DEFAULT")"
  code="${sp#*|}"
  sp="${sp%%|*}"
  if [[ -n "$(safe_num "$sp")" && "$code" =~ ^2|3 ]]; then
    # Mbps = bytes/sec * 8 / 1e6
    TCP_DL_Mbps="$(awk -v b="$sp" 'BEGIN{printf "%.1f", b*8/1000000}')"
  fi

  # rating (rough, for proxy experience)
  # handshake < 150ms excellent, <300 good, <600 ok
  # ttfb < 250ms excellent, <500 good, <1000 ok
  # dl > 50Mbps excellent, >20 good, >5 ok
  local score=0 parts=0
  if [[ -n "$TCP_HANDSHAKE_MS" ]]; then
    parts=$((parts+1))
    if [[ "$TCP_HANDSHAKE_MS" -lt 150 ]]; then score=$((score+35))
    elif [[ "$TCP_HANDSHAKE_MS" -lt 300 ]]; then score=$((score+28))
    elif [[ "$TCP_HANDSHAKE_MS" -lt 600 ]]; then score=$((score+20))
    else score=$((score+10))
    fi
  fi
  if [[ -n "$TCP_TTFB_MS" ]]; then
    parts=$((parts+1))
    if [[ "$TCP_TTFB_MS" -lt 250 ]]; then score=$((score+35))
    elif [[ "$TCP_TTFB_MS" -lt 500 ]]; then score=$((score+28))
    elif [[ "$TCP_TTFB_MS" -lt 1000 ]]; then score=$((score+20))
    else score=$((score+10))
    fi
  fi
  if [[ -n "$TCP_DL_Mbps" ]]; then
    parts=$((parts+1))
    # float compare via awk
    if awk -v x="$TCP_DL_Mbps" 'BEGIN{exit (x>=50)?0:1}'; then score=$((score+30))
    elif awk -v x="$TCP_DL_Mbps" 'BEGIN{exit (x>=20)?0:1}'; then score=$((score+24))
    elif awk -v x="$TCP_DL_Mbps" 'BEGIN{exit (x>=5)?0:1}'; then score=$((score+16))
    else score=$((score+8))
    fi
  fi

  if [[ "$parts" -gt 0 ]]; then
    # normalize to 0-100
    score="$(awk -v s="$score" -v p="$parts" 'BEGIN{printf "%.0f", s*3/p}')"
    score=$(( score>100?100:score ))
    if [[ "$score" -ge 85 ]]; then TCP_RATING="GOOD"
    elif [[ "$score" -ge 65 ]]; then TCP_RATING="WARN"
    else TCP_RATING="BAD"
    fi
  else
    TCP_RATING="unknown"
  fi

  [[ "${SILENT}" -eq 1 ]] && return 0
  echo -e "${BLUE}--- TCP 真实链路测试（更贴近代理体验）---${NC}"
  echo "Handshake(TLS) : ${TCP_HANDSHAKE_MS:-?} ms"
  echo "TTFB          : ${TCP_TTFB_MS:-?} ms"
  echo "Download      : ${TCP_DL_Mbps:-?} Mbps  (source=hetzner 100MB, maxtime=${TCP_SPEED_MAXTIME}s)"
  if [[ "$TCP_RATING" == "GOOD" ]]; then ok "TCP 体验：优秀"
  elif [[ "$TCP_RATING" == "WARN" ]]; then warn "TCP 体验：良好/一般"
  elif [[ "$TCP_RATING" == "BAD" ]]; then bad "TCP 体验：偏弱（建议换路由/机房/运营商）"
  else warn "TCP 体验：未知（可能 curl 失败/被墙/被风控）"
  fi
  hr
}

# ---------- overall summary ----------
grade() {
  local x="${1:-0}"
  if [[ "$x" -ge 85 ]]; then echo "优秀"
  elif [[ "$x" -ge 70 ]]; then echo "良好"
  elif [[ "$x" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}

overall_summary() {
  local host="$HOSTNAME_" ip="$IPV4_"
  [[ "$REDACT" -eq 1 ]] && { host="$(mask_host "$host")"; ip="$(mask_ipv4 "$ip")"; }

  # scores
  local net_score=0 disk_score=0 stream_score=0 tcp_score=0 total=0 used=0
  local net_grade="未知" disk_grade="未知" stream_grade="未知" tcp_grade="未知" overall="未知"

  # Network from ping + mtr
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"; [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  else
    net_score=0
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    [[ "$MTR_RATING" == "GOOD" ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')" || true
    [[ "$MTR_RATING" == "BAD"  ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')" || true
  fi
  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"

  # Disk
  if [[ "$RUN_DISK" -eq 1 ]]; then
    if [[ "$DISK_RATING" == "GOOD" ]]; then disk_score=90
    elif [[ "$DISK_RATING" == "WARN" ]]; then disk_score=70
    elif [[ "$DISK_RATING" == "BAD" ]]; then disk_score=50
    else disk_score=0
    fi
  else
    disk_score=0
  fi

  # Streaming (0..100)
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

  # TCP
  if [[ "$RUN_TCP" -eq 1 ]]; then
    if [[ "$TCP_RATING" == "GOOD" ]]; then tcp_score=90
    elif [[ "$TCP_RATING" == "WARN" ]]; then tcp_score=75
    elif [[ "$TCP_RATING" == "BAD" ]]; then tcp_score=55
    else tcp_score=0
    fi
  else
    tcp_score=0
  fi

  net_grade="$(grade "$net_score")"
  disk_grade="$(grade "$disk_score")"
  stream_grade="$(grade "$stream_score")"
  tcp_grade="$(grade "$tcp_score")"

  # weights (net 40, tcp 20, disk 15, stream 25)
  total=0; used=0
  if [[ "$RUN_PING" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$net_score" -v w=40 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+40)); fi
  if [[ "$RUN_TCP" -eq 1  ]]; then total="$(awk -v t="$total" -v x="$tcp_score" -v w=20 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+20)); fi
  if [[ "$RUN_DISK" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$disk_score" -v w=15 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+15)); fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$stream_score" -v w=25 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+25)); fi
  if [[ "$used" -gt 0 ]]; then total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"; else total=0; fi
  overall="$(grade "$total")"

  # header
  echo -e "${PURPLE}====================== ✅ VPS 体检总结报告 ======================${NC}"

  # base info card
  echo -e "${BLUE}[基础信息]${NC}"
  if [[ "$RUN_SYS" -eq 1 ]]; then
    printf "  %-6s: %s\n" "Host" "$host"
    printf "  %-6s: %s\n" "OS"   "$OS_"
    printf "  %-6s: %s\n" "Kern" "$KERNEL_ | Virt=${VIRT_}"
    printf "  %-6s: %s\n" "CPU"  "$CPU_ | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
    printf "  %-6s: %s\n" "Disk" "/ ${DISKROOT_}"
  else
    echo "  （未执行系统信息）"
  fi
  if [[ "$RUN_IP" -eq 1 ]]; then
    printf "  %-6s: %s\n" "IPv4" "$ip"
    printf "  %-6s: %s\n" "Geo"  "${GEO_}"
    printf "  %-6s: %s\n" "ASN"  "${ASN_} | ISP=${ORG_}"
  else
    echo "  公网信息：未执行"
  fi
  hr

  # network
  echo -e "${BLUE}[网络]${NC}  ${net_score}/100（${net_grade}）  $(bar "$net_score")"
  if [[ "$RUN_PING" -eq 1 ]]; then
    printf "  %-10s: GOOD=%s WARN=%s BAD=%s | worstLoss=%s%% | worstAvg=%sms\n" \
      "Ping" "$PING_GOOD" "$PING_WARN" "$PING_BAD" "${PING_WORST_LOSS:-?}" "${PING_WORST_AVG:-?}"
  else
    echo "  Ping      : 未执行"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    printf "  %-10s: target=%s | lastLoss=%s%% | lastAvg=%sms | rating=%s\n" \
      "MTR" "${TARGETS[0]}" "${MTR_LASTLOSS:-?}" "${MTR_LASTAVG:-?}" "${MTR_RATING}"
  else
    echo "  MTR       : 未执行"
  fi
  hr

  # tcp
  echo -e "${BLUE}[TCP真实链路]${NC}  ${tcp_score}/100（${tcp_grade}）  $(bar "$tcp_score")"
  if [[ "$RUN_TCP" -eq 1 ]]; then
    printf "  %-10s: Handshake=%sms | TTFB=%sms | Download=%s Mbps | rating=%s\n" \
      "curl" "${TCP_HANDSHAKE_MS:-?}" "${TCP_TTFB_MS:-?}" "${TCP_DL_Mbps:-?}" "${TCP_RATING}"
  else
    echo "  未执行"
  fi
  hr

  # disk
  echo -e "${BLUE}[磁盘]${NC}  ${disk_score}/100（${disk_grade}）  $(bar "$disk_score")"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    printf "  %-10s: %s | approx=%s MB/s | rating=%s\n" "dd" "${DISK_SPEED_RAW}" "${DISK_MBPS:-?}" "${DISK_RATING}"
  else
    echo "  未执行"
  fi
  hr

  # streaming
  echo -e "${BLUE}[流媒体]${NC}  ${stream_score}/100（${stream_grade}）  $(bar "$stream_score")"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    printf "  %-10s: YouTube=%s(CC=%s) | 动画疯=%s | Netflix=%s | Disney+=%s | TikTok=%s | Prime=%s | Max=%s\n" \
      "Status" "$YT_OK" "$YT_CC" "$AG_STATUS" "$NF_OK" "$DP_OK" "$TT_OK" "$PV_OK" "$MX_OK"
  else
    echo "  未执行"
  fi
  hr

  # conclusion
  echo -e "${BLUE}[总评]${NC}  ${total}/100（${overall}）  $(bar "$total")"
  if [[ "$total" -ge 85 ]]; then
    ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then
    ok "结论：整体不错，日常中转/落地够用，建议关注路由与邻居波动。"
  elif [[ "$total" -ge 55 ]]; then
    warn "结论：整体一般，建议换机房/换商家或降低用途预期。"
  else
    bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi
  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${PURPLE}================================================================${NC}"
}

# ---------- run all ----------
run_all() {
  gather_system
  gather_ip
  run_ping_all
  run_mtr
  run_disk
  run_streaming
  run_tcp_real
  overall_summary
}

run_silent_all_then_summary() {
  SILENT=1
  info "正在后台静默执行检测（2~8 + 10），完成后输出最终✅总结..."
  gather_system
  gather_ip
  run_ping_all
  run_mtr
  run_disk
  run_streaming
  run_tcp_real
  SILENT=0
  overall_summary
}

# ---------- menu ----------
menu() {
  while true; do
    echo -e "${PURPLE}====================== VPS 一键体检 菜单 ======================${NC}"
    echo -e "Targets: ${CYAN}${TARGETS[*]}${NC}  ${GRAY}(MTR 默认用第一个 Target)${NC}"
    echo
    echo "  1) 设置测试目标（Targets）"
    echo "  2) 基本信息（系统/CPU/RAM/磁盘占用/虚拟化）"
    echo "  3) 公网信息（IPv4 / Geo / ASN / ISP）"
    echo "  4) 网络 Ping 测试（所有 Targets）"
    echo "  5) 路由 MTR 测试（仅第一个 Target）"
    echo "  6) 安装 mtr-tiny（Debian/Ubuntu）"
    echo "  7) 磁盘 dd 测速（输出速度）"
    echo "  8) 流媒体检测（YouTube/动画疯/Netflix/Disney+/TikTok/Prime/Max）"
    echo "  9) 一键全跑（2~8 + 10）并输出最终总结（会显示全过程）"
    echo "  10) TCP 真实链路测试（curl 握手/TTFB/下载，更贴近代理体验）"
    echo "  R) 后台静默全跑（2~8 + 10），只输出最终✅总结报告（不刷屏）"
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
      9) SILENT=0; run_all; pause ;;
      10) SILENT=0; run_tcp_real; pause ;;
      r|R) run_silent_all_then_summary; pause ;;
      0|q|Q) ok "Bye."; exit 0 ;;
      *) warn "无效选择：${c:-空}"; pause ;;
    esac
  done
}

# ---------- entry ----------
menu
