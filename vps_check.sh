#!/usr/bin/env bash
# =========================================================
# ✅ VPS Health + Streaming Check (Read-only) - Menu Edition
# - 菜单交互：系统 / 公网 / Ping / MTR / 磁盘 / 流媒体 / TCP真实链路
# - R：后台静默全跑（2~8+10），只输出最终✅总结（不刷屏）
# - 10：TCP真实链路测试（多源测速，取“中位数”，更贴近代理体验）
# - 修复：
#   1) awk: asort never defined -> 不再用 asort（用 bash+sort 求中位数）
#   2) 进度条出现 ????? -> 使用纯 ASCII（= .），避免编码问题
#   3) 输出出现 \033[0m -> 统一用 printf %b 输出颜色
#   4) 评分/评级尽量中文化
# - 只读检测，不改系统配置（仅菜单里安装 mtr 会安装软件包）
# =========================================================

set -u
set -o pipefail

# --- 让终端尽量使用 UTF-8（可用就用，不可用就忽略） ---
export LC_ALL="${LC_ALL:-C.UTF-8}" 2>/dev/null || true

# ---------- UI ----------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
MAGENTA=$'\033[35m'; CYAN=$'\033[36m'; GRAY=$'\033[90m'; NC=$'\033[0m'
BOLD=$'\033[1m'

say()  { printf "%b\n" "$*"; }
ok()   { say "${GREEN}✅ $*${NC}"; }
warn() { say "${YELLOW}⚠️  $*${NC}"; }
bad()  { say "${RED}❌ $*${NC}"; }
info() { say "${CYAN}ℹ️  $*${NC}"; }
hr()   { say "${MAGENTA}---------------------------------------------------------${NC}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() { read -r -p "回车继续..." _ || true; }

# ---------- defaults ----------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=10

TCP_RANGE_MB=16
TCP_MAXTIME=12

DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# ---------- numeric helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }

f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

# ---------- global state ----------
RUN_SYS=0 RUN_IP=0 RUN_PING=0 RUN_MTR=0 RUN_DISK=0 RUN_STREAM=0 RUN_TCP=0

HOSTNAME_="unknown"; OS_="unknown"; KERNEL_="unknown"; UPTIME_="unknown"
CPU_="unknown"; CORES_=""; RAM_=""; SWAP_=""; LOAD_=""; VIRT_="unknown"; DISKROOT_="unknown"

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
MTR_RATING="unknown"   # GOOD/WARN/BAD/unknown

# disk summary
DISK_SPEED_RAW="unknown"
DISK_MBPS=""
DISK_RATING="unknown"  # GOOD/WARN/BAD/unknown
DISK_SCORE=0

# stream summary
YT_CC="unknown"
YT_OK="unknown"
AG_STATUS="unknown"
NF_OK="unknown"
DP_OK="unknown"
TT_OK="unknown"
PV_OK="unknown"
MX_OK="unknown"
STREAM_SCORE=0

# tcp summary
TCP_TLS_MS=""
TCP_TTFB_MS=""
TCP_DL_MBPS=""
TCP_BEST_SRC=""
TCP_SAMPLES=0
TCP_EVAL="unknown"     # GOOD/WARN/BAD/unknown
TCP_SCORE=0

# ---------- text helpers ----------
rating_zh() {
  # input: GOOD/WARN/BAD/unknown
  case "${1:-unknown}" in
    GOOD) echo "优秀" ;;
    WARN) echo "一般" ;;
    BAD)  echo "偏弱" ;;
    *)    echo "未知" ;;
  esac
}

color_by_level() {
  # input: 优秀/良好/一般/偏弱/未知 -> prints color code
  case "$1" in
    优秀) printf "%b" "$GREEN" ;;
    良好) printf "%b" "$CYAN" ;;
    一般) printf "%b" "$YELLOW" ;;
    偏弱) printf "%b" "$RED" ;;
    *)    printf "%b" "$GRAY" ;;
  esac
}

grade_zh() {
  local x="${1:-0}"
  if [[ "$x" -ge 85 ]]; then echo "优秀"
  elif [[ "$x" -ge 70 ]]; then echo "良好"
  elif [[ "$x" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}

# ASCII 进度条（避免 █░ 导致 ?????）
bar() {
  # bar(score,width,color)
  local score="${1:-0}" width="${2:-30}" color="${3:-$GREEN}"
  local filled=$(( score*width/100 ))
  (( filled < 0 )) && filled=0
  (( filled > width )) && filled=width
  local empty=$(( width-filled ))
  local s_f="" s_e=""
  s_f="$(printf "%${filled}s" "" | tr ' ' '=')"
  s_e="$(printf "%${empty}s" "" | tr ' ' '.')"
  printf "%b[%s%s]%b" "$color" "$s_f" "$s_e" "$NC"
}

# ---------- set targets ----------
set_targets() {
  say ""
  read -r -p "输入你要测试的目标（空格分隔，留空=默认 1.1.1.1 8.8.8.8 www.google.com）: " input || true
  if [[ -n "${input:-}" ]]; then
    read -r -a TARGETS <<< "$input"
  else
    TARGETS=("${DEFAULT_TARGETS[@]}")
  fi
  ok "Targets = ${TARGETS[*]}"
  say ""
}

# ---------- system ----------
gather_system() {
  RUN_SYS=1
  HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
  UPTIME_="$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/^up /up /' || echo unknown)"
  OS_="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || echo unknown)"
  KERNEL_="$(uname -r 2>/dev/null || echo unknown)"
  CPU_="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || echo unknown)"
  CORES_="$(nproc 2>/dev/null || echo 1)"
  RAM_="$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  SWAP_="$(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  LOAD_="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || echo "0,0,0")"
  VIRT_="unknown"
  if need_cmd systemd-detect-virt; then VIRT_="$(systemd-detect-virt 2>/dev/null || echo none)"; fi
  DISKROOT_="$(df -hP / 2>/dev/null | tail -n 1 | awk '{print $3"/"$2" ("$5")"}' || echo unknown)"

  say "${MAGENTA}--- 基本信息 ---${NC}"
  say "Host     : ${HOSTNAME_}"
  say "OS       : ${OS_}"
  say "Kernel   : ${KERNEL_}"
  say "Uptime   : ${UPTIME_}"
  say "CPU      : ${CPU_} (${CORES_} 核)"
  say "RAM/Swap : ${RAM_} / ${SWAP_}"
  say "Load     : ${LOAD_}"
  say "Virt     : ${VIRT_}"
  say "Disk /   : ${DISKROOT_}"
  hr
}

# ---------- public ip ----------
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

  say "${MAGENTA}--- 公网信息 ---${NC}"
  say "IPv4     : ${IPV4_}"
  say "Geo      : ${GEO_}"
  say "ASN      : ${ASN_}"
  say "ISP/Org  : ${ORG_}"
  hr
}

# ---------- ping ----------
ping_once() {
  local target="$1" interval="$2"
  ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null
}

parse_ping_line() {
  # supports iputils & busybox
  # returns: min avg max mdev (some may be blank)
  local out="$1"
  local line
  line="$(echo "$out" | awk '/rtt min\/avg\/max\/mdev|round-trip min\/avg\/max/{print; exit}')"
  if [[ -z "${line:-}" ]]; then
    echo "|||"
    return 0
  fi
  # after '=' -> "min/avg/max/mdev"
  local stats
  stats="$(echo "$line" | awk -F'=' '{print $2}' | tr -d ' ' )"
  local min avg max mdev
  min="$(echo "$stats" | awk -F'/' '{print $1}')"
  avg="$(echo "$stats" | awk -F'/' '{print $2}')"
  max="$(echo "$stats" | awk -F'/' '{print $3}')"
  mdev="$(echo "$stats" | awk -F'/' '{print $4}' | awk '{print $1}')"
  echo "${min}|${avg}|${max}|${mdev}"
}

ping_test_one() {
  local target="$1"
  say "${MAGENTA}--- Ping: ${target} (${PING_COUNT} 次) ---${NC}"

  if ! need_cmd ping; then
    warn "没有 ping 命令，跳过。"
    say ""
    return 0
  fi

  local out loss min avg max mdev parsed
  out="$(ping_once "$target" "$PING_INTERVAL" || true)"
  if [[ -z "${out:-}" ]]; then
    warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  loss="$(safe_num "$loss")"

  parsed="$(parse_ping_line "$out")"
  min="$(echo "$parsed" | awk -F'|' '{print $1}')"
  avg="$(echo "$parsed" | awk -F'|' '{print $2}')"
  max="$(echo "$parsed" | awk -F'|' '{print $3}')"
  mdev="$(echo "$parsed" | awk -F'|' '{print $4}')"

  min="$(safe_num "$min")"; avg="$(safe_num "$avg")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  say "丢包 : ${loss:-?}%"
  say "RTT  : min=${min:-?}ms  avg=${avg:-?}ms  max=${max:-?}ms  mdev=${mdev:-?}ms"

  local rating="WARN"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="GOOD"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="WARN"
  else rating="BAD"
  fi

  if [[ "$rating" == "GOOD" ]]; then ok "丢包：优秀（≤1%）"; ((PING_GOOD++)) || true
  elif [[ "$rating" == "WARN" ]]; then warn "丢包：一般（1%~5%）"; ((PING_WARN++)) || true
  else bad "丢包：偏弱（>5%）"; ((PING_BAD++)) || true
  fi

  if [[ -n "${avg:-}" ]]; then
    if f_lt "$avg" "80"; then ok "延迟：优秀（<80ms）"
    elif f_lt "$avg" "150"; then warn "延迟：一般（80~150ms）"
    else warn "延迟：偏高（≥150ms）"
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
  say ""
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
  say "${MAGENTA}--- MTR: ${target} (${MTR_COUNT} 轮) ---${NC}"

  if ! need_cmd mtr; then
    warn "未安装 mtr。（可在菜单选择安装 mtr-tiny）"
    MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"
    hr
    return 0
  fi

  local out last_line last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"
  echo "$out" | head -n 3
  say "${GRAY}...（中间省略）...${NC}"
  echo "$out" | tail -n 7

  last_line="$(echo "$out" | awk 'NF>0{l=$0} END{print l}')"
  last_loss="$(echo "$last_line" | awk '{print $3}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $6}')"
  last_loss="$(safe_num "$last_loss")"
  last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

  say ""
  say "终点(最后一跳)：丢包=${last_loss:-?}%  平均=${last_avg:-?}ms"
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
  say "${MAGENTA}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"

  if ! need_cmd dd; then
    warn "dd 不存在，跳过。"
    DISK_SPEED_RAW="unknown"; DISK_MBPS=""; DISK_RATING="unknown"; DISK_SCORE=0
    hr
    return 0
  fi

  local tmp out speed mbps unit
  tmp="/tmp/vps_disk_test.$$"
  out="$(dd if=/dev/zero of="$tmp" bs=1M count="${DISK_TEST_MB}" conv=fdatasync 2>&1 || true)"
  rm -f "$tmp" >/dev/null 2>&1 || true

  speed="$(echo "$out" | tail -n 1 | awk -F', ' '{print $NF}' | sed 's/^[ \t]*//')"
  DISK_SPEED_RAW="${speed:-unknown}"
  say "结果 : ${DISK_SPEED_RAW}"

  mbps="$(echo "$DISK_SPEED_RAW" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$DISK_SPEED_RAW" | awk '{print $2}' 2>/dev/null || true)"
  mbps="$(safe_num "$mbps")"

  if [[ -n "${mbps:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then
      mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')"  # -> MB/s
    fi
    DISK_MBPS="$mbps"

    if f_ge "$mbps" "200"; then DISK_RATING="GOOD"; DISK_SCORE=90; ok "磁盘：优秀（≥200 MB/s）"
    elif f_ge "$mbps" "80"; then DISK_RATING="WARN"; DISK_SCORE=70; warn "磁盘：一般（80~200 MB/s）"
    else DISK_RATING="BAD"; DISK_SCORE=50; warn "磁盘：偏弱（<80 MB/s）"
    fi
  else
    warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
    DISK_RATING="unknown"; DISK_SCORE=0
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
    STREAM_SCORE=0
    return 0
  fi

  say "${MAGENTA}--- 流媒体解锁检测（best-effort）---${NC}"

  # YouTube
  local yt_code yt_html yt_cc
  yt_code="$(code_of "https://www.youtube.com/premium")"
  yt_html="$(fetch "https://www.youtube.com/premium")"
  yt_cc="$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d: -f2 | tr -d '"')"
  YT_CC="${yt_cc:-unknown}"
  say "YouTube Premium : HTTP ${yt_code}  地区=${YT_CC}"
  if [[ "$yt_code" == "200" || "$yt_code" == "302" ]]; then ok "YouTube：可访问"; YT_OK="OK"; else warn "YouTube：可能受限"; YT_OK="WARN"; fi
  say ""

  # 动画疯
  local ag_code ag_html
  ag_code="$(code_of "https://ani.gamer.com.tw/")"
  ag_html="$(fetch "https://ani.gamer.com.tw/")"
  say "动画疯         : HTTP ${ag_code}"
  if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
    warn "动画疯：检测到地区限制提示"
    AG_STATUS="REGION_BLOCK"
  elif [[ "$ag_code" == "200" ]]; then
    ok "动画疯：页面可访问（是否可播放以实际为准）"
    AG_STATUS="OK"
  elif [[ "$ag_code" == "403" || "$ag_code" == "503" ]]; then
    warn "动画疯：可能被风控/CF 拦截（HTTP ${ag_code}）"
    AG_STATUS="WAF_OR_RISK"
  else
    warn "动画疯：状态不确定（HTTP ${ag_code}）"
    AG_STATUS="UNKNOWN"
  fi
  say ""

  # Netflix
  local nf_code
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  say "Netflix         : HTTP ${nf_code}"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then ok "Netflix：可访问（以登录播放为准）"; NF_OK="OK"; else warn "Netflix：可能受限"; NF_OK="WARN"; fi
  say ""

  # Disney+
  local dp_code
  dp_code="$(code_of "https://www.disneyplus.com/")"
  say "Disney+         : HTTP ${dp_code}"
  if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then ok "Disney+：可访问（以登录播放为准）"; DP_OK="OK"; else warn "Disney+：可能受限"; DP_OK="WARN"; fi
  say ""

  # TikTok
  local tt_code tt_head tt_region
  tt_code="$(code_of "https://www.tiktok.com/")"
  tt_head="$(head_req "https://www.tiktok.com/")"
  tt_region="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="x-tt-region"{print $2}' | tr -d '\r' | head -n1)"
  say "TikTok          : HTTP ${tt_code}  x-tt-region=${tt_region:-unknown}"
  if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then
    warn "TikTok：可访问但可能受风控/CF 影响（建议多测几次）"
    TT_OK="OK"
  elif [[ "$tt_code" == "403" ]]; then
    warn "TikTok：403（常见于地区限制/风控）"
    TT_OK="WARN"
  else
    warn "TikTok：状态不确定"
    TT_OK="WARN"
  fi
  say ""

  # Prime Video
  local pv_code
  pv_code="$(code_of "https://www.primevideo.com/")"
  say "Prime Video     : HTTP ${pv_code}"
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then ok "Prime：可访问（片库看账号地区）"; PV_OK="OK"; else warn "Prime：可能受限"; PV_OK="WARN"; fi
  say ""

  # Max
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  say "Max(HBO)        : HTTP ${mx_code}"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then ok "Max：可访问（片库看地区与账号）"; MX_OK="OK"; else warn "Max：可能受限"; MX_OK="WARN"; fi
  say ""

  hr
  info "提示：Netflix/Disney+/Max/Prime 仅能判断“可访问/疑似受限”，最终以登录播放为准。"
  info "提示：TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。"
  hr

  # streaming score（粗略）
  local s=0
  [[ "$YT_OK" == "OK" ]] && ((s+=15)) || true
  [[ "$NF_OK" == "OK" ]] && ((s+=15)) || true
  [[ "$DP_OK" == "OK" ]] && ((s+=15)) || true
  [[ "$PV_OK" == "OK" ]] && ((s+=10)) || true
  [[ "$MX_OK" == "OK" ]] && ((s+=10)) || true
  [[ "$TT_OK" == "OK" ]] && ((s+=10)) || true
  [[ "$AG_STATUS" == "OK" ]] && ((s+=15)) || true
  STREAM_SCORE="$(awk -v x="$s" 'BEGIN{printf "%.0f", x*100/90}')"
}

# ---------- TCP real path test (multi-source median) ----------
median_lower() {
  # prints lower-median for numeric list
  # usage: median_lower "${arr[@]}"
  local nums=("$@")
  local n="${#nums[@]}"
  (( n == 0 )) && { echo ""; return 0; }
  printf "%s\n" "${nums[@]}" | awk 'NF' | sort -n | awk -v n="$n" 'NR==int((n+1)/2){print; exit}'
}

tcp_one() {
  # args: name url
  local name="$1" url="$2"
  local range_bytes=$((TCP_RANGE_MB*1024*1024))
  local end=$((range_bytes-1))

  local fmt out code tls ttfb spd
  fmt=$'code=%{http_code} tls=%{time_appconnect} ttfb=%{time_starttransfer} spd=%{speed_download}'
  out="$(curl -L -s -o /dev/null --max-time "${TCP_MAXTIME}" -r "0-${end}" -A "Mozilla/5.0" -w "$fmt" "$url" 2>/dev/null || true)"

  code="$(echo "$out" | awk -F'code=' '{print $2}' | awk '{print $1}')"
  tls="$(echo "$out"  | awk -F'tls='  '{print $2}' | awk '{print $1}')"
  ttfb="$(echo "$out" | awk -F'ttfb=' '{print $2}' | awk '{print $1}')"
  spd="$(echo "$out"  | awk -F'spd='  '{print $2}' | awk '{print $1}')"

  # code==000 => fail
  if [[ -z "${code:-}" || "$code" == "000" ]]; then
    echo "${name}|FAIL|||"
    return 0
  fi

  tls="$(safe_num "$tls")"
  ttfb="$(safe_num "$ttfb")"
  spd="$(safe_num "$spd")"

  local tls_ms="" ttfb_ms="" dl_mbps=""
  if [[ -n "$tls" ]]; then tls_ms="$(awk -v x="$tls" 'BEGIN{printf "%.0f", x*1000}')" ; fi
  if [[ -n "$ttfb" ]]; then ttfb_ms="$(awk -v x="$ttfb" 'BEGIN{printf "%.0f", x*1000}')" ; fi
  if [[ -n "$spd" ]]; then dl_mbps="$(awk -v x="$spd" 'BEGIN{printf "%.2f", x*8/1000000}')" ; fi

  echo "${name}|OK|${code}|${tls_ms}|${ttfb_ms}|${dl_mbps}"
}

tcp_score_calc() {
  # inputs: tls_ms ttfb_ms dl_mbps -> score 0..100
  local tls="${1:-}" ttfb="${2:-}" dl="${3:-}"
  local s_tls=50 s_ttfb=50 s_dl=50

  if [[ -n "$tls" ]]; then
    if (( tls <= 80 )); then s_tls=100
    elif (( tls <= 200 )); then s_tls=80
    elif (( tls <= 500 )); then s_tls=60
    else s_tls=40
    fi
  fi

  if [[ -n "$ttfb" ]]; then
    if (( ttfb <= 150 )); then s_ttfb=100
    elif (( ttfb <= 400 )); then s_ttfb=80
    elif (( ttfb <= 900 )); then s_ttfb=60
    else s_ttfb=40
    fi
  fi

  if [[ -n "$dl" ]]; then
    # dl is float
    if f_ge "$dl" "200"; then s_dl=100
    elif f_ge "$dl" "50"; then s_dl=85
    elif f_ge "$dl" "10"; then s_dl=70
    elif f_ge "$dl" "3"; then s_dl=55
    else s_dl=40
    fi
  fi

  awk -v a="$s_tls" -v b="$s_ttfb" -v c="$s_dl" 'BEGIN{printf "%.0f", (a+b+c)/3}'
}

run_tcp() {
  RUN_TCP=1
  say "${MAGENTA}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${NC}"
  if ! need_cmd curl; then
    bad "缺少 curl，无法进行 TCP 测试。"
    TCP_SCORE=0; TCP_EVAL="unknown"
    hr
    return 0
  fi

  info "范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速（能测几个算几个）"

  # sources（尽量稳定、支持 Range）
  # 注：hetzner 可能在部分机房被 000/超时，属于正常现象（被墙/路由/风控/限速）
  local -a SRC_NAME SRC_URL
  SRC_NAME=("cloudflare" "hetzner" "ovh" "cachefly")
  SRC_URL=(
    "https://speed.cloudflare.com/__down?bytes=$((TCP_RANGE_MB*1024*1024))"
    "https://speed.hetzner.de/100MB.bin"
    "https://proof.ovh.net/files/100Mb.dat"
    "https://cachefly.cachefly.net/100mb.test"
  )

  local -a tls_list ttfb_list dl_list
  tls_list=(); ttfb_list=(); dl_list=()

  local best_dl="" best_src=""

  local ok_count=0
  for i in "${!SRC_NAME[@]}"; do
    local name="${SRC_NAME[$i]}" url="${SRC_URL[$i]}"
    local row status code tls_ms ttfb_ms dl_mbps
    row="$(tcp_one "$name" "$url")"

    status="$(echo "$row" | awk -F'|' '{print $2}')"
    code="$(echo "$row"   | awk -F'|' '{print $3}')"
    tls_ms="$(echo "$row" | awk -F'|' '{print $4}')"
    ttfb_ms="$(echo "$row"| awk -F'|' '{print $5}')"
    dl_mbps="$(echo "$row"| awk -F'|' '{print $6}')"

    if [[ "$status" != "OK" || -z "${dl_mbps:-}" ]]; then
      say "• ${GRAY}${name}:${NC} ${GRAY}失败/超时（跳过）${NC}"
      continue
    fi

    ((ok_count++)) || true
    tls_list+=("${tls_ms:-999999}")
    ttfb_list+=("${ttfb_ms:-999999}")
    dl_list+=("$dl_mbps")

    if [[ -z "${best_dl:-}" ]]; then
      best_dl="$dl_mbps"; best_src="$name"
    else
      awk -v a="$dl_mbps" -v b="$best_dl" 'BEGIN{exit (a>b)?0:1}' && { best_dl="$dl_mbps"; best_src="$name"; } || true
    fi

    say "• ${GREEN}${name}:${NC} TLS=${tls_ms:-?}ms  TTFB=${ttfb_ms:-?}ms  下载=${dl_mbps:-?}Mbps  code=${code}"
  done

  TCP_SAMPLES="$ok_count"
  TCP_BEST_SRC="${best_src:-}"

  if (( ok_count == 0 )); then
    warn "TCP：没有有效样本（可能被限速/风控/超时），建议换时间多测几次。"
    TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
    TCP_EVAL="unknown"; TCP_SCORE=0
    hr
    return 0
  fi

  # median(lower)
  TCP_TLS_MS="$(median_lower "${tls_list[@]}")"
  TCP_TTFB_MS="$(median_lower "${ttfb_list[@]}")"
  TCP_DL_MBPS="$(median_lower "${dl_list[@]}")"

  # if dl_mbps missing (shouldn't), safe
  local tls_ms="${TCP_TLS_MS:-}" ttfb_ms="${TCP_TTFB_MS:-}" dl_mbps="${TCP_DL_MBPS:-}"
  TCP_SCORE="$(tcp_score_calc "$tls_ms" "$ttfb_ms" "$dl_mbps")"

  # eval
  local g
  g="$(grade_zh "$TCP_SCORE")"
  if [[ "$g" == "优秀" || "$g" == "良好" ]]; then TCP_EVAL="GOOD"
  elif [[ "$g" == "一般" ]]; then TCP_EVAL="WARN"
  else TCP_EVAL="BAD"
  fi

  say ""
  say "${GRAY}中位数结果：TLS=${tls_ms:-?}ms | TTFB=${ttfb_ms:-?}ms | 下载=${dl_mbps:-?}Mbps（最佳=${best_src:-?} ${best_dl:-?}Mbps）${NC}"

  if (( ok_count < 2 )); then
    warn "TCP：有效样本不足（只有 ${ok_count} 个），结果参考性下降，建议换时间多测几次。"
  fi

  local gcol; gcol="$(color_by_level "$(grade_zh "$TCP_SCORE")")"
  say "${gcol}✅ TCP 体验：$(grade_zh "$TCP_SCORE")${NC}"
  hr
}

# ---------- overall summary ----------
overall_summary() {
  say "${MAGENTA}====================== ✅ VPS 体检总结报告 ======================${NC}"

  # 网络评分（Ping + MTR）
  local net_score=0
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"
    [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    [[ "$MTR_RATING" == "GOOD" ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')" || true
    [[ "$MTR_RATING" == "BAD"  ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')" || true
  fi
  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"
  local net_grade; net_grade="$(grade_zh "$net_score")"

  # 磁盘评分
  local disk_score=0
  [[ "$RUN_DISK" -eq 1 ]] && disk_score="${DISK_SCORE:-0}"
  local disk_grade; disk_grade="$(grade_zh "$disk_score")"

  # 流媒体评分
  local stream_score=0
  [[ "$RUN_STREAM" -eq 1 ]] && stream_score="${STREAM_SCORE:-0}"
  local stream_grade; stream_grade="$(grade_zh "$stream_score")"

  # TCP评分
  local tcp_score=0
  [[ "$RUN_TCP" -eq 1 ]] && tcp_score="${TCP_SCORE:-0}"
  local tcp_grade; tcp_grade="$(grade_zh "$tcp_score")"

  # 综合（权重：网络40 TCP25 磁盘15 流媒体20；没跑的不计入 used）
  local total=0 used=0
  if [[ "$RUN_PING" -eq 1 || "$RUN_MTR" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$net_score" -v w="40" 'BEGIN{printf "%.0f", t + x*w/100}')"
    ((used+=40)) || true
  fi
  if [[ "$RUN_TCP" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$tcp_score" -v w="25" 'BEGIN{printf "%.0f", t + x*w/100}')"
    ((used+=25)) || true
  fi
  if [[ "$RUN_DISK" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$disk_score" -v w="15" 'BEGIN{printf "%.0f", t + x*w/100}')"
    ((used+=15)) || true
  fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$stream_score" -v w="20" 'BEGIN{printf "%.0f", t + x*w/100}')"
    ((used+=20)) || true
  fi
  if [[ "$used" -gt 0 ]]; then
    total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"
  else
    total=0
  fi
  local overall; overall="$(grade_zh "$total")"

  # 打印基础信息
  say "${MAGENTA}[基础信息]${NC}"
  if [[ "$RUN_SYS" -eq 1 ]]; then
    say "Host : ${HOSTNAME_}"
    say "OS   : ${OS_}"
    say "Kern : ${KERNEL_} | Virt=${VIRT_}"
    say "CPU  : ${CPU_} | 核数=${CORES_} | 内存=${RAM_} | Swap=${SWAP_}"
    say "Disk : / ${DISKROOT_}"
  else
    say "（未执行）"
  fi
  if [[ "$RUN_IP" -eq 1 ]]; then
    say "IPv4 : ${IPV4_}"
    say "Geo  : ${GEO_}"
    say "ASN  : ${ASN_}"
    say "ISP  : ${ORG_}"
  else
    say "公网信息：未执行"
  fi
  hr

  # 网络
  local net_col; net_col="$(color_by_level "$net_grade")"
  say "${MAGENTA}[网络]${NC}  ${net_col}${net_score}/100（${net_grade}）${NC}  $(bar "$net_score" 30 "$net_col")"
  if [[ "$RUN_PING" -eq 1 ]]; then
    say "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-?}% | 最差平均延迟=${PING_WORST_AVG:-?}ms"
  else
    say "Ping : 未执行"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    local mtrzh; mtrzh="$(rating_zh "$MTR_RATING")"
    say "MTR  : 目标=${TARGETS[0]} | 终点丢包=${MTR_LASTLOSS:-?}% | 终点平均=${MTR_LASTAVG:-?}ms | 评级=${mtrzh}"
  else
    say "MTR  : 未执行"
  fi
  hr

  # TCP
  local tcp_col; tcp_col="$(color_by_level "$tcp_grade")"
  say "${MAGENTA}[TCP真实链路]${NC}  ${tcp_col}${tcp_score}/100（${tcp_grade}）${NC}  $(bar "$tcp_score" 30 "$tcp_col")"
  if [[ "$RUN_TCP" -eq 1 ]]; then
    say "TLS  : ${TCP_TLS_MS:-?}ms | TTFB=${TCP_TTFB_MS:-?}ms"
    say "DL   : ${TCP_DL_MBPS:-?}Mbps（中位数，range=${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
    say "样本 : ${TCP_SAMPLES} 个 | 最佳源=${TCP_BEST_SRC:-?}"
  else
    say "未执行"
  fi
  hr

  # 磁盘
  local disk_col; disk_col="$(color_by_level "$disk_grade")"
  say "${MAGENTA}[磁盘]${NC}  ${disk_col}${disk_score}/100（${disk_grade}）${NC}  $(bar "$disk_score" 30 "$disk_col")"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    say "dd   : ${DISK_SPEED_RAW} | 约 ${DISK_MBPS:-?} MB/s | 评级=$(rating_zh "$DISK_RATING")"
  else
    say "未执行"
  fi
  hr

  # 流媒体
  local stream_col; stream_col="$(color_by_level "$stream_grade")"
  say "${MAGENTA}[流媒体]${NC}  ${stream_col}${stream_score}/100（${stream_grade}）${NC}  $(bar "$stream_score" 30 "$stream_col")"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    # 输出中文态
    local yt="未知" nf="未知" dp="未知" tt="未知" pv="未知" mx="未知" ag="未知"
    [[ "$YT_OK" == "OK" ]] && yt="可访问"
    [[ "$NF_OK" == "OK" ]] && nf="可访问"
    [[ "$DP_OK" == "OK" ]] && dp="可访问"
    [[ "$TT_OK" == "OK" ]] && tt="可访问"
    [[ "$PV_OK" == "OK" ]] && pv="可访问"
    [[ "$MX_OK" == "OK" ]] && mx="可访问"
    case "$AG_STATUS" in
      OK) ag="可访问" ;;
      WAF_OR_RISK) ag="可能风控/拦截" ;;
      REGION_BLOCK) ag="地区限制" ;;
      *) ag="未知" ;;
    esac
    say "YouTube=${yt}(地区=${YT_CC}) | 动画疯=${ag} | Netflix=${nf} | Disney+=${dp} | TikTok=${tt} | Prime=${pv} | Max=${mx}"
  else
    say "未执行"
  fi
  hr

  # 总评
  local total_col; total_col="$(color_by_level "$overall")"
  say "${MAGENTA}[总评]${NC}  ${total_col}${total}/100（${overall}）${NC}  $(bar "$total" 30 "$total_col")"
  if [[ "$total" -ge 85 ]]; then
    ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then
    ok "结论：整体不错，日常中转/落地够用，关注路由与邻居波动。"
  elif [[ "$total" -ge 55 ]]; then
    warn "结论：整体一般，建议降低用途预期或换线路/机房。"
  else
    bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi

  say ""
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  say "${MAGENTA}===============================================================${NC}"
}

# ---------- redact (optional) ----------
maybe_redact() {
  # if user passes --redact : mask ipv4 and hostname in summary values
  local mask="${1:-0}"
  [[ "$mask" -ne 1 ]] && return 0

  HOSTNAME_="***"
  if [[ "$IPV4_" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    IPV4_="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.***.***"
  fi
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
  info "正在后台执行检测（2~8+10），完成后输出最终✅总结..."
  gather_system >/dev/null 2>&1 || true
  gather_ip     >/dev/null 2>&1 || true
  run_ping_all  >/dev/null 2>&1 || true
  run_mtr       >/dev/null 2>&1 || true
  run_disk      >/dev/null 2>&1 || true
  run_streaming >/dev/null 2>&1 || true
  run_tcp       >/dev/null 2>&1 || true
  overall_summary
}

# ---------- menu ----------
menu() {
  local REDACT=0
  if [[ "${1:-}" == "--redact" ]]; then REDACT=1; fi

  while true; do
    say "${MAGENTA}====================== VPS 一键体检 菜单 ======================${NC}"
    say "Targets: ${TARGETS[*]}  ${GRAY}(MTR 默认用第一个 Target)${NC}"
    say ""
    say "  1) 设置测试目标（Targets）"
    say "  2) 基本信息（系统/CPU/RAM/磁盘占用/虚拟化）"
    say "  3) 公网信息（IPv4 / Geo / ASN / ISP）"
    say "  4) 网络 Ping 测试（所有 Targets）"
    say "  5) 路由 MTR 测试（仅第一个 Target）"
    say "  6) 安装 mtr-tiny（Debian/Ubuntu）"
    say "  7) 磁盘 dd 测速（输出速度）"
    say "  8) 流媒体检测（YouTube/动画疯/Netflix/Disney+/TikTok/Prime/Max）"
    say "  9) 一键全跑（2~8+10）并输出最终总结（会显示全过程）"
    say " 10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
    say "  R) 后台静默全跑（2~8+10），只输出最终✅总结报告（不刷屏）"
    say "  0) 退出"
    hr
    read -r -p "选择 [0-10/R]: " c || true
    say ""
    case "${c:-}" in
      1) set_targets; pause ;;
      2) gather_system; pause ;;
      3) gather_ip; pause ;;
      4) run_ping_all; pause ;;
      5) run_mtr; pause ;;
      6) install_mtr; pause ;;
      7) run_disk; pause ;;
      8) run_streaming; pause ;;
      9) maybe_redact "$REDACT"; run_all_verbose; pause ;;
      10) run_tcp; pause ;;
      r|R) maybe_redact "$REDACT"; run_all_silent; pause ;;
      0|q|Q) ok "Bye."; exit 0 ;;
      *) warn "无效选择：${c:-空}（请输入 0-10 或 R）"; pause ;;
    esac
  done
}

# ---------- entry ----------
menu "${1:-}"
