#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# VPS 一键体检（修复版）
# - 修复 ANSI 残留 \033[0m
# - 进度条使用“彩色块 + 灰点”，不再用 '='
# - TCP 多源中位数：不依赖 awk asort（兼容 mawk）
# - Ping mdev 解析失败不再显示 ?ms
# - MTR 终点丢包/平均延迟解析失败不再出现 -% / 100ms 乱值
# =========================

# -------- Locale（尽量避免出现 ????）--------
if command -v locale >/dev/null 2>&1; then
  if locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-8$'; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  fi
fi

# -------- Colors --------
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

FG_PINK="${ESC}[38;5;205m"
FG_PURPLE="${ESC}[38;5;141m"
FG_CYAN="${ESC}[38;5;51m"
FG_GREEN="${ESC}[38;5;82m"
FG_YELLOW="${ESC}[38;5;220m"
FG_RED="${ESC}[38;5;196m"
FG_GRAY="${ESC}[38;5;245m"
FG_WHITE="${ESC}[38;5;255m"

BG_GREEN="${ESC}[48;5;112m"
BG_CYAN="${ESC}[48;5;44m"
BG_YELLOW="${ESC}[48;5;214m"
BG_RED="${ESC}[48;5;161m"
BG_GRAY="${ESC}[48;5;238m"

# -------- Settings --------
TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")
PING_COUNT=50
MTR_CYCLES=100
DD_SIZE_MB=256

TCP_RANGE_MB=16
TCP_MAXTIME=12
TCP_SOURCES=("cloudflare" "hetzner" "ovh" "cachefly")

# -------- Runtime cache --------
TMPDIR="/tmp/vps_check.$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

REDact=0
if [[ "${1:-}" == "--redact" ]]; then
  REDact=1
fi

# -------- Helpers --------
println() { printf "%b\n" "$*"; }
hr() { println "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2() { println "${FG_PINK}=========================================================${RESET}"; }

pause() { read -r -p "回车继续..." _; }

exists() { command -v "$1" >/dev/null 2>&1; }

safe_num() {
  # if empty -> "未知"
  local v="${1:-}"
  [[ -z "$v" ]] && printf "未知" || printf "%s" "$v"
}

mask_ipv4() {
  local ip="$1"
  [[ "$REDact" -eq 0 ]] && { printf "%s" "$ip"; return; }
  # 1.2.3.4 -> 1.2.*.*
  printf "%s" "$ip" | awk -F. 'NF==4{print $1"."$2".*.*"; next}{print "*.*.*.*"}'
}

mask_host() {
  local h="$1"
  [[ "$REDact" -eq 0 ]] && { printf "%s" "$h"; return; }
  [[ -z "$h" ]] && { printf "unknown"; return; }
  printf "%s" "$h" | sed -E 's/^(.).*(.)$/\1***\2/'
}

# score -> label + colors
grade_label() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "优秀"; return; fi
  if (( s >= 75 )); then printf "良好"; return; fi
  if (( s >= 60 )); then printf "一般"; return; fi
  printf "偏弱"
}

grade_color_fg() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$FG_GREEN"; return; fi
  if (( s >= 75 )); then printf "%s" "$FG_CYAN"; return; fi
  if (( s >= 60 )); then printf "%s" "$FG_YELLOW"; return; fi
  printf "%s" "$FG_RED"
}
grade_color_bg() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$BG_GREEN"; return; fi
  if (( s >= 75 )); then printf "%s" "$BG_CYAN"; return; fi
  if (( s >= 60 )); then printf "%s" "$BG_YELLOW"; return; fi
  printf "%s" "$BG_RED"
}

# 彩色进度条（你要的那种“彩色块 + 灰点”，不用 '='）
bar() {
  local score="${1:-0}"
  local width="${2:-28}"
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100
  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))

  local fg; fg="$(grade_color_fg "$score")"
  local bg; bg="$(grade_color_bg "$score")"

  printf "%b" "${fg}[${RESET}"
  # filled colored blocks (background spaces)
  printf "%b" "${bg}"
  printf "%*s" "$filled" ""
  printf "%b" "${RESET}"
  # remainder grey dots
  printf "%b" "${FG_GRAY}${DIM}"
  if (( rest > 0 )); then
    printf "%*s" "$rest" "" | tr ' ' '·'
  fi
  printf "%b" "${RESET}${fg}]${RESET}"
}

# float format
f2() { awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x+0}'; }
f1() { awk -v x="${1:-0}" 'BEGIN{printf "%.1f", x+0}'; }
i0() { awk -v x="${1:-0}" 'BEGIN{printf "%d", x+0}'; }

median_of_list() {
  # input: numbers via stdin, output median (float)
  local arr n mid a b
  mapfile -t arr < <(cat | awk 'NF{print $1}' | sort -n)
  n="${#arr[@]}"
  if (( n == 0 )); then
    printf ""
    return 0
  fi
  mid=$(( n / 2 ))
  if (( n % 2 == 1 )); then
    printf "%s" "${arr[$mid]}"
  else
    a="${arr[$((mid-1))]}"
    b="${arr[$mid]}"
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f", (a+b)/2}'
  fi
}

# -------- Collectors --------
B_HOST=""; B_OS=""; B_KERN=""; B_VIRT=""; B_CPU=""; B_CORES=""; B_RAM=""; B_SWAP=""; B_DISK=""
P_IPV4=""; P_GEO=""; P_ASN=""; P_ISP=""

PING_WORST_LOSS=""; PING_WORST_AVG=""
PING_GOOD=0; PING_WARN=0; PING_BAD=0

MTR_TARGET=""
MTR_LAST_LOSS=""; MTR_LAST_AVG=""; MTR_SCORE=0; MTR_GRADE=""

DD_SPEED_MBPS=""
DD_SCORE=0

MEDIA_SCORE=0
MEDIA_LINE=""

TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
TCP_OK_SAMPLES=0
TCP_BEST_SRC=""
TCP_SCORE=0
TCP_NOTE=""

# -------- Basic info --------
do_basic() {
  B_HOST="$(hostname 2>/dev/null || echo "unknown")"
  if [[ -r /etc/os-release ]]; then
    B_OS="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
  else
    B_OS="Linux"
  fi
  B_KERN="$(uname -r 2>/dev/null || echo "")"
  if exists systemd-detect-virt; then
    B_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "$B_VIRT" ]] && B_VIRT="none"
  else
    B_VIRT="unknown"
  fi

  # CPU model + cores
  B_CPU="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "unknown")"
  B_CORES="$(nproc 2>/dev/null || echo "1")"

  # RAM/SWAP
  if exists free; then
    B_RAM="$(free -m | awk '/Mem:/ {print $2 " MB"}')"
    B_SWAP="$(free -m | awk '/Swap:/ {print $2 " MB"}')"
  else
    B_RAM="unknown"; B_SWAP="unknown"
  fi

  # Disk
  if exists df; then
    B_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')"
  else
    B_DISK="unknown"
  fi

  println "${FG_PINK}--- 基本信息 ---${RESET}"
  println "Host     : $(mask_host "$B_HOST")"
  println "OS       : $B_OS"
  println "Kernel   : $B_KERN"
  println "Virt     : $B_VIRT"
  println "CPU      : $B_CPU （${B_CORES} 核）"
  println "RAM/Swap : $B_RAM / $B_SWAP"
  println "Disk /   : $B_DISK"
  hr
}

# -------- Public info (IPv4/Geo/ASN/ISP) --------
do_public() {
  # IPv4
  P_IPV4="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "$P_IPV4" ]]; then
    P_IPV4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$P_IPV4" ]]; then
    # fallback: route
    P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
  fi

  # ipinfo (best effort)
  if [[ -n "$P_IPV4" ]]; then
    local js
    js="$(curl -fsS --max-time 6 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"
    if [[ -n "$js" ]]; then
      local city region country org
      city="$(printf "%s" "$js" | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      region="$(printf "%s" "$js" | sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      country="$(printf "%s" "$js" | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      org="$(printf "%s" "$js" | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"

      # org: "AS20473 The Constant Company, LLC"
      P_ASN="$(printf "%s" "$org" | awk '{print $1}')"
      P_ISP="$(printf "%s" "$org" | sed -E 's/^AS[0-9]+[ ]*//')"
      P_GEO="$(printf "%s, %s, %s" "${city:-unknown}" "${region:-unknown}" "${country:-unknown}")"
    else
      P_GEO="unknown"; P_ASN="unknown"; P_ISP="unknown"
    fi
  else
    P_GEO="unknown"; P_ASN="unknown"; P_ISP="unknown"
  fi

  println "${FG_PINK}--- 公网信息 ---${RESET}"
  println "IPv4     : $(mask_ipv4 "${P_IPV4:-unknown}")"
  println "Geo      : ${P_GEO:-unknown}"
  println "ASN      : ${P_ASN:-unknown}"
  println "ISP/Org  : ${P_ISP:-unknown}"
  hr
}

# -------- Ping --------
ping_one() {
  local t="$1"
  local out loss avg min max mdev
  out="$(ping -c "$PING_COUNT" -q "$t" 2>/dev/null || true)"

  loss="$(printf "%s" "$out" | awk -F',' '/packet loss/ {gsub(/^[ \t]+/,"",$3); gsub(/% packet loss.*/,"",$3); print $3}' | head -n1)"
  avg="$(printf "%s" "$out" | awk -F'/' '/rtt|round-trip/ {print $5}' | head -n1)"
  min="$(printf "%s" "$out" | awk -F'/' '/rtt|round-trip/ {print $4}' | head -n1)"
  max="$(printf "%s" "$out" | awk -F'/' '/rtt|round-trip/ {print $6}' | head -n1)"
  mdev="$(printf "%s" "$out" | awk -F'/' '/rtt|round-trip/ {print $7}' | head -n1)"
  mdev="${mdev%% *}"

  [[ -z "$loss" ]] && loss="未知"
  [[ -z "$avg"  ]] && avg="未知"
  [[ -z "$min"  ]] && min="未知"
  [[ -z "$max"  ]] && max="未知"
  [[ -z "$mdev" ]] && mdev="-"

  println "${FG_PURPLE}--- Ping: ${t} (${PING_COUNT} 次) ---${RESET}"
  println "丢包 : ${loss}%"
  println "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  # grade by loss+avg
  local s=0
  if [[ "$loss" == "未知" || "$avg" == "未知" ]]; then
    s=0
  else
    # loss as number
    local lossn avgn
    lossn="$(awk -v x="$loss" 'BEGIN{print x+0}')"
    avgn="$(awk -v x="$avg" 'BEGIN{print x+0}')"
    if awk -v l="$lossn" 'BEGIN{exit !(l<=1)}' && awk -v a="$avgn" 'BEGIN{exit !(a<80)}'; then
      s=95
    elif awk -v l="$lossn" 'BEGIN{exit !(l<=3)}' && awk -v a="$avgn" 'BEGIN{exit !(a<150)}'; then
      s=80
    elif awk -v l="$lossn" 'BEGIN{exit !(l<=5)}' && awk -v a="$avgn" 'BEGIN{exit !(a<250)}'; then
      s=65
    else
      s=40
    fi
  fi

  local glabel; glabel="$(grade_label "$s")"
  local gfg; gfg="$(grade_color_fg "$s")"

  # 丢包评价
  if [[ "$loss" != "未知" ]]; then
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}'; then
      println "${FG_GREEN}✅ 丢包：优秀（≤1%）${RESET}"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}'; then
      println "${FG_YELLOW}⚠️  丢包：一般（≤5%）${RESET}"
    else
      println "${FG_RED}❌ 丢包：偏弱（>5%）${RESET}"
    fi
  fi
  # 延迟评价
  if [[ "$avg" != "未知" ]]; then
    if awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      println "${FG_GREEN}✅ 延迟：优秀（<80ms）${RESET}"
    elif awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      println "${FG_YELLOW}⚠️  延迟：一般（<150ms）${RESET}"
    else
      println "${FG_RED}❌ 延迟：偏弱（≥150ms）${RESET}"
    fi
  fi

  # update worst
  if [[ "$loss" != "未知" ]]; then
    if [[ -z "$PING_WORST_LOSS" ]]; then
      PING_WORST_LOSS="$loss"
    else
      if awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}'; then
        PING_WORST_LOSS="$loss"
      fi
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if [[ -z "$PING_WORST_AVG" ]]; then
      PING_WORST_AVG="$avg"
    else
      if awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}'; then
        PING_WORST_AVG="$avg"
      fi
    fi
  fi

  if (( s >= 90 )); then ((PING_GOOD++)); elif (( s >= 60 )); then ((PING_WARN++)); else ((PING_BAD++)); fi
  hr
}

do_ping_all() {
  PING_WORST_LOSS=""; PING_WORST_AVG=""
  PING_GOOD=0; PING_WARN=0; PING_BAD=0

  for t in "${TARGETS[@]}"; do
    ping_one "$t"
  done

  println "${FG_CYAN}ℹ️  Ping 小结：目标数=${#TARGETS[@]} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% 最差平均延迟=${PING_WORST_AVG:-未知}ms${RESET}"
  hr
}

# -------- MTR --------
do_mtr_install() {
  println "${FG_CYAN}ℹ️  正在安装 mtr-tiny...${RESET}"
  if exists apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y mtr-tiny >/dev/null 2>&1 || apt-get install -y mtr >/dev/null 2>&1 || true
  fi
  if exists mtr; then
    println "${FG_GREEN}✅ mtr 已可用：$(mtr --version 2>/dev/null | head -n1)${RESET}"
  else
    println "${FG_RED}❌ 安装失败：系统缺少 mtr（请手动安装）${RESET}"
  fi
  hr
}

do_mtr() {
  local t="${TARGETS[0]}"
  MTR_TARGET="$t"

  if ! exists mtr; then
    println "${FG_YELLOW}⚠️  未检测到 mtr，请先选 6) 安装 mtr-tiny${RESET}"
    hr
    return 0
  fi

  println "${FG_PURPLE}--- MTR: ${t} (${MTR_CYCLES} 轮) ---${RESET}"
  local out
  out="$(mtr -rwzbc "$MTR_CYCLES" "$t" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    println "${FG_RED}❌ MTR 执行失败（可能被限制 ICMP 或无权限）${RESET}"
    hr
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0; MTR_GRADE="偏弱"
    return 0
  fi

  # 只显示前若干跳 + 终点
  # 为了不刷屏：保留头、尾和关键
  # 这里直接输出 mtr 的简表（你原来就这样）
  # 也可以改成中间省略，但你现在显示是正常的
  printf "%s\n" "$out" | sed -n '1,20p'
  if (( $(printf "%s\n" "$out" | wc -l) > 26 )); then
    println "${FG_GRAY}...(中间省略)...${RESET}"
    printf "%s\n" "$out" | tail -n 8
  fi

  # last hop line (destination)
  local lastline
  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"

  # parse last hop loss/avg from last 7 fields
  # fields: Loss% Snt Last Avg Best Wrst StDev  (7 items at end)
  local loss avg
  loss="$(printf "%s\n" "$lastline" | awk '{print $(NF-6)}' | tr -d '%' )"
  avg="$(printf "%s\n" "$lastline" | awk '{print $(NF-4)}')"

  if [[ -z "$loss" || -z "$avg" ]]; then
    MTR_LAST_LOSS="未知"
    MTR_LAST_AVG="未知"
    MTR_SCORE=0
    MTR_GRADE="偏弱"
    println "${FG_YELLOW}⚠️  终点数据解析失败：可能被 ICMP 限速/格式差异${RESET}"
    hr
    return 0
  fi

  MTR_LAST_LOSS="$(f1 "$loss")"
  MTR_LAST_AVG="$(f1 "$avg")"

  # score
  local s
  s=0
  if awk -v l="$loss" 'BEGIN{exit !(l<=0.5)}' && awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
    s=95
  elif awk -v l="$loss" 'BEGIN{exit !(l<=2)}' && awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
    s=80
  elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}' && awk -v a="$avg" 'BEGIN{exit !(a<250)}'; then
    s=65
  else
    s=40
  fi
  MTR_SCORE="$s"
  MTR_GRADE="$(grade_label "$s")"

  println
  println "终点（最后一跳）：丢包=${MTR_LAST_LOSS}%  平均=${MTR_LAST_AVG}ms"
  println "${FG_CYAN}ℹ️  提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。${RESET}"
  if (( s >= 90 )); then
    println "${FG_GREEN}✅ 路由质量：优秀${RESET}"
  elif (( s >= 60 )); then
    println "${FG_YELLOW}⚠️  路由质量：一般${RESET}"
  else
    println "${FG_RED}❌ 路由质量：偏弱${RESET}"
  fi
  hr
}

# -------- Disk dd --------
do_dd() {
  println "${FG_PURPLE}--- 磁盘快速测试（dd 写入 ${DD_SIZE_MB}MB 到 /tmp）---${RESET}"
  local out
  out="$(LANG=C dd if=/dev/zero of="$TMPDIR/dd_test" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1 || true)"
  rm -f "$TMPDIR/dd_test" >/dev/null 2>&1 || true

  # parse speed like "1.6 GB/s" or "1638 MB/s"
  local speed unit mbps
  speed="$(printf "%s\n" "$out" | awk -F',' 'END{print $3}' | awk '{print $1}')"
  unit="$(printf "%s\n" "$out" | awk -F',' 'END{print $3}' | awk '{print $2}')"

  if [[ -z "$speed" || -z "$unit" ]]; then
    DD_SPEED_MBPS=""
    DD_SCORE=0
    println "${FG_RED}❌ dd 测试失败${RESET}"
    hr
    return 0
  fi

  if [[ "$unit" == "GB/s" ]]; then
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x*1024}')"
  else
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x}')"
  fi
  DD_SPEED_MBPS="$mbps"

  # scoring
  if awk -v x="$mbps" 'BEGIN{exit !(x>=1500)}'; then
    DD_SCORE=95
    println "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    println "${FG_GREEN}✅ 磁盘：优秀（>=200 MB/s）${RESET}"
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=500)}'; then
    DD_SCORE=85
    println "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    println "${FG_CYAN}✅ 磁盘：良好（>=500 MB/s）${RESET}"
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=200)}'; then
    DD_SCORE=70
    println "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    println "${FG_YELLOW}⚠️  磁盘：一般（>=200 MB/s）${RESET}"
  else
    DD_SCORE=45
    println "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    println "${FG_RED}❌ 磁盘：偏弱（<200 MB/s）${RESET}"
  fi
  hr
}

# -------- Media (best-effort) --------
do_media() {
  println "${FG_PURPLE}--- 流媒体解锁检测（best-effort）---${RESET}"

  local yt_cc nf ds tt pv mx dm
  yt_cc="unknown"; nf="unknown"; ds="unknown"; tt="unknown"; pv="unknown"; mx="unknown"; dm="unknown"

  # YouTube countryCode best-effort
  local yth
  yth="$(curl -fsS --max-time 8 "https://www.youtube.com/premium" 2>/dev/null || true)"
  if [[ -n "$yth" ]]; then
    yt_cc="$(printf "%s" "$yth" | grep -oE 'countryCode"\s*:\s*"[A-Z]+"' | head -n1 | sed -E 's/.*"([A-Z]+)".*/\1/' )"
    [[ -z "$yt_cc" ]] && yt_cc="unknown"
  fi

  # 动画疯（常见 403/风控）
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://ani.gamer.com.tw/" || echo "000")"
  if [[ "$code" == "200" ]]; then
    dm="可访问"
    println "${FG_GREEN}✅ 动画疯：可访问${RESET}"
  elif [[ "$code" == "403" ]]; then
    dm="可能风控/CF 拦截"
    println "${FG_YELLOW}⚠️  动画疯：可能风控/CF 拦截（HTTP 403）${RESET}"
  else
    dm="未知"
    println "${FG_GRAY}⚪ 动画疯：未知（HTTP ${code}）${RESET}"
  fi

  # Netflix
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://www.netflix.com/title/80018499" || echo "000")"
  if [[ "$code" == "200" || "$code" == "404" ]]; then
    nf="可访问"
    println "${FG_GREEN}✅ Netflix：可访问（最终以登录播放为准）${RESET}"
  else
    nf="未知"
    println "${FG_GRAY}⚪ Netflix：未知（HTTP ${code}）${RESET}"
  fi

  # Disney+
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://www.disneyplus.com/" || echo "000")"
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    ds="可访问"
    println "${FG_GREEN}✅ Disney+：可访问（最终以登录播放为准）${RESET}"
  else
    ds="未知"
    println "${FG_GRAY}⚪ Disney+：未知（HTTP ${code}）${RESET}"
  fi

  # TikTok
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://www.tiktok.com/" || echo "000")"
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    tt="可访问（地区不确定）"
    println "${FG_YELLOW}⚠️  TikTok：可访问但可能无法判断地区（易受风控/Cloudflare 影响）${RESET}"
  else
    tt="未知"
    println "${FG_GRAY}⚪ TikTok：未知（HTTP ${code}）${RESET}"
  fi

  # Prime/Max（仅判断可访问）
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://www.primevideo.com/" || echo "000")"
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    pv="可访问"
    println "${FG_GREEN}✅ Prime Video：可访问（片库看账号地区）${RESET}"
  else
    pv="未知"
    println "${FG_GRAY}⚪ Prime Video：未知（HTTP ${code}）${RESET}"
  fi

  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "https://play.max.com/" || echo "000")"
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    mx="可访问"
    println "${FG_GREEN}✅ Max：可访问（最终以登录播放为准）${RESET}"
  else
    mx="未知"
    println "${FG_GRAY}⚪ Max：未知（HTTP ${code}）${RESET}"
  fi

  println "${FG_CYAN}ℹ️  提示：Netflix/Disney+/Max/Prime 只能判断“可访问/疑似受限”，最终以登录播放为准。${RESET}"
  println "${FG_CYAN}ℹ️  TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。${RESET}"

  # scoring (简单可用分)
  local s=0 ok=0 total=0
  total=7
  [[ "$yt_cc" != "unknown" ]] && ((ok++))
  [[ "$dm" == "可访问" ]] && ((ok++))
  [[ "$nf" == "可访问" ]] && ((ok++))
  [[ "$ds" == "可访问" ]] && ((ok++))
  [[ "$tt" != "未知" ]] && ((ok++))
  [[ "$pv" == "可访问" ]] && ((ok++))
  [[ "$mx" == "可访问" ]] && ((ok++))
  s=$(( ok * 100 / total ))
  MEDIA_SCORE="$s"

  local yt_show="可访问"
  [[ "$yt_cc" == "unknown" ]] && yt_show="可访问（地区=未知）" || yt_show="可访问（地区=${yt_cc}）"

  MEDIA_LINE="YouTube=${yt_show} | 动画疯=${dm} | Netflix=${nf} | Disney+=${ds} | TikTok=${tt} | Prime=${pv} | Max=${mx}"
  hr
}

# -------- TCP multi-source median --------
tcp_url_of() {
  case "$1" in
    cloudflare) echo "https://speed.cloudflare.com/__down?bytes=16777216" ;;   # 16MB
    hetzner)    echo "https://speed.hetzner.de/100MB.bin" ;;
    ovh)        echo "https://proof.ovh.net/files/100Mb.dat" ;;
    cachefly)   echo "https://speedtest.cachefly.net/100mb.test" ;;
    *)          echo "" ;;
  esac
}

do_tcp() {
  println "${FG_PURPLE}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${RESET}"
  println "${FG_CYAN}ℹ️  范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速（能测几个算几个）${RESET}"

  local tls_list=() ttfb_list=() dl_list=() ok_sources=()
  local best_dl=-1 best_src=""

  for src in "${TCP_SOURCES[@]}"; do
    local url; url="$(tcp_url_of "$src")"
    [[ -z "$url" ]] && continue

    # range bytes
    local bytes=$(( TCP_RANGE_MB * 1024 * 1024 ))
    local end=$(( bytes - 1 ))

    # curl metrics
    # time_appconnect: TLS handshake
    # time_starttransfer: TTFB
    # speed_download: bytes/sec
    local line
    line="$(curl -sS -o /dev/null \
      --max-time "$TCP_MAXTIME" \
      -L \
      -r "0-${end}" \
      -w "code=%{http_code} tls=%{time_appconnect} ttfb=%{time_starttransfer} spd=%{speed_download}" \
      "$url" 2>/dev/null || true)"

    local code tls ttfb spd
    code="$(printf "%s" "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^code=/){sub(/^code=/,"",$i); print $i; exit}}')"
    tls="$(printf "%s" "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^tls=/){sub(/^tls=/,"",$i); print $i; exit}}')"
    ttfb="$(printf "%s" "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^ttfb=/){sub(/^ttfb=/,"",$i); print $i; exit}}')"
    spd="$(printf "%s" "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^spd=/){sub(/^spd=/,"",$i); print $i; exit}}')"

    # 判断成功：code 200/206 且 spd 非空且非 0
    if [[ "$code" != "200" && "$code" != "206" ]]; then
      println "• ${FG_GRAY}${src}${RESET}: 失败/超时（跳过）"
      continue
    fi
    if [[ -z "$spd" || "$spd" == "0" ]]; then
      println "• ${FG_GRAY}${src}${RESET}: 失败/超时（跳过）"
      continue
    fi

    # convert
    local tls_ms ttfb_ms dl_mbps
    tls_ms="$(awk -v x="$tls" 'BEGIN{printf "%.2f", x*1000}')"
    ttfb_ms="$(awk -v x="$ttfb" 'BEGIN{printf "%.2f", x*1000}')"
    dl_mbps="$(awk -v x="$spd" 'BEGIN{printf "%.2f", x*8/1000000}')"

    tls_list+=("$tls_ms")
    ttfb_list+=("$ttfb_ms")
    dl_list+=("$dl_mbps")
    ok_sources+=("$src")

    if awk -v a="$dl_mbps" -v b="$best_dl" 'BEGIN{exit !(a>b)}'; then
      best_dl="$dl_mbps"
      best_src="$src"
    fi

    println "• ${FG_GREEN}${src}${RESET}: TLS=$(f0 "$tls_ms")ms  TTFB=$(f0 "$ttfb_ms")ms  下载=$(f2 "$dl_mbps")Mbps  code=${code}"
  done

  local n="${#dl_list[@]}"
  TCP_OK_SAMPLES="$n"
  TCP_BEST_SRC="$best_src"

  if (( n == 0 )); then
    TCP_TLS_MS=""
    TCP_TTFB_MS=""
    TCP_DL_MBPS=""
    TCP_SCORE=0
    TCP_NOTE="有效样本不足（可能被限速/风控/超时），建议换时间多测几次。"
    println "${FG_YELLOW}⚠️  TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。${RESET}"
    hr
    return 0
  fi

  local tls_med ttfb_med dl_med
  tls_med="$(printf "%s\n" "${tls_list[@]}" | median_of_list)"
  ttfb_med="$(printf "%s\n" "${ttfb_list[@]}" | median_of_list)"
  dl_med="$(printf "%s\n" "${dl_list[@]}" | median_of_list)"

  TCP_TLS_MS="$(f2 "${tls_med:-0}")"
  TCP_TTFB_MS="$(f2 "${ttfb_med:-0}")"
  TCP_DL_MBPS="$(f2 "${dl_med:-0}")"

  # score rules (以“中位数下载”为主)
  local s=0
  if awk -v d="$dl_med" 'BEGIN{exit !(d>=20)}' && awk -v t="$ttfb_med" 'BEGIN{exit !(t<=300)}'; then
    s=92
  elif awk -v d="$dl_med" 'BEGIN{exit !(d>=5)}'; then
    s=80
  elif awk -v d="$dl_med" 'BEGIN{exit !(d>=1)}'; then
    s=65
  else
    s=40
  fi
  TCP_SCORE="$s"

  if (( n < 2 )); then
    TCP_NOTE="有效样本较少（${n} 个），建议换时间多测几次更稳。"
    println "${FG_YELLOW}⚠️  TCP：有效样本较少（${n} 个），建议换时间多测几次更稳。${RESET}"
  fi

  println
  println "${FG_GRAY}中位数结果：TLS=$(f0 "$TCP_TLS_MS")ms | TTFB=$(f0 "$TCP_TTFB_MS")ms | 下载=$(f2 "$TCP_DL_MBPS")Mbps（最佳=${best_src} $(f2 "$best_dl")Mbps）${RESET}"

  local glabel; glabel="$(grade_label "$s")"
  local gfg; gfg="$(grade_color_fg "$s")"
  if (( s >= 90 )); then
    println "${FG_GREEN}✅ TCP 体验：优秀${RESET}"
  elif (( s >= 75 )); then
    println "${FG_CYAN}✅ TCP 体验：良好${RESET}"
  elif (( s >= 60 )); then
    println "${FG_YELLOW}⚠️  TCP 体验：一般${RESET}"
  else
    println "${FG_RED}❌ TCP 体验：偏弱${RESET}"
  fi
  hr
}

# -------- Summary --------
calc_network_score() {
  # Ping + MTR 合成
  local s_ping=0
  # Ping worst loss/avg -> score
  if [[ -n "${PING_WORST_LOSS:-}" && -n "${PING_WORST_AVG:-}" && "${PING_WORST_LOSS}" != "未知" && "${PING_WORST_AVG}" != "未知" ]]; then
    local l a
    l="$(awk -v x="$PING_WORST_LOSS" 'BEGIN{print x+0}')"
    a="$(awk -v x="$PING_WORST_AVG" 'BEGIN{print x+0}')"
    if awk -v l="$l" 'BEGIN{exit !(l<=1)}' && awk -v a="$a" 'BEGIN{exit !(a<80)}'; then s_ping=95
    elif awk -v l="$l" 'BEGIN{exit !(l<=3)}' && awk -v a="$a" 'BEGIN{exit !(a<150)}'; then s_ping=80
    elif awk -v l="$l" 'BEGIN{exit !(l<=5)}' && awk -v a="$a" 'BEGIN{exit !(a<250)}'; then s_ping=65
    else s_ping=40
    fi
  else
    s_ping=0
  fi

  local s_mtr="${MTR_SCORE:-0}"
  # if MTR not run -> fall back ping only
  if [[ -z "${MTR_LAST_AVG:-}" || "${MTR_LAST_AVG}" == "未知" ]]; then
    awk -v p="$s_ping" 'BEGIN{printf "%d", p}'
  else
    awk -v p="$s_ping" -v m="$s_mtr" 'BEGIN{printf "%d", (p*0.6 + m*0.4)}'
  fi
}

summary() {
  local net_score tcp_score disk_score media_score total
  net_score="$(calc_network_score)"
  tcp_score="${TCP_SCORE:-0}"
  disk_score="${DD_SCORE:-0}"
  media_score="${MEDIA_SCORE:-0}"

  # total weight: network 35, tcp 25, disk 20, media 20
  total="$(awk -v n="$net_score" -v t="$tcp_score" -v d="$disk_score" -v m="$media_score" \
    'BEGIN{printf "%d", (n*0.35 + t*0.25 + d*0.20 + m*0.20)}')"

  local net_g; net_g="$(grade_label "$net_score")"
  local tcp_g; tcp_g="$(grade_label "$tcp_score")"
  local dd_g;  dd_g="$(grade_label "$disk_score")"
  local me_g;  me_g="$(grade_label "$media_score")"
  local tt_g;  tt_g="$(grade_label "$total")"

  local net_fg tcp_fg dd_fg me_fg tt_fg
  net_fg="$(grade_color_fg "$net_score")"
  tcp_fg="$(grade_color_fg "$tcp_score")"
  dd_fg="$(grade_color_fg "$disk_score")"
  me_fg="$(grade_color_fg "$media_score")"
  tt_fg="$(grade_color_fg "$total")"

  hr2
  println "${FG_PINK}${BOLD}==================== ✅ VPS 体检总结报告 =====================${RESET}"

  println "${FG_PINK}[基础信息]${RESET}"
  println "Host : $(mask_host "$B_HOST")"
  println "OS   : $B_OS"
  println "Kern : $B_KERN | Virt=${B_VIRT}"
  println "CPU  : $B_CPU | 核数=${B_CORES} | 内存=${B_RAM} | Swap=${B_SWAP}"
  println "Disk : / ${B_DISK}"
  println "IPv4 : $(mask_ipv4 "${P_IPV4:-unknown}")"
  println "Geo  : ${P_GEO:-unknown}"
  println "ASN  : ${P_ASN:-unknown} ${P_ISP:-unknown}"
  hr

  # 网络
  println "${FG_PINK}[网络]${RESET}  ${net_score}/100 (${net_fg}${net_g}${RESET})  $(bar "$net_score")"
  println "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% | 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  if [[ -n "${MTR_TARGET:-}" ]]; then
    local m_loss="${MTR_LAST_LOSS:-未知}"
    local m_avg="${MTR_LAST_AVG:-未知}"
    local m_grade="${MTR_GRADE:-未知}"
    # MTR 评级中文
    local m_grade_cn="$m_grade"
    println "MTR  : 目标=${MTR_TARGET} | 终点丢包=${m_loss}% | 终点平均=${m_avg}ms | 评级=${m_grade_cn}"
  else
    println "MTR  : 未执行"
  fi
  hr

  # TCP
  println "${FG_PINK}[TCP真实链路]${RESET}  ${tcp_score}/100 (${tcp_fg}${tcp_g}${RESET})  $(bar "$tcp_score")"
  if (( TCP_OK_SAMPLES > 0 )); then
    println "TLS  : $(f0 "${TCP_TLS_MS:-0}")ms | TTFB=$(f0 "${TCP_TTFB_MS:-0}")ms"
    println "下载 : $(f2 "${TCP_DL_MBPS:-0}")Mbps（中位数，range=${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
    println "样本 : ${TCP_OK_SAMPLES} 个 | 最佳源=${TCP_BEST_SRC:-unknown}"
    [[ -n "${TCP_NOTE:-}" ]] && println "${FG_YELLOW}⚠️  ${TCP_NOTE}${RESET}"
  else
    println "TLS  : 未执行/无有效样本"
    println "下载 : 未执行/无有效样本"
    [[ -n "${TCP_NOTE:-}" ]] && println "${FG_YELLOW}⚠️  ${TCP_NOTE}${RESET}"
  fi
  hr

  # 磁盘
  println "${FG_PINK}[磁盘]${RESET}  ${disk_score}/100 (${dd_fg}${dd_g}${RESET})  $(bar "$disk_score")"
  if [[ -n "${DD_SPEED_MBPS:-}" ]]; then
    println "dd   : $(awk -v x="$DD_SPEED_MBPS" 'BEGIN{printf "%.0f", x}') MB/s（约）"
  else
    println "dd   : 未执行"
  fi
  hr

  # 流媒体
  println "${FG_PINK}[流媒体]${RESET}  ${media_score}/100 (${me_fg}${me_g}${RESET})  $(bar "$media_score")"
  println "${MEDIA_LINE:-未执行}"
  hr

  # 总评
  println "${FG_PINK}[总评]${RESET}  ${total}/100 (${tt_fg}${tt_g}${RESET})  $(bar "$total")"

  # 结论
  if (( total >= 90 )); then
    println "${FG_GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${RESET}"
  elif (( total >= 75 )); then
    println "${FG_CYAN}✅ 结论：整体不错，日常中转/落地够用，关注路由与邻居波动。${RESET}"
  elif (( total >= 60 )); then
    println "${FG_YELLOW}⚠️  结论：整体一般，建议换时段多测或降低用途预期。${RESET}"
  else
    println "${FG_RED}❌ 结论：整体偏弱，不建议做关键落地或高稳定需求用途。${RESET}"
  fi

  println
  println "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${RESET}"
  hr2
}

# -------- All-run --------
run_all_verbose() {
  do_basic
  do_public
  do_ping_all
  do_mtr
  do_dd
  do_media
  do_tcp
  summary
}

run_all_silent() {
  println "${FG_CYAN}ℹ️  正在后台静默执行检测（2~8+10），完成后输出最终✅总结...${RESET}"
  # 静默：把过程输出丢到文件（避免刷屏）
  {
    do_basic >/dev/null
    do_public >/dev/null
    do_ping_all >/dev/null
    do_mtr >/dev/null
    do_dd >/dev/null
    do_media >/dev/null
    do_tcp >/dev/null
  } 2>/dev/null || true
  summary
}

# -------- Menu --------
menu() {
  while true; do
    println
    println "${FG_PINK}====================== VPS 一键体检 菜单 ======================${RESET}"
    println "Targets: ${FG_PURPLE}${TARGETS[*]}${RESET}  ${FG_GRAY}(MTR 默认用第一个 Target)${RESET}"
    println
    println "  1) 设置测试目标（Targets）"
    println "  2) 基本信息（系统/CPU/RAM/磁盘占用/虚拟化）"
    println "  3) 公网信息（IPv4 / Geo / ASN / ISP）"
    println "  4) 网络 Ping 测试（所有 Targets）"
    println "  5) 路由 MTR 测试（仅第一个 Target）"
    println "  6) 安装 mtr-tiny（Debian/Ubuntu）"
    println "  7) 磁盘 dd 测速（输出速度）"
    println "  8) 流媒体检测（YouTube/动画疯/Netflix/Disney+/TikTok/Prime/Max）"
    println "  9) 一键全跑（2~8+10）并输出最终总结（会显示全过程）"
    println " 10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
    println "  R) 后台静默全跑（2~8+10），只输出最终✅总结报告（不刷屏）"
    println "  0) 退出"
    hr

    read -r -p "选择 [0-10/R]: " sel
    case "$sel" in
      1)
        read -r -p "请输入 Targets（用空格分隔），例如：1.1.1.1 8.8.8.8 www.google.com : " line
        if [[ -n "$line" ]]; then
          # shellcheck disable=SC2206
          TARGETS=($line)
        fi
        ;;
      2) do_basic; pause ;;
      3) do_public; pause ;;
      4) do_ping_all; pause ;;
      5) do_mtr; pause ;;
      6) do_mtr_install; pause ;;
      7) do_dd; pause ;;
      8) do_media; pause ;;
      9) run_all_verbose; pause ;;
      10) do_tcp; pause ;;
      R|r) run_all_silent; pause ;;
      0) exit 0 ;;
      *) println "${FG_YELLOW}⚠️  请输入有效选项${RESET}" ;;
    esac
  done
}

# -------- Entry --------
menu
