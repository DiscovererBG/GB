#!/usr/bin/env bash
# =========================================================
# ✅ VPS 一键体检（只读）+ 流媒体解锁 + TCP 真实链路测试（菜单版）
# - 菜单：2~8 常规检测 + 10 TCP 真实链路测试
# - 9：全跑（2~8+10）显示全过程
# - R：后台静默全跑（2~8+10），只输出最终✅总结（不刷屏）
# - 美化：总结报告进度条为绿色；“优秀/良好/一般/偏弱”与后面提示同色
# - 修复：MTR 解析、R 静默流程、unknown 逻辑、ANSI 颜色泄漏等
#
# ✅ 运行：
#   bash <(curl -fsSL "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh")
#   或：
#   curl -fsSL -o vps_check.sh "https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/vps_check.sh"
#   chmod +x vps_check.sh && ./vps_check.sh
#
# ✅ 打码模式（发到网上更安全）：
#   ./vps_check.sh --redact
#
# NOTE:
# - 只读检测：不会改系统配置（除非你手动选“安装 mtr-tiny”）
# - 流媒体解锁为 best-effort（最终以登录播放为准）
# =========================================================

set -euo pipefail

# -------------------- Colors --------------------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"; GRAY="\033[90m"; NC="\033[0m"
BOLD="\033[1m"

ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
hr()   { echo -e "${MAGENTA}---------------------------------------------------------${NC}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# -------------------- Defaults --------------------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=10

DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# TCP test defaults (range download: more stable, fast)
TCP_TEST_MAXTIME=12
TCP_RANGE_MB=8
TCP_RANGE_BYTES=$((TCP_RANGE_MB*1024*1024))

# 多个下载源，防止某个源抽风导致 http_code=000/404
TCP_SOURCES=(
  "https://speed.hetzner.de/100MB.bin"
  "https://proof.ovh.net/files/100Mb.dat"
  "https://speedtest.tele2.net/100MB.zip"
)

# -------------------- Numeric helpers --------------------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

# -------------------- Redact --------------------
REDACT=0
if [[ "${1:-}" == "--redact" ]]; then REDACT=1; fi

mask_ipv4() {
  local ip="${1:-unknown}"
  if [[ "$REDACT" -eq 1 && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$ip" | awk -F. '{printf "%s.%s.*.*",$1,$2}'
  else
    echo "$ip"
  fi
}
mask_host() {
  local h="${1:-unknown}"
  if [[ "$REDACT" -eq 1 && "$h" != "unknown" ]]; then
    echo "***"
  else
    echo "$h"
  fi
}

# -------------------- Global state for summary --------------------
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
MTR_RATING="unknown"

# disk summary
DISK_SPEED_RAW="unknown"
DISK_MBPS=""
DISK_RATING="unknown"

# streaming summary
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
TCP_HTTP_CODE=""
TCP_SRC_USED=""
TCP_EVAL="unknown"
TCP_SCORE=0

pause() { read -r -p "回车继续..." _ || true; }

# -------------------- Grade helpers (color unified) --------------------
grade_word() {
  local score="${1:-0}"
  if [[ "$score" -ge 85 ]]; then echo "优秀"
  elif [[ "$score" -ge 70 ]]; then echo "良好"
  elif [[ "$score" -ge 55 ]]; then echo "一般"
  else echo "偏弱"
  fi
}
grade_color() {
  local w="${1:-偏弱}"
  case "$w" in
    优秀) echo "$GREEN" ;;
    良好) echo "$CYAN" ;;
    一般) echo "$YELLOW" ;;
    偏弱) echo "$RED" ;;
    *) echo "$GRAY" ;;
  esac
}

# progress bar (GREEN bar, dim remainder)
bar() {
  local score="${1:-0}"
  local width="${2:-28}"
  [[ "$score" -lt 0 ]] && score=0
  [[ "$score" -gt 100 ]] && score=100
  local fill=$((score*width/100))
  local empty=$((width-fill))
  local s1="" s2=""
  s1="$(printf "%0.s█" $(seq 1 "$fill") 2>/dev/null || true)"
  s2="$(printf "%0.s░" $(seq 1 "$empty") 2>/dev/null || true)"
  echo -e "${GREEN}${s1}${GRAY}${s2}${NC}"
}

label_line() {
  # $1 title, $2 score
  local title="$1"; local score="$2"
  local w; w="$(grade_word "$score")"
  local c; c="$(grade_color "$w")"
  printf "%b[%s]%b  %3s/100 (%b%s%b)  %b\n" \
    "$MAGENTA" "$title" "$NC" "$score" "$c" "$w" "$NC" "$(bar "$score" 28)"
}

# -------------------- Set Targets --------------------
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
  UPTIME_="$(uptime -p 2>/dev/null || echo unknown)"
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

  echo -e "${BLUE}--- 基本信息 ---${NC}"
  echo "Host      : $(mask_host "$HOSTNAME_")"
  echo "OS        : ${OS_}"
  echo "Kernel    : ${KERNEL_} | Virt=${VIRT_}"
  echo "Uptime    : ${UPTIME_}"
  echo "CPU       : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
  echo "Load avg  : ${LOAD_}"
  echo "Disk /    : ${DISKROOT_}"
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

  echo -e "${BLUE}--- 公网信息 ---${NC}"
  echo "IPv4      : $(mask_ipv4 "$IPV4_")"
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

  # worst tracking
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

  # mtr -rwzbc 输出最后一行：HOST Loss% Snt Last Avg Best Wrst StDev
  last_line="$(echo "$out" | tail -n 1)"

  # Loss% 在第 3 列（带%），Avg 在第 6 列（ms 数值）
  last_loss="$(echo "$last_line" | awk '{print $3}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $6}')"
  last_loss="$(safe_num "$last_loss")"
  last_avg="$(safe_num "$last_avg")"

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

# -------------------- Disk dd --------------------
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

  DISK_MBPS=""
  DISK_RATING="unknown"

  if [[ -n "${mbps:-}" && -n "${unit:-}" ]]; then
    if [[ "$unit" == "GB/s" ]]; then
      mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')"
    fi
    DISK_MBPS="$mbps"
    if f_ge "$mbps" "200"; then ok "磁盘：优秀（>=200 MB/s）"; DISK_RATING="GOOD"
    elif f_ge "$mbps" "80"; then warn "磁盘：一般（80~200 MB/s）"; DISK_RATING="WARN"
    else warn "磁盘：偏低（<80 MB/s）"; DISK_RATING="BAD"
    fi
  else
    warn "无法解析 dd 速度（不同系统 dd 输出可能不同）"
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

  # 动画疯
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

# -------------------- TCP Real Link Test --------------------
tcp_try_one_source() {
  # prints: tls_ms ttfb_ms mbps http_code
  local url="$1"
  local range_end=$((TCP_RANGE_BYTES-1))

  # 用 curl -w 拿 TLS 握手、TTFB、总时间、下载字节
  # time_appconnect：TLS handshake 到完成
  # time_starttransfer：TTFB
  # size_download：下载字节
  local out
  out="$(curl -L -sS -A "Mozilla/5.0" \
      --max-time "${TCP_TEST_MAXTIME}" \
      -r "0-${range_end}" \
      -o /dev/null \
      -w "tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download} code=%{http_code}\n" \
      "$url" 2>/dev/null || true)"

  local tls ttfb total bytes code
  tls="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^tls=/){sub("tls=","",$i); print $i}}')"
  ttfb="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^ttfb=/){sub("ttfb=","",$i); print $i}}')"
  total="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^total=/){sub("total=","",$i); print $i}}')"
  bytes="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^bytes=/){sub("bytes=","",$i); print $i}}')"
  code="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^code=/){sub("code=","",$i); print $i}}')"

  tls="$(safe_num "$tls")"
  ttfb="$(safe_num "$ttfb")"
  total="$(safe_num "$total")"
  bytes="$(safe_num "$bytes")"
  code="${code:-000}"

  # 计算 Mbps（bits/sec / 1e6）
  local mbps=""
  if [[ -n "${bytes:-}" && -n "${total:-}" ]] && awk -v b="$bytes" -v t="$total" 'BEGIN{exit (t>0 && b>0)?0:1}'; then
    mbps="$(awk -v b="$bytes" -v t="$total" 'BEGIN{printf "%.2f", (b*8)/(t*1000000)}')"
  fi

  echo "${tls:-} ${ttfb:-} ${mbps:-} ${code}"
}

run_tcp() {
  RUN_TCP=1
  if ! need_cmd curl; then
    bad "缺少 curl，无法做 TCP 真实链路测试。"
    TCP_EVAL="unknown"
    return 0
  fi

  echo -e "${BLUE}--- TCP 真实链路测试（更贴近代理体验）---${NC}"

  local best_tls="" best_ttfb="" best_mbps="" best_code="000" best_src=""
  for u in "${TCP_SOURCES[@]}"; do
    local r tls ttfb mbps code
    r="$(tcp_try_one_source "$u")"
    tls="$(echo "$r" | awk '{print $1}')"
    ttfb="$(echo "$r" | awk '{print $2}')"
    mbps="$(echo "$r" | awk '{print $3}')"
    code="$(echo "$r" | awk '{print $4}')"

    # 200/206 都算成功（Range 常为 206）
    if [[ "$code" == "200" || "$code" == "206" ]]; then
      best_tls="$tls"; best_ttfb="$ttfb"; best_mbps="$mbps"; best_code="$code"; best_src="$u"
      break
    fi
  done

  TCP_TLS_MS=""
  TCP_TTFB_MS=""
  TCP_DL_MBPS=""
  TCP_HTTP_CODE="${best_code}"
  TCP_SRC_USED="${best_src}"

  if [[ -n "${best_tls:-}" ]]; then TCP_TLS_MS="$(awk -v x="$best_tls" 'BEGIN{printf "%.0f", x*1000}')"; fi
  if [[ -n "${best_ttfb:-}" ]]; then TCP_TTFB_MS="$(awk -v x="$best_ttfb" 'BEGIN{printf "%.0f", x*1000}')"; fi
  if [[ -n "${best_mbps:-}" ]]; then TCP_DL_MBPS="$best_mbps"; fi

  echo "Handshake(TLS) : ${TCP_TLS_MS:-?} ms"
  echo "TTFB          : ${TCP_TTFB_MS:-?} ms"
  if [[ -n "${TCP_DL_MBPS:-}" ]]; then
    echo "Download      : ${TCP_DL_MBPS} Mbps  (range=${TCP_RANGE_MB}MB, maxtime=${TCP_TEST_MAXTIME}s, http_code=${TCP_HTTP_CODE})"
  else
    echo "Download      : ? Mbps  (range=${TCP_RANGE_MB}MB, maxtime=${TCP_TEST_MAXTIME}s, http_code=${TCP_HTTP_CODE})"
  fi

  # 评分逻辑（更接近“代理体验”）：TLS+TTFB为主，下载作为辅助
  # - TLS <=150ms 且 TTFB <=300ms => 优秀
  # - TLS <=400ms 且 TTFB <=800ms => 良好
  # - 否则 一般/偏弱（下载太低也会拖低）
  local score=0
  local tls="${TCP_TLS_MS:-}" ttfb="${TCP_TTFB_MS:-}" mbps="${TCP_DL_MBPS:-}"

  if [[ -n "$tls" && -n "$ttfb" ]]; then
    if [[ "$tls" -le 150 && "$ttfb" -le 300 ]]; then score=90
    elif [[ "$tls" -le 400 && "$ttfb" -le 800 ]]; then score=80
    elif [[ "$tls" -le 800 && "$ttfb" -le 1500 ]]; then score=65
    else score=45
    fi
  else
    score=55
  fi

  # 下载很低额外扣分（避免 “0.10 Mbps 仍优秀” 这种情况）
  if [[ -n "${mbps:-}" ]]; then
    if awk -v x="$mbps" 'BEGIN{exit (x<1.0)?0:1}'; then score=$((score-20)); fi
    if awk -v x="$mbps" 'BEGIN{exit (x<5.0)?0:1}'; then score=$((score-10)); fi
  fi

  # http_code 非成功也扣分
  if [[ "${TCP_HTTP_CODE}" != "200" && "${TCP_HTTP_CODE}" != "206" ]]; then
    score=$((score-15))
  fi

  [[ "$score" -lt 0 ]] && score=0
  [[ "$score" -gt 100 ]] && score=100

  TCP_SCORE="$score"
  if [[ "$score" -ge 85 ]]; then TCP_EVAL="GOOD"; ok "TCP 体验：优秀"
  elif [[ "$score" -ge 70 ]]; then TCP_EVAL="GOOD"; ok "TCP 体验：良好"
  elif [[ "$score" -ge 55 ]]; then TCP_EVAL="WARN"; warn "TCP 体验：一般"
  else TCP_EVAL="BAD"; bad "TCP 体验：偏弱"
  fi

  hr
}

# -------------------- Overall summary --------------------
overall_summary() {
  echo -e "${MAGENTA}====================== ✅ VPS 体检总结报告 ======================${NC}"

  # ---- network score (ping+mtr) ----
  local net_score=0 disk_score=0 stream_score=0 tcp_score=0 total=0 used=0
  local net_grade disk_grade stream_grade tcp_grade overall

  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"; [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  else
    net_score=0
  fi

  if [[ "$RUN_MTR" -eq 1 ]]; then
    if [[ "$MTR_RATING" == "GOOD" ]]; then net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')"; fi
    if [[ "$MTR_RATING" == "BAD"  ]]; then net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')"; fi
  fi
  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"

  # ---- disk score ----
  if [[ "$RUN_DISK" -eq 1 ]]; then
    if [[ "$DISK_RATING" == "GOOD" ]]; then disk_score=90
    elif [[ "$DISK_RATING" == "WARN" ]]; then disk_score=70
    elif [[ "$DISK_RATING" == "BAD" ]]; then disk_score=50
    else disk_score=0
    fi
  else
    disk_score=0
  fi

  # ---- streaming score ----
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

  # ---- tcp score ----
  if [[ "$RUN_TCP" -eq 1 ]]; then
    tcp_score="${TCP_SCORE:-0}"
  else
    tcp_score=0
  fi

  # ---- total score (weights) ----
  # 网络 40 / TCP 20 / 流媒体 25 / 磁盘 15
  if [[ "$RUN_PING" -eq 1 || "$RUN_MTR" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$net_score" -v w=40 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+40))
  fi
  if [[ "$RUN_TCP" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$tcp_score" -v w=20 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+20))
  fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$stream_score" -v w=25 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+25))
  fi
  if [[ "$RUN_DISK" -eq 1 ]]; then
    total="$(awk -v t="$total" -v x="$disk_score" -v w=15 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+15))
  fi
  if [[ "$used" -gt 0 ]]; then
    total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')"
  else
    total=0
  fi

  net_grade="$(grade_word "$net_score")"
  disk_grade="$(grade_word "$disk_score")"
  stream_grade="$(grade_word "$stream_score")"
  tcp_grade="$(grade_word "$tcp_score")"
  overall="$(grade_word "$total")"

  # ---- print ----
  echo -e "${MAGENTA}[基础信息]${NC}"
  echo "Host : $(mask_host "$HOSTNAME_")"
  echo "OS   : ${OS_}"
  echo "Kern : ${KERNEL_} | Virt=${VIRT_}"
  echo "CPU  : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
  echo "Disk : / ${DISKROOT_}"
  echo "IPv4 : $(mask_ipv4 "$IPV4_")"
  echo "Geo  : ${GEO_}"
  echo "ASN  : ${ASN_}"
  echo "ISP  : ${ORG_}"
  hr

  label_line "网络" "$net_score"
  echo "Ping : GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% | worstAvg=${PING_WORST_AVG:-?}ms"
  echo "MTR  : target=${TARGETS[0]} | lastLoss=${MTR_LASTLOSS:-?}% | lastAvg=${MTR_LASTAVG:-?}ms | rating=${MTR_RATING}"
  hr

  label_line "TCP真实链路" "$tcp_score"
  echo "TLS  : ${TCP_TLS_MS:-?} ms | TTFB=${TCP_TTFB_MS:-?} ms"
  if [[ -n "${TCP_DL_MBPS:-}" ]]; then
    echo "DL   : ${TCP_DL_MBPS} Mbps (http_code=${TCP_HTTP_CODE}, range=${TCP_RANGE_MB}MB)"
  else
    echo "DL   : ? Mbps (http_code=${TCP_HTTP_CODE:-000}, range=${TCP_RANGE_MB}MB)"
  fi
  echo "Eval : ${TCP_EVAL}"
  hr

  label_line "磁盘" "$disk_score"
  echo "dd   : ${DISK_SPEED_RAW} | approx=${DISK_MBPS:-?} MB/s | rating=${DISK_RATING}"
  hr

  label_line "流媒体" "$stream_score"
  echo "YouTube=${YT_OK}(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  hr

  label_line "总评" "$total"
  local oc; oc="$(grade_color "$overall")"
  if [[ "$total" -ge 85 ]]; then
    echo -e "${GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${NC}"
  elif [[ "$total" -ge 70 ]]; then
    echo -e "${CYAN}✅ 结论：整体不错，日常中转/落地够用，关注路由与邻居波动。${NC}"
  elif [[ "$total" -ge 55 ]]; then
    echo -e "${YELLOW}⚠️ 结论：整体一般，建议降低用途预期或换机房对比。${NC}"
  else
    echo -e "${RED}❌ 结论：整体偏弱，不建议做关键落地或高稳定需求用途。${NC}"
  fi

  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${MAGENTA}================================================================${NC}"
}

# -------------------- Run all (verbose / silent) --------------------
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
  # 静默跑：把过程输出吞掉，只留最终总结
  info "正在后台执行检测（2~8 + 10），完成后输出最终✅总结..."
  {
    gather_system
    gather_ip
    run_ping_all
    run_mtr
    run_disk
    run_streaming
    run_tcp
  } >/dev/null 2>&1 || true
  overall_summary
}

# -------------------- Menu --------------------
menu() {
  while true; do
    echo -e "${MAGENTA}${BOLD}====================== VPS 一键体检 菜单 ======================${NC}"
    echo -e "Targets: ${MAGENTA}${TARGETS[*]}${NC}  ${GRAY}(MTR 默认用第一个 Target)${NC}"
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
    echo " 10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，更贴近代理体验）"
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
      R|r) run_all_silent; pause ;;
      0|q|Q) ok "Bye."; exit 0 ;;
      *) warn "无效选择：${c:-空}（请输入 0-10 或 R）"; pause ;;
    esac
  done
}

# -------------------- Entry --------------------
menu
