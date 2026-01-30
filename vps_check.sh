#!/usr/bin/env bash
# =========================================================
# VPS Health + Streaming + TCP Check (Read-only) - Menu Edition
# - 菜单：System / IP / Ping / MTR / Disk / Streaming / TCP
# - 10) TCP 真实链路测试：多源测速取中位数（更贴近代理体验）
# - R) 后台静默全跑（2~8+10），只输出最终✅总结（不刷屏）
# - 修复：MTR 终点统计解析、Ping 小结中文、总结进度条乱码(????)问题
# - 美化：优秀/良好/一般/偏弱 颜色与进度条一致
#
# Usage:
#   bash <(curl -fsSL "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh")
#   或保存到本地：chmod +x vps_check.sh && ./vps_check.sh
#
# NOTE:
# - 只读检测，不改系统配置（除非你选择“安装 mtr”）
# =========================================================

set -euo pipefail

# ---------- color / ui ----------
supports_color() {
  [[ -t 1 ]] || return 1
  [[ "${TERM:-}" != "dumb" ]] || return 1
  return 0
}

if supports_color; then
  RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; MAGENTA="\033[35m"; GRAY="\033[90m"; NC="\033[0m"
  BRED="\033[41m"; BGREEN="\033[42m"; BYELLOW="\033[43m"; BCYAN="\033[46m"; BGRAY="\033[100m"; BNC="\033[0m"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""; GRAY=""; NC=""
  BRED=""; BGREEN=""; BYELLOW=""; BCYAN=""; BGRAY=""; BNC=""
fi

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

# TCP test (multi-source median)
TCP_RANGE_MB=16
TCP_MAXTIME=12
TCP_SOURCES=(
  "cloudflare|https://speed.cloudflare.com/__down?bytes=16777216"
  "hetzner|https://speed.hetzner.de/100MB.bin"
  "ovh|https://proof.ovh.net/files/100Mb.dat"
  "cachefly|https://cachefly.cachefly.net/100mb.test"
)

# ---------- numeric helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

median_of_lines() { # read numbers each line -> median
  awk 'NF{a[++n]=$1} END{
    if(n==0){exit 0}
    asort(a)
    if(n%2==1){print a[(n+1)/2]}
    else{print (a[n/2]+a[n/2+1])/2}
  }'
}

clamp01() { awk -v x="$1" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}'; }

# ---------- progress bar (NO block chars -> avoid ???? on some terminals) ----------
# Use background color spaces for filled part (safe in SSH), fallback to ascii if no color.
bar() {
  local score="${1:-0}" c="${2:-good}" w=28
  local fill=$(( score*w/100 ))
  local empty=$(( w-fill ))
  local fc="$BGREEN" ec="$BGRAY"

  case "$c" in
    good) fc="$BGREEN" ;;
    ok)   fc="$BCYAN" ;;
    warn) fc="$BYELLOW" ;;
    bad)  fc="$BRED" ;;
    *)    fc="$BGREEN" ;;
  esac

  if supports_color; then
    printf "["
    # filled
    if (( fill>0 )); then
      printf "%b" "${fc}"
      printf "%*s" "$fill" ""
      printf "%b" "${BNC}"
    fi
    # empty
    if (( empty>0 )); then
      printf "%b" "${ec}"
      printf "%*s" "$empty" ""
      printf "%b" "${BNC}"
    fi
    printf "]"
  else
    # pure ascii fallback
    local i
    printf "["
    for ((i=0;i<fill;i++)); do printf "#"; done
    for ((i=0;i<empty;i++)); do printf "."; done
    printf "]"
  fi
}

# ---------- grade + color ----------
grade_text() {
  local x="$1"
  if [[ "$x" -ge 85 ]]; then echo "优秀"
  elif [[ "$x" -ge 70 ]]; then echo "良好"
  elif [[ "$x" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}
grade_color_tag() {
  local g="$1"
  case "$g" in
    优秀) echo "good" ;;
    良好) echo "ok" ;;
    一般) echo "warn" ;;
    偏弱) echo "bad" ;;
    *) echo "warn" ;;
  esac
}
grade_colored() {
  local g="$1"
  case "$g" in
    优秀) echo -e "${GREEN}${g}${NC}" ;;
    良好) echo -e "${CYAN}${g}${NC}" ;;
    一般) echo -e "${YELLOW}${g}${NC}" ;;
    偏弱) echo -e "${RED}${g}${NC}" ;;
    *) echo "$g" ;;
  esac
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
TCP_TLS_MS=""
TCP_TTFB_MS=""
TCP_DL_MBPS=""
TCP_BEST_SRC=""
TCP_BEST_MBPS=""
TCP_EVAL="unknown"
TCP_SCORE=0
TCP_GRADE="偏弱"

# ---------- helpers ----------
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

fetch()   { curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
head_req(){ curl -I -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
code_of() { curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }

# ---------- system ----------
gather_system() {
  RUN_SYS=1
  HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
  UPTIME_="$(uptime -p 2>/dev/null | sed 's/^up *//' || echo unknown)"
  OS_="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || echo unknown)"
  KERNEL_="$(uname -r 2>/dev/null || echo unknown)"
  CPU_="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || echo unknown)"
  CORES_="$(nproc 2>/dev/null || echo 1)"
  RAM_="$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  SWAP_="$(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  LOAD_="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || echo "0.00, 0.00, 0.00")"
  VIRT_="unknown"
  if need_cmd systemd-detect-virt; then VIRT_="$(systemd-detect-virt 2>/dev/null || echo none)"; fi
  DISKROOT_="$(df -hP / 2>/dev/null | tail -n 1 | awk '{print $3"/"$2" ("$5")"}' || echo unknown)"

  echo -e "${MAGENTA}--- 基本信息 ---${NC}"
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

# ---------- ip ----------
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
  echo "IPv4      : ${IPV4_}"
  echo "Geo       : ${GEO_}"
  echo "ASN       : ${ASN_}"
  echo "ISP/Org   : ${ORG_}"
  hr
}

# ---------- ping ----------
ping_once() {
  local target="$1" interval="$2"
  ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null
}

parse_ping_rtt() {
  # input: ping output; output: min avg max mdev (blank if not found)
  # Works for both:
  #   rtt min/avg/max/mdev = 1.0/2.0/3.0/0.1 ms
  #   round-trip min/avg/max = 1.0/2.0/3.0 ms
  local out="$1"
  local line
  line="$(echo "$out" | awk '/rtt min\/avg\/max\/mdev|round-trip min\/avg\/max/{print; exit}')"
  if [[ -z "${line:-}" ]]; then
    echo "||||"  # empty
    return 0
  fi

  local nums
  nums="$(echo "$line" | awk -F'=' '{print $2}' | tr -d ' ms' | tr -d '\r' | awk '{print $1}')"
  # nums could be "1/2/3/0.1" or "1/2/3"
  local min avg max mdev
  min="$(echo "$nums" | awk -F/ '{print $1}')"
  avg="$(echo "$nums" | awk -F/ '{print $2}')"
  max="$(echo "$nums" | awk -F/ '{print $3}')"
  mdev="$(echo "$nums" | awk -F/ '{print $4}')"

  echo "$(safe_num "$min")|$(safe_num "$avg")|$(safe_num "$max")|$(safe_num "$mdev")"
}

ping_test_one() {
  local target="$1"
  echo -e "${MAGENTA}--- Ping: ${target} (${PING_COUNT} packets) ---${NC}"

  if ! need_cmd ping; then
    warn "没有 ping 命令，跳过。"
    return 0
  fi

  local out loss rtt min avg max mdev
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /packet loss/){print $(i-1)} }' | awk '{print $1}' | tr -d '%')"
  loss="$(safe_num "$loss")"

  rtt="$(parse_ping_rtt "$out")"
  min="${rtt%%|*}"; rtt="${rtt#*|}"
  avg="${rtt%%|*}"; rtt="${rtt#*|}"
  max="${rtt%%|*}"; mdev="${rtt#*|}"

  echo "Loss      : ${loss:-?}%"
  echo "RTT ms    : min=${min:-?} avg=${avg:-?} max=${max:-?} mdev=${mdev:-?}"

  local rating="一般"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="优秀"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="一般"
  else rating="偏弱"
  fi

  if [[ "$rating" == "优秀" ]]; then ((PING_GOOD++)) || true
  elif [[ "$rating" == "一般" ]]; then ((PING_WARN++)) || true
  else ((PING_BAD++)) || true
  fi

  # show loss evaluation
  if [[ "$rating" == "优秀" ]]; then echo -e "${GREEN}✅ 丢包：优秀（<=1%）${NC}"
  elif [[ "$rating" == "一般" ]]; then echo -e "${YELLOW}⚠️  丢包：一般（1%~5%）${NC}"
  else echo -e "${RED}❌ 丢包：偏弱（>5%）${NC}"
  fi

  # latency eval
  if [[ -n "${avg:-}" ]]; then
    if f_lt "$avg" "80"; then echo -e "${GREEN}✅ 延迟：优秀（<80ms）${NC}"
    elif f_lt "$avg" "150"; then echo -e "${YELLOW}⚠️  延迟：一般（80~150ms）${NC}"
    else echo -e "${YELLOW}⚠️  延迟：偏高（>=150ms）${NC}"
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
  echo
}

run_ping_all() {
  RUN_PING=1
  PING_TOTAL_TARGETS="${#TARGETS[@]}"
  PING_GOOD=0; PING_WARN=0; PING_BAD=0
  PING_WORST_LOSS=""; PING_WORST_AVG=""

  for t in "${TARGETS[@]}"; do ping_test_one "$t"; done

  hr
  # 中文小结（你要求图二中文）
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

  local out last_line losscol last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"

  echo "$out" | head -n 3
  echo -e "${GRAY}...（中间省略）...${NC}"
  echo "$out" | tail -n 5

  last_line="$(echo "$out" | tail -n 1)"

  # robust: find token ending with % as loss column
  losscol="$(echo "$last_line" | awk '{
    for(i=1;i<=NF;i++){ if($i ~ /%$/){print i; exit} }
  }')"

  if [[ -n "${losscol:-}" ]]; then
    last_loss="$(echo "$last_line" | awk -v c="$losscol" '{print $c}' | tr -d '%')"
    last_avg="$(echo "$last_line" | awk -v c="$losscol" '{print $(c+3)}')" # loss% | Snt | Last | Avg
    last_loss="$(safe_num "$last_loss")"
    last_avg="$(safe_num "$last_avg")"
  else
    last_loss=""; last_avg=""
  fi

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

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
  echo "Result    : ${DISK_SPEED_RAW}"

  mbps="$(echo "$DISK_SPEED_RAW" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$DISK_SPEED_RAW" | awk '{print $2}' 2>/dev/null || true)"
  mbps="$(safe_num "$mbps")"
  if [[ -n "${mbps:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')" ; fi
    DISK_MBPS="$mbps"
    if f_ge "$mbps" "200"; then ok "磁盘：优秀（>=200 MB/s）"; DISK_RATING="GOOD"
    elif f_ge "$mbps" "80"; then warn "磁盘：良好（80~200 MB/s）"; DISK_RATING="WARN"
    else warn "磁盘：一般（<80 MB/s）"; DISK_RATING="BAD"
    fi
  else
    warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
    DISK_RATING="unknown"
  fi
  hr
}

# ---------- streaming ----------
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
  local nf_code nf_head nf_redirect
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  nf_head="$(head_req "https://www.netflix.com/title/80018499")"
  nf_redirect="$(echo "$nf_head" | awk '/^location:/I{print $2}' | tr -d '\r' | head -n1)"
  echo "Netflix HTTP         : ${nf_code}"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then
    [[ -n "${nf_redirect:-}" ]] && ok "Netflix：可访问（地区跳转属正常）" || ok "Netflix：可访问（需登录/播放验证）"
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
    [[ -n "${tt_region:-}" ]] && ok "TikTok：可访问（推测地区 ${tt_region}）" || warn "TikTok：可访问但无法判断地区（cf-ray=${tt_cf:-n/a}）"
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
  echo "Max(HBO) HTTP        : ${mx_code}"
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
  info "TikTok 易受风控/CF 影响，建议多测几次综合判断。"
  hr
}

# ---------- TCP real link (multi-source, median) ----------
tcp_one_source() {
  local name="$1" url="$2"

  # Range bytes (16MB default)
  local bytes=$((TCP_RANGE_MB*1024*1024))
  # curl metrics:
  # time_appconnect (TLS handshake to server) ; time_starttransfer (TTFB) ; speed_download (B/s) ; http_code
  local out
  out="$(curl -L -s -o /dev/null --max-time "${TCP_MAXTIME}" -r "0-$((bytes-1))" \
    -A "Mozilla/5.0" \
    -w "code=%{http_code} tls=%{time_appconnect} ttfb=%{time_starttransfer} spd=%{speed_download}\n" \
    "$url" 2>/dev/null || true)"

  local code tls ttfb spd
  code="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^code=/){sub("code=","",$i); print $i}}')"
  tls="$(echo "$out"  | awk '{for(i=1;i<=NF;i++) if($i ~ /^tls=/){sub("tls=","",$i); print $i}}')"
  ttfb="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^ttfb=/){sub("ttfb=","",$i); print $i}}')"
  spd="$(echo "$out"  | awk '{for(i=1;i<=NF;i++) if($i ~ /^spd=/){sub("spd=","",$i); print $i}}')"

  # normalize
  tls="$(safe_num "$tls")"
  ttfb="$(safe_num "$ttfb")"
  spd="$(safe_num "$spd")"
  [[ -z "${code:-}" ]] && code="000"

  # TLS/TTFB seconds -> ms
  local tls_ms="" ttfb_ms="" mbps=""
  if [[ -n "${tls:-}" ]]; then tls_ms="$(awk -v x="$tls" 'BEGIN{printf "%.0f", x*1000}')" ; fi
  if [[ -n "${ttfb:-}" ]]; then ttfb_ms="$(awk -v x="$ttfb" 'BEGIN{printf "%.0f", x*1000}')" ; fi
  if [[ -n "${spd:-}" ]]; then mbps="$(awk -v x="$spd" 'BEGIN{printf "%.2f", x*8/1000000}')" ; fi

  echo "${name}|${code}|${tls_ms:-}|${ttfb_ms:-}|${mbps:-}"
}

run_tcp() {
  RUN_TCP=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做 TCP 真实链路测试。"
    return 0
  fi

  echo -e "${MAGENTA}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${NC}"

  # header show ONLY names (no url)  ✅你要求修复
  local names=()
  local s
  for s in "${TCP_SOURCES[@]}"; do names+=("${s%%|*}"); done
  info "范围：${TCP_RANGE_MB}MB | maxTime=${TCP_MAXTIME}s | sources=$(IFS=/; echo "${names[*]}")（能测几个算几个）"

  local tls_list="" ttfb_list="" dl_list=""
  local best_mbps=0 best_src=""

  local lines=()
  local src name url res code tls_ms ttfb_ms mbps
  for src in "${TCP_SOURCES[@]}"; do
    name="${src%%|*}"
    url="${src#*|}"
    res="$(tcp_one_source "$name" "$url")"
    code="$(echo "$res" | awk -F'|' '{print $2}')"
    tls_ms="$(echo "$res" | awk -F'|' '{print $3}')"
    ttfb_ms="$(echo "$res" | awk -F'|' '{print $4}')"
    mbps="$(echo "$res" | awk -F'|' '{print $5}')"

    if [[ "$code" == "000" || -z "${code:-}" ]]; then
      echo -e "• ${name}: DL=?Mbps  code=000（跳过）"
      continue
    fi

    # keep only success-like codes
    if [[ "$code" != "200" && "$code" != "206" && "$code" != "302" && "$code" != "301" ]]; then
      echo -e "• ${name}: DL=${mbps:-?}Mbps  code=${code}（跳过）"
      continue
    fi

    echo -e "• ${name}: TLS=${tls_ms:-?}ms  TTFB=${ttfb_ms:-?}ms  DL=${mbps:-?}Mbps  code=${code}"

    # collect numbers
    if is_number "${tls_ms:-}"; then tls_list+="${tls_ms}"$'\n'; fi
    if is_number "${ttfb_ms:-}"; then ttfb_list+="${ttfb_ms}"$'\n'; fi
    if is_number "${mbps:-}"; then dl_list+="${mbps}"$'\n'; fi

    if is_number "${mbps:-}"; then
      awk -v a="$mbps" -v b="$best_mbps" 'BEGIN{exit (a>b)?0:1}' && best_mbps="$mbps" && best_src="$name" || true
    fi
  done

  echo

  # median
  local med_tls="" med_ttfb="" med_dl=""
  if [[ -n "${tls_list:-}" ]]; then med_tls="$(printf "%s" "$tls_list" | median_of_lines | awk '{printf "%.1f",$1}')" ; fi
  if [[ -n "${ttfb_list:-}" ]]; then med_ttfb="$(printf "%s" "$ttfb_list" | median_of_lines | awk '{printf "%.1f",$1}')" ; fi
  if [[ -n "${dl_list:-}" ]]; then med_dl="$(printf "%s" "$dl_list" | median_of_lines | awk '{printf "%.2f",$1}')" ; fi

  TCP_TLS_MS="${med_tls:-}"
  TCP_TTFB_MS="${med_ttfb:-}"
  TCP_DL_MBPS="${med_dl:-}"
  TCP_BEST_SRC="${best_src:-}"
  TCP_BEST_MBPS="${best_mbps:-}"

  if [[ -z "${TCP_DL_MBPS:-}" ]]; then
    warn "TCP：没有拿到任何可用测速结果（可能全被阻断/超时）"
    TCP_EVAL="BAD"
    TCP_SCORE=0
    TCP_GRADE="偏弱"
    hr
    return 0
  fi

  echo -e "${GRAY}Median: TLS=${TCP_TLS_MS:-?}ms | TTFB=${TCP_TTFB_MS:-?}ms | DL=${TCP_DL_MBPS:-?}Mbps (best=${TCP_BEST_SRC:-?} ${TCP_BEST_MBPS:-?}Mbps)${NC}"

  # scoring
  # DL dominates; TLS/TTFB provide latency penalty
  local score=0
  score="$(awk -v dl="${TCP_DL_MBPS:-0}" 'BEGIN{
    if(dl>=200) s=95;
    else if(dl>=50) s=85;
    else if(dl>=10) s=70;
    else if(dl>=3) s=55;
    else s=40;
    printf "%.0f", s
  }')"

  # latency penalty
  if is_number "${TCP_TTFB_MS:-}"; then
    score="$(awk -v s="$score" -v t="${TCP_TTFB_MS}" 'BEGIN{
      p=0;
      if(t>1500) p=25;
      else if(t>800) p=15;
      else if(t>400) p=8;
      else p=0;
      s=s-p; if(s<0)s=0; printf "%.0f", s
    }')"
  fi
  TCP_SCORE="$score"
  TCP_GRADE="$(grade_text "$TCP_SCORE")"

  if [[ "$TCP_GRADE" == "优秀" ]]; then
    ok "TCP 体验：优秀（median）"
    TCP_EVAL="GOOD"
  elif [[ "$TCP_GRADE" == "良好" ]]; then
    warn "TCP 体验：良好（median）"
    TCP_EVAL="WARN"
  elif [[ "$TCP_GRADE" == "一般" ]]; then
    warn "TCP 体验：一般（median）"
    TCP_EVAL="WARN"
  else
    bad "TCP 体验：偏弱（median）"
    TCP_EVAL="BAD"
  fi

  hr
}

# ---------- overall summary ----------
overall_summary() {
  echo -e "${MAGENTA}====================== ✅ VPS 体检总结报告 ======================${NC}"

  # scores
  local net_score=0 disk_score=0 stream_score=0 tcp_score=0 total=0 used=0
  local g_net="偏弱" g_disk="偏弱" g_stream="偏弱" g_tcp="偏弱" g_total="偏弱"

  # network score from ping + mtr
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"; [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f",(g*2+w)*50/d}')"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    if [[ "$MTR_RATING" == "GOOD" ]]; then net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')" ; fi
    if [[ "$MTR_RATING" == "BAD" ]]; then  net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')" ; fi
  fi
  net_score="$(clamp01 "$net_score")"
  g_net="$(grade_text "$net_score")"

  # disk
  if [[ "$RUN_DISK" -eq 1 ]]; then
    if [[ "$DISK_RATING" == "GOOD" ]]; then disk_score=90
    elif [[ "$DISK_RATING" == "WARN" ]]; then disk_score=70
    elif [[ "$DISK_RATING" == "BAD" ]]; then disk_score=55
    else disk_score=0
    fi
  fi
  g_disk="$(grade_text "$disk_score")"

  # streaming (rough)
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
    stream_score="$(clamp01 "$stream_score")"
  fi
  g_stream="$(grade_text "$stream_score")"

  # tcp
  if [[ "$RUN_TCP" -eq 1 ]]; then
    tcp_score="$TCP_SCORE"
  fi
  g_tcp="$(grade_text "$tcp_score")"

  # total weights
  # net 40, tcp 25, stream 20, disk 15 (你主要做中转/落地/代理体验，TCP 权重提高)
  total=0; used=0
  if [[ "$RUN_PING" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$net_score" -v w=40 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=40)) || true; fi
  if [[ "$RUN_TCP" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$tcp_score" -v w=25 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=25)) || true; fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$stream_score" -v w=20 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=20)) || true; fi
  if [[ "$RUN_DISK" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$disk_score" -v w=15 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=15)) || true; fi
  if [[ "$used" -gt 0 ]]; then total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"; fi
  g_total="$(grade_text "$total")"

  # base info
  echo -e "${MAGENTA}[基础信息]${NC}"
  [[ "$RUN_SYS" -eq 1 ]] && {
    echo "Host : ${HOSTNAME_}"
    echo "OS   : ${OS_}"
    echo "Kern : ${KERNEL_} | Virt=${VIRT_}"
    echo "CPU  : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
    echo "Disk : / ${DISKROOT_}"
  } || echo "（未执行）"
  [[ "$RUN_IP" -eq 1 ]] && {
    echo "IPv4 : ${IPV4_}"
    echo "Geo  : ${GEO_}"
    echo "ASN  : ${ASN_}"
    echo "ISP  : ${ORG_}"
  } || echo "公网信息：未执行"
  hr

  # network block
  echo -e "${MAGENTA}[网络]  ${net_score}/100 ($(grade_colored "$g_net"))  $(bar "$net_score" "$(grade_color_tag "$g_net")")${NC}"
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

  # tcp
  echo -e "${MAGENTA}[TCP真实链路]  ${tcp_score}/100 ($(grade_colored "$g_tcp"))  $(bar "$tcp_score" "$(grade_color_tag "$g_tcp")")${NC}"
  if [[ "$RUN_TCP" -eq 1 ]]; then
    echo "TLS  : ${TCP_TLS_MS:-?} ms | TTFB=${TCP_TTFB_MS:-?} ms"
    echo "DL   : ${TCP_DL_MBPS:-?} Mbps (median, range=${TCP_RANGE_MB}MB, maxTime=${TCP_MAXTIME}s)"
    echo "Eval : ${TCP_EVAL}"
  else
    echo "未执行"
  fi
  hr

  # disk
  echo -e "${MAGENTA}[磁盘]  ${disk_score}/100 ($(grade_colored "$g_disk"))  $(bar "$disk_score" "$(grade_color_tag "$g_disk")")${NC}"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    echo "dd   : ${DISK_SPEED_RAW} | approx=${DISK_MBPS:-?} MB/s | rating=${DISK_RATING}"
  else
    echo "未执行"
  fi
  hr

  # stream
  echo -e "${MAGENTA}[流媒体]  ${stream_score}/100 ($(grade_colored "$g_stream"))  $(bar "$stream_score" "$(grade_color_tag "$g_stream")")${NC}"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    echo "YouTube=${YT_OK}(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  else
    echo "未执行"
  fi
  hr

  # total
  echo -e "${MAGENTA}[总评]  ${total}/100 ($(grade_colored "$g_total"))  $(bar "$total" "$(grade_color_tag "$g_total")")${NC}"
  if [[ "$total" -ge 85 ]]; then
    ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then
    ok "结论：整体不错，日常中转/落地够用，关注路由与邻居波动。"
  elif [[ "$total" -ge 55 ]]; then
    warn "结论：整体一般，建议降低用途预期或换机房/换商家。"
  else
    bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi

  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${MAGENTA}================================================================${NC}"
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
  run_tcp
  overall_summary
}

run_all_silent() {
  info "正在后台执行检测（2~8 + 10），完成后输出最终✅总结..."
  {
    gather_system >/dev/null 2>&1 || true
    gather_ip     >/dev/null 2>&1 || true
    run_ping_all  >/dev/null 2>&1 || true
    run_mtr       >/dev/null 2>&1 || true
    run_disk      >/dev/null 2>&1 || true
    run_streaming >/dev/null 2>&1 || true
    run_tcp       >/dev/null 2>&1 || true
  } || true
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
    echo "  10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
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
      *) warn "无效选择：${c:-空}（请输入 0-10 或 R）"; pause ;;
    esac
  done
}

# ---------- entry ----------
menu
