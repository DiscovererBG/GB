#!/usr/bin/env bash
# =========================================================
# ✅ VPS 一键体检（只读）- 菜单版（全中文 + 修复版）
# ---------------------------------------------------------

# =========================================================

set -euo pipefail

# ---------------- UI / Colors ----------------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; MAGENTA="\033[35m"; GRAY="\033[90m"; NC="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
hr()   { echo -e "${MAGENTA}---------------------------------------------------------${NC}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }
pause() { read -r -p "回车继续..." _ || true; }

# ---------------- Defaults ----------------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=12

DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")
TARGETS=("${DEFAULT_TARGETS[@]}")

# ---------------- Flags ----------------
REDACT=0
[[ "${1:-}" == "--redact" ]] && REDACT=1

mask_ipv4() {
  local ip="${1:-unknown}"
  [[ "$REDACT" -eq 0 ]] && { echo "$ip"; return; }
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "$ip"; return; }
  echo "$ip" | awk -F. '{printf "%s.%s.*.*",$1,$2}'
}
mask_host() {
  local h="${1:-unknown}"
  [[ "$REDACT" -eq 0 ]] && { echo "$h"; return; }
  [[ ${#h} -le 2 ]] && { echo "*"; return; }
  echo "${h:0:1}***${h: -1}"
}

# ---------------- Numeric helpers ----------------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }

f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

clamp_0_100() { awk -v x="$1" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}'; }

# ---------------- Grade (CN) ----------------
grade_cn() {
  local s="${1:-0}"
  if [[ "$s" -ge 85 ]]; then echo "优秀"
  elif [[ "$s" -ge 70 ]]; then echo "良好"
  elif [[ "$s" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}
grade_color() {
  local g="${1:-未知}"
  case "$g" in
    优秀) echo -e "${GREEN}";;
    良好) echo -e "${CYAN}";;
    一般) echo -e "${YELLOW}";;
    偏弱) echo -e "${RED}";;
    *) echo -e "${GRAY}";;
  esac
}

# ---------------- Bar (ASCII, never garble) ----------------
bar() {
  # bar <score 0..100> <gradeCN>
  local score="${1:-0}" g="${2:-未知}"
  score="$(clamp_0_100 "$score")"
  local width=30
  local filled=$(( score*width/100 ))
  local empty=$(( width-filled ))
  local c; c="$(grade_color "$g")"
  local fill; fill="$(printf "%0.s=" $(seq 1 "$filled" 2>/dev/null || true))"
  local empt; empt="$(printf "%0.s." $(seq 1 "$empty" 2>/dev/null || true))"
  echo -e "[${c}${fill}${GRAY}${empt}${NC}]"
}

# ---------------- Global state for summary ----------------
RUN_SYS=0 RUN_IP=0 RUN_PING=0 RUN_MTR=0 RUN_DISK=0 RUN_STREAM=0 RUN_TCP=0

HOSTNAME_="unknown"; OS_="unknown"; KERNEL_="unknown"; UPTIME_="unknown"
CPU_="unknown"; CORES_="1"; RAM_="0 MB"; SWAP_="0 MB"; LOAD_="unknown"; VIRT_="unknown"; DISKROOT_="unknown"

IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"

# Ping summary
PING_TOTAL=0
PING_EXCELLENT=0 PING_OK=0 PING_WEAK=0
PING_WORST_LOSS="" PING_WORST_AVG=""

# MTR summary
MTR_LASTLOSS=""
MTR_LASTAVG=""
MTR_GRADE="未知"  # 优秀/良好/一般/偏弱/未知

# Disk summary
DISK_SPEED_RAW="未知"
DISK_MBPS=""
DISK_SCORE=0
DISK_GRADE="未知"

# Stream summary
YT_CC="未知"
YT_OK="未知"
AG_STATUS="未知"
NF_OK="未知"
DP_OK="未知"
TT_OK="未知"
PV_OK="未知"
MX_OK="未知"
STREAM_SCORE=0
STREAM_GRADE="未知"

# TCP summary
TCP_TLS_MS=""
TCP_TTFB_MS=""
TCP_DL_MBPS=""
TCP_SCORE=0
TCP_GRADE="未知"
TCP_NOTE=""

# ---------------- Targets ----------------
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

# ---------------- System ----------------
gather_system() {
  RUN_SYS=1
  HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
  UPTIME_="$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/^/up /' || echo unknown)"
  OS_="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || echo unknown)"
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
  echo "CPU      : ${CPU_}（${CORES_} 核）"
  echo "RAM/Swap : ${RAM_} / ${SWAP_}"
  echo "Load     : ${LOAD_}"
  echo "Virt     : ${VIRT_}"
  echo "Disk /   : ${DISKROOT_}"
  hr
}

# ---------------- IP Info ----------------
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
  echo "IPv4    : ${IPV4_}"
  echo "Geo     : ${GEO_}"
  echo "ASN     : ${ASN_}"
  echo "ISP/Org : ${ORG_}"
  hr
}

# ---------------- Ping ----------------
ping_once() {
  local target="$1" interval="$2"
  ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null
}

parse_ping_rtt() {
  # output -> prints: min avg max mdev (may be blank)
  local out="$1"
  # linux iputils: rtt min/avg/max/mdev = 1.2/2.3/3.4/0.1 ms
  local line
  line="$(echo "$out" | awk '/rtt min\/avg\/max\/mdev|round-trip min\/avg\/max/{print; exit}')"
  if [[ -z "${line:-}" ]]; then
    echo "|||"
    return
  fi
  local nums
  nums="$(echo "$line" | awk -F'=' '{print $2}' | awk '{print $1}' | tr -d ' ')" # 1/2/3/4
  local min avg max mdev
  min="$(echo "$nums" | awk -F/ '{print $1}')"
  avg="$(echo "$nums" | awk -F/ '{print $2}')"
  max="$(echo "$nums" | awk -F/ '{print $3}')"
  mdev="$(echo "$nums" | awk -F/ '{print $4}')"
  echo "${min}|${avg}|${max}|${mdev}"
}

ping_test_one() {
  local target="$1"
  echo -e "${MAGENTA}--- Ping：${target}（${PING_COUNT} 次）---${NC}"

  if ! need_cmd ping; then
    warn "缺少 ping，跳过。"
    return 0
  fi

  local out loss min avg max mdev
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  loss="$(safe_num "$loss")"

  local r; r="$(parse_ping_rtt "$out")"
  min="$(echo "$r" | awk -F'|' '{print $1}')"
  avg="$(echo "$r" | awk -F'|' '{print $2}')"
  max="$(echo "$r" | awk -F'|' '{print $3}')"
  mdev="$(echo "$r" | awk -F'|' '{print $4}')"

  min="$(safe_num "$min")"; avg="$(safe_num "$avg")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  echo "丢包 : ${loss:-未知}%"
  echo "RTT  : min=${min:-未知}ms  avg=${avg:-未知}ms  max=${max:-未知}ms  mdev=${mdev:-未知}ms"

  # 丢包评级
  local loss_grade="一般"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then loss_grade="优秀"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then loss_grade="一般"
  else loss_grade="偏弱"
  fi

  if [[ "$loss_grade" == "优秀" ]]; then ok "丢包：优秀（≤1%）"; ((PING_EXCELLENT++)) || true
  elif [[ "$loss_grade" == "一般" ]]; then warn "丢包：一般（1%~5%）"; ((PING_OK++)) || true
  else bad "丢包：偏弱（>5%）"; ((PING_WEAK++)) || true
  fi

  # 延迟评级（只提示，不计数）
  if [[ -n "${avg:-}" ]]; then
    if f_lt "$avg" "80"; then ok "延迟：优秀（<80ms）"
    elif f_lt "$avg" "150"; then warn "延迟：一般（80~150ms）"
    else warn "延迟：偏高（≥150ms）"
    fi
  fi

  # worst tracking
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
  PING_TOTAL="${#TARGETS[@]}"
  PING_EXCELLENT=0; PING_OK=0; PING_WEAK=0
  PING_WORST_LOSS=""; PING_WORST_AVG=""

  for t in "${TARGETS[@]}"; do
    ping_test_one "$t"
  done

  hr
  info "Ping 小结：目标数=${PING_TOTAL} | 优秀=${PING_EXCELLENT} 一般=${PING_OK} 偏弱=${PING_WEAK} | 最差丢包=${PING_WORST_LOSS:-未知}% 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  hr
}

# ---------------- MTR ----------------
install_mtr() {
  if ! need_cmd apt; then
    warn "系统没有 apt（非 Debian/Ubuntu），跳过安装。"
    return 0
  fi
  info "将执行：apt update && apt install -y mtr-tiny"
  apt update && apt install -y mtr-tiny
  ok "mtr 安装完成。"
}

run_mtr() {
  RUN_MTR=1
  local target="${TARGETS[0]}"
  echo -e "${MAGENTA}--- MTR：${target}（${MTR_COUNT} 轮）---${NC}"

  if ! need_cmd mtr; then
    warn "未安装 mtr。（可选 6 安装 mtr-tiny）"
    MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_GRADE="未知"
    hr
    return 0
  fi

  local out last_line last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"

  echo "$out" | head -n 3
  echo -e "${GRAY}...（中间省略）...${NC}"
  echo "$out" | tail -n 8

  # 取最后一行：Loss% Snt Last Avg Best Wrst StDev 在行尾 7 列
  last_line="$(echo "$out" | tail -n 1)"
  last_loss="$(echo "$last_line" | awk '{print $(NF-6)}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $(NF-3)}')"

  last_loss="$(safe_num "$last_loss")"
  last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

  echo
  echo "终点（最后一跳）：丢包=${last_loss:-未知}%  平均=${last_avg:-未知}ms"
  info "提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。"

  if [[ -n "${last_loss:-}" ]]; then
    if f_le "$last_loss" "1.0"; then ok "路由质量：优秀"; MTR_GRADE="优秀"
    elif f_le "$last_loss" "5.0"; then warn "路由质量：一般"; MTR_GRADE="一般"
    else bad "路由质量：偏弱"; MTR_GRADE="偏弱"
    fi
  else
    MTR_GRADE="未知"
  fi

  hr
}

# ---------------- Disk ----------------
run_disk() {
  RUN_DISK=1
  echo -e "${MAGENTA}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"

  if ! need_cmd dd; then
    warn "缺少 dd，跳过。"
    DISK_SPEED_RAW="未知"; DISK_MBPS=""; DISK_SCORE=0; DISK_GRADE="未知"
    hr
    return 0
  fi

  local tmp out speed num unit mbps
  tmp="/tmp/vps_disk_test.$$"
  out="$(dd if=/dev/zero of="$tmp" bs=1M count="${DISK_TEST_MB}" conv=fdatasync 2>&1 || true)"
  rm -f "$tmp" >/dev/null 2>&1 || true

  speed="$(echo "$out" | tail -n 1 | awk -F', ' '{print $NF}' | sed 's/^[ \t]*//')"
  DISK_SPEED_RAW="${speed:-未知}"
  echo "结果 : ${DISK_SPEED_RAW}"

  num="$(echo "$DISK_SPEED_RAW" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$DISK_SPEED_RAW" | awk '{print $2}' 2>/dev/null || true)"
  num="$(safe_num "$num")"

  DISK_MBPS=""
  if [[ -n "${num:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then
      mbps="$(awk -v x="$num" 'BEGIN{printf "%.2f", x*1024}')"
    else
      mbps="$num"
    fi
    DISK_MBPS="$mbps"

    # 评分（简单）
    if f_ge "$mbps" "200"; then DISK_SCORE=90
    elif f_ge "$mbps" "80"; then DISK_SCORE=70
    else DISK_SCORE=50
    fi
    DISK_GRADE="$(grade_cn "$DISK_SCORE")"
    echo -e "评级 : $(grade_color "$DISK_GRADE")${DISK_GRADE}${NC}（约 ${DISK_MBPS} MB/s）"
  else
    DISK_SCORE=0; DISK_GRADE="未知"
    warn "无法解析 dd 速度（不同系统输出差异较大）"
  fi

  hr
}

# ---------------- Streaming ----------------
fetch()   { curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
code_of() { curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }

run_streaming() {
  RUN_STREAM=1
  STREAM_SCORE=0
  if ! need_cmd curl; then
    bad "缺少 curl，无法做流媒体检测。"
    STREAM_GRADE="未知"
    return 0
  fi

  echo -e "${MAGENTA}--- 流媒体解锁检测（best-effort）---${NC}"

  # YouTube
  local yt_code yt_html yt_cc
  yt_code="$(code_of "https://www.youtube.com/premium")"
  yt_html="$(fetch "https://www.youtube.com/premium")"
  yt_cc="$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d: -f2 | tr -d '"')"
  YT_CC="${yt_cc:-未知}"
  echo "YouTube Premium : HTTP ${yt_code}  地区: ${YT_CC}"
  if [[ "$yt_code" == "200" || "$yt_code" == "302" ]]; then ok "YouTube：可访问"; YT_OK="可访问"; ((STREAM_SCORE+=15)) || true
  else bad "YouTube：疑似不可用"; YT_OK="不可用"
  fi
  echo

  # 动画疯
  local ag_code ag_html
  ag_code="$(code_of "https://ani.gamer.com.tw/")"
  ag_html="$(fetch "https://ani.gamer.com.tw/")"
  echo "动画疯         : HTTP ${ag_code}"
  if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
    warn "动画疯：地区限制提示"
    AG_STATUS="地区限制"
  elif [[ "$ag_code" == "200" ]]; then
    ok "动画疯：页面可访问（是否可播放以实际为准）"
    AG_STATUS="可访问"
    ((STREAM_SCORE+=15)) || true
  elif [[ "$ag_code" == "403" || "$ag_code" == "503" ]]; then
    warn "动画疯：可能风控/CF 拦截"
    AG_STATUS="可能风控/拦截"
  else
    warn "动画疯：状态未知"
    AG_STATUS="未知"
  fi
  echo

  # Netflix
  local nf_code
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  echo "Netflix         : HTTP ${nf_code}"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then ok "Netflix：可访问（最终以登录播放为准）"; NF_OK="可访问"; ((STREAM_SCORE+=15)) || true
  else warn "Netflix：疑似受限/不可用"; NF_OK="疑似受限"
  fi
  echo

  # Disney+
  local dp_code
  dp_code="$(code_of "https://www.disneyplus.com/")"
  echo "Disney+         : HTTP ${dp_code}"
  if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then ok "Disney+：可访问（最终以登录播放为准）"; DP_OK="可访问"; ((STREAM_SCORE+=15)) || true
  else warn "Disney+：疑似受限/不可用"; DP_OK="疑似受限"
  fi
  echo

  # TikTok
  local tt_code
  tt_code="$(code_of "https://www.tiktok.com/")"
  echo "TikTok          : HTTP ${tt_code}"
  if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then
    warn "TikTok：可访问但可能受风控/CF 影响（建议多测几次）"
    TT_OK="可访问"
    ((STREAM_SCORE+=10)) || true
  elif [[ "$tt_code" == "403" ]]; then
    bad "TikTok：403（常见于地区限制/风控）"
    TT_OK="不可用"
  else
    warn "TikTok：状态未知"
    TT_OK="未知"
  fi
  echo

  # PrimeVideo
  local pv_code
  pv_code="$(code_of "https://www.primevideo.com/")"
  echo "Prime Video     : HTTP ${pv_code}"
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then ok "Prime：可访问（片库看账号地区）"; PV_OK="可访问"; ((STREAM_SCORE+=10)) || true
  else warn "Prime：疑似受限"; PV_OK="疑似受限"
  fi
  echo

  # Max(HBO)
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  echo "Max(HBO)        : HTTP ${mx_code}"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then ok "Max：可访问（最终以登录播放为准）"; MX_OK="可访问"; ((STREAM_SCORE+=10)) || true
  else warn "Max：疑似受限"; MX_OK="疑似受限"
  fi
  echo

  # Normalize score to 0..100 (max 90)
  STREAM_SCORE="$(awk -v x="$STREAM_SCORE" 'BEGIN{printf "%.0f", x*100/90}')"
  STREAM_SCORE="$(clamp_0_100 "$STREAM_SCORE")"
  STREAM_GRADE="$(grade_cn "$STREAM_SCORE")"

  hr
  info "提示：Netflix/Disney+/Max/Prime 只能判断“可访问/疑似受限”，最终以登录播放为准。"
  info "TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。"
  hr
}

# ---------------- TCP Real Link (multi-source median) ----------------
# 说明：用 curl 的真实 TCP/TLS 连接 + 首包时间 + 下载速度（range 限制），更贴近代理体验
TCP_RANGE_MB=16

tcp_sources_names=( "cloudflare" "hetzner" "ovh" "cachefly" )
tcp_sources_urls=(
  "https://speed.cloudflare.com/__down?bytes=$((TCP_RANGE_MB*1024*1024))"
  "https://speed.hetzner.de/100MB.bin"
  "https://proof.ovh.net/files/100Mb.dat"
  "https://cachefly.cachefly.net/100mb.test"
)

median_of_list() {
  # usage: median_of_list "1.1 2.2 3.3"
  local s="$1"
  [[ -z "${s// /}" ]] && { echo ""; return; }
  # sort numeric
  local sorted
  sorted="$(echo "$s" | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+)?$' | sort -n)"
  local n
  n="$(echo "$sorted" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$n" -le 0 ]] && { echo ""; return; }
  if (( n % 2 == 1 )); then
    local mid=$(( (n+1)/2 ))
    echo "$sorted" | sed -n "${mid}p"
  else
    local a=$(( n/2 ))
    local b=$(( a+1 ))
    local va vb
    va="$(echo "$sorted" | sed -n "${a}p")"
    vb="$(echo "$sorted" | sed -n "${b}p")"
    awk -v x="$va" -v y="$vb" 'BEGIN{printf "%.2f",(x+y)/2}'
  fi
}

run_tcp() {
  RUN_TCP=1
  TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""; TCP_SCORE=0; TCP_GRADE="未知"; TCP_NOTE=""

  if ! need_cmd curl; then
    bad "缺少 curl，无法做 TCP 真实链路测试。"
    return 0
  fi

  echo -e "${MAGENTA}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${NC}"
  info "范围：${TCP_RANGE_MB}MB | 超时：${CURL_TIMEOUT}s | sources=${tcp_sources_names[*]}（能测几个算几个）"

  local tls_list="" ttfb_list="" dl_list=""
  local best_dl="0" best_name=""

  local i
  for i in "${!tcp_sources_names[@]}"; do
    local name="${tcp_sources_names[$i]}"
    local url="${tcp_sources_urls[$i]}"

    local range_bytes=$((TCP_RANGE_MB*1024*1024))
    local curl_out
    # 输出：time_appconnect time_starttransfer speed_download http_code
    curl_out="$(curl -L --max-time "${CURL_TIMEOUT}" --connect-timeout 5 \
      -A "Mozilla/5.0" -o /dev/null -r "0-$((range_bytes-1))" \
      -w "%{time_appconnect} %{time_starttransfer} %{speed_download} %{http_code}" \
      "$url" 2>/dev/null || true)"

    local t_app t_ttfb spd code
    t_app="$(echo "$curl_out" | awk '{print $1}')"
    t_ttfb="$(echo "$curl_out" | awk '{print $2}')"
    spd="$(echo "$curl_out" | awk '{print $3}')"
    code="$(echo "$curl_out" | awk '{print $4}')"

    # code 000 表示失败/超时
    if [[ -z "${code:-}" || "$code" == "000" ]]; then
      echo -e "• ${GRAY}${name}${NC}: 失败/超时（跳过）"
      continue
    fi

    # 允许 200/206/301/302 等
    local tls_ms="" ttfb_ms="" dl_mbps=""
    if is_number "$t_app"; then tls_ms="$(awk -v x="$t_app" 'BEGIN{printf "%.0f", x*1000}')" ; fi
    if is_number "$t_ttfb"; then ttfb_ms="$(awk -v x="$t_ttfb" 'BEGIN{printf "%.0f", x*1000}')" ; fi
    if is_number "$spd"; then dl_mbps="$(awk -v x="$spd" 'BEGIN{printf "%.2f", x*8/1000000}')" ; fi

    # dl_mbps 可能极低（被限速/风控），但仍算有效样本
    echo -e "• ${CYAN}${name}${NC}: TLS=${tls_ms:-未知}ms  TTFB=${ttfb_ms:-未知}ms  下载=${dl_mbps:-未知}Mbps  code=${code}"

    [[ -n "${tls_ms:-}" ]] && tls_list+="${tls_ms} "
    [[ -n "${ttfb_ms:-}" ]] && ttfb_list+="${ttfb_ms} "
    [[ -n "${dl_mbps:-}" ]] && dl_list+="${dl_mbps} "

    if [[ -n "${dl_mbps:-}" ]]; then
      awk -v a="$dl_mbps" -v b="$best_dl" 'BEGIN{exit (a>b)?0:1}' && { best_dl="$dl_mbps"; best_name="$name"; } || true
    fi
  done

  local med_tls med_ttfb med_dl
  med_tls="$(median_of_list "$tls_list")"
  med_ttfb="$(median_of_list "$ttfb_list")"
  med_dl="$(median_of_list "$dl_list")"

  if [[ -z "${med_dl:-}" || -z "${med_tls:-}" || -z "${med_ttfb:-}" ]]; then
    TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
    TCP_SCORE=0
    TCP_GRADE="未知"
    TCP_NOTE="无有效样本（可能超时/被限速/被风控），建议换时间多测几次"
    warn "TCP：有效样本不足（可能超时/限速/风控），建议换时间多测几次。"
    hr
    return 0
  fi

  TCP_TLS_MS="$med_tls"
  TCP_TTFB_MS="$med_ttfb"
  TCP_DL_MBPS="$med_dl"

  # 评分：下载为主，延迟为辅（0..100）
  # 下载分
  local dl_score=0 lat_score=0 tls_score=0 ttfb_score=0
  if awk -v x="$med_dl" 'BEGIN{exit (x>=300)?0:1}'; then dl_score=100
  elif awk -v x="$med_dl" 'BEGIN{exit (x>=100)?0:1}'; then dl_score=90
  elif awk -v x="$med_dl" 'BEGIN{exit (x>=30)?0:1}'; then dl_score=80
  elif awk -v x="$med_dl" 'BEGIN{exit (x>=10)?0:1}'; then dl_score=65
  elif awk -v x="$med_dl" 'BEGIN{exit (x>=3)?0:1}'; then dl_score=50
  else dl_score=35
  fi

  # TLS 分（越小越好）
  if [[ "$med_tls" -le 80 ]]; then tls_score=100
  elif [[ "$med_tls" -le 200 ]]; then tls_score=80
  elif [[ "$med_tls" -le 600 ]]; then tls_score=60
  else tls_score=40
  fi

  # TTFB 分
  if [[ "$med_ttfb" -le 200 ]]; then ttfb_score=100
  elif [[ "$med_ttfb" -le 500 ]]; then ttfb_score=80
  elif [[ "$med_ttfb" -le 1200 ]]; then ttfb_score=60
  else ttfb_score=40
  fi

  lat_score=$(( (tls_score + ttfb_score) / 2 ))
  TCP_SCORE="$(awk -v d="$dl_score" -v l="$lat_score" 'BEGIN{printf "%.0f", d*0.7 + l*0.3}')"
  TCP_SCORE="$(clamp_0_100 "$TCP_SCORE")"
  TCP_GRADE="$(grade_cn "$TCP_SCORE")"

  echo
  echo -e "${GRAY}中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳=${best_name:-未知} ${best_dl:-0}Mbps）${NC}"
  if [[ "$TCP_GRADE" == "优秀" ]]; then ok "TCP 体验：优秀"
  elif [[ "$TCP_GRADE" == "良好" ]]; then ok "TCP 体验：良好"
  elif [[ "$TCP_GRADE" == "一般" ]]; then warn "TCP 体验：一般"
  else bad "TCP 体验：偏弱"
  fi
  hr
}

# ---------------- Overall Summary ----------------
overall_summary() {
  echo -e "${MAGENTA}====================== ✅ VPS 体检总结报告 ======================${NC}"

  # 网络评分：基于 ping + mtr（简化）
  local net_score=0 net_grade="未知"
  if [[ "$RUN_PING" -eq 1 ]]; then
    # 优秀=2 一般=1 偏弱=0
    local denom="$PING_TOTAL"; [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v e="$PING_EXCELLENT" -v o="$PING_OK" -v d="$denom" 'BEGIN{printf "%.0f", (e*2+o)*50/d }')"
    # 0..100
  else
    net_score=0
  fi

  if [[ "$RUN_MTR" -eq 1 ]]; then
    if [[ "$MTR_GRADE" == "优秀" ]]; then net_score=$((net_score+10)); fi
    if [[ "$MTR_GRADE" == "偏弱" ]]; then net_score=$((net_score-10)); fi
  fi
  net_score="$(clamp_0_100 "$net_score")"
  net_grade="$(grade_cn "$net_score")"

  # 流媒体已算 STREAM_SCORE/STREAM_GRADE；磁盘 DISK_SCORE/DISK_GRADE；TCP TCP_SCORE/TCP_GRADE

  # 综合（权重：网络40 TCP25 流媒体20 磁盘15，没跑的不计入权重）
  local total=0 used=0
  local addw
  addw() { total="$(awk -v t="$total" -v x="$1" -v w="$2" 'BEGIN{printf "%.0f", t + x*w/100}')" ; used=$((used+$2)); }

  if [[ "$RUN_PING" -eq 1 || "$RUN_MTR" -eq 1 ]]; then addw "$net_score" 40; fi
  if [[ "$RUN_TCP" -eq 1 ]]; then addw "$TCP_SCORE" 25; fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then addw "$STREAM_SCORE" 20; fi
  if [[ "$RUN_DISK" -eq 1 ]]; then addw "$DISK_SCORE" 15; fi

  if [[ "$used" -gt 0 ]]; then total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')" ; else total=0; fi
  total="$(clamp_0_100 "$total")"
  local overall_grade; overall_grade="$(grade_cn "$total")"

  # Print
  echo -e "${MAGENTA}[基础信息]${NC}"
  if [[ "$RUN_SYS" -eq 1 ]]; then
    echo "Host : $(mask_host "$HOSTNAME_")"
    echo "OS   : ${OS_}"
    echo "Kern : ${KERNEL_} | Virt=${VIRT_}"
    echo "CPU  : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
    echo "Disk : / ${DISKROOT_}"
  else
    echo "（未执行）"
  fi
  if [[ "$RUN_IP" -eq 1 ]]; then
    echo "IPv4 : $(mask_ipv4 "$IPV4_")"
    echo "Geo  : ${GEO_}"
    echo "ASN  : ${ASN_}"
    echo "ISP  : ${ORG_}"
  else
    echo "公网信息：未执行"
  fi
  hr

  echo -e "${MAGENTA}[网络]${NC}  ${net_score}/100  ($(grade_color "$net_grade")${net_grade}${NC})  $(bar "$net_score" "$net_grade")"
  if [[ "$RUN_PING" -eq 1 ]]; then
    echo "Ping : 优秀=${PING_EXCELLENT} 一般=${PING_OK} 偏弱=${PING_WEAK} | 最差丢包=${PING_WORST_LOSS:-未知}% | 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  else
    echo "Ping : 未执行"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    echo "MTR  : target=${TARGETS[0]} | 终点丢包=${MTR_LASTLOSS:-未知}% | 终点平均=${MTR_LASTAVG:-未知}ms | 评级=$(grade_color "$MTR_GRADE")${MTR_GRADE}${NC}"
  else
    echo "MTR  : 未执行"
  fi
  hr

  echo -e "${MAGENTA}[TCP真实链路]${NC}  ${TCP_SCORE}/100  ($(grade_color "$TCP_GRADE")${TCP_GRADE}${NC})  $(bar "$TCP_SCORE" "$TCP_GRADE")"
  if [[ "$RUN_TCP" -eq 1 ]]; then
    if [[ "$TCP_GRADE" == "未知" ]]; then
      echo "提示 : ${TCP_NOTE:-未知}"
    else
      echo "TLS  : ${TCP_TLS_MS} ms | TTFB=${TCP_TTFB_MS} ms"
      echo "DL   : ${TCP_DL_MBPS} Mbps（中位数, range=${TCP_RANGE_MB}MB, maxTime=${CURL_TIMEOUT}s）"
      echo "评级 : $(grade_color "$TCP_GRADE")${TCP_GRADE}${NC}"
    fi
  else
    echo "未执行"
  fi
  hr

  echo -e "${MAGENTA}[磁盘]${NC}  ${DISK_SCORE}/100  ($(grade_color "$DISK_GRADE")${DISK_GRADE}${NC})  $(bar "$DISK_SCORE" "$DISK_GRADE")"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    echo "dd   : ${DISK_SPEED_RAW} | 约 ${DISK_MBPS:-未知} MB/s"
    echo "评级 : $(grade_color "$DISK_GRADE")${DISK_GRADE}${NC}"
  else
    echo "未执行"
  fi
  hr

  echo -e "${MAGENTA}[流媒体]${NC}  ${STREAM_SCORE}/100  ($(grade_color "$STREAM_GRADE")${STREAM_GRADE}${NC})  $(bar "$STREAM_SCORE" "$STREAM_GRADE")"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    echo "YouTube=${YT_OK}(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  else
    echo "未执行"
  fi
  hr

  echo -e "${MAGENTA}[总评]${NC}  ${total}/100  ($(grade_color "$overall_grade")${overall_grade}${NC})  $(bar "$total" "$overall_grade")"
  if [[ "$total" -ge 85 ]]; then ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then ok "结论：整体不错，日常中转/落地够用，关注路由与邻居波动。"
  elif [[ "$total" -ge 55 ]]; then warn "结论：整体一般，建议降低用途预期或考虑换机房。"
  else bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi

  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${MAGENTA}=================================================================${NC}"
}

# ---------------- Run All ----------------
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
  local log="/tmp/vps_check_${$}.log"
  info "正在后台静默执行检测（2~8+10），完成后输出最终✅总结..."
  {
    gather_system
    gather_ip
    run_ping_all
    run_mtr
    run_disk
    run_streaming
    run_tcp
  } >"$log" 2>&1 || true
  overall_summary
}

# ---------------- Menu ----------------
menu() {
  while true; do
    echo -e "${MAGENTA}====================== VPS 一键体检 菜单 ======================${NC}"
    echo -e "Targets: ${TARGETS[*]}  ${GRAY}（MTR 默认用第一个 Target）${NC}"
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
      *) warn "无效选择：${c:-空}（请输入 0~10 或 R）"; pause ;;
    esac
  done
}

menu
