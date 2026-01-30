#!/usr/bin/env bash
set -Euo pipefail

# =========================================================
# VPS 一键体检（终极修复版）
# - 进度条：彩色 █ + 灰色 ░（不再出现 '=' / '????'）
# - 修复 ANSI 残留 \033[0m
# - TCP 多源中位数：不依赖 awk asort（兼容 mawk）
# - dd 速度解析修复：不再把秒数当 MB/s
# - 媒体检测 HTTP 码修复：不再 403000；301/302 不误判不可用
# - mtr 安装提示修复：更可靠
# - 所有输出尽量中文化
# =========================================================

# ---------- Locale（尽量 UTF-8，避免乱码） ----------
if command -v locale >/dev/null 2>&1; then
  if locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-8$'; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  fi
fi

# ---------- Colors ----------
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

# 进度条颜色（前景即可）
C_GOOD="$FG_GREEN"
C_OK="$FG_CYAN"
C_WARN="$FG_YELLOW"
C_BAD="$FG_RED"

# ---------- Settings ----------
TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")
PING_COUNT=50
MTR_CYCLES=100
DD_SIZE_MB=256

TCP_RANGE_MB=16
TCP_MAXTIME=12
TCP_SOURCES=("cloudflare" "hetzner" "ovh" "cachefly")

# ---------- Runtime ----------
TMPDIR="/tmp/vps_check.$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

REDact=0
if [[ "${1:-}" == "--redact" ]]; then
  REDact=1
fi

# ---------- Helpers ----------
println() { printf "%b\n" "$*"; }
hr() { println "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2() { println "${FG_PINK}=========================================================${RESET}"; }
pause() { read -r -p "回车继续..." _; }

exists() { command -v "$1" >/dev/null 2>&1; }

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"${1:-}"; }

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

# ---------- 评分与颜色 ----------
grade_label() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "优秀"; return; fi
  if (( s >= 75 )); then printf "良好"; return; fi
  if (( s >= 60 )); then printf "一般"; return; fi
  printf "偏弱"
}

grade_color() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$C_GOOD"; return; fi
  if (( s >= 75 )); then printf "%s" "$C_OK"; return; fi
  if (( s >= 60 )); then printf "%s" "$C_WARN"; return; fi
  printf "%s" "$C_BAD"
}

# 彩色进度条：█ + ░（UTF-8 不行就退化成 # + .）
bar() {
  local score="${1:-0}"
  local width="${2:-28}"

  (( score < 0 )) && score=0
  (( score > 100 )) && score=100

  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))

  local full="█" empty="░"
  # 如果当前环境不是 UTF-8，避免出现 ????：退化成 ASCII
  if command -v locale >/dev/null 2>&1; then
    if ! (locale charmap 2>/dev/null | grep -qi 'UTF-8'); then
      full="#"; empty="."
    fi
  fi

  local col; col="$(grade_color "$score")"

  printf "%b" "${col}["
  if (( filled > 0 )); then
    printf "%s" "$(printf "%*s" "$filled" "" | tr ' ' "$full")"
  fi
  printf "%b" "${FG_GRAY}"
  if (( rest > 0 )); then
    printf "%s" "$(printf "%*s" "$rest" "" | tr ' ' "$empty")"
  fi
  printf "%b" "${col}]${RESET}"
}

# 浮点工具
f1() { awk -v x="${1:-0}" 'BEGIN{printf "%.1f", x+0}'; }
f2() { awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x+0}'; }

# 中位数（stdin 一列数字）
median_of_stdin() {
  mapfile -t arr < <(awk 'NF{print $1}' | sort -n)
  local n="${#arr[@]}"
  (( n == 0 )) && { printf ""; return 0; }
  local mid=$(( n/2 ))
  if (( n % 2 == 1 )); then
    printf "%s" "${arr[$mid]}"
  else
    local a="${arr[$((mid-1))]}"
    local b="${arr[$mid]}"
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f",(a+b)/2}'
  fi
}

# ---------- 全局缓存（用于最终总结） ----------
B_HOST=""; B_OS=""; B_KERN=""; B_VIRT=""; B_CPU=""; B_CORES=""; B_RAM=""; B_SWAP=""; B_DISK=""
P_IPV4=""; P_GEO=""; P_ASN=""; P_ISP=""

PING_WORST_LOSS="未知"; PING_WORST_AVG="未知"
PING_GOOD=0; PING_WARN=0; PING_BAD=0
PING_SCORE=0

MTR_TARGET=""; MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0; MTR_RATING_CN="未知"

DD_MBPS=""; DD_SCORE=0

MEDIA_SCORE=0
MEDIA_LINE=""

TCP_TLS_MS="未知"; TCP_TTFB_MS="未知"; TCP_DL_MBPS="未知"
TCP_OK_SAMPLES=0
TCP_BEST_SRC="未知"
TCP_SCORE=0
TCP_NOTE=""

# =========================================================
# 2) 基本信息
# =========================================================
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

  if exists df; then
    B_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')"
  else
    B_DISK="unknown"
  fi

  println "${FG_PINK}--- 基本信息 ---${RESET}"
  println "Host     : $(mask_host "$B_HOST")"
  println "系统     : $B_OS"
  println "内核     : $B_KERN"
  println "虚拟化   : $B_VIRT"
  println "CPU      : $B_CPU（${B_CORES} 核）"
  println "内存/Swap: $B_RAM / $B_SWAP"
  println "磁盘 /   : $B_DISK"
  hr
}

# =========================================================
# 3) 公网信息
# =========================================================
do_public() {
  P_IPV4="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"

  P_GEO="unknown"; P_ASN="unknown"; P_ISP="unknown"
  if [[ -n "$P_IPV4" ]]; then
    local js city region country org
    js="$(curl -fsS --max-time 6 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"
    if [[ -n "$js" ]]; then
      city="$(sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' <<<"$js" | head -n1)"
      region="$(sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' <<<"$js" | head -n1)"
      country="$(sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' <<<"$js" | head -n1)"
      org="$(sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' <<<"$js" | head -n1)"
      P_ASN="$(awk '{print $1}' <<<"$org")"
      P_ISP="$(sed -E 's/^AS[0-9]+[ ]*//' <<<"$org")"
      P_GEO="$(printf "%s, %s, %s" "${city:-unknown}" "${region:-unknown}" "${country:-unknown}")"
    fi
  fi

  println "${FG_PINK}--- 公网信息 ---${RESET}"
  println "IPv4     : $(mask_ipv4 "${P_IPV4:-unknown}")"
  println "Geo      : ${P_GEO:-unknown}"
  println "ASN      : ${P_ASN:-unknown}"
  println "ISP/Org  : ${P_ISP:-unknown}"
  hr
}

# =========================================================
# 4) Ping（所有 Targets）
# =========================================================
parse_ping() {
  local out="$1"
  local loss min avg max mdev
  loss="$(grep -Eo '[0-9.]+% packet loss' <<<"$out" | head -n1 | awk '{gsub("%","",$1);print $1}')"
  [[ -z "$loss" ]] && loss="未知"

  local rttline
  rttline="$(awk '/rtt|round-trip/ {print; exit}' <<<"$out")"
  if [[ -n "$rttline" && "$rttline" == *"="* ]]; then
    local part
    part="${rttline#*=}"
    part="${part% ms*}"
    part="$(trim "$part")"
    IFS='/' read -r min avg max mdev <<<"$part"
    min="$(trim "${min:-}")"; avg="$(trim "${avg:-}")"; max="$(trim "${max:-}")"; mdev="$(trim "${mdev:-}")"
  else
    min=""; avg=""; max=""; mdev=""
  fi

  [[ -z "$min" ]] && min="未知"
  [[ -z "$avg" ]] && avg="未知"
  [[ -z "$max" ]] && max="未知"
  [[ -z "$mdev" ]] && mdev="-"

  printf "%s|%s|%s|%s|%s" "$loss" "$min" "$avg" "$max" "$mdev"
}

ping_score_by_worst() {
  local loss="$1" avg="$2"
  if [[ "$loss" == "未知" || "$avg" == "未知" ]]; then
    echo 0; return
  fi
  local l a
  l="$(awk -v x="$loss" 'BEGIN{print x+0}')"
  a="$(awk -v x="$avg" 'BEGIN{print x+0}')"
  if awk -v l="$l" 'BEGIN{exit !(l<=1)}' && awk -v a="$a" 'BEGIN{exit !(a<80)}'; then
    echo 95; return
  fi
  if awk -v l="$l" 'BEGIN{exit !(l<=3)}' && awk -v a="$a" 'BEGIN{exit !(a<150)}'; then
    echo 80; return
  fi
  if awk -v l="$l" 'BEGIN{exit !(l<=5)}' && awk -v a="$a" 'BEGIN{exit !(a<250)}'; then
    echo 65; return
  fi
  echo 40
}

ping_one() {
  local t="$1"
  local out
  out="$(ping -c "$PING_COUNT" -q "$t" 2>/dev/null || true)"

  local parsed loss min avg max mdev
  parsed="$(parse_ping "$out")"
  IFS='|' read -r loss min avg max mdev <<<"$parsed"

  println "${FG_PURPLE}--- Ping: ${t} (${PING_COUNT} 次) ---${RESET}"
  println "丢包 : ${loss}%"
  println "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  # 单项评价（丢包）
  if [[ "$loss" != "未知" ]]; then
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}'; then
      println "${FG_GREEN}✅ 丢包：优秀（≤1%）${RESET}"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}'; then
      println "${FG_YELLOW}⚠️  丢包：一般（≤5%）${RESET}"
    else
      println "${FG_RED}❌ 丢包：偏弱（>5%）${RESET}"
    fi
  fi
  # 单项评价（延迟）
  if [[ "$avg" != "未知" ]]; then
    if awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      println "${FG_GREEN}✅ 延迟：优秀（<80ms）${RESET}"
    elif awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      println "${FG_YELLOW}⚠️  延迟：一般（<150ms）${RESET}"
    else
      println "${FG_RED}❌ 延迟：偏弱（≥150ms）${RESET}"
    fi
  fi

  # 更新 worst
  if [[ "$loss" != "未知" ]]; then
    if [[ "$PING_WORST_LOSS" == "未知" ]]; then
      PING_WORST_LOSS="$loss"
    else
      awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}' && PING_WORST_LOSS="$loss"
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if [[ "$PING_WORST_AVG" == "未知" ]]; then
      PING_WORST_AVG="$avg"
    else
      awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}' && PING_WORST_AVG="$avg"
    fi
  fi

  local s
  s="$(ping_score_by_worst "$loss" "$avg")"
  if (( s >= 90 )); then ((PING_GOOD++)); elif (( s >= 60 )); then ((PING_WARN++)); else ((PING_BAD++)); fi
  hr
}

do_ping_all() {
  PING_WORST_LOSS="未知"; PING_WORST_AVG="未知"
  PING_GOOD=0; PING_WARN=0; PING_BAD=0

  for t in "${TARGETS[@]}"; do
    ping_one "$t"
  done

  PING_SCORE="$(ping_score_by_worst "$PING_WORST_LOSS" "$PING_WORST_AVG")"
  println "${FG_CYAN}ℹ️  Ping 小结：目标数=${#TARGETS[@]} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS}% 最差平均延迟=${PING_WORST_AVG}ms${RESET}"
  hr
}

# =========================================================
# 6) 安装 mtr
# =========================================================
do_mtr_install() {
  println "${FG_CYAN}ℹ️  正在安装 mtr...${RESET}"
  if ! exists apt-get; then
    println "${FG_RED}❌ 当前系统没有 apt-get，无法自动安装${RESET}"
    hr
    return 0
  fi

  # 避免脚本因 apt 失败直接退出
  set +e
  apt-get update -y >/dev/null 2>&1
  apt-get install -y mtr-tiny >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    apt-get install -y mtr >/dev/null 2>&1
  fi
  set -e

  if exists mtr; then
    println "${FG_GREEN}✅ mtr 已可用：$(mtr --version 2>/dev/null | head -n1)${RESET}"
  else
    println "${FG_RED}❌ mtr 安装失败（可手动：apt-get install -y mtr 或 mtr-tiny）${RESET}"
  fi
  hr
}

# =========================================================
# 5) MTR（仅第一个 Target）
# =========================================================
do_mtr() {
  local t="${TARGETS[0]}"
  MTR_TARGET="$t"

  if ! exists mtr; then
    println "${FG_YELLOW}⚠️  MTR 未安装/不可用，跳过（可选 6 安装）${RESET}"
    hr
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0; MTR_RATING_CN="未知"
    return 0
  fi

  println "${FG_PURPLE}--- MTR: ${t} (${MTR_CYCLES} 轮) ---${RESET}"
  local out
  out="$(mtr -rwzbc "$MTR_CYCLES" "$t" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    println "${FG_RED}❌ MTR 执行失败（可能被限制 ICMP 或无权限）${RESET}"
    hr
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0; MTR_RATING_CN="未知"
    return 0
  fi

  printf "%s\n" "$out" | sed -n '1,20p'
  if (( $(printf "%s\n" "$out" | wc -l) > 26 )); then
    println "${FG_GRAY}...(中间省略)...${RESET}"
    printf "%s\n" "$out" | tail -n 8
  fi

  # 取最后一跳行（mtr -r 输出格式：最后 7 列是 Loss% Snt Last Avg Best Wrst StDev）
  local lastline
  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"

  local loss avg
  loss="$(awk '{print $(NF-6)}' <<<"$lastline" | tr -d '%' )"
  avg="$(awk '{print $(NF-4)}' <<<"$lastline")"

  # 解析失败就不要乱显示 -% / 100ms
  if [[ -z "$loss" || -z "$avg" ]]; then
    MTR_LAST_LOSS="未知"
    MTR_LAST_AVG="未知"
    MTR_SCORE=0
    MTR_RATING_CN="未知"
    println "${FG_YELLOW}⚠️  终点数据解析失败：可能被 ICMP 限速/输出格式差异${RESET}"
    hr
    return 0
  fi

  MTR_LAST_LOSS="$(f1 "$loss")"
  MTR_LAST_AVG="$(f1 "$avg")"

  local s
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
  MTR_RATING_CN="$(grade_label "$s")"

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

# =========================================================
# 7) dd 测速
# =========================================================
do_dd() {
  println "${FG_PURPLE}--- 磁盘快速测试（dd 写入 ${DD_SIZE_MB}MB 到 /tmp）---${RESET}"
  local out
  out="$(LANG=C dd if=/dev/zero of="$TMPDIR/dd_test" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1)"
  rm -f "$TMPDIR/dd_test" >/dev/null 2>&1 || true

  # 从 dd 输出里直接抓最后一个 “数字 + 单位/s”
  # 兼容：724 MB/s、1.6 GB/s、741 kB/s、MiB/s 等
  local speed unit
  speed="$(grep -Eo '[0-9.]+[[:space:]]*(kB|KB|MB|GB|KiB|MiB|GiB)/s' <<<"$out" | tail -n1 | awk '{print $1}')"
  unit="$(grep -Eo '[0-9.]+[[:space:]]*(kB|KB|MB|GB|KiB|MiB|GiB)/s' <<<"$out" | tail -n1 | awk '{print $2}')"

  if [[ -z "$speed" || -z "$unit" ]]; then
    DD_MBPS="未知"
    DD_SCORE=0
    println "${FG_RED}❌ dd 测试失败（无法解析速度）${RESET}"
    hr
    return 0
  fi

  # 转成 MB/s（十进制近似，足够用于评级）
  local mbps
  case "$unit" in
    GB/s|GiB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x*1024}')" ;;
    MB/s|MiB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x}')" ;;
    kB/s|KB/s|KiB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x/1024}')" ;;
    *) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x}')" ;;
  esac
  DD_MBPS="$mbps"

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

# =========================================================
# 8) 流媒体检测（best-effort）
# =========================================================
curl_code() {
  local url="$1"
  curl -fsS -o /dev/null -L --max-time 10 -w '%{http_code}' "$url" 2>/dev/null || echo "000"
}

media_line_item() {
  local name="$1" code="$2"
  # 规则：
  # 200/204：可访问
  # 301/302/307/308：可访问（跳转）
  # 403/451：可能受限/风控
  # 000：失败/超时
  if [[ "$code" == "200" || "$code" == "204" ]]; then
    echo "${name}=可访问"
    return
  fi
  if [[ "$code" =~ ^30[1278]$ ]]; then
    echo "${name}=可访问(跳转)"
    return
  fi
  if [[ "$code" == "403" || "$code" == "451" ]]; then
    echo "${name}=可能受限"
    return
  fi
  echo "${name}=不可用"
}

do_media() {
  println "${FG_PURPLE}--- 流媒体解锁检测（best-effort）---${RESET}"

  local y n d t p m a
  # YouTube（用 countryCode）
  y="$(curl -fsS --max-time 10 'https://www.youtube.com/premium' -H 'Accept-Language: en' 2>/dev/null \
      | tr -d '\n' | sed -n 's/.*countryCode":"\([A-Z]\{2\}\)".*/\1/p' | head -n1)"
  local ycode
  ycode="$(curl_code "https://www.youtube.com")"

  if [[ "$ycode" == "200" || "$ycode" =~ ^30 ]]; then
    if [[ -n "$y" ]]; then
      println "${FG_GREEN}✅ YouTube: 可访问（识别地区 ${y}）${RESET}"
    else
      println "${FG_GREEN}✅ YouTube: 可访问${RESET}"
    fi
  else
    println "${FG_RED}❌ YouTube: 不可用（HTTP ${ycode}）${RESET}"
  fi

  # 动画疯（通常 403 代表被风控/CF）
  a="$(curl_code "https://ani.gamer.com.tw/")"
  if [[ "$a" == "200" || "$a" =~ ^30 ]]; then
    println "${FG_GREEN}✅ 动画疯: 可访问${RESET}"
  elif [[ "$a" == "403" ]]; then
    println "${FG_YELLOW}⚠️  动画疯: 可能被风控/CF 拦截（HTTP 403）${RESET}"
  else
    println "${FG_RED}❌ 动画疯: 不可用（HTTP ${a}）${RESET}"
  fi

  n="$(curl_code "https://www.netflix.com/title/80018499")"
  d="$(curl_code "https://www.disneyplus.com/")"
  t="$(curl_code "https://www.tiktok.com/")"
  p="$(curl_code "https://www.primevideo.com/")"
  m="$(curl_code "https://play.max.com/")"

  # 组装一行给总结用（中文）
  MEDIA_LINE="$(media_line_item "YouTube" "$ycode")"
  MEDIA_LINE+=" | $(media_line_item "动画疯" "$a")"
  MEDIA_LINE+=" | $(media_line_item "Netflix" "$n")"
  MEDIA_LINE+=" | $(media_line_item "Disney+" "$d")"
  MEDIA_LINE+=" | $(media_line_item "TikTok" "$t")"
  MEDIA_LINE+=" | $(media_line_item "Prime" "$p")"
  MEDIA_LINE+=" | $(media_line_item "Max" "$m")"

  # 评分（简化但稳定）
  MEDIA_SCORE=0
  [[ "$ycode" == "200" || "$ycode" =~ ^30 ]] && ((MEDIA_SCORE+=15))
  [[ "$a" == "200" || "$a" =~ ^30 ]] && ((MEDIA_SCORE+=10))
  [[ "$a" == "403" ]] && ((MEDIA_SCORE+=6))
  [[ "$n" == "200" || "$n" =~ ^30 ]] && ((MEDIA_SCORE+=20))
  [[ "$d" == "200" || "$d" =~ ^30 ]] && ((MEDIA_SCORE+=15))
  [[ "$t" == "200" || "$t" =~ ^30 ]] && ((MEDIA_SCORE+=10))
  [[ "$p" == "200" || "$p" =~ ^30 ]] && ((MEDIA_SCORE+=10))
  [[ "$m" == "200" || "$m" =~ ^30 ]] && ((MEDIA_SCORE+=10))

  # 压到 0~100
  ((MEDIA_SCORE>100)) && MEDIA_SCORE=100

  println
  println "${FG_CYAN}ℹ️  提示：Netflix/Disney+/Max/Prime 只能判断“可访问/疑似受限”，最终以登录播放为准。${RESET}"
  println "${FG_CYAN}ℹ️  TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。${RESET}"
  hr
}

# =========================================================
# 10) TCP 真实链路测试（多源取中位数）
# =========================================================
tcp_url_of() {
  local src="$1"
  case "$src" in
    cloudflare) echo "https://speed.cloudflare.com/__down?bytes=$((TCP_RANGE_MB*1024*1024))" ;;
    hetzner)    echo "https://speed.hetzner.de/100MB.bin" ;;
    ovh)        echo "https://proof.ovh.net/files/100Mb.dat" ;;
    cachefly)   echo "https://cachefly.cachefly.net/100mb.test" ;;
    *)          echo "" ;;
  esac
}

tcp_test_one() {
  local src="$1"
  local url; url="$(tcp_url_of "$src")"
  [[ -z "$url" ]] && echo "FAIL" && return

  local range_bytes=$((TCP_RANGE_MB*1024*1024))
  local end=$((range_bytes-1))

  # 输出：appconnect starttransfer speed_download http_code
  # speed_download: bytes/sec
  local line
  line="$(curl -fsS -L --max-time "$TCP_MAXTIME" -r "0-${end}" -o /dev/null \
    -w '%{time_appconnect} %{time_starttransfer} %{speed_download} %{http_code}\n' \
    "$url" 2>/dev/null || true)"

  local tls ttfb spd code
  tls="$(awk '{print $1}' <<<"$line")"
  ttfb="$(awk '{print $2}' <<<"$line")"
  spd="$(awk '{print $3}' <<<"$line")"
  code="$(awk '{print $4}' <<<"$line")"

  # code 000 或空 => 失败
  if [[ -z "$code" || "$code" == "000" ]]; then
    echo "FAIL"
    return
  fi
  # tls/ttfb 有时会是 0（被缓存/复用连接），仍认为可用
  [[ -z "$tls" ]] && tls="0"
  [[ -z "$ttfb" ]] && ttfb="0"
  [[ -z "$spd" ]] && spd="0"

  # 转换：ms / Mbps
  local tls_ms ttfb_ms mbps
  tls_ms="$(awk -v x="$tls" 'BEGIN{printf "%.1f", x*1000}')"
  ttfb_ms="$(awk -v x="$ttfb" 'BEGIN{printf "%.1f", x*1000}')"
  mbps="$(awk -v b="$spd" 'BEGIN{printf "%.2f", (b*8)/1000000}')"

  echo "${tls_ms}|${ttfb_ms}|${mbps}|${code}"
}

tcp_score() {
  local tls="$1" ttfb="$2" dl="$3"
  # 简单稳定的打分：下载是核心，其次 ttfb、tls
  # dl: Mbps
  # tls/ttfb: ms
  if [[ "$dl" == "未知" || -z "$dl" ]]; then echo 0; return; fi
  local d t1 t2
  d="$(awk -v x="$dl" 'BEGIN{print x+0}')"
  t1="$(awk -v x="$tls" 'BEGIN{print x+0}')"
  t2="$(awk -v x="$ttfb" 'BEGIN{print x+0}')"

  local s=0
  # dl
  if awk -v d="$d" 'BEGIN{exit !(d>=200)}'; then s=$((s+55))
  elif awk -v d="$d" 'BEGIN{exit !(d>=50)}'; then s=$((s+45))
  elif awk -v d="$d" 'BEGIN{exit !(d>=10)}'; then s=$((s+35))
  elif awk -v d="$d" 'BEGIN{exit !(d>=3)}'; then s=$((s+25))
  else s=$((s+15)); fi
  # tls
  if awk -v t="$t1" 'BEGIN{exit !(t<=80)}'; then s=$((s+20))
  elif awk -v t="$t1" 'BEGIN{exit !(t<=200)}'; then s=$((s+15))
  elif awk -v t="$t1" 'BEGIN{exit !(t<=500)}'; then s=$((s+10))
  else s=$((s+5)); fi
  # ttfb
  if awk -v t="$t2" 'BEGIN{exit !(t<=200)}'; then s=$((s+25))
  elif awk -v t="$t2" 'BEGIN{exit !(t<=600)}'; then s=$((s+18))
  elif awk -v t="$t2" 'BEGIN{exit !(t<=1200)}'; then s=$((s+10))
  else s=$((s+5)); fi

  ((s>100)) && s=100
  echo "$s"
}

do_tcp() {
  println "${FG_PURPLE}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${RESET}"
  println "${FG_CYAN}ℹ️  范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速（能测几个算几个）${RESET}"

  local tls_list="$TMPDIR/tls.list"
  local ttfb_list="$TMPDIR/ttfb.list"
  local dl_list="$TMPDIR/dl.list"
  : >"$tls_list"; : >"$ttfb_list"; : >"$dl_list"

  TCP_OK_SAMPLES=0
  TCP_BEST_SRC="未知"
  local best_dl=0

  for src in "${TCP_SOURCES[@]}"; do
    local r
    r="$(tcp_test_one "$src")"
    if [[ "$r" == "FAIL" ]]; then
      println "• ${FG_GRAY}${src}: 失败/超时（跳过）${RESET}"
      continue
    fi

    local tls ttfb dl code
    IFS='|' read -r tls ttfb dl code <<<"$r"

    # 记录成功
    ((TCP_OK_SAMPLES++))
    printf "%s\n" "$tls" >>"$tls_list"
    printf "%s\n" "$ttfb" >>"$ttfb_list"
    printf "%s\n" "$dl" >>"$dl_list"

    # best
    if awk -v a="$dl" -v b="$best_dl" 'BEGIN{exit !(a>b)}'; then
      best_dl="$dl"
      TCP_BEST_SRC="$src"
    fi

    local c="$FG_GREEN"
    # code 非 2xx/3xx 也提示一下
    if [[ ! "$code" =~ ^2|^3 ]]; then c="$FG_YELLOW"; fi
    println "• ${c}${src}:${RESET} TLS=${tls}ms  TTFB=${ttfb}ms  下载=${dl}Mbps  code=${code}"
  done

  if (( TCP_OK_SAMPLES == 0 )); then
    TCP_TLS_MS="未知"; TCP_TTFB_MS="未知"; TCP_DL_MBPS="未知"
    TCP_SCORE=0
    TCP_NOTE="无可用样本（可能被限速/风控/超时）"
    println "${FG_RED}❌ TCP：无可用样本（建议换时间再测）${RESET}"
    hr
    return 0
  fi

  local mtls mttfb mdl
  mtls="$(median_of_stdin <"$tls_list")"
  mttfb="$(median_of_stdin <"$ttfb_list")"
  mdl="$(median_of_stdin <"$dl_list")"

  # 如果 median 没算出来（极端情况），用第一个值兜底
  [[ -z "$mtls" ]] && mtls="$(head -n1 "$tls_list" 2>/dev/null || echo "")"
  [[ -z "$mttfb" ]] && mttfb="$(head -n1 "$ttfb_list" 2>/dev/null || echo "")"
  [[ -z "$mdl" ]] && mdl="$(head -n1 "$dl_list" 2>/dev/null || echo "")"

  [[ -z "$mtls" ]] && mtls="未知"
  [[ -z "$mttfb" ]] && mttfb="未知"
  [[ -z "$mdl" ]] && mdl="未知"

  TCP_TLS_MS="$mtls"
  TCP_TTFB_MS="$mttfb"
  TCP_DL_MBPS="$mdl"

  TCP_SCORE="$(tcp_score "$TCP_TLS_MS" "$TCP_TTFB_MS" "$TCP_DL_MBPS")"
  local label; label="$(grade_label "$TCP_SCORE")"
  local col; col="$(grade_color "$TCP_SCORE")"

  if (( TCP_OK_SAMPLES < 2 )); then
    TCP_NOTE="有效样本不足（可能被限速/风控/超时），建议换时间多测几次"
    println "${FG_YELLOW}⚠️  TCP：有效样本不足（建议换时间多测几次）${RESET}"
  fi

  println
  println "${FG_GRAY}中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳源=${TCP_BEST_SRC} ${best_dl}Mbps）${RESET}"
  println "${col}✅ TCP 体验：${label}${RESET}"
  hr
}

# =========================================================
# 总结报告（2~8+10 的汇总）
# =========================================================
calc_network_score() {
  # network = ping(60%) + mtr(40%)；没有 mtr 就只用 ping
  if [[ "$MTR_LAST_LOSS" == "未知" || "$MTR_LAST_AVG" == "未知" || "$MTR_SCORE" -le 0 ]]; then
    echo "$PING_SCORE"
  else
    awk -v p="$PING_SCORE" -v m="$MTR_SCORE" 'BEGIN{printf "%d", (p*0.6 + m*0.4)+0.5}'
  fi
}

calc_total_score() {
  # 总评权重：网络 35% + TCP 25% + 磁盘 15% + 流媒体 25%
  local net="$1" tcp="$2" dd="$3" media="$4"
  awk -v n="$net" -v t="$tcp" -v d="$dd" -v m="$media" \
    'BEGIN{printf "%d", (n*0.35 + t*0.25 + d*0.15 + m*0.25)+0.5}'
}

summary_report() {
  local net_score total
  net_score="$(calc_network_score)"
  total="$(calc_total_score "$net_score" "$TCP_SCORE" "$DD_SCORE" "$MEDIA_SCORE")"

  local net_label tcp_label dd_label media_label total_label
  net_label="$(grade_label "$net_score")"
  tcp_label="$(grade_label "$TCP_SCORE")"
  dd_label="$(grade_label "$DD_SCORE")"
  media_label="$(grade_label "$MEDIA_SCORE")"
  total_label="$(grade_label "$total")"

  println
  hr2
  println "${FG_PINK}====================== ✅ VPS 体检总结报告 ======================${RESET}"
  println "${FG_PINK}[基础信息]${RESET}"
  println "Host : $(mask_host "$B_HOST")"
  println "OS   : $B_OS"
  println "Kern : $B_KERN | Virt=$B_VIRT"
  println "CPU  : $B_CPU | 核数=$B_CORES | 内存=$B_RAM | Swap=$B_SWAP"
  println "Disk : / $B_DISK"
  println "IPv4 : $(mask_ipv4 "${P_IPV4:-unknown}")"
  println "Geo  : ${P_GEO:-unknown}"
  println "ASN  : ${P_ASN:-unknown}"
  println "ISP  : ${P_ISP:-unknown}"
  hr

  println "${FG_PINK}[网络]${RESET}  ${net_score}/100 (${grade_color "$net_score")}${net_label}${RESET})  $(bar "$net_score")"
  println "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS}% | 最差平均延迟=${PING_WORST_AVG}ms"
  if [[ "$MTR_LAST_LOSS" == "未知" || "$MTR_LAST_AVG" == "未知" ]]; then
    println "MTR  : 未安装/不可用 或 解析失败（建议先选 6 安装 mtr）"
  else
    println "MTR  : 目标=${MTR_TARGET:-${TARGETS[0]}} | 终点丢包=${MTR_LAST_LOSS}% | 终点平均=${MTR_LAST_AVG}ms | 评级=${MTR_RATING_CN}"
  fi
  hr

  println "${FG_PINK}[TCP真实链路]${RESET}  ${TCP_SCORE}/100 (${grade_color "$TCP_SCORE")}${tcp_label}${RESET})  $(bar "$TCP_SCORE")"
  println "TLS  : ${TCP_TLS_MS} ms | TTFB=${TCP_TTFB_MS} ms"
  println "下载 : ${TCP_DL_MBPS} Mbps（中位数，range=${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
  println "样本 : ${TCP_OK_SAMPLES} 个 | 最佳源=${TCP_BEST_SRC}"
  [[ -n "${TCP_NOTE:-}" ]] && println "${FG_YELLOW}⚠️  说明：${TCP_NOTE}${RESET}"
  hr

  println "${FG_PINK}[磁盘]${RESET}  ${DD_SCORE}/100 (${grade_color "$DD_SCORE")}${dd_label}${RESET})  $(bar "$DD_SCORE")"
  if [[ -n "${DD_MBPS:-}" && "$DD_MBPS" != "未知" ]]; then
    println "dd   : 约 ${DD_MBPS} MB/s"
  else
    println "dd   : 未知（解析失败）"
  fi
  hr

  println "${FG_PINK}[流媒体]${RESET}  ${MEDIA_SCORE}/100 (${grade_color "$MEDIA_SCORE")}${media_label}${RESET})  $(bar "$MEDIA_SCORE")"
  println "${MEDIA_LINE:-（未检测）}"
  hr

  println "${FG_PINK}[总评]${RESET}  ${total}/100 (${grade_color "$total")}${total_label}${RESET})  $(bar "$total")"
  if (( total >= 90 )); then
    println "${FG_GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${RESET}"
  elif (( total >= 75 )); then
    println "${FG_CYAN}✅ 结论：整体不错，日常中转/落地够用。${RESET}"
  elif (( total >= 60 )); then
    println "${FG_YELLOW}⚠️  结论：整体一般，建议多测不同时段，必要时换机房/线路。${RESET}"
  else
    println "${FG_RED}❌ 结论：整体偏弱，建议换机房/线路或降低用途预期。${RESET}"
  fi

  println
  println "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${RESET}"
  println "${FG_PINK}================================================================${RESET}"
}

# =========================================================
# 菜单与“一键全跑”
# =========================================================
set_targets() {
  println "${FG_CYAN}当前 Targets：${FG_WHITE}${TARGETS[*]}${RESET}"
  read -r -p "请输入新的 Targets（空格分隔，例如：1.1.1.1 8.8.8.8 www.google.com）: " line
  line="$(trim "$line")"
  if [[ -n "$line" ]]; then
    read -r -a TARGETS <<<"$line"
  fi
  println "${FG_GREEN}✅ 已设置 Targets：${TARGETS[*]}${RESET}"
  hr
}

run_all_verbose() {
  do_basic
  do_public
  do_ping_all
  do_mtr
  do_dd
  do_media
  do_tcp
  summary_report
}

run_all_silent() {
  println "${FG_CYAN}ℹ️  正在后台静默执行检测（2~8+10），完成后输出最终✅总结...${RESET}"
  {
    do_basic
    do_public
    do_ping_all
    do_mtr
    do_dd
    do_media
    do_tcp
  } >/dev/null 2>&1 || true
  summary_report
}

menu() {
  while true; do
    println
    println "${FG_PINK}====================== VPS 一键体检 菜单 ======================${RESET}"
    println "Targets: ${FG_WHITE}${TARGETS[*]}${RESET}  ${FG_GRAY}(MTR 默认用第一个 Target)${RESET}"
    println
    println "  1) 设置测试目标（Targets）"
    println "  2) 基本信息（系统/CPU/RAM/磁盘占用/虚拟化）"
    println "  3) 公网信息（IPv4 / Geo / ASN / ISP）"
    println "  4) 网络 Ping 测试（所有 Targets）"
    println "  5) 路由 MTR 测试（仅第一个 Target）"
    println "  6) 安装 mtr（Debian/Ubuntu）"
    println "  7) 磁盘 dd 测速（输出速度）"
    println "  8) 流媒体检测（YouTube/动画疯/Netflix/Disney+/TikTok/Prime/Max）"
    println "  9) 一键全跑（2~8+10）并输出最终总结（会显示全过程）"
    println "  10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
    println "  R) 后台静默全跑（2~8+10），只输出最终✅总结报告（不刷屏）"
    println "  0) 退出"
    hr
    read -r -p "选择 [0-10/R]: " ch
    ch="$(trim "$ch")"

    case "$ch" in
      1) set_targets ;;
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
      *) println "${FG_YELLOW}⚠️  无效选择${RESET}" ;;
    esac
  done
}

# =========================================================
# main
# =========================================================
menu
