#!/usr/bin/env bash
# =========================================================
# VPS Health + Streaming Check (Read-only) - Menu Edition
# - 交互菜单：可选跑 System / IP / Ping / MTR / Disk / Streaming / TCP
# - R：后台静默全跑（2~8+10）只输出最终✅总结（不刷屏）
# - 修复：ping/mtr/dd/TCP 解析更稳；不再出现 \033[0m / ??????
# - 增强：TCP 多源测速取“中位数”，不依赖 awk asort（兼容 mawk/busybox awk）
# - 输出：最终总结全中文，进度条彩色（优秀绿/良好蓝/一般黄/偏弱红）
# =========================================================

set -euo pipefail

# ---------- UI ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; CYAN="\033[36m"; MAGENTA="\033[35m"; GRAY="\033[90m"; NC="\033[0m"
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
TARGETS=("${DEFAULT_TARGETS[@]}")

# ---------- redact ----------
REDACT=0
if [[ "${1:-}" == "--redact" ]]; then REDACT=1; fi

redact_ip() {
  local ip="$1"
  if [[ "$REDACT" -eq 1 && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "${ip%.*}.***"
  else
    echo "$ip"
  fi
}
redact_host() {
  local h="$1"
  if [[ "$REDACT" -eq 1 && -n "$h" && "$h" != "unknown" ]]; then
    echo "***"
  else
    echo "$h"
  fi
}

# ---------- numeric helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

# ---------- state ----------
RUN_SYS=0 RUN_IP=0 RUN_PING=0 RUN_MTR=0 RUN_DISK=0 RUN_STREAM=0 RUN_TCP=0

HOSTNAME_="unknown"; OS_="unknown"; KERNEL_="unknown"; UPTIME_="unknown"; CPU_="unknown"
CORES_="1"; RAM_="0 MB"; SWAP_="0 MB"; LOAD_="unknown"; VIRT_="unknown"; DISKROOT_="unknown"

IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"

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

# tcp summary
TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""; TCP_SAMPLES=0; TCP_BEST=""; TCP_RATING="unknown"

# ---------- grade/color helpers ----------
grade_text() {
  local s="$1"
  if [[ "$s" -ge 85 ]]; then echo "优秀"
  elif [[ "$s" -ge 70 ]]; then echo "良好"
  elif [[ "$s" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}

# label -> color (优秀绿/良好蓝/一般黄/偏弱红/未知灰)
label_color() {
  local label="$1"
  case "$label" in
    优秀) echo "$GREEN" ;;
    良好) echo "$BLUE" ;;
    一般) echo "$YELLOW" ;;
    偏弱) echo "$RED" ;;
    *) echo "$GRAY" ;;
  esac
}

# status -> 中文
status_cn() {
  case "$1" in
    GOOD) echo "优秀" ;;
    WARN) echo "一般" ;;
    BAD)  echo "偏弱" ;;
    *)    echo "未知" ;;
  esac
}

# 彩色进度条（纯ASCII，避免乱码）
bar() {
  local score="$1" width="${2:-34}"
  score="$(safe_num "$score")"
  [[ -z "$score" ]] && score=0
  if (( score < 0 )); then score=0; fi
  if (( score > 100 )); then score=100; fi
  local filled=$(( score * width / 100 ))
  local empty=$(( width - filled ))
  local i

  # color by grade
  local label
  label="$(grade_text "$score")"
  local col
  col="$(label_color "$label")"

  printf "["
  echo -ne "${col}"
  for ((i=0;i<filled;i++)); do printf "="; done
  echo -ne "${NC}${GRAY}"
  for ((i=0;i<empty;i++)); do printf "."; done
  echo -ne "${NC}"
  printf "]"
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
  UPTIME_="$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/^.*up \([^,]*\),.*$/\1/' || echo unknown)"
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
  echo "Host      : $(redact_host "$HOSTNAME_")"
  echo "OS        : ${OS_}"
  echo "Kernel    : ${KERNEL_}"
  echo "Uptime    : ${UPTIME_}"
  echo "CPU       : ${CPU_} (${CORES_} 核)"
  echo "RAM/Swap  : ${RAM_} / ${SWAP_}"
  echo "Load      : ${LOAD_}"
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

  echo -e "${MAGENTA}--- 公网信息 ---${NC}"
  echo "IPv4      : $(redact_ip "$IPV4_")"
  echo "Geo       : ${GEO_}"
  echo "ASN       : ${ASN_}"
  echo "ISP/Org   : ${ORG_}"
  hr
}

# ---------- ping ----------
ping_once() { ping -c "${PING_COUNT}" -i "${2}" -n "$1" 2>/dev/null; }

# 兼容多种 ping 输出，强稳解析
parse_rtt_line() {
  # 输出：min avg max mdev（抓不到就空）
  # 可能行：
  # rtt min/avg/max/mdev = 0.1/0.2/0.3/0.0 ms
  # round-trip min/avg/max/stddev = ...
  local out="$1"
  local line
  line="$(echo "$out" | grep -E 'rtt |round-trip ' | tail -n 1 || true)"
  [[ -z "$line" ]] && { echo "   "; return 0; }
  # 抽取等号后面的 “a/b/c/d”
  local nums
  nums="$(echo "$line" | sed -n 's/.* = \([0-9.]\+\/[0-9.]\+\/[0-9.]\+\/[0-9.]\+\).*/\1/p')"
  [[ -z "$nums" ]] && { echo "   "; return 0; }
  echo "$nums" | awk -F/ '{print $1, $2, $3, $4}'
}

ping_test_one() {
  local target="$1"
  echo -e "${MAGENTA}--- Ping: ${target} (${PING_COUNT} 次) ---${NC}"

  if ! need_cmd ping; then
    warn "没有 ping 命令，跳过。"
    return 0
  fi

  local out loss min avg max mdev rtt
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    warn "间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  loss="$(safe_num "$loss")"

  rtt="$(parse_rtt_line "$out")"
  min="$(echo "$rtt" | awk '{print $1}')" ; avg="$(echo "$rtt" | awk '{print $2}')" ; max="$(echo "$rtt" | awk '{print $3}')" ; mdev="$(echo "$rtt" | awk '{print $4}')"
  min="$(safe_num "$min")"; avg="$(safe_num "$avg")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  echo "丢包 : ${loss:-?-}%"
  echo "RTT  : min=${min:--}ms  avg=${avg:--}ms  max=${max:--}ms  抖动=${mdev:--}ms"

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
  info "Ping 小结：目标数=${PING_TOTAL_TARGETS} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-?-}% 最差平均延迟=${PING_WORST_AVG:-?-}ms"
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
  echo -e "${MAGENTA}--- MTR: ${target} (${MTR_COUNT} 轮) ---${NC}"

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

  # mtr 最后一行通常是终点行（含主机名/IP）
  last_line="$(echo "$out" | tail -n 1 | tr -s ' ')"
  last_loss="$(echo "$last_line" | awk '{print $3}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $6}')"
  last_loss="$(safe_num "$last_loss")"; last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

  echo
  echo "终点(最后一跳)：丢包=${last_loss:--}%  平均=${last_avg:--}ms"
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
  echo "结果 : ${DISK_SPEED_RAW}"

  mbps="$(echo "$DISK_SPEED_RAW" | awk '{print $1}' 2>/dev/null || true)"
  unit="$(echo "$DISK_SPEED_RAW" | awk '{print $2}' 2>/dev/null || true)"
  mbps="$(safe_num "$mbps")"

  if [[ -n "${mbps:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')" ; fi
    DISK_MBPS="$mbps"
    if f_ge "$mbps" "200"; then ok "磁盘：优秀（≥200 MB/s）"; DISK_RATING="GOOD"
    elif f_ge "$mbps" "80"; then warn "磁盘：一般（80~200 MB/s）"; DISK_RATING="WARN"
    else bad "磁盘：偏弱（<80 MB/s）"; DISK_RATING="BAD"
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
  echo "YouTube Premium : HTTP ${yt_code}  地区: ${YT_CC}"
  if [[ "$yt_code" == "200" || "$yt_code" == "302" ]]; then ok "YouTube：可访问"; YT_OK="OK"
  else bad "YouTube：可能不可用（HTTP ${yt_code}）"; YT_OK="BAD"
  fi
  echo

  # AniGamer
  local ag_code ag_html
  ag_code="$(code_of "https://ani.gamer.com.tw/")"
  ag_html="$(fetch "https://ani.gamer.com.tw/")"
  echo "动画疯 : HTTP ${ag_code}"
  if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
    warn "动画疯：检测到地区限制提示"
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
  echo "Netflix : HTTP ${nf_code}"
  if [[ "$nf_code" == "200" || "$nf_code" == "302" ]]; then ok "Netflix：可访问（最终以登录播放为准）"; NF_OK="OK"
  else warn "Netflix：可能受限（HTTP ${nf_code}）"; NF_OK="WARN"
  fi
  echo

  # Disney+
  local dp_code
  dp_code="$(code_of "https://www.disneyplus.com/")"
  echo "Disney+ : HTTP ${dp_code}"
  if [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]]; then ok "Disney+：可访问（最终以登录播放为准）"; DP_OK="OK"
  else warn "Disney+：可能受限（HTTP ${dp_code}）"; DP_OK="WARN"
  fi
  echo

  # TikTok
  local tt_code tt_head tt_region tt_cf
  tt_code="$(code_of "https://www.tiktok.com/")"
  tt_head="$(head_req "https://www.tiktok.com/")"
  tt_region="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="x-tt-region"{print $2}' | tr -d '\r' | head -n1)"
  tt_cf="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="cf-ray"{print $2}' | tr -d '\r' | head -n1)"
  echo "TikTok  : HTTP ${tt_code}  x-tt-region: ${tt_region:-unknown}"
  if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then
    [[ -n "${tt_region:-}" ]] && ok "TikTok：可访问（推测地区 ${tt_region}）" || warn "TikTok：可访问但无法判断地区（易受风控/CF影响，cf-ray=${tt_cf:-n/a}）"
    TT_OK="OK"
  elif [[ "$tt_code" == "403" ]]; then
    bad "TikTok：403（常见于地区限制/风控/CF拦截）"
    TT_OK="BAD"
  else
    warn "TikTok：状态不确定（HTTP ${tt_code}）"
    TT_OK="WARN"
  fi
  echo

  # Prime Video
  local pv_code
  pv_code="$(code_of "https://www.primevideo.com/")"
  echo "Prime  : HTTP ${pv_code}"
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then ok "Prime：可访问（片库看账号地区）"; PV_OK="OK"
  else warn "Prime：可能受限（HTTP ${pv_code}）"; PV_OK="WARN"
  fi
  echo

  # Max
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  echo "Max    : HTTP ${mx_code}"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then ok "Max：可访问（最终以登录播放为准）"; MX_OK="OK"
  else warn "Max：可能受限（HTTP ${mx_code}）"; MX_OK="WARN"
  fi

  hr
  info "提示：Netflix/Disney+/Max/Prime 只能判断“可访问/疑似受限”，最终以登录播放为准。"
  info "提示：TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。"
  hr
}

# ---------- TCP Real Test (multi-source median, no asort) ----------
# 取 16MB 范围测速：Range + 限时 + 速度中位数（更贴近代理体验）
tcp_one() {
  # $1=name $2=url $3=use_range(0/1)
  local name="$1" url="$2" use_range="${3:-1}"

  # 1) TLS/TTFB：用 curl write-out（time_appconnect=time to TLS handshake; time_starttransfer=TTFB）
  local tls ttfb code
  local wout
  wout="$(curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" \
    -w "%{time_appconnect} %{time_starttransfer} %{http_code}" "$url" 2>/dev/null || true)"
  tls="$(echo "$wout" | awk '{print $1}')" ; ttfb="$(echo "$wout" | awk '{print $2}')" ; code="$(echo "$wout" | awk '{print $3}')"

  # 秒 -> ms
  tls="$(safe_num "$tls")"; ttfb="$(safe_num "$ttfb")"
  local tls_ms="" ttfb_ms=""
  [[ -n "$tls" ]] && tls_ms="$(awk -v x="$tls" 'BEGIN{printf "%.0f", x*1000}')" || true
  [[ -n "$ttfb" ]] && ttfb_ms="$(awk -v x="$ttfb" 'BEGIN{printf "%.0f", x*1000}')" || true

  # 2) Download：用 range 控制 16MB，测平均下载速率（bytes/s -> Mbps）
  local range_arg=()
  if [[ "$use_range" == "1" ]]; then
    range_arg=(-r 0-16777215)   # 16MB-1
  fi

  local bytes_per_sec
  bytes_per_sec="$(curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" \
    "${range_arg[@]}" -w "%{speed_download} %{http_code}" "$url" 2>/dev/null | awk '{print $1, $2}' || true)"

  local sp code2
  sp="$(echo "$bytes_per_sec" | awk '{print $1}')" ; code2="$(echo "$bytes_per_sec" | awk '{print $2}')"
  sp="$(safe_num "$sp")"

  local mbps=""
  if [[ -n "$sp" ]]; then
    # bytes/s -> Mbps
    mbps="$(awk -v b="$sp" 'BEGIN{printf "%.2f", (b*8)/1000000 }')"
  fi

  # 如果 code2 为空，用前一个 code
  [[ -z "${code2:-}" ]] && code2="${code:-000}"
  # 判断是否有效：HTTP 200/206 且 mbps 有数
  if [[ "$code2" =~ ^(200|206)$ && -n "${mbps:-}" ]]; then
    echo "${name}|OK|${tls_ms:-}|${ttfb_ms:-}|${mbps}|${code2}"
  else
    echo "${name}|FAIL|${tls_ms:-}|${ttfb_ms:-}|${mbps:-}|${code2:-000}"
  fi
}

# 求中位数：纯 bash 排序（n小，最多4个源），不用 awk asort
median_of_list() {
  # 输入：若干数字（字符串数组）
  local arr=("$@")
  local n="${#arr[@]}"
  (( n == 0 )) && { echo ""; return 0; }

  # 简单冒泡排序（n<=4）
  local i j tmp
  for ((i=0;i<n;i++)); do
    for ((j=0;j<n-1;j++)); do
      awk -v a="${arr[j]}" -v b="${arr[j+1]}" 'BEGIN{exit (a>b)?0:1}' && {
        tmp="${arr[j]}"; arr[j]="${arr[j+1]}"; arr[j+1]="$tmp";
      } || true
    done
  done

  if (( n % 2 == 1 )); then
    echo "${arr[$((n/2))]}"
  else
    # 偶数：取中间两个平均
    awk -v a="${arr[$((n/2-1))]}" -v b="${arr[$((n/2))]}" 'BEGIN{printf "%.2f", (a+b)/2}'
  fi
}

run_tcp() {
  RUN_TCP=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做 TCP 真实链路测试。"
    TCP_RATING="unknown"
    return 0
  fi

  echo -e "${MAGENTA}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${NC}"
  echo -e "${CYAN}范围: 16MB | 超时: ${CURL_TIMEOUT}s | 多源测速（能测几个算几个）${NC}"

  # sources（尽量使用支持 range 的静态文件）
  # cloudflare: 用大文件 CDN（可 range）
  local cf_url="https://speed.cloudflare.com/__down?bytes=16777216"
  # hetzner: 有些机房/线路会 000 超时，允许失败
  local hz_url="https://speed.hetzner.de/100MB.bin"
  # ovh: 用可 range 文件
  local ovh_url="https://proof.ovh.net/files/100Mb.dat"
  # cachefly: 可能被限速/风控，允许失败
  local cf2_url="https://cachefly.cachefly.net/100mb.test"

  local lines=()
  lines+=("$(tcp_one "cloudflare" "$cf_url" 0)")
  lines+=("$(tcp_one "hetzner" "$hz_url" 1)")
  lines+=("$(tcp_one "ovh" "$ovh_url" 1)")
  lines+=("$(tcp_one "cachefly" "$cf2_url" 1)")

  local ok_tls=() ok_ttfb=() ok_dl=()
  local best_dl=0 best_name=""
  TCP_SAMPLES=0

  local line name st tls_ms ttfb_ms dl code
  for line in "${lines[@]}"; do
    IFS='|' read -r name st tls_ms ttfb_ms dl code <<< "$line"

    if [[ "$st" == "OK" ]]; then
      ((TCP_SAMPLES++)) || true
      [[ -n "${tls_ms:-}" ]] && ok_tls+=("$tls_ms") || true
      [[ -n "${ttfb_ms:-}" ]] && ok_ttfb+=("$ttfb_ms") || true
      [[ -n "${dl:-}" ]] && ok_dl+=("$dl") || true

      # best
      if [[ -n "${dl:-}" ]]; then
        awk -v a="$dl" -v b="$best_dl" 'BEGIN{exit (a>b)?0:1}' && { best_dl="$dl"; best_name="$name"; } || true
      fi

      echo -e "• ${GREEN}${name}${NC}: TLS=${tls_ms:-?-}ms  TTFB=${ttfb_ms:-?-}ms  下载=${dl:-?-}Mbps  code=${code}"
    else
      # 失败显示中文
      local failmsg="失败/超时"
      if [[ "${code:-000}" == "000" ]]; then failmsg="失败/超时"; fi
      echo -e "• ${GRAY}${name}${NC}: ${failmsg}（跳过）"
    fi
  done

  # median
  local med_tls med_ttfb med_dl
  med_tls="$(median_of_list "${ok_tls[@]}")"
  med_ttfb="$(median_of_list "${ok_ttfb[@]}")"
  med_dl="$(median_of_list "${ok_dl[@]}")"

  TCP_TLS_MS="${med_tls:-}"
  TCP_TTFB_MS="${med_ttfb:-}"
  TCP_DL_MBPS="${med_dl:-}"
  TCP_BEST="${best_name:-}"

  echo
  if (( TCP_SAMPLES < 2 )); then
    warn "TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。"
    TCP_RATING="unknown"
    hr
    return 0
  fi

  echo -e "${GRAY}中位数结果：TLS=${TCP_TLS_MS:-?-}ms | TTFB=${TCP_TTFB_MS:-?-}ms | 下载=${TCP_DL_MBPS:-?-}Mbps（最佳=${TCP_BEST:-unknown} ${best_dl:-0}Mbps）${NC}"

  # rating (粗略规则：DL为主，TTFB/TLS辅助)
  # DL >= 50 优秀；10~50 良好；3~10 一般；<3 偏弱
  local dlv
  dlv="$(safe_num "$TCP_DL_MBPS")"
  if [[ -z "$dlv" ]]; then
    TCP_RATING="unknown"
    warn "TCP：无法计算评分（下载值缺失）"
  else
    if f_ge "$dlv" "50"; then
      ok "TCP 体验：优秀"
      TCP_RATING="GOOD"
    elif f_ge "$dlv" "10"; then
      echo -e "${BLUE}✅ TCP 体验：良好${NC}"
      TCP_RATING="GOOD"   # 记为偏好上限，最终分数按 DL 算
    elif f_ge "$dlv" "3"; then
      warn "TCP 体验：一般"
      TCP_RATING="WARN"
    else
      bad "TCP 体验：偏弱"
      TCP_RATING="BAD"
    fi
  fi

  hr
}

# ---------- overall summary ----------
overall_summary() {
  echo -e "${MAGENTA}====================== ✅ VPS 体检总结报告 ======================${NC}"

  # scores
  local net_score=0 disk_score=0 stream_score=0 tcp_score=0 total=0
  local net_label="未知" disk_label="未知" stream_label="未知" tcp_label="未知" overall_label="未知"

  # network score based on ping + mtr
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"
    [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  else
    net_score=0
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    if [[ "$MTR_RATING" == "GOOD" ]]; then net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')" ; fi
    if [[ "$MTR_RATING" == "BAD"  ]]; then net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')" ; fi
  fi
  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"
  net_label="$(grade_text "$net_score")"

  # disk score
  if [[ "$RUN_DISK" -eq 1 ]]; then
    case "$DISK_RATING" in
      GOOD) disk_score=90 ;;
      WARN) disk_score=70 ;;
      BAD)  disk_score=50 ;;
      *)    disk_score=0 ;;
    esac
  else
    disk_score=0
  fi
  disk_label="$(grade_text "$disk_score")"

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
    stream_score="$s"
    stream_score="$(awk -v x="$stream_score" 'BEGIN{printf "%.0f", x*100/90}')"
  else
    stream_score=0
  fi
  stream_label="$(grade_text "$stream_score")"

  # tcp score (use DL median)
  if [[ "$RUN_TCP" -eq 1 ]]; then
    local dlv
    dlv="$(safe_num "$TCP_DL_MBPS")"
    if [[ -z "$dlv" ]]; then
      tcp_score=0
    else
      if f_ge "$dlv" "50"; then tcp_score=90
      elif f_ge "$dlv" "10"; then tcp_score=80
      elif f_ge "$dlv" "3";  then tcp_score=65
      else tcp_score=40
      fi
    fi
  else
    tcp_score=0
  fi
  tcp_label="$(grade_text "$tcp_score")"

  # total weights (net 35, tcp 25, disk 15, stream 25)
  local w_net=35 w_tcp=25 w_disk=15 w_stream=25 used=0
  total=0
  if [[ "$RUN_PING" -eq 1 || "$RUN_MTR" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$net_score" -v w="$w_net" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_net)) || true; fi
  if [[ "$RUN_TCP" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$tcp_score" -v w="$w_tcp" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_tcp)) || true; fi
  if [[ "$RUN_DISK" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$disk_score" -v w="$w_disk" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_disk)) || true; fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$stream_score" -v w="$w_stream" 'BEGIN{printf "%.0f", t + x*w/100}')"; ((used+=w_stream)) || true; fi
  if [[ "$used" -gt 0 ]]; then total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"; fi
  overall_label="$(grade_text "$total")"

  # ---------- print ----------
  echo -e "${MAGENTA}[基础信息]${NC}"
  if [[ "$RUN_SYS" -eq 1 ]]; then
    echo "Host : $(redact_host "$HOSTNAME_")"
    echo "OS   : ${OS_}"
    echo "Kern : ${KERNEL_} | Virt=${VIRT_}"
    echo "CPU  : ${CPU_} | 核数=${CORES_} | 内存=${RAM_} | Swap=${SWAP_}"
    echo "Disk : / ${DISKROOT_}"
  else
    echo "（未执行）"
  fi
  if [[ "$RUN_IP" -eq 1 ]]; then
    echo "IPv4 : $(redact_ip "$IPV4_")"
    echo "Geo  : ${GEO_}"
    echo "ASN  : ${ASN_}"
    echo "ISP  : ${ORG_}"
  else
    echo "公网信息：未执行"
  fi
  hr

  # 网络
  local net_col; net_col="$(label_color "$net_label")"
  echo -e "${MAGENTA}[网络]${NC}  ${net_score}/100 ${net_col}(${net_label})${NC}  $(bar "$net_score")"
  if [[ "$RUN_PING" -eq 1 ]]; then
    echo "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-?-}% | 最差平均延迟=${PING_WORST_AVG:-?-}ms"
  else
    echo "Ping : 未执行"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    local mtr_cn; mtr_cn="$(status_cn "$MTR_RATING")"
    echo "MTR  : 目标=${TARGETS[0]} | 终点丢包=${MTR_LASTLOSS:--}% | 终点平均=${MTR_LASTAVG:--}ms | 评级=${mtr_cn}"
  else
    echo "MTR  : 未执行"
  fi
  hr

  # TCP
  local tcp_col; tcp_col="$(label_color "$tcp_label")"
  echo -e "${MAGENTA}[TCP真实链路]${NC}  ${tcp_score}/100 ${tcp_col}(${tcp_label})${NC}  $(bar "$tcp_score")"
  if [[ "$RUN_TCP" -eq 1 ]]; then
    echo "TLS  : ${TCP_TLS_MS:--}ms | TTFB=${TCP_TTFB_MS:--}ms"
    echo "DL   : ${TCP_DL_MBPS:--}Mbps（中位数，range=16MB，超时=${CURL_TIMEOUT}s）"
    echo "样本 : ${TCP_SAMPLES} 个 | 最佳源=${TCP_BEST:-unknown}"
  else
    echo "未执行"
  fi
  hr

  # 磁盘
  local dcol; dcol="$(label_color "$disk_label")"
  echo -e "${MAGENTA}[磁盘]${NC}  ${disk_score}/100 ${dcol}(${disk_label})${NC}  $(bar "$disk_score")"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    echo "dd   : ${DISK_SPEED_RAW} | 约 ${DISK_MBPS:-?-} MB/s | 评级=$(status_cn "$DISK_RATING")"
  else
    echo "未执行"
  fi
  hr

  # 流媒体
  local scol; scol="$(label_color "$stream_label")"
  echo -e "${MAGENTA}[流媒体]${NC}  ${stream_score}/100 ${scol}(${stream_label})${NC}  $(bar "$stream_score")"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    # 中文化状态
    local ag="未知"
    case "$AG_STATUS" in
      OK) ag="可访问" ;;
      WAF_OR_RISK) ag="可能风控/拦截" ;;
      REGION_BLOCK) ag="地区限制" ;;
      *) ag="未知" ;;
    esac
    echo "YouTube=可访问(地区=${YT_CC:-unknown}) | 动画疯=${ag} | Netflix=$( [[ "$NF_OK" == "OK" ]] && echo "可访问" || echo "疑似受限" ) | Disney+=$( [[ "$DP_OK" == "OK" ]] && echo "可访问" || echo "疑似受限" ) | TikTok=$( [[ "$TT_OK" == "OK" ]] && echo "可访问" || echo "疑似受限" ) | Prime=$( [[ "$PV_OK" == "OK" ]] && echo "可访问" || echo "疑似受限" ) | Max=$( [[ "$MX_OK" == "OK" ]] && echo "可访问" || echo "疑似受限" )"
  else
    echo "未执行"
  fi
  hr

  # 总评
  local ocol; ocol="$(label_color "$overall_label")"
  echo -e "${MAGENTA}[总评]${NC}  ${total}/100 ${ocol}(${overall_label})${NC}  $(bar "$total")"
  if [[ "$total" -ge 85 ]]; then ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then echo -e "${BLUE}✅ 结论：整体不错，日常中转/落地够用，关注路由与邻居波动。${NC}"
  elif [[ "$total" -ge 55 ]]; then warn "结论：整体一般，建议降低用途预期或换机房/换商家。"
  else bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
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
  info "正在后台静默执行检测（2~8+10），完成后输出最终✅总结..."
  {
    gather_system >/dev/null
    gather_ip >/dev/null
    run_ping_all >/dev/null
    run_mtr >/dev/null
    run_disk >/dev/null
    run_streaming >/dev/null
    run_tcp >/dev/null
  } 2>/dev/null || true
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
      *) warn "无效选择：${c:-空}（请输入 0-10 或 R）"; pause ;;
    esac
  done
}

menu
