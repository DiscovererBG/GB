#!/usr/bin/env bash
# =========================================================
# VPS Health + Streaming + TCP Real Test (Read-only) - Menu
# - 修复：mawk 无 asort -> 使用 sort 计算中位数（兼容 Debian 默认 mawk）
# - 修复：总结进度条出现 ???? -> 改用 ASCII '=' '.' + ANSI 颜色（不再依赖 █）
# - 优化：Ping/MTR 解析更稳；Ping 小结全中文；颜色统一
# - 新增：10) TCP 真实链路（多源测速取“中位数”）
# - 新增：R) 后台静默全跑（2~8+10），只输出最终✅总结报告（不刷屏）
# - 只读检测，不改系统配置（除非你选 6 安装 mtr）
# =========================================================

set -euo pipefail

# -------------------- Colors --------------------
NC="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
GRAY="\033[90m"

# “亮色”更醒目（可改成普通色）
LRED="\033[91m"
LGREEN="\033[92m"
LYELLOW="\033[93m"
LBLUE="\033[94m"
LMAGENTA="\033[95m"
LCYAN="\033[96m"
LGRAY="\033[37m"

ok()   { echo -e "${LGREEN}✅ $*${NC}"; }
warn() { echo -e "${LYELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${LRED}❌ $*${NC}"; }
info() { echo -e "${LCYAN}ℹ️  $*${NC}"; }
hr()   { echo -e "${LMAGENTA}---------------------------------------------------------${NC}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# -------------------- Defaults --------------------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5

MTR_COUNT=100

DISK_TEST_MB=256
CURL_TIMEOUT=10

DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# TCP real test
TCP_MAXTIME=12
TCP_RANGE_MB=16
TCP_RANGE_BYTES=$((TCP_RANGE_MB*1024*1024))

# Multi sources (能测几个算几个)
TCP_SOURCES=(
  "cloudflare|https://speed.cloudflare.com/__down?bytes=${TCP_RANGE_BYTES}"
  "hetzner|https://speed.hetzner.de/100MB.bin"
  "ovh|https://proof.ovh.net/files/100Mb.dat"
  "cachefly|https://cachefly.cachefly.net/100mb.test"
)

# -------------------- Numeric helpers --------------------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }

f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

to_ms() { awk -v s="${1:-0}" 'BEGIN{printf "%.0f", s*1000}'; }

# -------------------- Redact mode --------------------
REDACT=0
if [[ "${1:-}" == "--redact" ]]; then REDACT=1; shift || true; fi

mask_ip() {
  local ip="${1:-unknown}"
  if [[ "$REDACT" -eq 0 ]]; then echo "$ip"; return; fi
  if [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.***.***"
  else
    echo "masked"
  fi
}
mask_host() {
  local h="${1:-unknown}"
  if [[ "$REDACT" -eq 0 ]]; then echo "$h"; return; fi
  [[ -z "$h" || "$h" == "unknown" ]] && echo "masked" && return
  echo "${h:0:2}***"
}

# -------------------- Global state --------------------
RUN_SYS=0 RUN_IP=0 RUN_PING=0 RUN_MTR=0 RUN_DISK=0 RUN_STREAM=0 RUN_TCP=0

HOSTNAME_="unknown"; OS_=""; KERNEL_=""; UPTIME_=""; CPU_=""; CORES_=""; RAM_=""; SWAP_=""; LOAD_=""; VIRT_=""; DISKROOT_=""
IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"

TARGETS=("${DEFAULT_TARGETS[@]}")

# Ping summary
PING_TOTAL_TARGETS=0
PING_GOOD=0
PING_WARN=0
PING_BAD=0
PING_WORST_LOSS=""
PING_WORST_AVG=""

# MTR summary
MTR_LASTLOSS=""
MTR_LASTAVG=""
MTR_RATING="unknown"

# Disk summary
DISK_SPEED_RAW="unknown"
DISK_MBPS=""
DISK_RATING="unknown"

# Stream summary
YT_CC="unknown"; YT_OK="unknown"
AG_STATUS="unknown"
NF_OK="unknown"
DP_OK="unknown"
TT_OK="unknown"
PV_OK="unknown"
MX_OK="unknown"

# TCP summary
TCP_TLS_MS=""   # median
TCP_TTFB_MS=""  # median
TCP_DL_MBPS=""  # median
TCP_BEST_MBPS=""
TCP_RATING="unknown"
TCP_LAST_TEXT=""

pause() { read -r -p "回车继续..." _ || true; }

# -------------------- Pretty helpers --------------------
grade_text() {
  local score="$1"
  if [[ "$score" -ge 85 ]]; then echo "优秀"
  elif [[ "$score" -ge 70 ]]; then echo "良好"
  elif [[ "$score" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}
grade_color() {
  local g="$1"
  case "$g" in
    "优秀") echo -e "${LGREEN}${g}${NC}" ;;
    "良好") echo -e "${LCYAN}${g}${NC}" ;;
    "一般") echo -e "${LYELLOW}${g}${NC}" ;;
    "偏弱") echo -e "${LRED}${g}${NC}" ;;
    *) echo "$g" ;;
  esac
}

# ASCII 进度条（避免 █ 导致 ????）
bar() {
  local score="${1:-0}" width="${2:-28}" color="${3:-LGREEN}"
  local filled=$(( score*width/100 ))
  ((filled<0)) && filled=0
  ((filled>width)) && filled=$width

  local fill_str="" empty_str=""
  for ((i=0;i<filled;i++)); do fill_str+="="; done
  for ((i=filled;i<width;i++)); do empty_str+="."; done

  local c=""
  case "$color" in
    LGREEN) c="$LGREEN" ;;
    LCYAN)  c="$LCYAN" ;;
    LYELLOW)c="$LYELLOW" ;;
    LRED)   c="$LRED" ;;
    *) c="$LGREEN" ;;
  esac
  echo -e "[${c}${fill_str}${GRAY}${empty_str}${NC}]"
}

score_color_key() {
  local score="$1"
  if [[ "$score" -ge 85 ]]; then echo "LGREEN"
  elif [[ "$score" -ge 70 ]]; then echo "LCYAN"
  elif [[ "$score" -ge 55 ]]; then echo "LYELLOW"
  else echo "LRED"
  fi
}

# -------------------- Targets --------------------
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

# -------------------- System --------------------
gather_system() {
  RUN_SYS=1
  HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
  UPTIME_="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"
  OS_="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null || echo "")"
  KERNEL_="$(uname -r 2>/dev/null || echo unknown)"
  CPU_="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || echo "")"
  CORES_="$(nproc 2>/dev/null || echo 1)"
  RAM_="$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  SWAP_="$(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  LOAD_="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || echo "")"
  VIRT_="unknown"
  if need_cmd systemd-detect-virt; then VIRT_="$(systemd-detect-virt 2>/dev/null || echo none)"; fi
  DISKROOT_="$(df -hP / 2>/dev/null | tail -n 1 | awk '{print $3"/"$2" ("$5")"}' || echo "")"

  echo -e "${LMAGENTA}--- 基本信息 ---${NC}"
  echo "Host      : $(mask_host "$HOSTNAME_")"
  echo "OS        : ${OS_:-unknown}"
  echo "Kernel    : ${KERNEL_}"
  echo "Uptime    : ${UPTIME_}"
  echo "CPU       : ${CPU_:-unknown} (${CORES_} cores)"
  echo "RAM/Swap  : ${RAM_} / ${SWAP_}"
  echo "Load avg  : ${LOAD_:-unknown}"
  echo "Virt      : ${VIRT_}"
  echo "Disk /    : ${DISKROOT_:-unknown}"
  hr
}

# -------------------- Public IP --------------------
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

  echo -e "${LMAGENTA}--- 公网信息 ---${NC}"
  echo "IPv4      : $(mask_ip "$IPV4_")"
  echo "Geo       : ${GEO_}"
  echo "ASN       : ${ASN_}"
  echo "ISP/Org   : ${ORG_}"
  hr
}

# -------------------- Ping --------------------
ping_once() {
  local target="$1" interval="$2"
  ping -c "${PING_COUNT}" -i "${interval}" -n "$target" 2>/dev/null
}

parse_ping_rtt_line() {
  # Input: ping output; output: "min avg max mdev" (mdev may be empty)
  local out="$1"
  local line part nums
  line="$(echo "$out" | awk '/rtt|round-trip/ {print; exit}')"
  [[ -z "${line:-}" ]] && { echo ""; return; }
  part="${line#*=}"
  part="${part% ms*}"
  part="$(echo "$part" | tr -d ' ')"
  # part like 0.026/0.030/0.034/0.003 or 0.059/0.059/0.059
  nums="$part"
  echo "$nums"
}

ping_test_one() {
  local target="$1"
  echo -e "${LMAGENTA}--- Ping: ${target} (${PING_COUNT} packets) ---${NC}"

  if ! need_cmd ping; then
    warn "没有 ping 命令，跳过。"
    return 0
  fi

  local out loss rtts min avg max mdev
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  # loss: find token like "0%" before "packet loss"
  loss="$(echo "$out" | awk '/packet loss/{
      for(i=1;i<=NF;i++){
        if($i ~ /%/){gsub(/%/,"",$i); print $i; exit}
      }
    }')"
  loss="$(safe_num "$loss")"

  rtts="$(parse_ping_rtt_line "$out")"
  min="$(echo "$rtts" | awk -F/ '{print $1}')"
  avg="$(echo "$rtts" | awk -F/ '{print $2}')"
  max="$(echo "$rtts" | awk -F/ '{print $3}')"
  mdev="$(echo "$rtts" | awk -F/ '{print $4}')"
  min="$(safe_num "$min")"; avg="$(safe_num "$avg")"; max="$(safe_num "$max")"; mdev="$(safe_num "$mdev")"

  echo "Loss      : ${loss:-?}%"
  if [[ -n "${mdev:-}" ]]; then
    echo "RTT ms    : min=${min:-?} avg=${avg:-?} max=${max:-?} mdev=${mdev:-?}"
  else
    echo "RTT ms    : min=${min:-?} avg=${avg:-?} max=${max:-?}"
  fi

  # rating by loss
  local rating="WARN"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="GOOD"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="WARN"
  else rating="BAD"
  fi

  if [[ "$rating" == "GOOD" ]]; then ok "丢包：优秀（<=1%）"; ((PING_GOOD++)) || true
  elif [[ "$rating" == "WARN" ]]; then warn "丢包：一般（1%~5%）"; ((PING_WARN++)) || true
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
  info "Ping 小结：目标数=${PING_TOTAL_TARGETS} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-?}% 最差平均延迟=${PING_WORST_AVG:-?}ms"
  hr
}

# -------------------- MTR --------------------
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
  echo -e "${LMAGENTA}--- MTR: ${target} (${MTR_COUNT} cycles) ---${NC}"

  if ! need_cmd mtr; then
    warn "未安装 mtr。（可在菜单选择 6 安装 mtr-tiny）"
    MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"
    hr
    return 0
  fi

  local out last_line last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"

  # 展示首尾，避免刷屏太多
  echo "$out" | head -n 3
  echo -e "${GRAY}...（中间省略）...${NC}"
  echo "$out" | tail -n 6

  # 取“最后一个 hop 行”（更稳，不用 tail -1）
  last_line="$(echo "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"

  # columns: hop host loss% snt last avg best wrst stdev
  last_loss="$(echo "$last_line" | awk '{gsub(/%/,"",$3); print $3}')"
  last_avg="$(echo "$last_line" | awk '{print $6}')"

  last_loss="$(safe_num "$last_loss")"
  last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"
  MTR_LASTAVG="${last_avg:-}"

  echo
  echo "终点（最后一跳）：Loss=${last_loss:-?}%  Avg=${last_avg:-?} ms"
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

# -------------------- Disk dd --------------------
run_disk() {
  RUN_DISK=1
  echo -e "${LMAGENTA}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"
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
    elif f_ge "$mbps" "80"; then warn "磁盘：一般（80~200 MB/s）"; DISK_RATING="WARN"
    else bad "磁盘：偏弱（<80 MB/s）"; DISK_RATING="BAD"
    fi
  else
    warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
    DISK_RATING="unknown"
  fi
  hr
}

# -------------------- Streaming --------------------
fetch()   { curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
head_req(){ curl -I -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
code_of() { curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }

run_streaming() {
  RUN_STREAM=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做流媒体检测。"
    return 0
  fi

  echo -e "${LMAGENTA}--- 流媒体解锁检测（best-effort）---${NC}"

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
  local tt_code tt_head tt_region
  tt_code="$(code_of "https://www.tiktok.com/")"
  tt_head="$(head_req "https://www.tiktok.com/")"
  tt_region="$(echo "$tt_head" | awk -F': ' 'tolower($1)=="x-tt-region"{print $2}' | tr -d '\r' | head -n1)"
  echo "TikTok HTTP          : ${tt_code}  x-tt-region: ${tt_region:-unknown}"
  if [[ "$tt_code" == "200" || "$tt_code" == "302" ]]; then TT_OK="OK"; warn "TikTok：可访问但可能无法判断地区（易受风控/CF 影响）"
  elif [[ "$tt_code" == "403" ]]; then TT_OK="BAD"; bad "TikTok：403（常见于地区限制/风控/CF 拦截）"
  else TT_OK="WARN"; warn "TikTok：状态不确定（HTTP ${tt_code}）"
  fi
  echo

  # Prime Video
  local pv_code
  pv_code="$(code_of "https://www.primevideo.com/")"
  echo "PrimeVideo HTTP      : ${pv_code}"
  if [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]]; then PV_OK="OK"; ok "Prime Video：可访问（片库看账号地区）"
  else PV_OK="WARN"; warn "Prime Video：可能不可访问/风控（HTTP ${pv_code}）"
  fi
  echo

  # Max
  local mx_code
  mx_code="$(code_of "https://play.max.com/")"
  echo "Max(HBO) HTTP        : ${mx_code}"
  if [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]]; then MX_OK="OK"; ok "Max：可访问（最终以登录播放为准）"
  else MX_OK="WARN"; warn "Max：可能不可访问/地区限制（HTTP ${mx_code}）"
  fi
  echo

  hr
  info "提示：Netflix/Disney+/Max/Prime 仅能判断“可访问/疑似限制”，最终以登录播放为准。"
  info "TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。"
  hr
}

# -------------------- Median helpers (NO asort) --------------------
median_from_lines() {
  # input: numbers in stdin, one per line
  local n
  n="$(wc -l | awk '{print $1}')"
  [[ -z "${n:-}" || "$n" -le 0 ]] && { echo ""; return; }

  local sorted
  sorted="$(cat | sort -n)"
  if (( n % 2 == 1 )); then
    local mid=$(( (n+1)/2 ))
    echo "$sorted" | awk -v m="$mid" 'NR==m{print $1; exit}'
  else
    local m1=$(( n/2 ))
    local m2=$(( m1+1 ))
    local a b
    a="$(echo "$sorted" | awk -v m="$m1" 'NR==m{print $1; exit}')"
    b="$(echo "$sorted" | awk -v m="$m2" 'NR==m{print $1; exit}')"
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f", (a+b)/2}'
  fi
}

# -------------------- TCP Real Test --------------------
tcp_one_source() {
  # echo: name|tls_ms|ttfb_ms|dl_mbps|http_code|ok(1/0)
  local name="$1" url="$2"
  local range_args=()

  # cloudflare down?bytes=... already exact size; others use range
  if [[ "$name" != "cloudflare" ]]; then
    range_args=(--range "0-$((TCP_RANGE_BYTES-1))")
  fi

  # time_appconnect=TLS handshake time (https), time_starttransfer=TTFB (start transfer)
  local w out time_total size_dl code t_app t_ttfb
  w="%{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{http_code}"

  out="$(curl -L -s -o /dev/null -A "Mozilla/5.0" --max-time "${TCP_MAXTIME}" "${range_args[@]}" -w "$w" "$url" 2>/dev/null || true)"
  t_app="$(echo "$out" | awk '{print $1}')"
  t_ttfb="$(echo "$out" | awk '{print $2}')"
  time_total="$(echo "$out" | awk '{print $3}')"
  size_dl="$(echo "$out" | awk '{print $4}')"
  code="$(echo "$out" | awk '{print $5}')"

  # convert to ms
  local tls_ms ttfb_ms
  tls_ms="$(to_ms "${t_app:-0}")"
  ttfb_ms="$(to_ms "${t_ttfb:-0}")"

  # Mbps
  local mbps=""
  if is_number "${time_total:-}" && is_number "${size_dl:-}" && awk -v t="$time_total" 'BEGIN{exit (t>0)?0:1}'; then
    mbps="$(awk -v s="$size_dl" -v t="$time_total" 'BEGIN{printf "%.2f", (s*8)/(t*1000000)}')"
  fi

  # ok if code 200 or 206
  local okflag=0
  if [[ "$code" == "200" || "$code" == "206" ]]; then okflag=1; fi

  echo "${name}|${tls_ms}|${ttfb_ms}|${mbps:-}|${code:-000}|${okflag}"
}

tcp_eval_score() {
  # Rough score from median tls/ttfb/dl
  local tls="$1" ttfb="$2" dl="$3"
  local score=0

  # TLS
  if [[ -n "${tls:-}" ]]; then
    if (( tls < 120 )); then score=$((score+30))
    elif (( tls < 300 )); then score=$((score+22))
    elif (( tls < 800 )); then score=$((score+12))
    else score=$((score+6))
    fi
  fi

  # TTFB
  if [[ -n "${ttfb:-}" ]]; then
    if (( ttfb < 200 )); then score=$((score+30))
    elif (( ttfb < 500 )); then score=$((score+22))
    elif (( ttfb < 1200 )); then score=$((score+12))
    else score=$((score+6))
    fi
  fi

  # DL Mbps
  if [[ -n "${dl:-}" ]]; then
    # dl is float
    if awk -v x="$dl" 'BEGIN{exit (x>=200)?0:1}'; then score=$((score+40))
    elif awk -v x="$dl" 'BEGIN{exit (x>=50)?0:1}'; then score=$((score+30))
    elif awk -v x="$dl" 'BEGIN{exit (x>=10)?0:1}'; then score=$((score+20))
    elif awk -v x="$dl" 'BEGIN{exit (x>=3)?0:1}'; then score=$((score+12))
    else score=$((score+6))
    fi
  fi

  ((score>100)) && score=100
  echo "$score"
}

run_tcp() {
  RUN_TCP=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做 TCP 真实链路测试。"
    TCP_RATING="unknown"
    return 0
  fi

  echo -e "${LMAGENTA}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${NC}"
  info "范围：${TCP_RANGE_MB}MB | maxTime=${TCP_MAXTIME}s | sources=cloudflare/hetzner/ovh/cachefly（能测几个算几个）"

  local tls_list="" ttfb_list="" dl_list=""
  local best_dl=""; local best_src=""; local lines=()

  for item in "${TCP_SOURCES[@]}"; do
    local name url
    name="${item%%|*}"
    url="${item#*|}"

    local r tls_ms ttfb_ms dl_mbps code okflag
    r="$(tcp_one_source "$name" "$url")"
    tls_ms="$(echo "$r" | cut -d'|' -f2)"
    ttfb_ms="$(echo "$r" | cut -d'|' -f3)"
    dl_mbps="$(echo "$r" | cut -d'|' -f4)"
    code="$(echo "$r" | cut -d'|' -f5)"
    okflag="$(echo "$r" | cut -d'|' -f6)"

    if [[ "$okflag" -eq 1 && -n "${dl_mbps:-}" ]]; then
      tls_list+="${tls_ms}\n"
      ttfb_list+="${ttfb_ms}\n"
      dl_list+="${dl_mbps}\n"

      if [[ -z "${best_dl:-}" ]] || awk -v a="$dl_mbps" -v b="$best_dl" 'BEGIN{exit (a>b)?0:1}'; then
        best_dl="$dl_mbps"
        best_src="$name"
      fi

      # colored per source name
      local cname="$LGREEN"
      [[ "$name" == "hetzner" ]] && cname="$LYELLOW"
      [[ "$name" == "ovh" ]] && cname="$LGREEN"
      [[ "$name" == "cachefly" ]] && cname="$LGREEN"
      echo -e "  • ${cname}${name}${NC}: TLS=${tls_ms}ms  TTFB=${ttfb_ms}ms  DL=${dl_mbps}Mbps  code=${code}"
    else
      echo -e "  • ${GRAY}${name}${NC}: DL=?Mbps  code=${code}（跳过）"
    fi
  done

  # median
  local tls_med ttfb_med dl_med
  tls_med="$(printf "%b" "$tls_list" | sed '/^$/d' | median_from_lines)"
  ttfb_med="$(printf "%b" "$ttfb_list" | sed '/^$/d' | median_from_lines)"
  dl_med="$(printf "%b" "$dl_list" | sed '/^$/d' | median_from_lines)"

  # normalize formats
  [[ -n "${tls_med:-}" ]] && tls_med="$(awk -v x="$tls_med" 'BEGIN{printf "%.0f", x}')"
  [[ -n "${ttfb_med:-}" ]] && ttfb_med="$(awk -v x="$ttfb_med" 'BEGIN{printf "%.0f", x}')"

  TCP_TLS_MS="${tls_med:-}"
  TCP_TTFB_MS="${ttfb_med:-}"
  TCP_DL_MBPS="${dl_med:-}"
  TCP_BEST_MBPS="${best_dl:-}"

  if [[ -n "${TCP_TLS_MS:-}" && -n "${TCP_TTFB_MS:-}" && -n "${TCP_DL_MBPS:-}" ]]; then
    local score
    score="$(tcp_eval_score "$TCP_TLS_MS" "$TCP_TTFB_MS" "$TCP_DL_MBPS")"
    # map score -> rating
    if [[ "$score" -ge 85 ]]; then TCP_RATING="GOOD"; ok "TCP 体验：优秀（median）"
    elif [[ "$score" -ge 70 ]]; then TCP_RATING="WARN"; warn "TCP 体验：良好（median）"
    elif [[ "$score" -ge 55 ]]; then TCP_RATING="WARN"; warn "TCP 体验：一般（median）"
    else TCP_RATING="BAD"; bad "TCP 体验：偏弱（median）"
    fi
    echo -e "${GRAY}Median: TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | DL=${TCP_DL_MBPS}Mbps (best=${best_src:-?} ${best_dl:-?}Mbps)${NC}"
  else
    warn "TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。"
    TCP_RATING="unknown"
  fi

  hr
}

# -------------------- Score + Summary --------------------
calc_net_score() {
  local net_score=0
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"
    [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  else
    net_score=0
  fi

  if [[ "$RUN_MTR" -eq 1 ]]; then
    if [[ "$MTR_RATING" == "GOOD" ]]; then net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')" ; fi
    if [[ "$MTR_RATING" == "BAD" ]]; then  net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')" ; fi
  fi

  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"
  echo "$net_score"
}

calc_disk_score() {
  local disk_score=0
  if [[ "$RUN_DISK" -eq 1 ]]; then
    if [[ "$DISK_RATING" == "GOOD" ]]; then disk_score=90
    elif [[ "$DISK_RATING" == "WARN" ]]; then disk_score=70
    elif [[ "$DISK_RATING" == "BAD" ]]; then disk_score=50
    else disk_score=0
    fi
  fi
  echo "$disk_score"
}

calc_stream_score() {
  local stream_score=0
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
  fi
  echo "$stream_score"
}

calc_tcp_score() {
  # score derived similarly to tcp_eval_score output
  if [[ "$RUN_TCP" -ne 1 || -z "${TCP_TLS_MS:-}" || -z "${TCP_TTFB_MS:-}" || -z "${TCP_DL_MBPS:-}" ]]; then
    echo "0"; return
  fi
  tcp_eval_score "$TCP_TLS_MS" "$TCP_TTFB_MS" "$TCP_DL_MBPS"
}

overall_summary() {
  local net_score disk_score stream_score tcp_score total used
  net_score="$(calc_net_score)"
  disk_score="$(calc_disk_score)"
  stream_score="$(calc_stream_score)"
  tcp_score="$(calc_tcp_score)"

  # weights: net 35, tcp 25, disk 20, stream 20（更贴近代理体验）
  local w_net=35 w_tcp=25 w_disk=20 w_stream=20
  total=0; used=0

  if [[ "$RUN_PING" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$net_score" -v w="$w_net" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_net)); fi
  if [[ "$RUN_TCP" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$tcp_score" -v w="$w_tcp" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_tcp)); fi
  if [[ "$RUN_DISK" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$disk_score" -v w="$w_disk" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_disk)); fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$stream_score" -v w="$w_stream" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_stream)); fi

  if [[ "$used" -gt 0 ]]; then
    total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"
  else
    total=0
  fi

  local overall_g; overall_g="$(grade_text "$total")"
  local overall_gc; overall_gc="$(grade_color "$overall_g")"
  local overall_bar; overall_bar="$(bar "$total" 28 "$(score_color_key "$total")")"

  echo -e "${LMAGENTA}====================== ✅ VPS 体检总结报告 ======================${NC}"

  echo -e "${LMAGENTA}[基础信息]${NC}"
  echo "Host : $(mask_host "$HOSTNAME_")"
  echo "OS   : ${OS_:-unknown}"
  echo "Kern : ${KERNEL_:-unknown} | Virt=${VIRT_:-unknown}"
  echo "CPU  : ${CPU_:-unknown} | Cores=${CORES_:-?} | RAM=${RAM_:-?} | Swap=${SWAP_:-?}"
  echo "Disk : / ${DISKROOT_:-unknown}"
  echo "IPv4 : $(mask_ip "$IPV4_")"
  echo "Geo  : ${GEO_:-unknown}"
  echo "ASN  : ${ASN_:-unknown}"
  echo "ISP  : ${ORG_:-unknown}"
  hr

  # 网络
  local net_g net_gc net_bar
  net_g="$(grade_text "$net_score")"
  net_gc="$(grade_color "$net_g")"
  net_bar="$(bar "$net_score" 28 "$(score_color_key "$net_score")")"
  echo -e "${LMAGENTA}[网络]${NC}  ${net_score}/100 (${net_gc})  ${net_bar}"
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

  # TCP
  if [[ "$RUN_TCP" -eq 1 ]]; then
    local tcp_g tcp_gc tcp_bar
    tcp_g="$(grade_text "$tcp_score")"
    tcp_gc="$(grade_color "$tcp_g")"
    tcp_bar="$(bar "$tcp_score" 28 "$(score_color_key "$tcp_score")")"
    echo -e "${LMAGENTA}[TCP真实链路]${NC}  ${tcp_score}/100 (${tcp_gc})  ${tcp_bar}"
    echo "TLS  : ${TCP_TLS_MS:-?} ms | TTFB=${TCP_TTFB_MS:-?} ms"
    echo "DL   : ${TCP_DL_MBPS:-?} Mbps (median, range=${TCP_RANGE_MB}MB, maxTime=${TCP_MAXTIME}s)"
    echo "Eval : ${TCP_RATING}"
  else
    echo -e "${LMAGENTA}[TCP真实链路]${NC}  未执行"
  fi
  hr

  # 磁盘
  local disk_g disk_gc disk_bar
  disk_g="$(grade_text "$disk_score")"
  disk_gc="$(grade_color "$disk_g")"
  disk_bar="$(bar "$disk_score" 28 "$(score_color_key "$disk_score")")"
  echo -e "${LMAGENTA}[磁盘]${NC}  ${disk_score}/100 (${disk_gc})  ${disk_bar}"
  if [[ "$RUN_DISK" -eq 1 ]]; then
    echo "dd   : ${DISK_SPEED_RAW} | approx=${DISK_MBPS:-?} MB/s | rating=${DISK_RATING}"
  else
    echo "dd   : 未执行"
  fi
  hr

  # 流媒体
  local stream_g stream_gc stream_bar
  stream_g="$(grade_text "$stream_score")"
  stream_gc="$(grade_color "$stream_g")"
  stream_bar="$(bar "$stream_score" 28 "$(score_color_key "$stream_score")")"
  echo -e "${LMAGENTA}[流媒体]${NC}  ${stream_score}/100 (${stream_gc})  ${stream_bar}"
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    echo "YouTube=${YT_OK}(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  else
    echo "未执行"
  fi
  hr

  echo -e "${LMAGENTA}[总评]${NC}  ${total}/100 (${overall_gc})  ${overall_bar}"

  if [[ "$total" -ge 85 ]]; then
    ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif [[ "$total" -ge 70 ]]; then
    ok "结论：整体不错，日常中转/落地够用，关注路由与邻居波动。"
  elif [[ "$total" -ge 55 ]]; then
    warn "结论：整体一般，建议降低用途预期或考虑换机房。"
  else
    bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi

  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${LMAGENTA}================================================================${NC}"
}

# -------------------- Run all (show) --------------------
run_all() {
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

# -------------------- Run all quiet (R) --------------------
run_all_quiet() {
  info "正在后台静默执行检测（2~8+10），完成后输出最终✅总结..."
  local log="/tmp/vps_check_$(date +%s).log"
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
  echo -e "${GRAY}（静默日志已保存：${log}）${NC}"
}

# -------------------- Menu --------------------
menu() {
  while true; do
    echo -e "${LMAGENTA}====================== VPS 一键体检 菜单 ======================${NC}"
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
      9) run_all; pause ;;
      10) run_tcp; pause ;;
      r|R) run_all_quiet; pause ;;
      0|q|Q) ok "Bye."; exit 0 ;;
      *) warn "无效选择：${c:-空}（请输入 0-10 或 R）"; pause ;;
    esac
  done
}

# -------------------- Entry --------------------
menu
