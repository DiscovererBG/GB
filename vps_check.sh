#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# VPS 一键体检（最终修复版）
# - 强制 bash 运行，避免 sh/dash 导致 bad substitution
# - 进度条：彩色块 + 灰点（ASCII '.'，不再出现 ????）
# - 修复 ANSI 残留 \033[0m 被打印
# - TCP 多源中位数：不依赖 awk asort（兼容 mawk）
# - dd 速度解析：从末行提取 "x.xx GB/s" / "x.xx MB/s"（不再误判）
# - 流媒体 HTTP code：只取最终码（不再 403000），301/302 视为可访问
# - IP 国家自动识别：ISO code -> 中文国家名
# ==========================================================

# -------- 强制 bash（避免 /bin/sh 执行）--------
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "❌ 请用 bash 运行：bash vps_check.sh"
  exit 1
fi

# -------- Locale（尽量避免乱码）--------
if command -v locale >/dev/null 2>&1; then
  if locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-8$'; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  else
    export LANG=C LC_ALL=C
  fi
fi

# -------- Colors --------
ESC=$'\033'
RESET="${ESC}[0m"
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

# -------- Runtime --------
TMPDIR="/tmp/vps_check.$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

REDACT=0
if [[ "${1:-}" == "--redact" ]]; then
  REDACT=1
fi

# -------- Helpers --------
println() { printf "%b\n" "$*"; }
hr()      { println "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2()     { println "${FG_PINK}=========================================================${RESET}"; }
pause()   { read -r -p "回车继续..." _; }
exists()  { command -v "$1" >/dev/null 2>&1; }

mask_ipv4() {
  local ip="${1:-}"
  [[ "$REDACT" -eq 0 ]] && { printf "%s" "$ip"; return; }
  printf "%s" "$ip" | awk -F. 'NF==4{print $1"."$2".*.*"; next}{print "*.*.*.*"}'
}
mask_host() {
  local h="${1:-}"
  [[ "$REDACT" -eq 0 ]] && { printf "%s" "$h"; return; }
  [[ -z "$h" ]] && { printf "unknown"; return; }
  printf "%s" "$h" | sed -E 's/^(.).*(.)$/\1***\2/'
}

country_cn() {
  # 常见国家代码 -> 中文（可按需继续补）
  local c="${1:-}"
  case "$c" in
    SG) echo "新加坡" ;;
    HK) echo "中国香港" ;;
    TW) echo "中国台湾" ;;
    JP) echo "日本" ;;
    KR) echo "韩国" ;;
    US) echo "美国" ;;
    GB) echo "英国" ;;
    DE) echo "德国" ;;
    FR) echo "法国" ;;
    NL) echo "荷兰" ;;
    CA) echo "加拿大" ;;
    AU) echo "澳大利亚" ;;
    IN) echo "印度" ;;
    ID) echo "印度尼西亚" ;;
    MY) echo "马来西亚" ;;
    TH) echo "泰国" ;;
    VN) echo "越南" ;;
    PH) echo "菲律宾" ;;
    TR) echo "土耳其" ;;
    RU) echo "俄罗斯" ;;
    UA) echo "乌克兰" ;;
    BR) echo "巴西" ;;
    MX) echo "墨西哥" ;;
    AR) echo "阿根廷" ;;
    IT) echo "意大利" ;;
    ES) echo "西班牙" ;;
    SE) echo "瑞典" ;;
    NO) echo "挪威" ;;
    FI) echo "芬兰" ;;
    DK) echo "丹麦" ;;
    CH) echo "瑞士" ;;
    AT) echo "奥地利" ;;
    PL) echo "波兰" ;;
    CZ) echo "捷克" ;;
    PT) echo "葡萄牙" ;;
    IE) echo "爱尔兰" ;;
    *)  echo "$c" ;;
  esac
}

grade_label() {
  local s="${1:-0}"
  if (( s >= 90 )); then echo "优秀"; return; fi
  if (( s >= 75 )); then echo "良好"; return; fi
  if (( s >= 60 )); then echo "一般"; return; fi
  echo "偏弱"
}
grade_fg() {
  local s="${1:-0}"
  if (( s >= 90 )); then echo "$FG_GREEN"; return; fi
  if (( s >= 75 )); then echo "$FG_CYAN"; return; fi
  if (( s >= 60 )); then echo "$FG_YELLOW"; return; fi
  echo "$FG_RED"
}
grade_bg() {
  local s="${1:-0}"
  if (( s >= 90 )); then echo "$BG_GREEN"; return; fi
  if (( s >= 75 )); then echo "$BG_CYAN"; return; fi
  if (( s >= 60 )); then echo "$BG_YELLOW"; return; fi
  echo "$BG_RED"
}
grade_text_colored() {
  local s="${1:-0}"
  local fg; fg="$(grade_fg "$s")"
  printf "%b%s%b" "$fg" "$(grade_label "$s")" "$RESET"
}

# 你要的进度条：彩色块 + 灰点（不再 '='；灰点用 '.'，不会变 ????）
bar() {
  local score="${1:-0}"
  local width="${2:-28}"
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100
  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))

  local fg bg
  fg="$(grade_fg "$score")"
  bg="$(grade_bg "$score")"

  printf "%b" "${fg}[${RESET}"
  printf "%b" "$bg"
  printf "%*s" "$filled" ""
  printf "%b" "$RESET"

  printf "%b" "${FG_GRAY}${DIM}"
  if (( rest > 0 )); then
    printf "%*s" "$rest" "" | tr ' ' '.'
  fi
  printf "%b" "${RESET}${fg}]${RESET}"
}

# median：stdin numbers
median_of_list() {
  local -a arr
  mapfile -t arr < <(awk 'NF{print $1}' | sort -n)
  local n="${#arr[@]}"
  (( n == 0 )) && { printf ""; return; }
  local mid=$(( n/2 ))
  if (( n % 2 == 1 )); then
    printf "%s" "${arr[$mid]}"
  else
    awk -v a="${arr[$((mid-1))]}" -v b="${arr[$mid]}" 'BEGIN{printf "%.2f",(a+b)/2}'
  fi
}

# -------- Global results cache --------
B_HOST="unknown"; B_OS="unknown"; B_KERN=""; B_VIRT="unknown"; B_CPU="unknown"; B_CORES="1"; B_RAM="unknown"; B_SWAP="unknown"; B_DISK="unknown"
P_IPV4=""; P_CITY=""; P_REGION=""; P_COUNTRY=""; P_COUNTRY_CN=""; P_ASN="unknown"; P_ISP="unknown"; P_GEO="unknown"
PING_GOOD=0; PING_WARN=0; PING_BAD=0; PING_WORST_LOSS=""; PING_WORST_AVG=""; PING_SCORE=0
MTR_TARGET=""; MTR_LAST_LOSS=""; MTR_LAST_AVG=""; MTR_SCORE=0; MTR_STATUS="未测"
DD_MBPS=""; DD_SCORE=0
MEDIA_SCORE=0; MEDIA_LINE=""
TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""; TCP_OK_SAMPLES=0; TCP_BEST_SRC=""; TCP_SCORE=0; TCP_NOTE=""

# -------- Basic info --------
do_basic() {
  B_HOST="$(hostname 2>/dev/null || echo "unknown")"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    B_OS="${PRETTY_NAME:-Linux}"
  else
    B_OS="Linux"
  fi
  B_KERN="$(uname -r 2>/dev/null || true)"

  if exists systemd-detect-virt; then
    B_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "$B_VIRT" ]] && B_VIRT="none"
  fi

  B_CPU="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "unknown")"
  B_CORES="$(nproc 2>/dev/null || echo "1")"

  if exists free; then
    B_RAM="$(free -m | awk '/Mem:/ {print $2 " MB"}' 2>/dev/null || echo "unknown")"
    B_SWAP="$(free -m | awk '/Swap:/ {print $2 " MB"}' 2>/dev/null || echo "unknown")"
  fi

  if exists df; then
    B_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}' || echo "unknown")"
  fi

  println "${FG_PINK}--- 基本信息 ---${RESET}"
  println "Host     : $(mask_host "$B_HOST")"
  println "系统     : $B_OS"
  println "内核     : ${B_KERN:-未知}"
  println "运行时长 : $(uptime -p 2>/dev/null | sed 's/^up //' || echo "未知")"
  println "虚拟化   : ${B_VIRT:-未知}"
  println "CPU      : $B_CPU（${B_CORES} 核）"
  println "内存/Swap: $B_RAM / $B_SWAP"
  println "磁盘 /   : $B_DISK"
  hr
}

# -------- Public IP / Geo / ASN / ISP --------
do_public() {
  P_IPV4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="unknown"

  P_CITY=""; P_REGION=""; P_COUNTRY=""; P_COUNTRY_CN=""; P_ASN="unknown"; P_ISP="unknown"; P_GEO="unknown"

  if [[ "$P_IPV4" != "unknown" ]]; then
    local js
    js="$(curl -fsS --max-time 6 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"
    if [[ -n "$js" ]]; then
      P_CITY="$(printf "%s" "$js" | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      P_REGION="$(printf "%s" "$js" | sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      P_COUNTRY="$(printf "%s" "$js" | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      local org
      org="$(printf "%s" "$js" | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      if [[ -n "$org" ]]; then
        P_ASN="$(printf "%s" "$org" | awk '{print $1}')"
        P_ISP="$(printf "%s" "$org" | sed -E 's/^AS[0-9]+[ ]*//')"
      fi
      [[ -n "$P_COUNTRY" ]] && P_COUNTRY_CN="$(country_cn "$P_COUNTRY")"
      if [[ -n "$P_COUNTRY_CN" && -n "$P_CITY" && -n "$P_REGION" ]]; then
        P_GEO="${P_COUNTRY_CN}（${P_CITY}, ${P_REGION}）"
      elif [[ -n "$P_COUNTRY_CN" ]]; then
        P_GEO="${P_COUNTRY_CN}（${P_COUNTRY}）"
      else
        P_GEO="unknown"
      fi
    fi
  fi

  println "${FG_PINK}--- 公网信息 ---${RESET}"
  println "IPv4     : $(mask_ipv4 "$P_IPV4")"
  println "地区     : ${P_GEO:-unknown}"
  println "ASN      : ${P_ASN:-unknown}"
  println "运营商   : ${P_ISP:-unknown}"
  hr
}

# -------- Ping --------
ping_one() {
  local t="$1"
  if ! exists ping; then
    println "${FG_RED}❌ 系统缺少 ping（iputils-ping），跳过${RESET}"
    return 0
  fi

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
  [[ -z "$mdev" ]] && mdev="0.000"

  println "${FG_PURPLE}--- Ping: ${t}（${PING_COUNT} 次）---${RESET}"
  println "丢包 : ${loss}%"
  println "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  # grade
  local s=0
  if [[ "$loss" == "未知" || "$avg" == "未知" ]]; then
    s=0
  else
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
    if [[ -z "$PING_WORST_LOSS" ]] || awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}'; then
      PING_WORST_LOSS="$loss"
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if [[ -z "$PING_WORST_AVG" ]] || awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}'; then
      PING_WORST_AVG="$avg"
    fi
  fi

  if (( s >= 90 )); then ((PING_GOOD++)); elif (( s >= 60 )); then ((PING_WARN++)); else ((PING_BAD++)); fi
  hr
}

do_ping_all() {
  PING_GOOD=0; PING_WARN=0; PING_BAD=0; PING_WORST_LOSS=""; PING_WORST_AVG=""
  for t in "${TARGETS[@]}"; do
    ping_one "$t"
  done

  # ping_score（用于总评网络）
  if [[ -n "${PING_WORST_LOSS:-}" && -n "${PING_WORST_AVG:-}" ]]; then
    local loss="$PING_WORST_LOSS" avg="$PING_WORST_AVG"
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}' && awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      PING_SCORE=95
    elif awk -v l="$loss" 'BEGIN{exit !(l<=3)}' && awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      PING_SCORE=80
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}' && awk -v a="$avg" 'BEGIN{exit !(a<250)}'; then
      PING_SCORE=65
    else
      PING_SCORE=40
    fi
  else
    PING_SCORE=0
  fi

  println "${FG_CYAN}ℹ️  Ping 小结：目标数=${#TARGETS[@]} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% 最差平均延迟=${PING_WORST_AVG:-未知}ms${RESET}"
  hr
}

# -------- MTR install & test --------
do_mtr_install() {
  println "${FG_CYAN}ℹ️  正在安装 mtr...${RESET}"
  if ! exists apt-get; then
    println "${FG_RED}❌ 当前系统无 apt-get，无法自动安装 mtr${RESET}"
    hr
    return 0
  fi

  local log="$TMPDIR/mtr_install.log"
  : >"$log"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$log" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y mtr-tiny >>"$log" 2>&1 || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y mtr >>"$log" 2>&1 || true

  if exists mtr; then
    println "${FG_GREEN}✅ mtr 已可用：$(mtr --version 2>/dev/null | head -n1)${RESET}"
  else
    println "${FG_RED}❌ mtr 安装失败（你可手动：apt-get install -y mtr-tiny）${RESET}"
    println "${FG_GRAY}安装日志（末尾 20 行）：${RESET}"
    tail -n 20 "$log" | sed 's/\r$//'
  fi
  hr
}

do_mtr() {
  local t="${TARGETS[0]}"
  MTR_TARGET="$t"

  if ! exists mtr; then
    println "${FG_YELLOW}⚠️  MTR 未安装/不可用，跳过（可先选 6 安装）${RESET}"
    MTR_STATUS="未测"
    hr
    return 0
  fi

  println "${FG_PURPLE}--- MTR: ${t}（${MTR_CYCLES} 轮）---${RESET}"
  local out
  out="$(mtr -rwzbc "$MTR_CYCLES" "$t" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    println "${FG_RED}❌ MTR 执行失败（可能 ICMP 被限制）${RESET}"
    MTR_STATUS="失败"
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    hr
    return 0
  fi

  # 直接输出（避免重复 HOST 头）
  printf "%s\n" "$out"
  MTR_STATUS="已测"

  # 取最后一跳（目的地）
  local lastline loss avg
  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"
  loss="$(printf "%s\n" "$lastline" | awk '{print $(NF-6)}' | tr -d '%' )"
  avg="$(printf "%s\n" "$lastline" | awk '{print $(NF-4)}')"

  if [[ -z "$loss" || -z "$avg" ]]; then
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    println "${FG_YELLOW}⚠️  终点数据解析失败：可能格式差异/被限速${RESET}"
    hr
    return 0
  fi

  MTR_LAST_LOSS="$(awk -v x="$loss" 'BEGIN{printf "%.1f",x+0}')"
  MTR_LAST_AVG="$(awk -v x="$avg"  'BEGIN{printf "%.1f",x+0}')"

  # score
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
  if ! exists dd; then
    println "${FG_RED}❌ 系统缺少 dd，跳过${RESET}"
    DD_MBPS=""; DD_SCORE=0
    hr
    return 0
  fi

  println "${FG_PURPLE}--- 磁盘快速测试（dd 写入 ${DD_SIZE_MB}MB 到 /tmp）---${RESET}"
  local out last line speed unit mbps
  out="$(LANG=C dd if=/dev/zero of="$TMPDIR/dd_test" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1 || true)"
  rm -f "$TMPDIR/dd_test" >/dev/null 2>&1 || true

  # 取末行，并移除逗号
  last="$(printf "%s\n" "$out" | tail -n 1 | sed 's/,//g')"
  # 在末行里找：数值 + 单位(B/s)
  speed="$(printf "%s\n" "$last" | awk '{
    for(i=1;i<=NF;i++){
      if($i ~ /^[0-9.]+$/ && $(i+1) ~ /B\/s$/){v=$i; u=$(i+1)}
    }
  } END{print v}')"
  unit="$(printf "%s\n" "$last" | awk '{
    for(i=1;i<=NF;i++){
      if($i ~ /^[0-9.]+$/ && $(i+1) ~ /B\/s$/){v=$i; u=$(i+1)}
    }
  } END{print u}')"

  if [[ -z "$speed" || -z "$unit" ]]; then
    println "${FG_RED}❌ dd 速度解析失败（输出末行：$last）${RESET}"
    DD_MBPS=""; DD_SCORE=0
    hr
    return 0
  fi

  case "$unit" in
    KB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f",x/1024}')" ;;
    MB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f",x}')" ;;
    GB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f",x*1024}')" ;;
    TB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f",x*1024*1024}')" ;;
    *)    mbps="" ;;
  esac

  if [[ -z "$mbps" ]]; then
    println "${FG_RED}❌ dd 单位不识别：$unit${RESET}"
    DD_MBPS=""; DD_SCORE=0
    hr
    return 0
  fi

  DD_MBPS="$mbps"

  if awk -v x="$mbps" 'BEGIN{exit !(x>=1500)}'; then
    DD_SCORE=95
    println "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    println "${FG_GREEN}✅ 磁盘：优秀（>=1500 MB/s）${RESET}"
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
http_code() {
  # 仅输出最终 http code；避免 403000 这种拼接
  local url="$1"
  curl -sS -L --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000"
}

media_item() {
  local name="$1" url="$2"
  local code; code="$(http_code "$url")"
  # 200-399 视为可访问；403/451 风控；000 失败
  if [[ "$code" =~ ^[23][0-9]{2}$ ]]; then
    echo "${name}=可访问"
    return 0
  fi
  if [[ "$code" =~ ^3[0-9]{2}$ ]]; then
    echo "${name}=可访问"
    return 0
  fi
  if [[ "$code" == "403" || "$code" == "451" ]]; then
    echo "${name}=可能风控/拦截"
    return 0
  fi
  echo "${name}=不可用"
}

do_media() {
  println "${FG_PURPLE}--- 流媒体解锁检测（best-effort）---${RESET}"

  # YouTube 地区（简单取 countryCode）
  local yt_js cc
  yt_js="$(curl -fsS --max-time 8 "https://www.youtube.com/premium" 2>/dev/null || true)"
  cc="$(printf "%s" "$yt_js" | sed -n 's/.*"countryCode":"\([A-Z]\{2\}\)".*/\1/p' | head -n1)"
  [[ -z "$cc" ]] && cc="${P_COUNTRY:-unknown}"
  [[ -z "$cc" ]] && cc="unknown"
  local cc_cn; cc_cn="$(country_cn "$cc")"

  println "YouTube Premium : HTTP 200  地区：${cc_cn}（${cc}）"
  println "${FG_GREEN}✅ YouTube：可访问${RESET}"
  println

  # 其它：用 code 判定（注意：最终以登录播放为准）
  local a n d t p m
  a="$(media_item "动画疯" "https://ani.gamer.com.tw/")"
  n="$(media_item "Netflix" "https://www.netflix.com/title/80018499")"
  d="$(media_item "Disney+" "https://www.disneyplus.com/")"
  t="$(media_item "TikTok" "https://www.tiktok.com/")"
  p="$(media_item "Prime" "https://www.primevideo.com/")"
  m="$(media_item "Max" "https://play.max.com/")"

  println "$a"
  println "$n（最终以登录播放为准）"
  println "$d（最终以登录播放为准）"
  println "$t（可能受风控/Cloudflare 影响）"
  println "$p（片库看账号地区）"
  println "$m（最终以登录播放为准）"

  # 一个粗略分：可访问+10，可能风控+6，不可用+0
  local score=0
  for x in "$a" "$n" "$d" "$t" "$p" "$m"; do
    if [[ "$x" == *"可访问"* ]]; then
      score=$((score+10))
    elif [[ "$x" == *"可能风控"* ]]; then
      score=$((score+6))
    fi
  done
  # 满分 60 -> 折算 100
  MEDIA_SCORE=$(( score * 100 / 60 ))
  MEDIA_LINE="YouTube=可访问(地区=${cc}) | ${a} | ${n} | ${d} | ${t} | ${p} | ${m}"
  hr
}

# -------- TCP Real test (multi-source median) --------
tcp_url() {
  case "$1" in
    cloudflare) echo "https://speed.cloudflare.com/__down?bytes=104857600" ;;  # 100MB
    hetzner)    echo "https://speed.hetzner.de/100MB.bin" ;;
    ovh)        echo "https://proof.ovh.net/files/100Mb.dat" ;;
    cachefly)   echo "https://cachefly.cachefly.net/100mb.test" ;;
    *) echo "" ;;
  esac
}

do_tcp() {
  if ! exists curl; then
    println "${FG_RED}❌ 系统缺少 curl，无法做 TCP 测试${RESET}"
    TCP_SCORE=0; TCP_OK_SAMPLES=0
    hr
    return 0
  fi

  println "${FG_PURPLE}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${RESET}"
  println "${FG_CYAN}ℹ️  范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速（能测几个算几个）${RESET}"

  : >"$TMPDIR/tcp_tls.txt"
  : >"$TMPDIR/tcp_ttfb.txt"
  : >"$TMPDIR/tcp_dl.txt"

  TCP_OK_SAMPLES=0
  TCP_BEST_SRC=""
  local best_dl="0"

  for src in "${TCP_SOURCES[@]}"; do
    local url; url="$(tcp_url "$src")"
    [[ -z "$url" ]] && continue

    local range_end=$(( TCP_RANGE_MB*1024*1024 - 1 ))
    local r
    r="$(curl -sS -L --connect-timeout 5 --max-time "$TCP_MAXTIME" \
          -r "0-${range_end}" -o /dev/null \
          -w 'tls=%{time_appconnect} ttfb=%{time_starttransfer} dl=%{speed_download} code=%{http_code}\n' \
          "$url" 2>/dev/null || true)"

    local code tls ttfb dl_bps
    code="$(awk '{for(i=1;i<=NF;i++)if($i ~ /^code=/){sub(/^code=/,"",$i);print $i}}' <<<"$r")"
    tls="$(awk  '{for(i=1;i<=NF;i++)if($i ~ /^tls=/){sub(/^tls=/,"",$i);print $i}}'  <<<"$r")"
    ttfb="$(awk '{for(i=1;i<=NF;i++)if($i ~ /^ttfb=/){sub(/^ttfb=/,"",$i);print $i}}' <<<"$r")"
    dl_bps="$(awk '{for(i=1;i<=NF;i++)if($i ~ /^dl=/){sub(/^dl=/,"",$i);print $i}}' <<<"$r")"

    if [[ -z "$code" || "$code" == "000" ]]; then
      println "• ${FG_GRAY}${src}:${RESET} 失败/超时（跳过）"
      continue
    fi
    # 只要不是 4xx/5xx 严重错误就算成功（206/200/302 都行）
    if [[ "$code" =~ ^[45] ]]; then
      println "• ${FG_GRAY}${src}:${RESET} HTTP ${code}（跳过）"
      continue
    fi

    # 转换单位
    local tls_ms ttfb_ms dl_mbps
    tls_ms="$(awk -v x="${tls:-0}"  'BEGIN{printf "%.0f", (x+0)*1000}')"
    ttfb_ms="$(awk -v x="${ttfb:-0}" 'BEGIN{printf "%.0f", (x+0)*1000}')"
    dl_mbps="$(awk -v x="${dl_bps:-0}" 'BEGIN{printf "%.2f", (x+0)*8/1000000}')"

    printf "%s\n" "$tls_ms"  >>"$TMPDIR/tcp_tls.txt"
    printf "%s\n" "$ttfb_ms" >>"$TMPDIR/tcp_ttfb.txt"
    printf "%s\n" "$dl_mbps" >>"$TMPDIR/tcp_dl.txt"
    TCP_OK_SAMPLES=$((TCP_OK_SAMPLES+1))

    if awk -v a="$dl_mbps" -v b="$best_dl" 'BEGIN{exit !(a>b)}'; then
      best_dl="$dl_mbps"
      TCP_BEST_SRC="$src"
    fi

    println "• ${FG_GREEN}${src}:${RESET} TLS=${tls_ms}ms  TTFB=${ttfb_ms}ms  下载=${dl_mbps}Mbps  code=${code}"
  done

  if (( TCP_OK_SAMPLES == 0 )); then
    TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
    TCP_SCORE=0
    TCP_NOTE="无有效样本（可能被限速/风控/超时）"
    println "${FG_RED}❌ TCP：无有效样本（可能被限速/风控/超时）${RESET}"
    hr
    return 0
  fi

  TCP_TLS_MS="$(median_of_list <"$TMPDIR/tcp_tls.txt")"
  TCP_TTFB_MS="$(median_of_list <"$TMPDIR/tcp_ttfb.txt")"
  TCP_DL_MBPS="$(median_of_list <"$TMPDIR/tcp_dl.txt")"

  # 评分：以下载为主，结合 TLS/TTFB 轻微扣分
  local s=0
  local dl="${TCP_DL_MBPS:-0}"
  local tlsm="${TCP_TLS_MS:-9999}"
  local ttfbm="${TCP_TTFB_MS:-9999}"

  if awk -v x="$dl" 'BEGIN{exit !(x>=50)}'; then s=92
  elif awk -v x="$dl" 'BEGIN{exit !(x>=20)}'; then s=82
  elif awk -v x="$dl" 'BEGIN{exit !(x>=5)}';  then s=68
  else s=45
  fi

  # 惩罚：TLS/TTFB 太大
  if awk -v x="$tlsm" 'BEGIN{exit !(x>800)}'; then s=$((s-10)); fi
  if awk -v x="$ttfbm" 'BEGIN{exit !(x>1200)}'; then s=$((s-10)); fi
  (( s < 0 )) && s=0
  (( s > 100 )) && s=100

  TCP_SCORE="$s"

  if (( TCP_OK_SAMPLES < 2 )); then
    TCP_NOTE="有效样本不足（可能被限速/风控/超时），建议换时间多测几次"
    println "${FG_YELLOW}⚠️  TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。${RESET}"
  fi

  println
  println "${FG_GRAY}中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳源=${TCP_BEST_SRC:-unknown} ${best_dl}Mbps）${RESET}"
  local fg; fg="$(grade_fg "$TCP_SCORE")"
  println "${fg}✅ TCP 体验：$(grade_label "$TCP_SCORE")${RESET}"
  hr
}

# -------- Summary --------
calc_network_score() {
  # 网络 = Ping + (可选)MTR
  local s="$PING_SCORE"
  if [[ "$MTR_STATUS" == "已测" && "$MTR_SCORE" -gt 0 ]]; then
    s=$(( (PING_SCORE + MTR_SCORE) / 2 ))
  fi
  echo "$s"
}

summary_report() {
  local net_score; net_score="$(calc_network_score)"
  local net_label; net_label="$(grade_label "$net_score")"
  local tcp_label; tcp_label="$(grade_label "$TCP_SCORE")"
  local dd_label;  dd_label="$(grade_label "$DD_SCORE")"
  local media_label; media_label="$(grade_label "$MEDIA_SCORE")"

  # 总评（可按你口味调权重）
  local total=$(( (net_score*35 + TCP_SCORE*25 + DD_SCORE*15 + MEDIA_SCORE*25) / 100 ))
  local total_label; total_label="$(grade_label "$total")"

  hr2
  println "====================== ✅ VPS 体检总结报告 ======================"
  println "[基础信息]"
  println "Host : $(mask_host "$B_HOST")"
  println "OS   : $B_OS"
  println "Kern : ${B_KERN:-未知} | Virt=${B_VIRT:-未知}"
  println "CPU  : $B_CPU | 核数=${B_CORES} | 内存=${B_RAM} | Swap=${B_SWAP}"
  println "Disk : / ${B_DISK}"
  println "IPv4 : $(mask_ipv4 "$P_IPV4")"
  println "地区 : ${P_GEO:-unknown}"
  println "ASN  : ${P_ASN:-unknown}"
  println "ISP  : ${P_ISP:-unknown}"
  hr

  # 网络
  println "[网络]  ${net_score}/100 (${net_label})  $(bar "$net_score")"
  println "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% | 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  if [[ "$MTR_STATUS" == "已测" ]]; then
    println "MTR  : 目标=${MTR_TARGET:-unknown} | 终点丢包=${MTR_LAST_LOSS:-未知}% | 终点平均=${MTR_LAST_AVG:-未知}ms | 评级=$(grade_text_colored "$MTR_SCORE")"
  else
    println "MTR  : 未测（可先选 6 安装 mtr）"
  fi
  hr

  # TCP
  println "[TCP真实链路]  ${TCP_SCORE}/100 (${tcp_label})  $(bar "$TCP_SCORE")"
  println "TLS  : ${TCP_TLS_MS:-?} ms | TTFB=${TCP_TTFB_MS:-?} ms"
  println "下载 : ${TCP_DL_MBPS:-?} Mbps（中位数，range=${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
  println "样本 : ${TCP_OK_SAMPLES} 个 | 最佳源=${TCP_BEST_SRC:-unknown}"
  [[ -n "${TCP_NOTE:-}" ]] && println "提示 : ${TCP_NOTE}"
  hr

  # 磁盘
  println "[磁盘]  ${DD_SCORE}/100 (${dd_label})  $(bar "$DD_SCORE")"
  if [[ -n "${DD_MBPS:-}" ]]; then
    println "dd   : 约 ${DD_MBPS} MB/s"
  else
    println "dd   : 未测/失败"
  fi
  hr

  # 流媒体
  println "[流媒体]  ${MEDIA_SCORE}/100 (${media_label})  $(bar "$MEDIA_SCORE")"
  println "${MEDIA_LINE:-流媒体：未测}"
  hr

  # 总评
  println "[总评]  ${total}/100 (${total_label})  $(bar "$total")"
  if (( total >= 90 )); then
    println "${FG_GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${RESET}"
  elif (( total >= 75 )); then
    println "${FG_CYAN}✅ 结论：整体不错，日常中转/落地够用，关注路由与邻居波动。${RESET}"
  elif (( total >= 60 )); then
    println "${FG_YELLOW}⚠️  结论：整体一般，建议多测不同时间段，必要时换机房/线路。${RESET}"
  else
    println "${FG_RED}❌ 结论：整体偏弱，建议更换线路/机房。${RESET}"
  fi

  println
  println "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${RESET}"
  println "================================================================"
  hr2
}

# -------- Menu --------
show_menu() {
  hr2
  println "${FG_PINK}===================== VPS 一键体检 菜单 =====================${RESET}"
  println "Targets: ${FG_PINK}${TARGETS[*]}${RESET}  ${FG_GRAY}(MTR 默认用第一个 Target)${RESET}"
  println
  println "1) 设置测试目标（Targets）"
  println "2) 基本信息（系统/CPU/内存/磁盘/虚拟化）"
  println "3) 公网信息（IPv4 / 地区(中文) / ASN / ISP）"
  println "4) 网络 Ping 测试（所有 Targets）"
  println "5) 路由 MTR 测试（仅第一个 Target）"
  println "6) 安装 mtr（Debian/Ubuntu）"
  println "7) 磁盘 dd 测速（写入 /tmp）"
  println "8) 流媒体检测（best-effort）"
  println "9) 一键全跑（2~8+10）并输出最终总结（会显示全过程）"
  println "10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
  println "R) 后台静默全跑（2~8+10），只输出最终总结（不刷屏）"
  println "0) 退出"
  hr
}

set_targets() {
  println "${FG_CYAN}ℹ️  请输入 Targets（空格或逗号分隔），例如：1.1.1.1 8.8.8.8 www.google.com${RESET}"
  read -r -p "Targets: " line
  line="$(echo "$line" | tr ',' ' ' | xargs)"
  if [[ -z "$line" ]]; then
    println "${FG_YELLOW}⚠️  输入为空，保留默认 Targets${RESET}"
    hr
    return 0
  fi
  # shellcheck disable=SC2206
  TARGETS=($line)
  println "${FG_GREEN}✅ 已更新 Targets：${TARGETS[*]}${RESET}"
  hr
}

run_all() {
  do_basic
  do_public
  do_ping_all
  do_mtr
  do_dd
  do_media
  do_tcp
  summary_report
}

run_all_quiet() {
  println "${FG_CYAN}ℹ️  正在后台静默执行检测（2~8+10），完成后输出最终✅总结...${RESET}"
  # 把过程输出吃掉，但保留数据计算
  exec 3>&1 4>&2
  exec >"$TMPDIR/quiet.log" 2>&1
  run_all
  exec >&3 2>&4
  summary_report
}

# -------- Main --------
while true; do
  show_menu
  read -r -p "选择 [0-10/R]: " choice
  choice="$(echo "$choice" | tr '[:lower:]' '[:upper:]')"

  case "$choice" in
    1) set_targets; pause ;;
    2) do_basic; pause ;;
    3) do_public; pause ;;
    4) do_ping_all; pause ;;
    5) do_mtr; pause ;;
    6) do_mtr_install; pause ;;
    7) do_dd; pause ;;
    8) do_media; pause ;;
    9) run_all; pause ;;
    10) do_tcp; pause ;;
    R) run_all_quiet; pause ;;
    0) exit 0 ;;
    *) println "${FG_YELLOW}⚠️  无效选择${RESET}"; pause ;;
  esac
done
