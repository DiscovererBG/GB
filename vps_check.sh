#!/usr/bin/env bash
# VPS 一键体检（稳定修复版，中文 + 彩色条 + 一键全跑不中断）

set -Eeuo pipefail

# ===== 1) 强制 bash（修复 “bad substitution”）=====
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "❌ 请用 bash 运行，不要用 sh/dash：bash vps_check.sh"
  exit 1
fi

# ===== 2) Locale（尽量避免 ????）=====
if command -v locale >/dev/null 2>&1; then
  if locale -a 2>/dev/null | grep -qi '^c\.utf-8$'; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-8$'; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  fi
fi

# ===== Colors =====
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

# ===== Settings =====
TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")
PING_COUNT=50
MTR_CYCLES=100
DD_SIZE_MB=256

TCP_RANGE_MB=16
TCP_MAXTIME=12
TCP_SOURCES=("cloudflare" "hetzner" "ovh" "cachefly")

# ===== Runtime =====
TMPDIR="/tmp/vps_check.$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

REDACT=0
if [[ "${1:-}" == "--redact" ]]; then
  REDACT=1
fi

# ===== Helpers =====
println() { printf "%b\n" "$*"; }
hr()  { println "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2() { println "${FG_PINK}=========================================================${RESET}"; }
pause(){ read -r -p "回车继续..." _; }
exists(){ command -v "$1" >/dev/null 2>&1; }

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
colored_grade_text() {
  local s="${1:-0}"
  local g; g="$(grade_label "$s")"
  local c; c="$(grade_fg "$s")"
  printf "%b%s%b" "$c" "$g" "$RESET"
}

# 你要的进度条：彩色块 + 灰点（不用 '='）
bar() {
  local score="${1:-0}"
  local width="${2:-28}"
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100
  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))

  local fg; fg="$(grade_fg "$score")"
  local bg; bg="$(grade_bg "$score")"

  printf "%b" "${fg}[${RESET}"
  printf "%b" "${bg}"
  printf "%*s" "$filled" ""
  printf "%b" "${RESET}"
  printf "%b" "${FG_GRAY}${DIM}"
  if (( rest > 0 )); then
    printf "%*s" "$rest" "" | tr ' ' '·'
  fi
  printf "%b" "${RESET}${fg}]${RESET}"
}

median_of_numbers() {
  # stdin: 一列数字，输出中位数（兼容 mawk，不用 asort）
  mapfile -t arr < <(awk 'NF{print $1+0}' | sort -n)
  local n="${#arr[@]}"
  [[ "$n" -eq 0 ]] && { printf ""; return; }
  local mid=$(( n/2 ))
  if (( n % 2 == 1 )); then
    printf "%s" "${arr[$mid]}"
  else
    awk -v a="${arr[$((mid-1))]}" -v b="${arr[$mid]}" 'BEGIN{printf "%.2f", (a+b)/2}'
  fi
}

# 一键全跑：任何一步失败都不中断
safe_step() {
  local title="$1"; shift
  println "${FG_CYAN}ℹ️  开始：${title}${RESET}"
  set +e
  "$@"
  local rc=$?
  set -e
  if (( rc != 0 )); then
    println "${FG_YELLOW}⚠️  ${title}：已跳过/失败（不影响继续）${RESET}"
    return 0
  fi
  return 0
}

# ===== 缓存：保证“基本信息”最终汇总与前面一致 =====
B_HOST=""; B_OS=""; B_KERN=""; B_UPTIME=""; B_VIRT=""; B_CPU=""; B_CORES=""; B_RAM=""; B_SWAP=""; B_DISK=""
P_IPV4=""; P_GEO_CN=""; P_GEO_RAW=""; P_ASN=""; P_ISP=""

PING_WORST_LOSS=""; PING_WORST_AVG=""
PING_GOOD=0; PING_WARN=0; PING_BAD=0

MTR_TARGET=""; MTR_LAST_LOSS=""; MTR_LAST_AVG=""; MTR_SCORE=0

DD_MBPS=""; DD_SCORE=0

MEDIA_SCORE=0
MEDIA_LINE=""

TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
TCP_OK_SAMPLES=0; TCP_BEST_SRC=""
TCP_SCORE=0

# ===== 地区自动识别（国家代码 -> 中文）=====
country_cn() {
  local cc="${1:-}"
  case "$cc" in
    SG) echo "新加坡" ;;
    HK) echo "香港" ;;
    TW) echo "台湾" ;;
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
    RU) echo "俄罗斯" ;;
    TR) echo "土耳其" ;;
    ID) echo "印尼" ;;
    MY) echo "马来西亚" ;;
    TH) echo "泰国" ;;
    VN) echo "越南" ;;
    PH) echo "菲律宾" ;;
    *) echo "" ;;
  esac
}

# ===== 2) 基本信息 =====
do_basic() {
  B_HOST="$(hostname 2>/dev/null || echo "unknown")"
  if [[ -r /etc/os-release ]]; then
    B_OS="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
  else
    B_OS="Linux"
  fi
  B_KERN="$(uname -r 2>/dev/null || echo "unknown")"

  if exists uptime; then
    # 取 “up ...” 部分，尽量简洁
    B_UPTIME="$(uptime -p 2>/dev/null | sed 's/^up[ ]*//')"
    [[ -z "$B_UPTIME" ]] && B_UPTIME="$(uptime 2>/dev/null | sed -n 's/.*up \([^,]*\),.*/\1/p')"
    [[ -z "$B_UPTIME" ]] && B_UPTIME="未知"
  else
    B_UPTIME="未知"
  fi

  if exists systemd-detect-virt; then
    B_VIRT="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "$B_VIRT" ]] && B_VIRT="unknown"
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
  println "主机名   : $(mask_host "$B_HOST")"
  println "系统     : $B_OS"
  println "内核     : $B_KERN"
  println "运行时长 : $B_UPTIME"
  println "虚拟化   : $B_VIRT"
  println "CPU      : $B_CPU（${B_CORES} 核）"
  println "内存/Swap: $B_RAM / $B_SWAP"
  println "磁盘 /   : $B_DISK"
  hr
}

# ===== 3) 公网信息 =====
do_public() {
  P_IPV4="$(curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="unknown"

  # ipinfo：拿 country/city/region/org
  local js cc city region org
  js="$(curl -fsS --max-time 8 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"
  cc="$(printf "%s" "$js" | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
  city="$(printf "%s" "$js" | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
  region="$(printf "%s" "$js" | sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
  org="$(printf "%s" "$js" | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"

  if [[ -n "$org" ]]; then
    P_ASN="$(printf "%s" "$org" | awk '{print $1}')"
    P_ISP="$(printf "%s" "$org" | sed -E 's/^AS[0-9]+[ ]*//')"
  else
    P_ASN="unknown"; P_ISP="unknown"
  fi

  P_GEO_RAW="$(printf "%s, %s" "${city:-unknown}" "${region:-unknown}")"
  local cn
  cn="$(country_cn "$cc")"
  if [[ -n "$cn" ]]; then
    P_GEO_CN="${cn}（${P_GEO_RAW}）"
  else
    P_GEO_CN="${P_GEO_RAW}"
  fi

  println "${FG_PINK}--- 公网信息 ---${RESET}"
  println "IPv4     : $(mask_ipv4 "$P_IPV4")"
  println "地区     : ${P_GEO_CN:-unknown}"
  println "ASN      : ${P_ASN:-unknown}"
  println "运营商   : ${P_ISP:-unknown}"
  hr
}

# ===== 4) Ping（彻底修复：不再 awk 报错，不再出现 loss%）=====
ping_one() {
  local t="$1"
  local out loss min avg max mdev

  out="$(LANG=C ping -c "$PING_COUNT" -q "$t" 2>/dev/null || true)"
  # 丢包：从 “0% packet loss” 提取
  loss="$(printf "%s\n" "$out" | sed -n 's/.* \([0-9.]\+\)% packet loss.*/\1/p' | head -n1)"
  [[ -z "$loss" ]] && loss="未知"

  # RTT：从 “= a/b/c/d ms” 提取
  local rtt
  rtt="$(printf "%s\n" "$out" | sed -n 's/.*=[ ]*\([0-9.]\+\)\/\([0-9.]\+\)\/\([0-9.]\+\)\/\([0-9.]\+\)[ ]*ms.*/\1 \2 \3 \4/p' | head -n1)"
  if [[ -n "$rtt" ]]; then
    read -r min avg max mdev <<<"$rtt"
  else
    min="未知"; avg="未知"; max="未知"; mdev="未知"
  fi

  println "${FG_PURPLE}--- Ping: ${t} (${PING_COUNT} 次) ---${RESET}"
  println "丢包 : ${loss}%"
  println "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  # 评价（只用数字才算）
  local s=0
  if [[ "$loss" != "未知" && "$avg" != "未知" ]]; then
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}' && awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      s=95
    elif awk -v l="$loss" 'BEGIN{exit !(l<=3)}' && awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      s=80
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}' && awk -v a="$avg" 'BEGIN{exit !(a<250)}'; then
      s=65
    else
      s=40
    fi
  fi

  # 丢包提示
  if [[ "$loss" != "未知" ]]; then
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}'; then
      println "${FG_GREEN}✅ 丢包：优秀（≤1%）${RESET}"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}'; then
      println "${FG_YELLOW}⚠️  丢包：一般（≤5%）${RESET}"
    else
      println "${FG_RED}❌ 丢包：偏弱（>5%）${RESET}"
    fi
  fi
  # 延迟提示
  if [[ "$avg" != "未知" ]]; then
    if awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      println "${FG_GREEN}✅ 延迟：优秀（<80ms）${RESET}"
    elif awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      println "${FG_YELLOW}⚠️  延迟：一般（<150ms）${RESET}"
    else
      println "${FG_RED}❌ 延迟：偏弱（≥150ms）${RESET}"
    fi
  fi

  # worst 统计
  if [[ "$loss" != "未知" ]]; then
    [[ -z "$PING_WORST_LOSS" ]] && PING_WORST_LOSS="$loss"
    awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}' && PING_WORST_LOSS="$loss" || true
  fi
  if [[ "$avg" != "未知" ]]; then
    [[ -z "$PING_WORST_AVG" ]] && PING_WORST_AVG="$avg"
    awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}' && PING_WORST_AVG="$avg" || true
  fi

  if (( s >= 90 )); then ((PING_GOOD++))
  elif (( s >= 60 )); then ((PING_WARN++))
  else ((PING_BAD++))
  fi

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

# ===== 6) 安装 mtr（失败不退出）=====
do_mtr_install() {
  println "${FG_CYAN}ℹ️  正在安装 mtr...${RESET}"
  if exists apt-get; then
    # 降低失败概率：重试
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y mtr-tiny >/dev/null 2>&1 && return 0
    apt-get install -y mtr >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ===== 5) MTR =====
do_mtr() {
  local t="${TARGETS[0]}"
  MTR_TARGET="$t"

  if ! exists mtr; then
    println "${FG_YELLOW}⚠️  MTR 未安装/不可用，已跳过${RESET}"
    hr
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    return 0
  fi

  println "${FG_PURPLE}--- MTR: ${t} (${MTR_CYCLES} 轮) ---${RESET}"
  local out
  out="$(mtr -rwzbc "$MTR_CYCLES" "$t" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    println "${FG_YELLOW}⚠️  MTR 执行失败（可能 ICMP 被限制），已跳过${RESET}"
    hr
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    return 0
  fi

  # 打印（保持你原先风格：前几行 + 尾部）
  printf "%s\n" "$out" | sed -n '1,20p'
  if (( $(printf "%s\n" "$out" | wc -l) > 26 )); then
    println "${FG_GRAY}...(中间省略)...${RESET}"
    printf "%s\n" "$out" | tail -n 8
  fi

  # 取最后一跳：最后一行 “x. ...” 的内容
  local lastline loss avg
  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"
  loss="$(printf "%s\n" "$lastline" | awk '{print $(NF-6)}' | tr -d '%')"
  avg="$(printf "%s\n" "$lastline"  | awk '{print $(NF-4)}')"

  if [[ -n "$loss" && -n "$avg" ]]; then
    MTR_LAST_LOSS="$loss"
    MTR_LAST_AVG="$avg"
    # 评分
    if awk -v l="$loss" 'BEGIN{exit !(l<=0.5)}' && awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      MTR_SCORE=95
    elif awk -v l="$loss" 'BEGIN{exit !(l<=2)}' && awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      MTR_SCORE=80
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}' && awk -v a="$avg" 'BEGIN{exit !(a<250)}'; then
      MTR_SCORE=65
    else
      MTR_SCORE=40
    fi
  else
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
  fi

  println
  if [[ "$MTR_LAST_LOSS" != "未知" && "$MTR_LAST_AVG" != "未知" ]]; then
    println "终点（最后一跳）：丢包=${MTR_LAST_LOSS}%  平均=${MTR_LAST_AVG}ms"
  fi
  println "${FG_CYAN}ℹ️  提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。${RESET}"
  if (( MTR_SCORE >= 90 )); then
    println "${FG_GREEN}✅ 路由质量：优秀${RESET}"
  elif (( MTR_SCORE >= 60 )); then
    println "${FG_YELLOW}⚠️  路由质量：一般${RESET}"
  else
    println "${FG_RED}❌ 路由质量：偏弱${RESET}"
  fi
  hr
}

# ===== 7) dd 磁盘（修复解析，避免 0.16MB/s 这种乱值）=====
do_dd() {
  println "${FG_PURPLE}--- 磁盘 dd 测速（写入 /tmp ${DD_SIZE_MB}MB）---${RESET}"
  local file="/tmp/vps_dd_test.$$"
  local out
  out="$(LANG=C dd if=/dev/zero of="$file" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1)"
  rm -f "$file" >/dev/null 2>&1 || true

  # dd 最后一行：... copied, X s, Y MB/s  或  Y GB/s
  local speed unit mbps
  speed="$(printf "%s\n" "$out" | tail -n 1 | sed -n 's/.*,[ ]*\([0-9.]\+\)[ ]*\(kB\/s\|MB\/s\|GB\/s\).*/\1/p')"
  unit="$(printf "%s\n" "$out" | tail -n 1 | sed -n 's/.*,[ ]*\([0-9.]\+\)[ ]*\(kB\/s\|MB\/s\|GB\/s\).*/\2/p')"

  if [[ -z "$speed" || -z "$unit" ]]; then
    println "${FG_YELLOW}⚠️  dd 解析失败，已跳过${RESET}"
    hr
    DD_MBPS=""; DD_SCORE=0
    return 0
  fi

  case "$unit" in
    GB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x*1024}')" ;;
    MB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x}')" ;;
    kB/s) mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x/1024}')" ;;
  esac

  DD_MBPS="$mbps"

  if awk -v x="$mbps" 'BEGIN{exit !(x>=1500)}'; then DD_SCORE=95
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=500)}'; then DD_SCORE=85
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=200)}'; then DD_SCORE=70
  else DD_SCORE=45
  fi

  println "结果：约 ${DD_MBPS} MB/s"
  if (( DD_SCORE >= 90 )); then
    println "${FG_GREEN}✅ 磁盘：优秀（>=1500 MB/s）${RESET}"
  elif (( DD_SCORE >= 75 )); then
    println "${FG_CYAN}✅ 磁盘：良好（>=500 MB/s）${RESET}"
  elif (( DD_SCORE >= 60 )); then
    println "${FG_YELLOW}⚠️  磁盘：一般（>=200 MB/s）${RESET}"
  else
    println "${FG_RED}❌ 磁盘：偏弱（<200 MB/s）${RESET}"
  fi
  hr
}

# ===== 8) 流媒体（best-effort，修复 code 乱拼）=====
curl_code() {
  local url="$1"
  # 只输出 http_code（纯数字），避免 403000 这种拼错
  curl -sS -L --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000"
}

do_media() {
  println "${FG_PURPLE}--- 流媒体解锁检测（best-effort）---${RESET}"

  local yt nf ds tk pv hb
  yt="$(curl_code "https://www.youtube.com/premium")"
  nf="$(curl_code "https://www.netflix.com/")"
  ds="$(curl_code "https://www.disneyplus.com/")"
  tk="$(curl_code "https://www.tiktok.com/")"
  pv="$(curl_code "https://www.primevideo.com/")"
  hb="$(curl_code "https://play.max.com/")"

  # 简单打分：200/3xx算可访问
  local ok=0 total=6
  is_ok() { [[ "$1" =~ ^2|^3 ]]; }

  is_ok "$yt" && ((ok++))
  is_ok "$nf" && ((ok++))
  is_ok "$ds" && ((ok++))
  is_ok "$tk" && ((ok++))
  is_ok "$pv" && ((ok++))
  is_ok "$hb" && ((ok++))

  MEDIA_SCORE=$(( ok * 100 / total ))

  MEDIA_LINE="YouTube=${yt} | Netflix=${nf} | Disney+=${ds} | TikTok=${tk} | Prime=${pv} | Max=${hb}"

  # 输出（尽量不啰嗦）
  if is_ok "$yt"; then println "${FG_GREEN}✅ YouTube: 可访问${RESET}"; else println "${FG_RED}❌ YouTube: 不可用（HTTP $yt）${RESET}"; fi
  if is_ok "$nf"; then println "${FG_GREEN}✅ Netflix: 可访问（最终以登录播放为准）${RESET}"; else println "${FG_RED}❌ Netflix: 不可用（HTTP $nf）${RESET}"; fi
  if is_ok "$ds"; then println "${FG_GREEN}✅ Disney+: 可访问（最终以登录播放为准）${RESET}"; else println "${FG_RED}❌ Disney+: 不可用（HTTP $ds）${RESET}"; fi
  if is_ok "$tk"; then println "${FG_YELLOW}⚠️  TikTok: 可访问但可能受风控/CF影响${RESET}"; else println "${FG_RED}❌ TikTok: 不可用（HTTP $tk）${RESET}"; fi
  if is_ok "$pv"; then println "${FG_GREEN}✅ Prime Video: 可访问（片库看账号地区）${RESET}"; else println "${FG_RED}❌ Prime Video: 不可用（HTTP $pv）${RESET}"; fi
  if is_ok "$hb"; then println "${FG_GREEN}✅ Max(HBO): 可访问（最终以登录播放为准）${RESET}"; else println "${FG_RED}❌ Max(HBO): 不可用（HTTP $hb）${RESET}"; fi

  println "${FG_CYAN}ℹ️  提示：Netflix/Disney+/Max/Prime 仅能判断“可访问/疑似受限”，最终以登录播放为准。${RESET}"
  hr
}

# ===== 10) TCP 真链路（多源取中位数；source 失败/超时会跳过；输出全中文）=====
tcp_url_of() {
  local src="$1"
  case "$src" in
    cloudflare) echo "https://speed.cloudflare.com/__down?bytes=$((TCP_RANGE_MB*1024*1024))" ;;
    hetzner)    echo "https://speed.hetzner.de/100MB.bin" ;;
    ovh)        echo "https://proof.ovh.net/files/100Mb.dat" ;;
    cachefly)   echo "https://speedtest.cachefly.net/100mb.test" ;;
    *) echo "" ;;
  esac
}

tcp_test_one() {
  local src="$1"
  local url; url="$(tcp_url_of "$src")"
  [[ -z "$url" ]] && return 1

  # TLS/TTFB/速度：用 curl 的 time_* + speed_download
  local line tls ttfb sp code
  line="$(curl -sS -L --max-time "$TCP_MAXTIME" \
    -o /dev/null \
    -w '%{http_code} %{time_appconnect} %{time_starttransfer} %{speed_download}' \
    "$url" 2>/dev/null || true)"

  code="$(awk '{print $1}' <<<"$line")"
  tls="$(awk '{print $2}' <<<"$line")"
  ttfb="$(awk '{print $3}' <<<"$line")"
  sp="$(awk '{print $4}' <<<"$line")"

  # 必须有 code 且是 2xx/3xx，并且 speed 有值
  if [[ ! "$code" =~ ^2|^3 ]] || [[ -z "${sp:-}" ]]; then
    return 1
  fi

  # 秒 -> ms
  local tls_ms ttfb_ms mbps
  tls_ms="$(awk -v x="$tls"  'BEGIN{printf "%.0f", x*1000}')"
  ttfb_ms="$(awk -v x="$ttfb" 'BEGIN{printf "%.0f", x*1000}')"
  mbps="$(awk -v x="$sp" 'BEGIN{printf "%.2f", (x*8)/1000000}')"

  printf "%s %s %s %s\n" "$src" "$tls_ms" "$ttfb_ms" "$mbps"
  return 0
}

do_tcp() {
  println "${FG_PURPLE}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${RESET}"
  println "${FG_CYAN}范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速${RESET}"

  local ok=0
  : >"$TMPDIR/tcp_tls"
  : >"$TMPDIR/tcp_ttfb"
  : >"$TMPDIR/tcp_dl"

  TCP_BEST_SRC=""
  local best_dl=0

  for src in "${TCP_SOURCES[@]}"; do
    local r
    r="$(tcp_test_one "$src" || true)"
    if [[ -z "$r" ]]; then
      println "• ${FG_GRAY}${src}: 失败/超时（跳过）${RESET}"
      continue
    fi
    ok=$((ok+1))
    local s tlsms ttfbms dl
    s="$(awk '{print $1}' <<<"$r")"
    tlsms="$(awk '{print $2}' <<<"$r")"
    ttfbms="$(awk '{print $3}' <<<"$r")"
    dl="$(awk '{print $4}' <<<"$r")"

    printf "%s\n" "$tlsms"  >>"$TMPDIR/tcp_tls"
    printf "%s\n" "$ttfbms" >>"$TMPDIR/tcp_ttfb"
    printf "%s\n" "$dl"     >>"$TMPDIR/tcp_dl"

    # best
    if awk -v a="$dl" -v b="$best_dl" 'BEGIN{exit !(a>b)}'; then
      best_dl="$dl"
      TCP_BEST_SRC="$s"
    fi

    println "• ${FG_GREEN}${s}${RESET}: TLS=${tlsms}ms  TTFB=${ttfbms}ms  下载=${dl}Mbps"
  done

  TCP_OK_SAMPLES="$ok"
  if (( ok == 0 )); then
    println "${FG_YELLOW}⚠️  TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。${RESET}"
    hr
    TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
    TCP_SCORE=0
    return 0
  fi

  TCP_TLS_MS="$(median_of_numbers <"$TMPDIR/tcp_tls")"
  TCP_TTFB_MS="$(median_of_numbers <"$TMPDIR/tcp_ttfb")"
  TCP_DL_MBPS="$(median_of_numbers <"$TMPDIR/tcp_dl")"

  println
  println "${FG_CYAN}中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳源=${TCP_BEST_SRC:-unknown} ${best_dl}Mbps）${RESET}"

  # 评分（按下载+TTFB粗略）
  local s=0
  if awk -v d="$TCP_DL_MBPS" 'BEGIN{exit !(d>=200)}' && awk -v t="$TCP_TTFB_MS" 'BEGIN{exit !(t<=500)}'; then
    s=90
  elif awk -v d="$TCP_DL_MBPS" 'BEGIN{exit !(d>=50)}' && awk -v t="$TCP_TTFB_MS" 'BEGIN{exit !(t<=1200)}'; then
    s=75
  elif awk -v d="$TCP_DL_MBPS" 'BEGIN{exit !(d>=10)}'; then
    s=65
  else
    s=40
  fi
  TCP_SCORE="$s"

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

# ===== 汇总（修复：优秀/良好/一般/偏弱有颜色；基本信息一致；条形显示正确）=====
summary() {
  hr2
  println "✅ ${FG_PINK}VPS 体检总结报告${RESET}"
  hr2

  println "${FG_PINK}[基础信息]${RESET}"
  println "Host : $(mask_host "$B_HOST")"
  println "OS   : $B_OS"
  println "Kern : $B_KERN | Virt=$B_VIRT"
  println "CPU  : $B_CPU | 核数=$B_CORES | 内存=$B_RAM | Swap=$B_SWAP"
  println "Disk : / $B_DISK"
  println "IPv4 : $(mask_ipv4 "$P_IPV4")"
  println "地区 : ${P_GEO_CN:-unknown}"
  println "ASN  : ${P_ASN:-unknown}"
  println "运营商: ${P_ISP:-unknown}"
  hr

  # 网络评分：以 ping+ mtr 简化合成
  local net_score=0
  # ping：优=95 一般=70 偏弱=40
  local ping_score=0
  if (( PING_GOOD+PING_WARN+PING_BAD > 0 )); then
    ping_score=$(( (PING_GOOD*95 + PING_WARN*70 + PING_BAD*40) / (PING_GOOD+PING_WARN+PING_BAD) ))
  fi
  if (( MTR_SCORE > 0 )); then
    net_score=$(( (ping_score*60 + MTR_SCORE*40) / 100 ))
  else
    net_score="$ping_score"
  fi

  println "${FG_PINK}[网络]${RESET}  ${net_score}/100（$(colored_grade_text "$net_score")）  $(bar "$net_score")"
  println "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% | 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  if (( MTR_SCORE > 0 )); then
    println "MTR  : 目标=${MTR_TARGET:-unknown} | 终点丢包=${MTR_LAST_LOSS:-未知}% | 终点平均=${MTR_LAST_AVG:-未知}ms | 评级=$(colored_grade_text "$MTR_SCORE")"
  else
    println "MTR  : 未测试/不可用"
  fi
  hr

  println "${FG_PINK}[TCP真实链路]${RESET}  ${TCP_SCORE:-0}/100（$(colored_grade_text "${TCP_SCORE:-0}")）  $(bar "${TCP_SCORE:-0}")"
  if [[ -n "${TCP_DL_MBPS:-}" ]]; then
    println "TLS  : ${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms"
    println "下载 : ${TCP_DL_MBPS}Mbps（中位数，${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
    println "样本 : ${TCP_OK_SAMPLES} 个 | 最佳源=${TCP_BEST_SRC:-unknown}"
  else
    println "TLS  : 未知"
    println "下载 : 未知"
  fi
  hr

  println "${FG_PINK}[磁盘]${RESET}  ${DD_SCORE}/100（$(colored_grade_text "$DD_SCORE")）  $(bar "$DD_SCORE")"
  if [[ -n "${DD_MBPS:-}" ]]; then
    println "dd   : 约 ${DD_MBPS} MB/s（写入 /tmp ${DD_SIZE_MB}MB）"
  else
    println "dd   : 未测试/不可用"
  fi
  hr

  println "${FG_PINK}[流媒体]${RESET}  ${MEDIA_SCORE}/100（$(colored_grade_text "$MEDIA_SCORE")）  $(bar "$MEDIA_SCORE")"
  println "$MEDIA_LINE"
  hr

  # 总评：网络30 + TCP30 + 磁盘20 + 流媒体20
  local total=$(( net_score*30/100 + TCP_SCORE*30/100 + DD_SCORE*20/100 + MEDIA_SCORE*20/100 ))
  println "${FG_PINK}[总评]${RESET}  ${total}/100（$(colored_grade_text "$total")）  $(bar "$total")"
  if (( total >= 80 )); then
    println "${FG_GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${RESET}"
  elif (( total >= 60 )); then
    println "${FG_CYAN}✅ 结论：整体不错，日常中转/落地够用，关注路由与邻居波动。${RESET}"
  else
    println "${FG_YELLOW}⚠️  结论：整体一般，建议多测不同时间段，必要时换机房/线路。${RESET}"
  fi

  println
  println "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${RESET}"
  hr2
}

# ===== 菜单 =====
menu() {
  println "${FG_PINK}================ VPS 一键体检 菜单 ================${RESET}"
  println "Targets: ${TARGETS[*]}"
  println
  println "1) 设置测试目标"
  println "2) 基本信息"
  println "3) 公网信息"
  println "4) 网络 Ping 测试"
  println "5) 路由 MTR 测试"
  println "6) 安装 mtr"
  println "7) 磁盘 dd 测速"
  println "8) 流媒体检测"
  println "9) 一键全跑 并输出最终总结"
  println "10) TCP 真实链路测试"
  println "R) 后台静默全跑 只输出最终总结"
  println "0) 退出"
  hr
}

set_targets() {
  println "${FG_CYAN}当前 Targets：${TARGETS[*]}${RESET}"
  read -r -p "请输入新的 Targets（空格分隔，例如：1.1.1.1 8.8.8.8 www.google.com）: " line || true
  if [[ -n "${line// /}" ]]; then
    read -r -a TARGETS <<<"$line"
    println "${FG_GREEN}✅ 已更新 Targets：${TARGETS[*]}${RESET}"
  else
    println "${FG_YELLOW}⚠️ 未修改${RESET}"
  fi
  hr
}

run_all() {
  safe_step "基本信息" do_basic
  safe_step "公网信息" do_public
  safe_step "Ping 测试" do_ping_all
  safe_step "MTR 测试" do_mtr
  safe_step "磁盘 dd 测速" do_dd
  safe_step "流媒体检测" do_media
  safe_step "TCP 真实链路" do_tcp
  safe_step "输出总结" summary
}

run_all_quiet() {
  # “静默”只是不刷分段提示，仍会输出最终总结
  do_basic || true
  do_public || true
  do_ping_all || true
  do_mtr || true
  do_dd || true
  do_media || true
  do_tcp || true
  summary || true
}

# ===== 主循环 =====
while true; do
  menu
  read -r -p "选择 [0-10/R]: " c || true
  case "${c^^}" in
    1) set_targets; pause ;;
    2) do_basic; pause ;;
    3) do_public; pause ;;
    4) do_ping_all; pause ;;
    5) do_mtr; pause ;;
    6)
      if do_mtr_install; then
        println "${FG_GREEN}✅ mtr 安装成功${RESET}"
      else
        println "${FG_RED}❌ mtr 安装失败（可手动：apt-get update && apt-get install -y mtr-tiny）${RESET}"
      fi
      hr
      pause
      ;;
    7) do_dd; pause ;;
    8) do_media; pause ;;
    9) run_all; pause ;;
    10) do_tcp; pause ;;
    R) run_all_quiet; pause ;;
    0) exit 0 ;;
    *) println "${FG_YELLOW}⚠️  输入无效${RESET}"; pause ;;
  esac
done
