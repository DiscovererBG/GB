#!/usr/bin/env bash
# ==========================================================
# VPS 一键体检（稳定修复版）
# 1) 不再 set -e（任何一步失败不会整脚本退出）
# 2) 进度条：彩色块 + 灰点（不再用 '='）
# 3) Ping 解析修复：不再出现 min=mdev= / mdev=?ms
# 4) TCP 多源中位数：不依赖 awk asort（兼容 mawk）
# 5) MTR 终点丢包/平均延迟解析更稳，失败显示“未知”
# 6) 输出尽量中文化（评级/提示/字段）
# 7) 9/R 必跑完：curl/mtr/dd 任一步失败只降级，不退出
# ==========================================================

set -u
set -o pipefail

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
hr()  { println "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2() { println "${FG_PINK}=========================================================${RESET}"; }
pause() { read -r -p "回车继续..." _; }
exists() { command -v "$1" >/dev/null 2>&1; }

mask_ipv4() {
  local ip="$1"
  [[ "$REDact" -eq 0 ]] && { printf "%s" "$ip"; return; }
  printf "%s" "$ip" | awk -F. 'NF==4{print $1"."$2".*.*"; next}{print "*.*.*.*"}'
}
mask_host() {
  local h="$1"
  [[ "$REDact" -eq 0 ]] && { printf "%s" "$h"; return; }
  [[ -z "$h" ]] && { printf "unknown"; return; }
  printf "%s" "$h" | sed -E 's/^(.).*(.)$/\1***\2/'
}

f2() { awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x+0}'; }
f1() { awk -v x="${1:-0}" 'BEGIN{printf "%.1f", x+0}'; }

grade_label() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "优秀"; return; fi
  if (( s >= 75 )); then printf "良好"; return; fi
  if (( s >= 60 )); then printf "一般"; return; fi
  printf "偏弱"
}
grade_fg() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$FG_GREEN"; return; fi
  if (( s >= 75 )); then printf "%s" "$FG_CYAN"; return; fi
  if (( s >= 60 )); then printf "%s" "$FG_YELLOW"; return; fi
  printf "%s" "$FG_RED"
}
grade_bg() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$BG_GREEN"; return; fi
  if (( s >= 75 )); then printf "%s" "$BG_CYAN"; return; fi
  if (( s >= 60 )); then printf "%s" "$BG_YELLOW"; return; fi
  printf "%s" "$BG_RED"
}

# ✅ 进度条：彩色“█”块 + 灰点（不使用 '='）
bar() {
  local score="${1:-0}" width="${2:-28}"
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100
  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))
  local fg; fg="$(grade_fg "$score")"
  local bg; bg="$(grade_bg "$score")"

  printf "%b" "${fg}[${RESET}"
  printf "%b" "${bg}${FG_WHITE}"
  if (( filled > 0 )); then
    printf "%*s" "$filled" "" | tr " " "█"
  fi
  printf "%b" "${RESET}"
  printf "%b" "${FG_GRAY}${DIM}"
  if (( rest > 0 )); then
    printf "%*s" "$rest" "" | tr " " "·"
  fi
  printf "%b" "${RESET}${fg}]${RESET}"
}

median_of_list() {
  # stdin: numbers (one per line). output: median
  local arr n mid a b
  mapfile -t arr < <(cat | awk 'NF{print $1}' | sort -n)
  n="${#arr[@]}"
  (( n==0 )) && { printf ""; return 0; }
  mid=$(( n/2 ))
  if (( n%2==1 )); then
    printf "%s" "${arr[$mid]}"
  else
    a="${arr[$((mid-1))]}"; b="${arr[$mid]}"
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f",(a+b)/2}'
  fi
}

ensure_deps() {
  # best-effort install
  local pkgs=("$@")
  if ! exists apt-get; then return 0; fi
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || true
}

# ------------------ Runtime Results ------------------
B_HOST=""; B_OS=""; B_KERN=""; B_VIRT=""; B_CPU=""; B_CORES=""; B_RAM=""; B_SWAP=""; B_DISK=""; B_UPTIME=""
P_IPV4=""; P_GEO=""; P_ASN=""; P_ISP=""

PING_WORST_LOSS="未知"; PING_WORST_AVG="未知"
PING_GOOD=0; PING_WARN=0; PING_BAD=0
PING_SCORE=0

MTR_TARGET=""; MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0

DD_SPEED_MBPS=""; DD_SCORE=0
MEDIA_SCORE=0; MEDIA_LINE=""
TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""; TCP_OK_SAMPLES=0; TCP_BEST_SRC=""; TCP_SCORE=0; TCP_NOTE=""

# -------- Basic info --------
do_basic() {
  B_HOST="$(hostname 2>/dev/null || echo "unknown")"
  if [[ -r /etc/os-release ]]; then
    B_OS="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
  else
    B_OS="Linux"
  fi
  B_KERN="$(uname -r 2>/dev/null || echo "unknown")"
  if exists systemd-detect-virt; then
    B_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "$B_VIRT" ]] && B_VIRT="none"
  else
    B_VIRT="unknown"
  fi

  B_CPU="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "unknown")"
  B_CORES="$(nproc 2>/dev/null || echo "1")"

  if exists free; then
    B_RAM="$(free -m | awk '/Mem:/ {print $2 " MB"}')"
    B_SWAP="$(free -m | awk '/Swap:/ {print $2 " MB"}')"
  else
    B_RAM="unknown"; B_SWAP="unknown"
  fi

  if exists uptime; then
    B_UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //')"
    [[ -z "$B_UPTIME" ]] && B_UPTIME="unknown"
  else
    B_UPTIME="unknown"
  fi

  if exists df; then
    B_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')"
    [[ -z "$B_DISK" ]] && B_DISK="unknown"
  else
    B_DISK="unknown"
  fi

  println "${FG_PINK}--- 基本信息 ---${RESET}"
  println "Host     : $(mask_host "$B_HOST")"
  println "系统     : $B_OS"
  println "内核     : $B_KERN"
  println "运行时长 : $B_UPTIME"
  println "虚拟化   : $B_VIRT"
  println "CPU      : $B_CPU（${B_CORES} 核）"
  println "内存/Swap: $B_RAM / $B_SWAP"
  println "磁盘 /   : $B_DISK"
  hr
}

# -------- Public info --------
do_public() {
  ensure_deps curl >/dev/null 2>&1 || true

  P_IPV4="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="unknown"

  P_GEO="unknown"; P_ASN="unknown"; P_ISP="unknown"
  if [[ "$P_IPV4" != "unknown" ]]; then
    local js city region country org
    js="$(curl -fsS --max-time 6 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"
    if [[ -n "$js" ]]; then
      city="$(printf "%s" "$js" | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      region="$(printf "%s" "$js" | sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      country="$(printf "%s" "$js" | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      org="$(printf "%s" "$js" | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"

      P_ASN="$(printf "%s" "$org" | awk '{print $1}' | head -n1)"
      [[ -z "$P_ASN" ]] && P_ASN="unknown"
      P_ISP="$(printf "%s" "$org" | sed -E 's/^AS[0-9]+[ ]*//' | head -n1)"
      [[ -z "$P_ISP" ]] && P_ISP="unknown"

      P_GEO="$(printf "%s, %s, %s" "${city:-unknown}" "${region:-unknown}" "${country:-unknown}")"
    fi
  fi

  println "${FG_PINK}--- 公网信息 ---${RESET}"
  println "IPv4     : $(mask_ipv4 "$P_IPV4")"
  println "Geo      : $P_GEO"
  println "ASN      : $P_ASN"
  println "ISP/Org  : $P_ISP"
  hr
}

# -------- Ping parsing (fix) --------
parse_ping_rtt() {
  # output: min avg max mdev
  awk '
    /rtt|round-trip/ {
      split($0, a, "=")
      gsub(/^[ \t]+/, "", a[2])
      gsub(/ ms.*/, "", a[2])
      split(a[2], v, "/")
      print v[1], v[2], v[3], v[4]
      exit
    }
  '
}

ping_one() {
  local t="$1"
  local out loss min avg max mdev
  out="$(ping -c "$PING_COUNT" -q "$t" 2>/dev/null || true)"

  loss="$(printf "%s" "$out" | awk -F',' '/packet loss/ {gsub(/^[ \t]+/,"",$3); gsub(/% packet loss.*/,"",$3); print $3; exit}')"
  [[ -z "$loss" ]] && loss="未知"

  read -r min avg max mdev < <(printf "%s\n" "$out" | parse_ping_rtt)
  [[ -z "${min:-}" ]] && min="未知"
  [[ -z "${avg:-}" ]] && avg="未知"
  [[ -z "${max:-}" ]] && max="未知"
  [[ -z "${mdev:-}" ]] && mdev="-"

  println "${FG_PURPLE}--- Ping: ${t} (${PING_COUNT} 次) ---${RESET}"
  println "丢包 : ${loss}%"
  println "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  local s=0
  if [[ "$loss" == "未知" || "$avg" == "未知" ]]; then
    s=0
  else
    local lossn avgn
    lossn="$(awk -v x="$loss" 'BEGIN{print x+0}')"
    avgn="$(awk -v x="$avg" 'BEGIN{print x+0}')"
    if awk -v l="$lossn" 'BEGIN{exit !(l<=1)}' && awk -v a="$avgn" 'BEGIN{exit !(a<80)}'; then
      s=95
    elif awk -v l="$lossn" 'BEGIN{exit !(l<=5)}' && awk -v a="$avgn" 'BEGIN{exit !(a<150)}'; then
      s=75
    elif awk -v l="$lossn" 'BEGIN{exit !(l<=10)}' && awk -v a="$avgn" 'BEGIN{exit !(a<250)}'; then
      s=60
    else
      s=40
    fi
  fi

  if [[ "$loss" != "未知" ]]; then
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}'; then
      println "${FG_GREEN}✅ 丢包：优秀（≤1%）${RESET}"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}'; then
      println "${FG_YELLOW}⚠️  丢包：一般（≤5%）${RESET}"
    else
      println "${FG_RED}❌ 丢包：偏弱（>5%）${RESET}"
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      println "${FG_GREEN}✅ 延迟：优秀（<80ms）${RESET}"
    elif awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      println "${FG_YELLOW}⚠️  延迟：一般（<150ms）${RESET}"
    else
      println "${FG_RED}❌ 延迟：偏弱（≥150ms）${RESET}"
    fi
  fi

  # worst
  if [[ "$loss" != "未知" ]]; then
    if [[ "$PING_WORST_LOSS" == "未知" ]]; then PING_WORST_LOSS="$loss"; else
      if awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}'; then PING_WORST_LOSS="$loss"; fi
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if [[ "$PING_WORST_AVG" == "未知" ]]; then PING_WORST_AVG="$avg"; else
      if awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}'; then PING_WORST_AVG="$avg"; fi
    fi
  fi

  if (( s >= 90 )); then ((PING_GOOD++)); elif (( s >= 60 )); then ((PING_WARN++)); else ((PING_BAD++)); fi
  hr
}

do_ping_all() {
  PING_WORST_LOSS="未知"; PING_WORST_AVG="未知"
  PING_GOOD=0; PING_WARN=0; PING_BAD=0

  for t in "${TARGETS[@]}"; do
    ping_one "$t"
  done

  # score: based on worst loss/avg and counts
  if [[ "$PING_WORST_LOSS" == "未知" || "$PING_WORST_AVG" == "未知" ]]; then
    PING_SCORE=0
  else
    local lossn avgn
    lossn="$(awk -v x="$PING_WORST_LOSS" 'BEGIN{print x+0}')"
    avgn="$(awk -v x="$PING_WORST_AVG" 'BEGIN{print x+0}')"
    if awk -v l="$lossn" 'BEGIN{exit !(l<=1)}' && awk -v a="$avgn" 'BEGIN{exit !(a<80)}'; then
      PING_SCORE=95
    elif awk -v l="$lossn" 'BEGIN{exit !(l<=5)}' && awk -v a="$avgn" 'BEGIN{exit !(a<150)}'; then
      PING_SCORE=80
    elif awk -v l="$lossn" 'BEGIN{exit !(l<=10)}' && awk -v a="$avgn" 'BEGIN{exit !(a<250)}'; then
      PING_SCORE=65
    else
      PING_SCORE=40
    fi
  fi

  println "${FG_CYAN}ℹ️  Ping 小结：目标数=${#TARGETS[@]} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS}% 最差平均延迟=${PING_WORST_AVG}ms${RESET}"
  hr
}

# -------- MTR --------
do_mtr_install() {
  println "${FG_CYAN}ℹ️  正在安装 mtr-tiny...${RESET}"
  ensure_deps mtr-tiny mtr >/dev/null 2>&1 || true
  if exists mtr; then
    println "${FG_GREEN}✅ mtr 已可用${RESET}"
  else
    println "${FG_RED}❌ mtr 安装失败（可手动安装：apt-get install -y mtr-tiny）${RESET}"
  fi
  hr
}

do_mtr() {
  local t="${TARGETS[0]}"
  MTR_TARGET="$t"

  if ! exists mtr; then
    # 9/R 自动尝试安装一次（失败就降级）
    do_mtr_install >/dev/null 2>&1 || true
  fi
  if ! exists mtr; then
    println "${FG_YELLOW}⚠️  MTR 未安装/不可用，跳过${RESET}"
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    hr
    return 0
  fi

  println "${FG_PURPLE}--- MTR: ${t} (${MTR_CYCLES} 轮) ---${RESET}"
  local out
  out="$(mtr -rwzbc "$MTR_CYCLES" "$t" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    println "${FG_YELLOW}⚠️  MTR 执行失败（可能被 ICMP 限制）${RESET}"
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    hr
    return 0
  fi

  printf "%s\n" "$out"

  # 解析终点（最后一跳）Loss% 和 Avg
  local lastline loss avg
  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"
  loss="$(printf "%s\n" "$lastline" | awk '{print $(NF-6)}' | tr -d '%' )"
  avg="$(printf "%s\n" "$lastline"  | awk '{print $(NF-4)}')"

  if [[ -z "$loss" || -z "$avg" ]]; then
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    println "${FG_YELLOW}⚠️  终点数据解析失败（不同 mtr 输出格式/被限速）${RESET}"
    hr
    return 0
  fi

  MTR_LAST_LOSS="$(f1 "$loss")"
  MTR_LAST_AVG="$(f1 "$avg")"

  local s=0
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
  local out speed unit mbps
  out="$(LANG=C dd if=/dev/zero of="$TMPDIR/dd_test" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1 || true)"
  rm -f "$TMPDIR/dd_test" >/dev/null 2>&1 || true

  speed="$(printf "%s\n" "$out" | awk -F',' 'END{print $3}' | awk '{print $1}')"
  unit="$(printf "%s\n" "$out" | awk -F',' 'END{print $3}' | awk '{print $2}')"

  if [[ -z "$speed" || -z "$unit" ]]; then
    DD_SPEED_MBPS=""; DD_SCORE=0
    println "${FG_YELLOW}⚠️  dd 测速失败（跳过）${RESET}"
    hr
    return 0
  fi

  if [[ "$unit" == "GB/s" ]]; then
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x*1024}')"
  else
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x}')"
  fi
  DD_SPEED_MBPS="$mbps"

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
curl_code() {
  local url="$1"
  curl -fsS -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000"
}

do_media() {
  ensure_deps curl >/dev/null 2>&1 || true

  println "${FG_PURPLE}--- 流媒体解锁检测（best-effort）---${RESET}"

  local y_code nf_code ds_code tt_code pv_code mx_code an_code
  local y_cc="unknown"

  # YouTube: best effort countryCode
  y_code="$(curl -fsS -o /tmp/yt.$$ --max-time 12 "https://www.youtube.com/premium" 2>/dev/null && echo 200 || echo 000)"
  if [[ "$y_code" == "200" ]]; then
    y_cc="$(grep -oE 'countryCode":"[A-Z]{2}' /tmp/yt.$$ 2>/dev/null | head -n1 | cut -d'"' -f3)"
    [[ -z "$y_cc" ]] && y_cc="unknown"
  fi
  rm -f /tmp/yt.$$ >/dev/null 2>&1 || true

  an_code="$(curl_code "https://ani.gamer.com.tw/")"
  nf_code="$(curl_code "https://www.netflix.com/title/81215567")"
  ds_code="$(curl_code "https://www.disneyplus.com/")"
  tt_code="$(curl_code "https://www.tiktok.com/")"
  pv_code="$(curl_code "https://www.primevideo.com/")"
  mx_code="$(curl_code "https://play.max.com/")"

  # classify
  local penalty=0
  local yt="可访问" ani="可访问" nf="可访问" ds="可访问" tt="可访问" pv="可访问" mx="可访问"

  [[ "$y_code"  == "200" ]] || { yt="不可用"; penalty=$((penalty+25)); }
  if [[ "$an_code" == "200" ]]; then
    ani="可访问"
  elif [[ "$an_code" == "403" ]]; then
    ani="可能风控/CF 拦截"
    penalty=$((penalty+17))
  else
    ani="不可用"
    penalty=$((penalty+25))
  fi

  for_pair() { :; }

  [[ "$nf_code" == "200" ]] || { nf="不可用"; penalty=$((penalty+15)); }
  [[ "$ds_code" == "200" ]] || { ds="不可用"; penalty=$((penalty+15)); }
  if [[ "$tt_code" == "200" ]]; then
    tt="可访问（地区可能不确定）"
    penalty=$((penalty+5))
  else
    tt="不可用"
    penalty=$((penalty+15))
  fi
  [[ "$pv_code" == "200" ]] || { pv="不可用"; penalty=$((penalty+10)); }
  [[ "$mx_code" == "200" ]] || { mx="不可用"; penalty=$((penalty+10)); }

  MEDIA_SCORE=$((100-penalty))
  (( MEDIA_SCORE<0 )) && MEDIA_SCORE=0

  println "YouTube Premium : HTTP ${y_code}  地区：${y_cc}"
  println "${FG_GREEN}✅ YouTube：${yt}${RESET}"
  println
  println "动画疯         : HTTP ${an_code}"
  if [[ "$ani" == "可访问" ]]; then
    println "${FG_GREEN}✅ 动画疯：可访问${RESET}"
  elif [[ "$ani" == "可能风控/CF 拦截" ]]; then
    println "${FG_YELLOW}⚠️  动画疯：可能风控/CF 拦截${RESET}"
  else
    println "${FG_RED}❌ 动画疯：不可用${RESET}"
  fi
  println
  println "Netflix         : HTTP ${nf_code}"
  println "${FG_GREEN}✅ Netflix：${nf}（最终以登录播放为准）${RESET}"
  println
  println "Disney+         : HTTP ${ds_code}"
  println "${FG_GREEN}✅ Disney+：${ds}（最终以登录播放为准）${RESET}"
  println
  println "TikTok          : HTTP ${tt_code}"
  if [[ "$tt_code" == "200" ]]; then
    println "${FG_YELLOW}⚠️  TikTok：${tt}${RESET}"
  else
    println "${FG_RED}❌ TikTok：${tt}${RESET}"
  fi
  println
  println "Prime Video     : HTTP ${pv_code}"
  println "${FG_GREEN}✅ Prime：${pv}（片库看账号地区）${RESET}"
  println
  println "Max(HBO)        : HTTP ${mx_code}"
  println "${FG_GREEN}✅ Max：${mx}（最终以登录播放为准）${RESET}"

  println
  println "${FG_CYAN}ℹ️  提示：Netflix/Disney+/Max/Prime 仅能判断“可访问/疑似受限”，最终以登录播放为准。${RESET}"
  println "${FG_CYAN}ℹ️  TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。${RESET}"

  # summary line
  MEDIA_LINE="YouTube=${yt}(CC=${y_cc}) | 动画疯=${ani} | Netflix=${nf} | Disney+=${ds} | TikTok=${tt} | Prime=${pv} | Max=${mx}"
  hr
}

# -------- TCP real link (multi-source median) --------
tcp_url_for_source() {
  local s="$1"
  case "$s" in
    cloudflare) printf "%s" "https://speed.cloudflare.com/__down?bytes=$((TCP_RANGE_MB*1024*1024))" ;;
    hetzner)    printf "%s" "https://speed.hetzner.de/100MB.bin" ;;
    ovh)        printf "%s" "https://proof.ovh.net/files/100Mb.dat" ;;
    cachefly)   printf "%s" "https://cachefly.cachefly.net/100mb.test" ;;
    *)          printf "%s" "" ;;
  esac
}

tcp_test_one() {
  local src="$1"
  local url range_bytes end_byte
  url="$(tcp_url_for_source "$src")"
  [[ -z "$url" ]] && return 1

  range_bytes=$((TCP_RANGE_MB*1024*1024))
  end_byte=$((range_bytes-1))

  local tmp="$TMPDIR/tcp_${src}.out"
  local fmt code t_connect t_app t_ttfb t_total bytes

  # curl metrics in seconds
  fmt='%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download}\n'

  # Use range to limit to 16MB; for cloudflare url already limits bytes, still ok with -r
  local out
  out="$(curl -L -sS --max-time "$TCP_MAXTIME" -r "0-${end_byte}" -o /dev/null -w "$fmt" "$url" 2>/dev/null || true)"
  printf "%s\n" "$out" >"$tmp" 2>/dev/null || true

  code="$(awk '{print $1}' "$tmp" 2>/dev/null | head -n1)"
  [[ -z "$code" ]] && code="000"

  if [[ "$code" != "200" && "$code" != "206" ]]; then
    return 2
  fi

  t_connect="$(awk '{print $2}' "$tmp")"
  t_app="$(awk '{print $3}' "$tmp")"
  t_ttfb="$(awk '{print $4}' "$tmp")"
  t_total="$(awk '{print $5}' "$tmp")"
  bytes="$(awk '{print $6}' "$tmp")"

  # ms
  local tls_ms ttfb_ms
  tls_ms="$(awk -v t="$t_app" 'BEGIN{printf "%.0f", t*1000}')"
  # fallback if appconnect is 0
  if [[ "$tls_ms" == "0" || -z "$tls_ms" ]]; then
    tls_ms="$(awk -v t="$t_connect" 'BEGIN{printf "%.0f", t*1000}')"
  fi
  ttfb_ms="$(awk -v t="$t_ttfb" 'BEGIN{printf "%.0f", t*1000}')"

  # Mbps = (bytes*8)/(time_total*1e6)
  local mbps
  mbps="$(awk -v b="$bytes" -v tt="$t_total" 'BEGIN{ if(tt<=0){print ""} else {printf "%.2f", (b*8)/(tt*1000000)} }')"
  [[ -z "$mbps" ]] && return 3

  printf "%s %s %s %s\n" "$src" "$tls_ms" "$ttfb_ms" "$mbps"
  return 0
}

do_tcp() {
  ensure_deps curl >/dev/null 2>&1 || true

  println "${FG_PURPLE}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${RESET}"
  println "${FG_CYAN}ℹ️  范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速（能测几个算几个）${RESET}"

  local tls_list="$TMPDIR/tls.list"
  local ttfb_list="$TMPDIR/ttfb.list"
  local dl_list="$TMPDIR/dl.list"
  : >"$tls_list"; : >"$ttfb_list"; : >"$dl_list"

  TCP_OK_SAMPLES=0
  TCP_BEST_SRC=""
  local best_dl=0

  for src in "${TCP_SOURCES[@]}"; do
    local line
    line="$(tcp_test_one "$src" 2>/dev/null || true)"
    if [[ -z "$line" ]]; then
      println "• ${FG_GRAY}${src}${RESET}: ${FG_GRAY}失败/超时（跳过）${RESET}"
      continue
    fi
    local s tls ttfb dl
    s="$(awk '{print $1}' <<<"$line")"
    tls="$(awk '{print $2}' <<<"$line")"
    ttfb="$(awk '{print $3}' <<<"$line")"
    dl="$(awk '{print $4}' <<<"$line")"

    TCP_OK_SAMPLES=$((TCP_OK_SAMPLES+1))
    printf "%s\n" "$tls"  >>"$tls_list"
    printf "%s\n" "$ttfb" >>"$ttfb_list"
    printf "%s\n" "$dl"   >>"$dl_list"

    # best source
    if awk -v a="$dl" -v b="$best_dl" 'BEGIN{exit !(a>b)}'; then
      best_dl="$dl"
      TCP_BEST_SRC="$s"
    fi

    println "• ${FG_GREEN}${s}${RESET}: TLS=${tls}ms  TTFB=${ttfb}ms  下载=${dl}Mbps"
  done

  if (( TCP_OK_SAMPLES < 2 )); then
    TCP_TLS_MS="未知"; TCP_TTFB_MS="未知"; TCP_DL_MBPS="未知"
    TCP_SCORE=40
    TCP_NOTE="有效样本不足（可能被限速/风控/超时），建议换时间多测几次。"
    println "${FG_YELLOW}⚠️  TCP：${TCP_NOTE}${RESET}"
    hr
    return 0
  fi

  local med_tls med_ttfb med_dl
  med_tls="$(cat "$tls_list"  | median_of_list)"
  med_ttfb="$(cat "$ttfb_list" | median_of_list)"
  med_dl="$(cat "$dl_list"   | median_of_list)"

  TCP_TLS_MS="$(f1 "$med_tls")"
  TCP_TTFB_MS="$(f1 "$med_ttfb")"
  TCP_DL_MBPS="$(f2 "$med_dl")"

  # score model (兼顾延迟和吞吐)
  local s_speed s_tls s_ttfb
  # speed: 0..100 where 30Mbps≈85
  s_speed="$(awk -v x="$med_dl" 'BEGIN{
    if(x<=0) print 0;
    else if(x>=300) print 100;
    else if(x>=30)  print 85 + (x-30)*(15/(300-30));
    else            print (x/30)*85
  }')"
  # tls: <50ms=100, 300ms=60, 1000ms=20
  s_tls="$(awk -v x="$med_tls" 'BEGIN{
    if(x<=50) print 100;
    else if(x>=1000) print 20;
    else if(x>=300) print 60 - (x-300)*(40/(1000-300));
    else print 100 - (x-50)*(40/(300-50));
  }')"
  # ttfb: <100ms=100, 800ms=40
  s_ttfb="$(awk -v x="$med_ttfb" 'BEGIN{
    if(x<=100) print 100;
    else if(x>=800) print 40;
    else print 100 - (x-100)*(60/(800-100));
  }')"

  TCP_SCORE="$(awk -v a="$s_speed" -v b="$s_tls" -v c="$s_ttfb" 'BEGIN{printf "%d", (a*0.6 + b*0.2 + c*0.2)}')"
  local glabel; glabel="$(grade_label "$TCP_SCORE")"
  local gfg; gfg="$(grade_fg "$TCP_SCORE")"

  println
  println "${FG_GRAY}中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳源=${TCP_BEST_SRC} ${best_dl}Mbps）${RESET}"
  println "${gfg}✅ TCP 体验：${glabel}${RESET}"
  hr
}

# -------- Final report --------
print_report() {
  hr2
  println "${BOLD}✅ VPS 体检总结报告${RESET}"
  hr

  println "${FG_PINK}[基础信息]${RESET}"
  println "Host : $(mask_host "$B_HOST")"
  println "OS   : $B_OS"
  println "Kern : $B_KERN | Virt=$B_VIRT"
  println "CPU  : $B_CPU | 核数=${B_CORES} | 内存=${B_RAM} | Swap=${B_SWAP}"
  println "Disk : / $B_DISK"
  println "IPv4 : $(mask_ipv4 "$P_IPV4")"
  println "Geo  : $P_GEO"
  println "ASN  : $P_ASN"
  println "ISP  : $P_ISP"
  hr

  # 网络( Ping + MTR )
  local net_score="$PING_SCORE"
  local net_label; net_label="$(grade_label "$net_score")"
  local net_fg; net_fg="$(grade_fg "$net_score")"
  println "${FG_PINK}[网络]${RESET}  ${net_score}/100 ${net_fg}(${net_label})${RESET}  $(bar "$net_score")"
  println "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS}% | 最差平均延迟=${PING_WORST_AVG}ms"
  if [[ "$MTR_LAST_LOSS" == "未知" || "$MTR_LAST_AVG" == "未知" ]]; then
    println "MTR  : 目标=${TARGETS[0]} | 终点丢包=未知 | 终点平均=未知 | 评级=未知"
  else
    local mtr_label; mtr_label="$(grade_label "$MTR_SCORE")"
    println "MTR  : 目标=${TARGETS[0]} | 终点丢包=${MTR_LAST_LOSS}% | 终点平均=${MTR_LAST_AVG}ms | 评级=${mtr_label}"
  fi
  hr

  # TCP
  local tcp_label; tcp_label="$(grade_label "$TCP_SCORE")"
  local tcp_fg; tcp_fg="$(grade_fg "$TCP_SCORE")"
  println "${FG_PINK}[TCP真实链路]${RESET}  ${TCP_SCORE}/100 ${tcp_fg}(${tcp_label})${RESET}  $(bar "$TCP_SCORE")"
  println "TLS  : ${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms"
  println "DL   : ${TCP_DL_MBPS}Mbps（中位数, range=${TCP_RANGE_MB}MB, 超时=${TCP_MAXTIME}s）"
  if [[ -n "${TCP_NOTE:-}" ]]; then
    println "${FG_YELLOW}⚠️  提示：${TCP_NOTE}${RESET}"
  else
    println "样本 : ${TCP_OK_SAMPLES} 个 | 最佳源=${TCP_BEST_SRC}"
  fi
  hr

  # 磁盘
  local dd_label; dd_label="$(grade_label "$DD_SCORE")"
  local dd_fg; dd_fg="$(grade_fg "$DD_SCORE")"
  println "${FG_PINK}[磁盘]${RESET}  ${DD_SCORE}/100 ${dd_fg}(${dd_label})${RESET}  $(bar "$DD_SCORE")"
  if [[ -n "$DD_SPEED_MBPS" ]]; then
    println "dd   : 约 ${DD_SPEED_MBPS} MB/s"
  else
    println "dd   : 未知"
  fi
  hr

  # 流媒体
  local media_label; media_label="$(grade_label "$MEDIA_SCORE")"
  local media_fg; media_fg="$(grade_fg "$MEDIA_SCORE")"
  println "${FG_PINK}[流媒体]${RESET}  ${MEDIA_SCORE}/100 ${media_fg}(${media_label})${RESET}  $(bar "$MEDIA_SCORE")"
  println "$MEDIA_LINE"
  hr

  # 总评：权重（网络35 + TCP25 + 磁盘20 + 流媒体20）
  local total
  total="$(awk -v a="$PING_SCORE" -v b="$TCP_SCORE" -v c="$DD_SCORE" -v d="$MEDIA_SCORE" 'BEGIN{printf "%d", a*0.35 + b*0.25 + c*0.20 + d*0.20}')"
  local total_label; total_label="$(grade_label "$total")"
  local total_fg; total_fg="$(grade_fg "$total")"
  println "${FG_PINK}[总评]${RESET}  ${total}/100 ${total_fg}(${total_label})${RESET}  $(bar "$total")"

  if (( total >= 90 )); then
    println "${FG_GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${RESET}"
  elif (( total >= 75 )); then
    println "${FG_CYAN}✅ 结论：整体不错，日常中转/落地够用，关注路由与邻居波动。${RESET}"
  elif (( total >= 60 )); then
    println "${FG_YELLOW}⚠️  结论：整体一般，建议多测不同时间段，必要时换机房/线路。${RESET}"
  else
    println "${FG_RED}❌ 结论：整体偏弱，不建议承担关键用途。${RESET}"
  fi

  println
  println "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${RESET}"
  hr2
}

# -------- Run wrappers --------
run_all_verbose() {
  do_basic
  do_public
  do_ping_all
  do_mtr
  do_dd
  do_media
  do_tcp
  print_report
}

run_all_silent_report() {
  println "${FG_CYAN}ℹ️  正在后台静默执行检测（2~8+10），完成后输出最终✅总结...${RESET}"
  do_basic   >/dev/null 2>&1 || true
  do_public  >/dev/null 2>&1 || true
  do_ping_all >/dev/null 2>&1 || true
  do_mtr     >/dev/null 2>&1 || true
  do_dd      >/dev/null 2>&1 || true
  do_media   >/dev/null 2>&1 || true
  do_tcp     >/dev/null 2>&1 || true
  print_report
}

# -------- Menu --------
menu() {
  while true; do
    println
    println "${FG_PINK}===================== VPS 一键体检 菜单 =====================${RESET}"
    println "Targets: ${FG_PINK}${TARGETS[*]}${RESET}  ${FG_GRAY}(MTR 默认用第一个 Target)${RESET}"
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
    println "  10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
    println "  R) 后台静默全跑（2~8+10），只输出最终✅总结报告（不刷屏）"
    println "  0) 退出"
    hr
    read -r -p "选择 [0-10/R]: " choice

    case "$choice" in
      1)
        read -r -p "输入 Targets（空格分隔，例如：1.1.1.1 8.8.8.8 www.google.com）: " line
        if [[ -n "${line// /}" ]]; then
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
      R|r) run_all_silent_report; pause ;;
      0) exit 0 ;;
      *) println "${FG_YELLOW}⚠️  无效选择${RESET}" ;;
    esac
  done
}

menu
