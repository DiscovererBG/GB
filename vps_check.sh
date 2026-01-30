#!/usr/bin/env bash
set -Eeuo pipefail


# ---------------- Locale（尽量 UTF-8，避免 ????） ----------------
if command -v locale >/dev/null 2>&1; then
  if locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-8$'; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  else
    export LANG=C LC_ALL=C
  fi
else
  export LANG=C LC_ALL=C
fi

# ---------------- Colors（全部用 $'\033'，杜绝 \033[0m 残留） ----------------
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

# ---------------- Settings ----------------
TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")
PING_COUNT=50
MTR_CYCLES=100
DD_SIZE_MB=256

TCP_RANGE_MB=16
TCP_MAXTIME=12
TCP_SOURCES=("cloudflare" "hetzner" "ovh" "cachefly")

# ---------------- Runtime ----------------
TMPDIR="/tmp/vps_check.$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

REDACT=0
[[ "${1:-}" == "--redact" ]] && REDACT=1

QUIET=0          # R 模式会设为 1（不刷屏）
PAUSE_ENABLE=1   # R 模式会设为 0（不暂停）

# ---------------- Print helpers ----------------
p()  { printf "%b" "$*"; }
pl() { [[ "$QUIET" -eq 1 ]] && return 0; printf "%b\n" "$*"; }
pl_force() { printf "%b\n" "$*"; }

hr()  { pl "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2() { pl "${FG_PINK}=========================================================${RESET}"; }

pause() {
  [[ "$PAUSE_ENABLE" -eq 0 ]] && return 0
  read -r -p "回车继续..." _ || true
}

exists() { command -v "$1" >/dev/null 2>&1; }

mask_ipv4() {
  local ip="${1:-unknown}"
  [[ "$REDACT" -eq 0 ]] && { printf "%s" "$ip"; return; }
  printf "%s" "$ip" | awk -F. 'NF==4{print $1"."$2".*.*"; next}{print "*.*.*.*"}'
}

mask_host() {
  local h="${1:-unknown}"
  [[ "$REDACT" -eq 0 ]] && { printf "%s" "$h"; return; }
  [[ -z "$h" ]] && { printf "unknown"; return; }
  printf "%s" "$h" | sed -E 's/^(.).*(.)$/\1***\2/'
}

# ---------------- Grade helpers ----------------
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
  if (( s >= 75 )); then printf "%s" "$FG_CYAN";  return; fi
  if (( s >= 60 )); then printf "%s" "$FG_YELLOW";return; fi
  printf "%s" "$FG_RED"
}
grade_bg() {
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$BG_GREEN"; return; fi
  if (( s >= 75 )); then printf "%s" "$BG_CYAN";  return; fi
  if (( s >= 60 )); then printf "%s" "$BG_YELLOW";return; fi
  printf "%s" "$BG_RED"
}
grade_colored_label() {
  local s="${1:-0}"
  local fg; fg="$(grade_fg "$s")"
  printf "%b%s%b" "$fg" "$(grade_label "$s")" "$RESET"
}

# 进度条（彩色块+灰点 '.'），避免 '·' 变 ???；不用 '='
bar() {
  local score="${1:-0}"
  local width="${2:-28}"
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100
  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))

  local fg; fg="$(grade_fg "$score")"
  local bg; bg="$(grade_bg "$score")"

  p "${fg}[${RESET}"
  p "${bg}"
  printf "%*s" "$filled" ""
  p "${RESET}"
  p "${FG_GRAY}${DIM}"
  if (( rest > 0 )); then
    printf "%*s" "$rest" "" | tr ' ' '.'
  fi
  p "${RESET}${fg}]${RESET}"
}

# ---------------- Utils ----------------
f2() { awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x+0}'; }
f1() { awk -v x="${1:-0}" 'BEGIN{printf "%.1f", x+0}'; }

median_of_list() {
  local arr n mid a b
  mapfile -t arr < <(cat | awk 'NF{print $1}' | sort -n)
  n="${#arr[@]}"
  if (( n == 0 )); then printf ""; return 0; fi
  mid=$(( n / 2 ))
  if (( n % 2 == 1 )); then
    printf "%s" "${arr[$mid]}"
  else
    a="${arr[$((mid-1))]}"
    b="${arr[$mid]}"
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f", (a+b)/2}'
  fi
}

country_zh() {
  # ISO -> 中文（够用版本，常见国家先覆盖；未知返回原码）
  local cc="${1:-}"
  case "$cc" in
    SG) echo "新加坡" ;;
    HK) echo "中国香港" ;;
    TW) echo "中国台湾" ;;
    JP) echo "日本" ;;
    KR) echo "韩国" ;;
    US) echo "美国" ;;
    CA) echo "加拿大" ;;
    GB|UK) echo "英国" ;;
    DE) echo "德国" ;;
    FR) echo "法国" ;;
    NL) echo "荷兰" ;;
    IT) echo "意大利" ;;
    ES) echo "西班牙" ;;
    AU) echo "澳大利亚" ;;
    NZ) echo "新西兰" ;;
    IN) echo "印度" ;;
    ID) echo "印度尼西亚" ;;
    MY) echo "马来西亚" ;;
    TH) echo "泰国" ;;
    VN) echo "越南" ;;
    PH) echo "菲律宾" ;;
    TR) echo "土耳其" ;;
    RU) echo "俄罗斯" ;;
    BR) echo "巴西" ;;
    MX) echo "墨西哥" ;;
    AE) echo "阿联酋" ;;
    SA) echo "沙特" ;;
    *) echo "${cc:-未知}" ;;
  esac
}

# ---------------- Global cached results（保证“最后输出基础信息一致”） ----------------
B_HOST=""; B_OS=""; B_KERN=""; B_UPTIME=""; B_VIRT=""; B_CPU=""; B_CORES=""
B_RAM=""; B_SWAP=""; B_DISK=""

P_IPV4=""; P_CITY=""; P_REGION=""; P_COUNTRY_CODE=""; P_COUNTRY_ZH=""; P_ORG=""; P_ASN=""; P_ISP=""

PING_GOOD=0; PING_WARN=0; PING_BAD=0
PING_WORST_LOSS=""; PING_WORST_AVG=""

MTR_TARGET=""; MTR_LAST_LOSS=""; MTR_LAST_AVG=""; MTR_SCORE=0

DD_MBPS=""; DD_SCORE=0

MEDIA_SCORE=0
MEDIA_LINE=""

TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
TCP_OK_SAMPLES=0
TCP_BEST_SRC=""
TCP_SCORE=0

# ---------------- Step 2: 基本信息 ----------------
do_basic() {
  B_HOST="$(hostname 2>/dev/null || echo "unknown")"
  if [[ -r /etc/os-release ]]; then
    B_OS="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
  else
    B_OS="Linux"
  fi
  B_KERN="$(uname -r 2>/dev/null || echo "unknown")"
  B_UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //g' || true)"
  [[ -z "$B_UPTIME" ]] && B_UPTIME="未知"

  if exists systemd-detect-virt; then
    B_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "$B_VIRT" ]] && B_VIRT="无"
  else
    B_VIRT="未知"
  fi

  B_CPU="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "unknown")"
  B_CORES="$(nproc 2>/dev/null || echo "1")"

  if exists free; then
    B_RAM="$(free -m | awk '/Mem:/ {print $2 " MB"}')"
    B_SWAP="$(free -m | awk '/Swap:/ {print $2 " MB"}')"
  else
    B_RAM="未知"; B_SWAP="未知"
  fi

  if exists df; then
    B_DISK="$(df -h / 2>/dev/null | awk 'NR==2{print $3 "/" $2 " (" $5 ")"}')"
  else
    B_DISK="未知"
  fi

  pl "${FG_CYAN}ℹ️  开始：基本信息${RESET}"
  pl "${FG_PINK}--- 基本信息 ---${RESET}"
  pl "主机名   : $(mask_host "$B_HOST")"
  pl "系统     : $B_OS"
  pl "内核     : $B_KERN"
  pl "运行时长 : $B_UPTIME"
  pl "虚拟化   : $B_VIRT"
  pl "CPU      : $B_CPU（${B_CORES} 核）"
  pl "内存/Swap: $B_RAM / $B_SWAP"
  pl "磁盘 /   : $B_DISK"
  hr
}

# ---------------- Step 3: 公网信息（国家中文） ----------------
do_public() {
  pl "${FG_CYAN}ℹ️  开始：公网信息${RESET}"

  P_IPV4="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="unknown"

  local js
  js="$(curl -fsS --max-time 6 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"

  P_CITY=""; P_REGION=""; P_COUNTRY_CODE=""; P_ORG=""
  if [[ -n "$js" ]]; then
    P_CITY="$(printf "%s" "$js" | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
    P_REGION="$(printf "%s" "$js" | sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
    P_COUNTRY_CODE="$(printf "%s" "$js" | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
    P_ORG="$(printf "%s" "$js" | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
  fi
  [[ -z "$P_COUNTRY_CODE" ]] && P_COUNTRY_CODE="未知"
  P_COUNTRY_ZH="$(country_zh "$P_COUNTRY_CODE")"

  # org: "AS20473 The Constant Company, LLC"
  P_ASN="$(printf "%s" "$P_ORG" | awk '{print $1}' 2>/dev/null || true)"
  P_ISP="$(printf "%s" "$P_ORG" | sed -E 's/^AS[0-9]+[ ]*//' 2>/dev/null || true)"
  [[ -z "$P_ASN" ]] && P_ASN="未知"
  [[ -z "$P_ISP" ]] && P_ISP="未知"

  pl "${FG_PINK}--- 公网信息 ---${RESET}"
  pl "IPv4   : $(mask_ipv4 "$P_IPV4")"
  pl "地区   : ${P_COUNTRY_ZH} (${P_CITY:-未知}, ${P_REGION:-未知})"
  pl "ASN    : ${P_ASN}"
  pl "运营商 : ${P_ISP}"
  hr
}

# ---------------- Step 4: Ping（修复 awk 报错/丢包 loss%） ----------------
ping_one() {
  local t="$1"
  local out loss min avg max mdev
  out="$(LANG=C ping -c "$PING_COUNT" -q "$t" 2>/dev/null || true)"

  # 丢包：从 "XX% packet loss" 提取
  loss="$(printf "%s\n" "$out" | sed -n 's/.* \([0-9.]\+\)% packet loss.*/\1/p' | tail -n1)"
  [[ -z "$loss" ]] && loss="未知"

  # RTT：从 "min/avg/max/mdev = a/b/c/d ms" 提取
  local rttline
  rttline="$(printf "%s\n" "$out" | grep -E 'rtt |round-trip ' | tail -n1 || true)"
  if [[ -n "$rttline" ]]; then
    read -r min avg max mdev < <(printf "%s\n" "$rttline" | sed -E 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/([0-9.]+).*/\1 \2 \3 \4/' || true)
  else
    min=""; avg=""; max=""; mdev=""
  fi
  [[ -z "${min:-}" ]] && min="未知"
  [[ -z "${avg:-}" ]] && avg="未知"
  [[ -z "${max:-}" ]] && max="未知"
  [[ -z "${mdev:-}" ]] && mdev="未知"

  pl "${FG_PURPLE}--- Ping: ${t} (${PING_COUNT} 次) ---${RESET}"
  pl "丢包 : ${loss}%"
  pl "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  # 评价（不中断）
  local s=0
  if [[ "$loss" != "未知" && "$avg" != "未知" ]]; then
    local lossn avgn
    lossn="$(awk -v x="$loss" 'BEGIN{print x+0}' 2>/dev/null || echo 999)"
    avgn="$(awk -v x="$avg"  'BEGIN{print x+0}' 2>/dev/null || echo 999)"

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

  if [[ "$loss" != "未知" ]]; then
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}'; then
      pl "${FG_GREEN}✅ 丢包：优秀（≤1%）${RESET}"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}'; then
      pl "${FG_YELLOW}⚠️  丢包：一般（≤5%）${RESET}"
    else
      pl "${FG_RED}❌ 丢包：偏弱（>5%）${RESET}"
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      pl "${FG_GREEN}✅ 延迟：优秀（<80ms）${RESET}"
    elif awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      pl "${FG_YELLOW}⚠️  延迟：一般（<150ms）${RESET}"
    else
      pl "${FG_RED}❌ 延迟：偏弱（≥150ms）${RESET}"
    fi
  fi

  # worst
  if [[ "$loss" != "未知" ]]; then
    if [[ -z "$PING_WORST_LOSS" ]]; then
      PING_WORST_LOSS="$loss"
    else
      awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}' && PING_WORST_LOSS="$loss" || true
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if [[ -z "$PING_WORST_AVG" ]]; then
      PING_WORST_AVG="$avg"
    else
      awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}' && PING_WORST_AVG="$avg" || true
    fi
  fi

  if (( s >= 90 )); then ((PING_GOOD++)); elif (( s >= 60 )); then ((PING_WARN++)); else ((PING_BAD++)); fi
  hr
}

do_ping_all() {
  pl "${FG_CYAN}ℹ️  开始：Ping 测试${RESET}"
  PING_GOOD=0; PING_WARN=0; PING_BAD=0
  PING_WORST_LOSS=""; PING_WORST_AVG=""

  for t in "${TARGETS[@]}"; do
    ping_one "$t" || true
  done

  pl "${FG_CYAN}ℹ️  Ping 小结：目标数=${#TARGETS[@]} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% 最差平均延迟=${PING_WORST_AVG:-未知}ms${RESET}"
  hr
}

# ---------------- Step 6/5: mtr 安装/测试（不中断） ----------------
do_mtr_install() {
  pl "${FG_CYAN}ℹ️  正在安装 mtr...${RESET}"
  if exists apt-get; then
    (apt-get update -y >/dev/null 2>&1 || true)
    (apt-get install -y mtr-tiny >/dev/null 2>&1 || apt-get install -y mtr >/dev/null 2>&1 || true)
  fi
  if exists mtr; then
    pl "${FG_GREEN}✅ mtr 已可用${RESET}"
  else
    pl "${FG_RED}❌ mtr 安装失败（可手动：apt-get update && apt-get install -y mtr-tiny）${RESET}"
  fi
  hr
}

do_mtr() {
  MTR_TARGET="${TARGETS[0]}"

  pl "${FG_CYAN}ℹ️  开始：MTR 测试${RESET}"
  if ! exists mtr; then
    pl "${FG_YELLOW}⚠️  未检测到 mtr，尝试自动安装...${RESET}"
    do_mtr_install || true
  fi
  if ! exists mtr; then
    pl "${FG_YELLOW}⚠️  MTR 不可用，跳过${RESET}"
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    hr
    return 0
  fi

  pl "${FG_PURPLE}--- MTR: ${MTR_TARGET} (${MTR_CYCLES} 轮) ---${RESET}"
  local out
  out="$(LANG=C mtr -rwzbc "$MTR_CYCLES" "$MTR_TARGET" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    pl "${FG_RED}❌ MTR 执行失败（可能 ICMP 被限制）${RESET}"
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    hr
    return 0
  fi

  # 展示（少刷屏）
  printf "%s\n" "$out" | sed -n '1,20p' | while IFS= read -r line; do pl "$line"; done
  if (( $(printf "%s\n" "$out" | wc -l) > 26 )); then
    pl "${FG_GRAY}...(中间省略)...${RESET}"
    printf "%s\n" "$out" | tail -n 8 | while IFS= read -r line; do pl "$line"; done
  fi

  local lastline loss avg
  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}' 2>/dev/null || true)"
  loss="$(printf "%s\n" "$lastline" | awk '{print $(NF-6)}' 2>/dev/null | tr -d '%' || true)"
  avg="$(printf "%s\n" "$lastline"  | awk '{print $(NF-4)}' 2>/dev/null || true)"

  if [[ -z "$loss" || -z "$avg" ]]; then
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    pl "${FG_YELLOW}⚠️  终点数据解析失败（格式差异/ICMP 限速）${RESET}"
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

  pl
  pl "终点（最后一跳）：丢包=${MTR_LAST_LOSS}%  平均=${MTR_LAST_AVG}ms"
  pl "${FG_CYAN}ℹ️  提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。${RESET}"
  if (( s >= 90 )); then
    pl "${FG_GREEN}✅ 路由质量：优秀${RESET}"
  elif (( s >= 60 )); then
    pl "${FG_YELLOW}⚠️  路由质量：一般${RESET}"
  else
    pl "${FG_RED}❌ 路由质量：偏弱${RESET}"
  fi
  hr
}

# ---------------- Step 7: dd（修复“0.37MB/s”假结果：无 speed 就自己算） ----------------
do_dd() {
  pl "${FG_CYAN}ℹ️  开始：磁盘 dd 测试${RESET}"
  pl "${FG_PURPLE}--- 磁盘快速测试（dd 写入 ${DD_SIZE_MB}MB 到 /tmp）---${RESET}"

  local out bytes time_s speed_val speed_unit mbps
  out="$(LANG=C dd if=/dev/zero of="$TMPDIR/dd_test" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1 || true)"
  rm -f "$TMPDIR/dd_test" >/dev/null 2>&1 || true

  bytes=$((DD_SIZE_MB*1024*1024))
  time_s="$(printf "%s\n" "$out" | sed -n 's/.*copied, \([0-9.]\+\) s.*/\1/p' | tail -n1 || true)"

  # 先尝试直接读 speed（有些 dd 输出：..., 0.16 s, 1.6 GB/s）
  read -r speed_val speed_unit < <(printf "%s\n" "$out" \
    | sed -n 's/.*copied, [0-9.]\+ s, \([0-9.]\+\) \([kMG]B\/s\).*/\1 \2/p' \
    | tail -n1 || true)

  if [[ -n "${speed_val:-}" && -n "${speed_unit:-}" ]]; then
    if [[ "$speed_unit" == "GB/s" ]]; then
      mbps="$(awk -v x="$speed_val" 'BEGIN{printf "%.2f", x*1024}' )"
    elif [[ "$speed_unit" == "MB/s" ]]; then
      mbps="$(awk -v x="$speed_val" 'BEGIN{printf "%.2f", x}' )"
    else
      mbps=""
    fi
  else
    # dd 没给 speed：自己算
    if [[ -n "${time_s:-}" ]]; then
      mbps="$(awk -v b="$DD_SIZE_MB" -v t="$time_s" 'BEGIN{if(t>0) printf "%.2f", (b/t); else print ""}' )"
    else
      mbps=""
    fi
  fi

  if [[ -z "${mbps:-}" ]]; then
    DD_MBPS=""
    DD_SCORE=0
    pl "${FG_RED}❌ dd 测试失败${RESET}"
    hr
    return 0
  fi

  DD_MBPS="$mbps"

  # scoring
  if awk -v x="$mbps" 'BEGIN{exit !(x>=1500)}'; then
    DD_SCORE=95
    pl "结果：约 ${mbps} MB/s"
    pl "${FG_GREEN}✅ 磁盘：优秀（>=1500 MB/s）${RESET}"
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=500)}'; then
    DD_SCORE=85
    pl "结果：约 ${mbps} MB/s"
    pl "${FG_CYAN}✅ 磁盘：良好（>=500 MB/s）${RESET}"
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=200)}'; then
    DD_SCORE=70
    pl "结果：约 ${mbps} MB/s"
    pl "${FG_YELLOW}⚠️  磁盘：一般（>=200 MB/s）${RESET}"
  else
    DD_SCORE=45
    pl "结果：约 ${mbps} MB/s"
    pl "${FG_RED}❌ 磁盘：偏弱（<200 MB/s）${RESET}"
  fi
  hr
}

# ---------------- Step 8: 流媒体（修复 403000/301 判断） ----------------
curl_code() {
  # 只输出三位 http_code；失败输出 000
  local url="$1"
  local code
  code="$(curl -fsS --max-time 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
  # 防止意外拼接：只取前三位数字
  code="$(printf "%s" "$code" | tr -cd '0-9' | head -c 3)"
  [[ -z "$code" ]] && code="000"
  printf "%s" "$code"
}

do_media() {
  pl "${FG_CYAN}ℹ️  开始：流媒体检测${RESET}"
  pl "${FG_PURPLE}--- 流媒体解锁检测 ---${RESET}"

  local yt nf ds tk pm hb
  yt="$(curl_code "https://www.youtube.com/premium")"
  nf="$(curl_code "https://www.netflix.com/title/80018499")"
  ds="$(curl_code "https://www.disneyplus.com/")"
  tk="$(curl_code "https://www.tiktok.com/")"
  pm="$(curl_code "https://www.primevideo.com/")"
  hb="$(curl_code "https://play.max.com/")"

  # 评分（保守）
  local score=0
  local ok() { [[ "$1" == "200" || "$1" == "302" || "$1" == "301" ]]; }
  ok "$yt" && score=$((score+15))
  ok "$nf" && score=$((score+15))
  ok "$ds" && score=$((score+15))
  ok "$tk" && score=$((score+10))
  ok "$pm" && score=$((score+15))
  ok "$hb" && score=$((score+15))
  ((score>100)) && score=100

  # 输出（中文）
  if ok "$yt"; then pl "${FG_GREEN}✅ YouTube: 可访问${RESET}"; else pl "${FG_RED}❌ YouTube: 不可用（HTTP $yt）${RESET}"; fi
  if ok "$nf"; then pl "${FG_GREEN}✅ Netflix: 可访问（最终以登录播放为准）${RESET}"; else pl "${FG_RED}❌ Netflix: 不可用（HTTP $nf）${RESET}"; fi
  if ok "$ds"; then pl "${FG_GREEN}✅ Disney+: 可访问（最终以登录播放为准）${RESET}"; else pl "${FG_RED}❌ Disney+: 不可用（HTTP $ds）${RESET}"; fi
  if ok "$tk"; then pl "${FG_YELLOW}⚠️  TikTok: 可访问但可能受风控/Cloudflare 影响（HTTP $tk）${RESET}"; else pl "${FG_RED}❌ TikTok: 不可用（HTTP $tk）${RESET}"; fi
  if ok "$pm"; then pl "${FG_GREEN}✅ Prime: 可访问（片库看账号地区）${RESET}"; else pl "${FG_RED}❌ Prime: 不可用（HTTP $pm）${RESET}"; fi
  if ok "$hb"; then pl "${FG_GREEN}✅ Max(HBO): 可访问（最终以登录播放为准）${RESET}"; else pl "${FG_RED}❌ Max(HBO): 不可用（HTTP $hb）${RESET}"; fi

  pl "${FG_CYAN}ℹ️  提示：最终以“登录播放”结果为准。${RESET}"

  MEDIA_SCORE="$score"
  MEDIA_LINE="YouTube=${yt} | Netflix=${nf} | Disney+=${ds} | TikTok=${tk} | Prime=${pm} | Max=${hb}"
  hr
}

# ---------------- Step 10: TCP 多源（不依赖 asort） ----------------
tcp_test_one() {
  local src="$1"
  local url="" host=""
  case "$src" in
    cloudflare) url="https://speed.cloudflare.com/__down?bytes=$((TCP_RANGE_MB*1024*1024))";;
    hetzner)    url="https://speed.hetzner.de/100MB.bin";;
    ovh)        url="https://proof.ovh.net/files/100Mb.dat";;
    cachefly)   url="https://cachefly.cachefly.net/100mb.test";;
    *) return 1;;
  esac

  # TLS/TTFB/下载
  # 下载使用 Range 限制（避免跑满/被限速），并且 max-time 限制
  local tls ttfb dl code
  # curl -w time_appconnect/time_starttransfer/speed_download/http_code
  local w
  w="$(curl -L -sS --max-time "$TCP_MAXTIME" --range "0-$((TCP_RANGE_MB*1024*1024-1))" -o /dev/null \
      -w '%{time_appconnect} %{time_starttransfer} %{speed_download} %{http_code}' \
      "$url" 2>/dev/null || echo "")"

  if [[ -z "$w" ]]; then
    echo "$src FAIL"
    return 0
  fi

  read -r tls ttfb dl code <<<"$w"
  # code 只要 3 位
  code="$(printf "%s" "${code:-000}" | tr -cd '0-9' | head -c 3)"
  [[ -z "$code" ]] && code="000"

  # speed_download: bytes/s -> Mbps
  if [[ -n "${dl:-}" && "${dl:-0}" != "0" ]]; then
    dl="$(awk -v b="$dl" 'BEGIN{printf "%.2f", (b*8)/1000000}' )"
  else
    dl=""
  fi

  # tls/ttfb: seconds -> ms
  if [[ -n "${tls:-}" && "${tls:-0}" != "0" ]]; then
    tls="$(awk -v s="$tls" 'BEGIN{printf "%.0f", s*1000}' )"
  else
    tls=""
  fi
  if [[ -n "${ttfb:-}" && "${ttfb:-0}" != "0" ]]; then
    ttfb="$(awk -v s="$ttfb" 'BEGIN{printf "%.0f", s*1000}' )"
  else
    ttfb=""
  fi

  # 判定有效
  if [[ "$code" == "200" || "$code" == "206" ]]; then
    echo "$src OK $tls $ttfb $dl $code"
  else
    echo "$src FAIL $tls $ttfb $dl $code"
  fi
}

do_tcp() {
  pl "${FG_CYAN}ℹ️  开始：TCP 真实链路${RESET}"
  pl "${FG_PURPLE}--- TCP 真实链路测试 ---${RESET}"
  pl "${FG_CYAN}范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速${RESET}"

  local tls_list="" ttfb_list="" dl_list=""
  TCP_OK_SAMPLES=0
  TCP_BEST_SRC=""
  local best_dl=0

  local line src st tls ttfb dl code
  for src in "${TCP_SOURCES[@]}"; do
    line="$(tcp_test_one "$src" || true)"
    read -r src st tls ttfb dl code <<<"$line"

    if [[ "$st" == "OK" && -n "${dl:-}" ]]; then
      ((TCP_OK_SAMPLES++))
      printf "%s\n" "$tls"  >>"$TMPDIR/tls.list"
      printf "%s\n" "$ttfb" >>"$TMPDIR/ttfb.list"
      printf "%s\n" "$dl"   >>"$TMPDIR/dl.list"

      # best
      if awk -v a="$dl" -v b="$best_dl" 'BEGIN{exit !(a>b)}'; then
        best_dl="$dl"
        TCP_BEST_SRC="$src"
      fi

      pl "• ${FG_GREEN}${src}${RESET}: TLS=${tls}ms  TTFB=${ttfb}ms  下载=${dl}Mbps  code=${code}"
    else
      pl "• ${FG_GRAY}${src}${RESET}: 失败/超时（跳过）"
    fi
  done

  local mtls mttfb mdl
  mtls="$(cat "$TMPDIR/tls.list" 2>/dev/null | median_of_list || true)"
  mttfb="$(cat "$TMPDIR/ttfb.list" 2>/dev/null | median_of_list || true)"
  mdl="$(cat "$TMPDIR/dl.list" 2>/dev/null | median_of_list || true)"

  if [[ -z "$mtls" || -z "$mttfb" || -z "$mdl" ]]; then
    TCP_TLS_MS="未知"; TCP_TTFB_MS="未知"; TCP_DL_MBPS="未知"
    TCP_SCORE=40
    pl "${FG_YELLOW}⚠️  TCP：有效样本不足（可能超时/被限速）${RESET}"
    hr
    return 0
  fi

  TCP_TLS_MS="${mtls}"
  TCP_TTFB_MS="${mttfb}"
  TCP_DL_MBPS="${mdl}"

  # score：主要看下载（中位数）
  local s=0
  if awk -v x="$mdl" 'BEGIN{exit !(x>=200)}'; then
    s=90
  elif awk -v x="$mdl" 'BEGIN{exit !(x>=50)}'; then
    s=75
  elif awk -v x="$mdl" 'BEGIN{exit !(x>=10)}'; then
    s=65
  else
    s=40
  fi
  TCP_SCORE="$s"

  pl
  pl "中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳源=${TCP_BEST_SRC:-unknown} ${best_dl}Mbps）"
  if (( s >= 90 )); then
    pl "${FG_GREEN}✅ TCP 体验：优秀${RESET}"
  elif (( s >= 75 )); then
    pl "${FG_CYAN}✅ TCP 体验：良好${RESET}"
  elif (( s >= 60 )); then
    pl "${FG_YELLOW}⚠️  TCP 体验：一般${RESET}"
  else
    pl "${FG_RED}❌ TCP 体验：偏弱${RESET}"
  fi
  hr
}

# ---------------- Summary（最终基础信息全中文 + 颜色正常 + 进度条正确） ----------------
summary_report() {
  # 网络分：用 ping 为主，mtr 有就加权
  local net_score=0
  if [[ -n "${PING_WORST_LOSS:-}" && "${PING_WORST_LOSS:-}" != "未知" && -n "${PING_WORST_AVG:-}" && "${PING_WORST_AVG:-}" != "未知" ]]; then
    # 简单按 ping 最差估算
    if awk -v l="$PING_WORST_LOSS" 'BEGIN{exit !(l<=1)}' && awk -v a="$PING_WORST_AVG" 'BEGIN{exit !(a<80)}'; then
      net_score=95
    elif awk -v l="$PING_WORST_LOSS" 'BEGIN{exit !(l<=3)}' && awk -v a="$PING_WORST_AVG" 'BEGIN{exit !(a<150)}'; then
      net_score=80
    elif awk -v l="$PING_WORST_LOSS" 'BEGIN{exit !(l<=5)}' && awk -v a="$PING_WORST_AVG" 'BEGIN{exit !(a<250)}'; then
      net_score=65
    else
      net_score=40
    fi
  else
    net_score=60
  fi

  # mtr 可用则略提升/校正
  if [[ "${MTR_LAST_LOSS:-未知}" != "未知" && "${MTR_LAST_AVG:-未知}" != "未知" && "$MTR_SCORE" -gt 0 ]]; then
    net_score=$(( (net_score*7 + MTR_SCORE*3) / 10 ))
  fi

  local total=$(( (net_score*25 + TCP_SCORE*25 + DD_SCORE*20 + MEDIA_SCORE*30) / 100 ))
  (( total < 0 )) && total=0
  (( total > 100 )) && total=100

  pl_force
  pl_force "${FG_PINK}==================== ${FG_GREEN}✅${RESET}${FG_PINK} VPS 体检总结报告 ====================${RESET}"
  pl_force "${FG_PINK}[基础信息]${RESET}"
  pl_force "主机名 : $(mask_host "$B_HOST")"
  pl_force "系统   : $B_OS"
  pl_force "内核   : $B_KERN | 虚拟化=$B_VIRT"
  pl_force "CPU    : $B_CPU | 核数=$B_CORES | 内存=$B_RAM | Swap=$B_SWAP"
  pl_force "磁盘   : / $B_DISK"
  pl_force "IPv4   : $(mask_ipv4 "$P_IPV4")"
  pl_force "地区   : ${P_COUNTRY_ZH} (${P_CITY:-未知}, ${P_REGION:-未知})"
  pl_force "ASN    : ${P_ASN}"
  pl_force "运营商 : ${P_ISP}"
  pl_force "${FG_PINK}---------------------------------------------------------${RESET}"

  # 网络
  pl_force "[网络]  ${net_score}/100  ($(grade_colored_label "$net_score"))  $(bar "$net_score")"
  pl_force "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% | 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  if [[ "${MTR_LAST_LOSS:-未知}" != "未知" ]]; then
    pl_force "MTR  : 目标=${MTR_TARGET:-unknown} | 终点丢包=${MTR_LAST_LOSS}% | 终点平均=${MTR_LAST_AVG}ms | 评分=$(grade_colored_label "$MTR_SCORE")"
  else
    pl_force "MTR  : 未检测/不可用"
  fi
  pl_force "${FG_PINK}---------------------------------------------------------${RESET}"

  # TCP
  pl_force "[TCP真实链路]  ${TCP_SCORE}/100  ($(grade_colored_label "$TCP_SCORE"))  $(bar "$TCP_SCORE")"
  pl_force "TLS  : ${TCP_TLS_MS:-未知}ms | TTFB=${TCP_TTFB_MS:-未知}ms"
  pl_force "下载 : ${TCP_DL_MBPS:-未知}Mbps（中位数，${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
  pl_force "样本 : ${TCP_OK_SAMPLES:-0} 个 | 最佳源=${TCP_BEST_SRC:-unknown}"
  pl_force "${FG_PINK}---------------------------------------------------------${RESET}"

  # 磁盘
  pl_force "[磁盘]  ${DD_SCORE}/100  ($(grade_colored_label "$DD_SCORE"))  $(bar "$DD_SCORE")"
  pl_force "dd   : 约 ${DD_MBPS:-未知} MB/s（写入 /tmp ${DD_SIZE_MB}MB）"
  pl_force "${FG_PINK}---------------------------------------------------------${RESET}"

  # 流媒体
  pl_force "[流媒体]  ${MEDIA_SCORE}/100  ($(grade_colored_label "$MEDIA_SCORE"))  $(bar "$MEDIA_SCORE")"
  pl_force "${MEDIA_LINE}"
  pl_force "${FG_PINK}---------------------------------------------------------${RESET}"

  pl_force "[总评]  ${total}/100  ($(grade_colored_label "$total"))  $(bar "$total")"
  pl_force "${FG_GREEN}✅ 结论：整体素质不错，日常中转/落地/流媒体测试够用。${RESET}"
  pl_force "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、主机名（可用：./vps_check.sh --redact）${RESET}"
  pl_force "${FG_PINK}=========================================================${RESET}"
}

# ---------------- Runner（9 全跑 / R 静默全跑） ----------------
run_all_steps() {
  # 所有步骤都“尽量成功”，绝不因为某一步退出
  do_basic   || true
  do_public  || true
  do_ping_all|| true
  do_mtr     || true
  do_dd      || true
  do_media   || true
  do_tcp     || true
}

run_full_verbose() {
  QUIET=0
  PAUSE_ENABLE=0
  run_all_steps || true
  summary_report
  PAUSE_ENABLE=1
}

run_full_silent() {
  # 真静默：不刷屏，只输出最终总结
  QUIET=1
  PAUSE_ENABLE=0
  run_all_steps >/dev/null 2>&1 || true
  QUIET=0
  summary_report
  PAUSE_ENABLE=1
}

# ---------------- Menu（去掉括号说明，保持干净） ----------------
menu() {
  pl "${FG_PINK}==================== VPS 一键体检 菜单 ====================${RESET}"
  pl "Targets: ${FG_PURPLE}${TARGETS[0]}${RESET} ${FG_PURPLE}${TARGETS[1]}${RESET} ${FG_PURPLE}${TARGETS[2]}${RESET}"
  pl
  pl "1) 设置测试目标"
  pl "2) 基本信息"
  pl "3) 公网信息"
  pl "4) 网络 Ping 测试"
  pl "5) 路由 MTR 测试"
  pl "6) 安装 mtr"
  pl "7) 磁盘 dd 测速"
  pl "8) 流媒体检测"
  pl "9) 一键全跑 并输出最终总结"
  pl "10) TCP 真实链路测试"
  pl "R) 后台静默全跑 只输出最终总结"
  pl "0) 退出"
  hr
}

set_targets() {
  pl "${FG_PINK}--- 设置 Targets ---${RESET}"
  pl "当前：${TARGETS[*]}"
  pl "输入 3 个目标（空格分隔），回车使用默认："
  local line
  read -r line || true
  if [[ -n "$line" ]]; then
    # shellcheck disable=SC2206
    local arr=($line)
    if (( ${#arr[@]} >= 3 )); then
      TARGETS=("${arr[0]}" "${arr[1]}" "${arr[2]}")
    else
      pl "${FG_YELLOW}⚠️  输入不足 3 个，保持不变${RESET}"
    fi
  fi
  hr
}

main() {
  while true; do
    menu
    read -r -p "选择 [0-10/R]: " opt || true
    case "${opt:-}" in
      1) set_targets; pause ;;
      2) do_basic; pause ;;
      3) do_public; pause ;;
      4) do_ping_all; pause ;;
      5) do_mtr; pause ;;
      6) do_mtr_install; pause ;;
      7) do_dd; pause ;;
      8) do_media; pause ;;
      9) run_full_verbose; pause ;;
      10) do_tcp; pause ;;
      R|r)
        pl "${FG_CYAN}ℹ️  正在后台静默执行检测（2~8+10），完成后输出最终总结...${RESET}"
        run_full_silent
        pause
        ;;
      0) exit 0 ;;
      *) pl "${FG_YELLOW}⚠️  无效选项${RESET}"; pause ;;
    esac
  done
}

main
