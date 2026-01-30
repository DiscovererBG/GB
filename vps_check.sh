#!/usr/bin/env bash
# =========================================================
# VPS Health + Streaming Check (Read-only) - Menu Edition
# - 菜单模式：System / IP / Ping / MTR / Disk / Streaming
# - R：后台静默全跑(2~8)，只输出最终✅总结报告（不刷屏）
# - 修复：MTR 终点 lastLoss/lastAvg 解析
# - 增强：公网查询 HTTPS + 多备用源；dd 速度解析更稳
# - 可选：--redact 自动打码（Host/IPv4）
#
# Usage:
#   bash <(curl -fsSL "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh")
#   或：
#   chmod +x vps_check.sh && ./vps_check.sh
#   ./vps_check.sh --redact
#
# NOTE:
# - 默认只读检测，不改系统配置（除非你在菜单选 6 安装 mtr-tiny）
# - 流媒体检测 best-effort（最终以登录播放为准）
# =========================================================

set -euo pipefail

# ---------- args ----------
REDACT=0
if [[ "${1:-}" == "--redact" ]]; then REDACT=1; fi

# ---------- TTY + color ----------
IS_TTY=0
[[ -t 1 ]] && IS_TTY=1

if [[ "$IS_TTY" -eq 1 ]]; then
  RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; GRAY="\033[90m"; NC="\033[0m"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; GRAY=""; NC=""
fi

QUIET=0  # R 模式会把它置 1

ok()   { [[ "$QUIET" -eq 1 ]] && return 0; echo -e "${GREEN}✅ $*${NC}"; }
warn() { [[ "$QUIET" -eq 1 ]] && return 0; echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { [[ "$QUIET" -eq 1 ]] && return 0; echo -e "${RED}❌ $*${NC}"; }
info() { [[ "$QUIET" -eq 1 ]] && return 0; echo -e "${CYAN}ℹ️  $*${NC}"; }
hr()   { [[ "$QUIET" -eq 1 ]] && return 0; echo -e "${BLUE}---------------------------------------------------------${NC}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- defaults ----------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=10
DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# ---------- helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num()  { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

pause() { read -r -p "回车继续..." _ || true; }

mask_ipv4() {
  local ip="${1:-}"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$ip" | awk -F. '{print $1"."$2".***."$4}'
  else
    echo "$ip"
  fi
}
mask_host() {
  local h="${1:-}"
  [[ -z "$h" ]] && { echo ""; return; }
  # vultr -> v***r / hostname -> h***e
  local n=${#h}
  if [[ "$n" -le 3 ]]; then echo "***"; return; fi
  echo "${h:0:1}***${h: -1}"
}

bar() {
  # bar score 0-100
  local s="${1:-0}"
  local blocks=$(( s / 10 ))
  local i
  local out=""
  for ((i=0;i<10;i++)); do
    if (( i < blocks )); then out+="█"; else out+="░"; fi
  done
  echo "$out"
}

grade() {
  local x="$1"
  if [[ "$x" -ge 85 ]]; then echo "优秀"
  elif [[ "$x" -ge 70 ]]; then echo "良好"
  elif [[ "$x" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}

# ---------- global state ----------
RUN_SYS=0 RUN_IP=0 RUN_PING=0 RUN_MTR=0 RUN_DISK=0 RUN_STREAM=0

HOSTNAME_=""; OS_=""; KERNEL_=""; UPTIME_=""; CPU_=""; CORES_=""; RAM_=""; SWAP_=""; LOAD_=""; VIRT_=""; DISKROOT_=""
IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"
TARGETS=("${DEFAULT_TARGETS[@]}")

# ping summary
PING_TOTAL_TARGETS=0
PING_GOOD=0; PING_WARN=0; PING_BAD=0
PING_WORST_LOSS=""; PING_WORST_AVG=""

# mtr summary
MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"

# disk summary
DISK_SPEED_RAW="unknown"; DISK_MBPS=""; DISK_RATING="unknown"

# stream summary
YT_CC="unknown"; YT_OK="unknown"
AG_STATUS="unknown"
NF_OK="unknown"; DP_OK="unknown"; TT_OK="unknown"; PV_OK="unknown"; MX_OK="unknown"

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

# ---------- 2) system ----------
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

  [[ "$QUIET" -eq 1 ]] && return 0
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

# ---------- 3) public ip ----------
curl_get() {
  # curl_get URL (quiet)
  curl -4 -s --max-time 6 -A "Mozilla/5.0" "$1" 2>/dev/null || true
}

gather_ip() {
  RUN_IP=1
  IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"

  if ! need_cmd curl; then
    [[ "$QUIET" -eq 1 ]] || bad "缺少 curl，无法查询公网信息。"
    return 0
  fi

  # 多备用源拿 IPv4
  local ip=""
  for u in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com" \
    "https://checkip.amazonaws.com"
  do
    ip="$(curl_get "$u" | tr -d ' \r\n')"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break || ip=""
  done
  [[ -n "$ip" ]] && IPV4_="$ip"

  # 用 ipwho.is (HTTPS) 查地理/ASN/ISP
  local json=""
  json="$(curl_get "https://ipwho.is/${IPV4_}")"
  if echo "$json" | grep -q '"success":true'; then
    # country, region, city
    GEO_="$(echo "$json" | sed -n 's/.*"country":"\([^"]*\)".*"region":"\([^"]*\)".*"city":"\([^"]*\)".*/\1, \2, \3/p' | head -n1)"
    ASN_="$(echo "$json" | sed -n 's/.*"connection":{[^}]*"asn":\([0-9]\+\).*/AS\1/p' | head -n1)"
    ORG_="$(echo "$json" | sed -n 's/.*"connection":{[^}]*"org":"\([^"]*\)".*/\1/p' | head -n1)"
  fi

  [[ "$QUIET" -eq 1 ]] && return 0
  echo -e "${BLUE}--- 公网信息 ---${NC}"
  echo "IPv4      : ${IPV4_}"
  echo "Geo       : ${GEO_}"
  echo "ASN       : ${ASN_}"
  echo "ISP/Org   : ${ORG_}"
  hr
}

# ---------- 4) ping ----------
ping_once() {
  local target="$1" interval="$2"
  ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null
}

ping_test_one() {
  local target="$1"

  [[ "$QUIET" -eq 1 ]] || echo -e "${BLUE}--- Ping：${target} (${PING_COUNT} packets) ---${NC}"

  if ! need_cmd ping; then
    [[ "$QUIET" -eq 1 ]] || warn "没有 ping 命令，跳过。"
    return 0
  fi

  local out loss avg min max mdev
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    [[ "$QUIET" -eq 1 ]] || warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  avg="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')"
  min="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $1}' | awk '{print $1}')"
  max="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $3}' | awk '{print $1}')"
  mdev="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $4}' | awk '{print $1}')"

  loss="$(safe_num "$loss")"
  avg="$(safe_num "$avg")"; min="$(safe_num "$min")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  if [[ "$QUIET" -eq 0 ]]; then
    echo "Loss      : ${loss:-?}%"
    echo "RTT ms    : min=${min:-?} avg=${avg:-?} max=${max:-?} mdev=${mdev:-?}"
  fi

  local rating="WARN"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="GOOD"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="WARN"
  else rating="BAD"
  fi

  if [[ "$rating" == "GOOD" ]]; then [[ "$QUIET" -eq 1 ]] || ok "丢包：优秀（<=1%）"; ((PING_GOOD++)) || true
  elif [[ "$rating" == "WARN" ]]; then [[ "$QUIET" -eq 1 ]] || warn "丢包：一般（1%~5%）"; ((PING_WARN++)) || true
  else [[ "$QUIET" -eq 1 ]] || bad "丢包：偏高（>5%）"; ((PING_BAD++)) || true
  fi

  if [[ -n "${avg:-}" && "$QUIET" -eq 0 ]]; then
    if f_lt "$avg" "80"; then ok "延迟：优秀（<80ms）"
    elif f_lt "$avg" "150"; then warn "延迟：一般（80~150ms）"
    else warn "延迟：偏高（>=150ms）"
    fi
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

  [[ "$QUIET" -eq 1 ]] || echo
}

run_ping_all() {
  RUN_PING=1
  PING_TOTAL_TARGETS="${#TARGETS[@]}"
  PING_GOOD=0; PING_WARN=0; PING_BAD=0
  PING_WORST_LOSS=""; PING_WORST_AVG=""

  for t in "${TARGETS[@]}"; do ping_test_one "$t"; done

  [[ "$QUIET" -eq 1 ]] && return 0
  hr
  info "Ping 小结：Targets=${PING_TOTAL_TARGETS} | GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% worstAvg=${PING_WORST_AVG:-?}ms"
  hr
}

# ---------- 6) install mtr ----------
install_mtr() {
  if ! need_cmd apt; then
    warn "系统没有 apt（非 Debian/Ubuntu）或未找到 apt，跳过安装。"
    return 0
  fi
  info "将执行：apt update && apt install -y mtr-tiny"
  apt update && apt install -y mtr-tiny
  ok "mtr 安装完成。"
}

# ---------- 5) mtr ----------
run_mtr() {
  RUN_MTR=1
  local target="${TARGETS[0]}"

  [[ "$QUIET" -eq 1 ]] || echo -e "${BLUE}--- MTR：${target} (${MTR_COUNT} cycles) ---${NC}"

  if ! need_cmd mtr; then
    [[ "$QUIET" -eq 1 ]] || warn "未安装 mtr。（可在菜单选择安装 mtr-tiny）"
    MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"
    [[ "$QUIET" -eq 1 ]] || hr
    return 0
  fi

  local out last_line last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"

  # 只在非静默模式打印过程
  if [[ "$QUIET" -eq 0 ]]; then
    echo "$out" | head -n 3
    echo -e "${GRAY}...（中间省略）...${NC}"
    echo "$out" | tail -n 5
  fi

  last_line="$(echo "$out" | tail -n 1)"

  # ✅ 修复：用“从末尾倒数列”取 Loss% 和 Avg，更稳
  # 列结构(从末尾)：StDev Wrst Best Avg Last Snt Loss%
  last_loss="$(echo "$last_line" | awk '{print $(NF-6)}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $(NF-3)}')"
  last_loss="$(safe_num "$last_loss")"
  last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

  if [[ "$QUIET" -eq 0 ]]; then
    echo
    echo "终点(最后一跳) : Loss=${last_loss:-?}%  Avg=${last_avg:-?} ms"
    info "提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。"
  fi

  if [[ -n "${last_loss:-}" ]]; then
    if f_le "$last_loss" "1.0"; then [[ "$QUIET" -eq 1 ]] || ok "路由质量：优秀"; MTR_RATING="GOOD"
    elif f_le "$last_loss" "5.0"; then [[ "$QUIET" -eq 1 ]] || warn "路由质量：一般"; MTR_RATING="WARN"
    else [[ "$QUIET" -eq 1 ]] || bad "路由质量：偏差"; MTR_RATING="BAD"
    fi
  else
    MTR_RATING="unknown"
  fi

  [[ "$QUIET" -eq 1 ]] || hr
}

# ---------- 7) disk ----------
to_mbps() {
  # input: "813 MB/s" or "1.2 GB/s" or "900 kB/s"
  local num unit
  num="$(echo "${1:-}" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "${1:-}" | awk '{print $2}' 2>/dev/null || true)"
  num="$(safe_num "$num")"
  [[ -z "$num" || -z "$unit" ]] && { echo ""; return; }

  case "$unit" in
    GB/s) awk -v x="$num" 'BEGIN{printf "%.2f", x*1024}' ;;
    MB/s) awk -v x="$num" 'BEGIN{printf "%.2f", x}' ;;
    kB/s|KB/s) awk -v x="$num" 'BEGIN{printf "%.2f", x/1024}' ;;
    B/s) awk -v x="$num" 'BEGIN{printf "%.2f", x/1024/1024}' ;;
    *) echo "" ;;
  esac
}

run_disk() {
  RUN_DISK=1
  [[ "$QUIET" -eq 1 ]] || echo -e "${BLUE}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"

  if ! need_cmd dd; then
    [[ "$QUIET" -eq 1 ]] || warn "dd 不存在，跳过。"
    DISK_SPEED_RAW="unknown"; DISK_MBPS=""; DISK_RATING="unknown"
    [[ "$QUIET" -eq 1 ]] || hr
    return 0
  fi

  local tmp out speed mbps
  tmp="/tmp/vps_disk_test.$$"
  out="$(dd if=/dev/zero of="$tmp" bs=1M count="${DISK_TEST_MB}" conv=fdatasync 2>&1 || true)"
  rm -f "$tmp" >/dev/null 2>&1 || true

  speed="$(echo "$out" | tail -n 1 | awk -F', ' '{print $NF}' | sed 's/^[ \t]*//')"
  DISK_SPEED_RAW="${speed:-unknown}"

  mbps="$(to_mbps "$DISK_SPEED_RAW")"
  DISK_MBPS="${mbps:-}"

  if [[ -n "${DISK_MBPS:-}" ]]; then
    if f_ge "$DISK_MBPS" "200"; then DISK_RATING="GOOD"; [[ "$QUIET" -eq 1 ]] || ok "磁盘：不错（>=200 MB/s）"
    elif f_ge "$DISK_MBPS" "80"; then DISK_RATING="WARN"; [[ "$QUIET" -eq 1 ]] || warn "磁盘：一般（80~200 MB/s）"
    else DISK_RATING="BAD"; [[ "$QUIET" -eq 1 ]] || warn "磁盘：偏低（<80 MB/s）"
    fi
  else
    DISK_RATING="unknown"
    [[ "$QUIET" -eq 1 ]] || warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
  fi

  [[ "$QUIET" -eq 1 ]] && return 0
  echo "Result    : ${DISK_SPEED_RAW}"
  hr
}

# ---------- 8) streaming ----------
fetch()    { curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
head_req() { curl -I -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
code_of()  { curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }

run_streaming() {
  RUN_STREAM=1
  if ! need_cmd curl; then
    [[ "$QUIET" -eq 1 ]] || bad "缺少 curl，无法做流媒体检测。"
    return 0
  fi

  [[ "$QUIET" -eq 1 ]] || echo -e "${BLUE}--- 流媒体解锁检测（详细，best-effort）---${NC}"

  # YouTube
  local yt_code yt_html yt_cc
  yt_code="$(code_of "https://www.youtube.com/premium")"
  yt_html="$(fetch "https://www.youtube.com/premium")"
  yt_cc="$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d: -f2 | tr -d '"')"
  YT_CC="${yt_cc:-unknown}"
  if [[ "$yt_code" == "200" || "$yt_code" == "302" ]]; then YT_OK="OK"; else YT_OK="BAD"; fi
  [[ "$QUIET" -eq 1 ]] || echo "YouTube Premium HTTP : ${yt_code}  countryCode: ${YT_CC}"

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
  [[ "$QUIET" -eq 1 ]] || echo "动画疯 HTTP         : ${ag_code}"

  # Netflix
  local nf_code
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then NF_OK="OK"; else NF_OK="WARN"; fi
  [[ "$QUIET" -eq 1 ]] || echo "Netflix HTTP         : ${nf_code}"

  # Disney+
  local dp_code
  dp_code="$(code_of "https://www.disneyplus.com/")"
  if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then DP_OK="OK"; else DP_OK="WARN"; fi
  [[ "$QUIET" -eq 1 ]] || echo "Disney+ HTTP         : ${dp_code}"

  # TikTok
  local tt_code tt_head tt_region
  tt_code="$(code_of "https://www.tiktok.com/")"
  tt_head="$(head_req "https://www.tiktok.com/")"
  tt_region="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="x-tt-region"{print $2}' | tr -d '\r' | head -n1)"
  if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then TT_OK="OK"
  elif [[ "$tt_code" == "403" ]]; then TT_OK="BAD"
  else TT_OK="WARN"
  fi
  [[ "$QUIET" -eq 1 ]] || echo "TikTok HTTP          : ${tt_code}  x-tt-region: ${tt_region:-unknown}"

  # Prime Video
  local pv_code
  pv_code="$(code_of "https://www.primevideo.com/")"
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then PV_OK="OK"; else PV_OK="WARN"; fi
  [[ "$QUIET" -eq 1 ]] || echo "PrimeVideo HTTP      : ${pv_code}"

  # Max
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then MX_OK="OK"; else MX_OK="WARN"; fi
  [[ "$QUIET" -eq 1 ]] || echo "Max(HBO) HTTP         : ${mx_code}"

  [[ "$QUIET" -eq 1 ]] && return 0
  hr
  info "提示：Netflix/Disney+/Max/Prime 仅能判断“可访问/疑似限制”，最终以登录播放为准。"
  info "TikTok 易受 Cloudflare/风控影响，建议多测几次综合判断。"
  hr
}

# ---------- final summary (beautified) ----------
overall_summary() {
  # scoring
  local net_score=0 disk_score=0 stream_score=0 total=0
  local net_grade="未知" disk_grade="未知" stream_grade="未知" overall=""

  # Net score
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"
    [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  else
    net_score=0
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    [[ "$MTR_RATING" == "GOOD" ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')" || true
    [[ "$MTR_RATING" == "BAD"  ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')" || true
  fi
  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"

  # Disk score
  if [[ "$RUN_DISK" -eq 1 ]]; then
    if [[ "$DISK_RATING" == "GOOD" ]]; then disk_score=90
    elif [[ "$DISK_RATING" == "WARN" ]]; then disk_score=70
    elif [[ "$DISK_RATING" == "BAD" ]]; then disk_score=50
    else disk_score=0
    fi
  else
    disk_score=0
  fi

  # Stream score
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

  net_grade="$(grade "$net_score")"
  disk_grade="$(grade "$disk_score")"
  stream_grade="$(grade "$stream_score")"

  # total weights auto-adjust
  local w_net=50 w_disk=20 w_stream=30
  local used=0
  total=0
  if [[ "$RUN_PING" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$net_score"   -v w="$w_net"    'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_net)) || true; fi
  if [[ "$RUN_DISK" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$disk_score"  -v w="$w_disk"   'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_disk)) || true; fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$stream_score" -v w="$w_stream" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_stream)) || true; fi
  if [[ "$used" -gt 0 ]]; then total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')" ; else total=0; fi
  overall="$(grade "$total")"

  # redact
  local show_host="$HOSTNAME_"
  local show_ip="$IPV4_"
  if [[ "$REDACT" -eq 1 ]]; then
    show_host="$(mask_host "$HOSTNAME_")"
    show_ip="$(mask_ipv4 "$IPV4_")"
  fi

  echo -e "${BLUE}====================== ✅ VPS 体检总结报告 ======================${NC}"

  echo -e "${BLUE}[基础信息]${NC}"
  if [[ "$RUN_SYS" -eq 1 ]]; then
    echo "  Host : ${show_host}"
    echo "  OS   : ${OS_}"
    echo "  Kern : ${KERNEL_} | Virt=${VIRT_}"
    echo "  CPU  : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
    echo "  Disk : / ${DISKROOT_}"
  else
    echo "  未检测（建议先跑 9 或 R）"
  fi
  if [[ "$RUN_IP" -eq 1 ]]; then
    echo "  IPv4 : ${show_ip}"
    echo "  Geo  : ${GEO_}"
    echo "  ASN  : ${ASN_} | ISP=${ORG_}"
  else
    echo "  公网信息：未检测"
  fi

  echo
  echo -e "${BLUE}[网络]${NC}  ${net_score}/100（${net_grade}）  $(bar "$net_score")"
  if [[ "$RUN_PING" -eq 1 ]]; then
    echo "  Ping : GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% | worstAvg=${PING_WORST_AVG:-?}ms"
  else
    echo "  Ping : 未检测"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    echo "  MTR  : target=${TARGETS[0]} | lastLoss=${MTR_LASTLOSS:-?}% | lastAvg=${MTR_LASTAVG:-?}ms | rating=${MTR_RATING}"
  else
    echo "  MTR  : 未检测（可装 mtr-tiny 或跳过）"
  fi

  echo
  echo -e "${BLUE}[磁盘]${NC}  ${disk_score}/100（${disk_grade}）  $(bar "$disk_score")"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    echo "  dd   : ${DISK_SPEED_RAW} | approx=${DISK_MBPS:-?} MB/s | rating=${DISK_RATING}"
  else
    echo "  未检测"
  fi

  echo
  echo -e "${BLUE}[流媒体]${NC}  ${stream_score}/100（${stream_grade}）  $(bar "$stream_score")"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    echo "  YouTube=${YT_OK}(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  else
    echo "  未检测"
  fi

  echo
  echo -e "${BLUE}[总评]${NC}  ${total}/100（${overall}）  $(bar "$total")"
  if [[ "$total" -ge 85 ]]; then
    echo -e "  ${GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${NC}"
  elif [[ "$total" -ge 70 ]]; then
    echo -e "  ${GREEN}✅ 结论：整体不错，日常用途够用，关注高峰期波动即可。${NC}"
  elif [[ "$total" -ge 55 ]]; then
    echo -e "  ${YELLOW}⚠️ 结论：整体一般，建议降低用途预期或换机房/换商家。${NC}"
  else
    echo -e "  ${RED}❌ 结论：整体偏弱，不建议做关键落地或高稳定需求用途。${NC}"
  fi

  echo
  echo -e "${CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${NC}"
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
  overall_summary
}

run_all_quiet() {
  # 静默执行：不刷屏，只保留最终总结
  QUIET=1
  gather_system >/dev/null 2>&1 || true
  gather_ip     >/dev/null 2>&1 || true
  run_ping_all  >/dev/null 2>&1 || true
  run_mtr       >/dev/null 2>&1 || true
  run_disk      >/dev/null 2>&1 || true
  run_streaming >/dev/null 2>&1 || true
  QUIET=0
  overall_summary
}

# ---------- menu ----------
menu() {
  while true; do
    echo -e "${BLUE}====================== VPS 一键体检 菜单 ======================${NC}"
    printf "Targets: %s %b(MTR 默认用第一个 Target)%b\n\n" "${TARGETS[*]}" "${GRAY}" "${NC}"
    echo "  1) 设置测试目标（Targets）"
    echo "  2) 基本信息（系统/CPU/RAM/磁盘占用/虚拟化）"
    echo "  3) 公网信息（IPv4 / Geo / ASN / ISP）"
    echo "  4) 网络 Ping 测试（所有 Targets）"
    echo "  5) 路由 MTR 测试（仅第一个 Target）"
    echo "  6) 安装 mtr-tiny（Debian/Ubuntu）"
    echo "  7) 磁盘 dd 测速（输出速度）"
    echo "  8) 流媒体检测（YouTube/动画疯/Netflix/Disney+/TikTok/Prime/Max）"
    echo "  9) 一键全跑（2~8）并输出最终总结（会显示全过程）"
    echo "  R) 后台静默全跑（2~8），只输出最终✅总结报告（不刷屏）"
    echo "  0) 退出"
    echo -e "${BLUE}---------------------------------------------------------${NC}"

    read -r -p "选择 [0-9/R]: " c || true
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
      r|R)
        echo -e "${CYAN}ℹ️  正在后台执行检测（2~8），完成后输出最终✅总结...${NC}"
        run_all_quiet
        pause
        ;;
      0|q|Q)
        ok "Bye."
        exit 0
        ;;
      *)
        warn "无效选择：${c:-空}（请输入 0-9 或 R）"
        pause
        ;;
    esac
  done
}

# ---------- entry ----------
menu
