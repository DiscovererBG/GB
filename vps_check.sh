#!/usr/bin/env bash
# =========================================================
# VPS 一键体检（稳定修复版）
# - 一键全跑(9)不再中途退出
# - 进度条：彩色块 + 灰点（不用 '='，不用 '·' 防止 ????）
# - Ping 解析修复：不再出现 loss% / min=mdev 错位
# - dd 解析修复：不再把耗时当速度（0.16MB/s 那种）
# - TCP 多源中位数：不依赖 gawk asort（兼容 mawk）
# - ANSI 残留修复：不再出现 \033[0m
# - 公网地区：自动识别国家（中文）
# =========================================================

set -u -o pipefail

# ---------- UTF8/Locale（尽量不乱码） ----------
if command -v locale >/dev/null 2>&1; then
  if locale -a 2>/dev/null | grep -qi '^C\.UTF-8$'; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  elif locale -a 2>/dev/null | grep -qi '^en_US\.utf-8$'; then
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  else
    export LANG=C LC_ALL=C
  fi
else
  export LANG=C LC_ALL=C
fi

# ---------- 颜色（仅 TTY 才输出彩色，避免把转义符打到文件里） ----------
IS_TTY=0
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then IS_TTY=1; fi

ESC=$'\033'
RESET=""; BOLD=""; DIM=""
FG_PINK=""; FG_PURPLE=""; FG_CYAN=""; FG_GREEN=""; FG_YELLOW=""; FG_RED=""; FG_GRAY=""; FG_WHITE=""
BG_GREEN=""; BG_CYAN=""; BG_YELLOW=""; BG_RED=""; BG_GRAY=""

if [[ "$IS_TTY" -eq 1 ]]; then
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
fi

# ---------- Settings ----------
TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")
PING_COUNT=50
MTR_CYCLES=100
DD_SIZE_MB=256

TCP_RANGE_MB=16
TCP_MAXTIME=12
TCP_SOURCES=("cloudflare" "hetzner" "ovh" "cachefly")

TMPDIR="/tmp/vps_check.$$"
mkdir -p "$TMPDIR"
cleanup(){ rm -rf "$TMPDIR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

REDACT=0
if [[ "${1:-}" == "--redact" ]]; then REDACT=1; fi

# ---------- Helpers ----------
say(){ printf "%b\n" "$*"; }
hr(){ say "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2(){ say "${FG_PINK}=========================================================${RESET}"; }

exists(){ command -v "$1" >/dev/null 2>&1; }

mask_ipv4(){
  local ip="${1:-}"
  if [[ "$REDACT" -eq 0 ]]; then printf "%s" "${ip:-unknown}"; return; fi
  printf "%s" "$ip" | awk -F. 'NF==4{print $1"."$2".*.*"; next}{print "*.*.*.*"}'
}
mask_host(){
  local h="${1:-unknown}"
  if [[ "$REDACT" -eq 0 ]]; then printf "%s" "$h"; return; fi
  printf "%s" "$h" | sed -E 's/^(.).*(.)$/\1***\2/'
}

f1(){ awk -v x="${1:-0}" 'BEGIN{printf "%.1f", x+0}'; }
f2(){ awk -v x="${1:-0}" 'BEGIN{printf "%.2f", x+0}'; }

grade_label(){
  local s="${1:-0}"
  if (( s >= 90 )); then printf "优秀"; return; fi
  if (( s >= 75 )); then printf "良好"; return; fi
  if (( s >= 60 )); then printf "一般"; return; fi
  printf "偏弱"
}
grade_fg(){
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$FG_GREEN"; return; fi
  if (( s >= 75 )); then printf "%s" "$FG_CYAN"; return; fi
  if (( s >= 60 )); then printf "%s" "$FG_YELLOW"; return; fi
  printf "%s" "$FG_RED"
}
grade_bg(){
  local s="${1:-0}"
  if (( s >= 90 )); then printf "%s" "$BG_GREEN"; return; fi
  if (( s >= 75 )); then printf "%s" "$BG_CYAN"; return; fi
  if (( s >= 60 )); then printf "%s" "$BG_YELLOW"; return; fi
  printf "%s" "$BG_RED"
}

# 进度条：彩色块（背景色空格）+ 灰点（ASCII '.' 防止 ????）
bar(){
  local score="${1:-0}" width="${2:-28}"
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100
  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))
  local fg bg
  fg="$(grade_fg "$score")"
  bg="$(grade_bg "$score")"

  printf "%b" "${fg}[${RESET}"
  # filled
  printf "%b" "${bg}"
  printf "%*s" "$filled" ""
  printf "%b" "${RESET}"
  # rest: gray '.' (ASCII)
  printf "%b" "${FG_GRAY}${DIM}"
  if (( rest > 0 )); then
    printf "%*s" "$rest" "" | tr ' ' '.'
  fi
  printf "%b" "${RESET}${fg}]${RESET}"
}

median_of_list(){
  # stdin numbers -> median
  local arr n mid a b
  mapfile -t arr < <(awk 'NF{print $1}' | sort -n)
  n="${#arr[@]}"
  if (( n == 0 )); then printf ""; return 0; fi
  mid=$(( n / 2 ))
  if (( n % 2 == 1 )); then
    printf "%s" "${arr[$mid]}"
  else
    a="${arr[$((mid-1))]}"; b="${arr[$mid]}"
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f", (a+b)/2}'
  fi
}

# 国家码 -> 中文
country_zh(){
  local cc="${1:-}"
  cc="${cc^^}"
  case "$cc" in
    SG) echo "新加坡";;
    HK) echo "中国香港";;
    TW) echo "中国台湾";;
    MO) echo "中国澳门";;
    JP) echo "日本";;
    KR) echo "韩国";;
    US) echo "美国";;
    GB|UK) echo "英国";;
    DE) echo "德国";;
    FR) echo "法国";;
    NL) echo "荷兰";;
    CA) echo "加拿大";;
    AU) echo "澳大利亚";;
    IN) echo "印度";;
    ID) echo "印度尼西亚";;
    MY) echo "马来西亚";;
    TH) echo "泰国";;
    VN) echo "越南";;
    PH) echo "菲律宾";;
    RU) echo "俄罗斯";;
    TR) echo "土耳其";;
    BR) echo "巴西";;
    MX) echo "墨西哥";;
    ES) echo "西班牙";;
    IT) echo "意大利";;
    SE) echo "瑞典";;
    NO) echo "挪威";;
    FI) echo "芬兰";;
    CH) echo "瑞士";;
    AT) echo "奥地利";;
    PL) echo "波兰";;
    CZ) echo "捷克";;
    IL) echo "以色列";;
    AE) echo "阿联酋";;
    SA) echo "沙特";;
    *) echo "${cc:-未知}";;
  esac
}

# ---------- 数据缓存 ----------
B_HOST=""; B_OS=""; B_KERN=""; B_UPTIME=""; B_VIRT=""; B_CPU=""; B_CORES=""; B_RAM=""; B_SWAP=""; B_DISK=""
P_IPV4=""; P_CITY=""; P_REGION=""; P_COUNTRY=""; P_COUNTRY_ZH=""; P_ASN=""; P_ISP=""; P_GEO_ZH=""

PING_WORST_LOSS=""; PING_WORST_AVG=""
PING_GOOD=0; PING_WARN=0; PING_BAD=0

MTR_TARGET=""; MTR_LAST_LOSS=""; MTR_LAST_AVG=""; MTR_SCORE=0

DD_MBPS=""; DD_SCORE=0

MEDIA_SCORE=0; MEDIA_LINE=""

TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
TCP_OK_SAMPLES=0; TCP_BEST_SRC=""
TCP_SCORE=0

# ---------- Step Runner：保证 9 全跑不会中断 ----------
run_step(){
  # run_step "标题" func_name
  local title="$1" fn="$2"
  say "${FG_CYAN}ℹ️  开始：${title}${RESET}"
  if "$fn" >/dev/null 2>&1; then
    return 0
  else
    # 失败也不中断
    say "${FG_YELLOW}⚠️  ${title}：失败/跳过（不中断）${RESET}"
    return 0
  fi
}

# ---------- 基本信息 ----------
do_basic(){
  B_HOST="$(hostname 2>/dev/null || echo "unknown")"
  if [[ -r /etc/os-release ]]; then
    B_OS="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
  else
    B_OS="Linux"
  fi
  B_KERN="$(uname -r 2>/dev/null || echo "unknown")"
  B_UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //')"
  if [[ -z "$B_UPTIME" ]]; then B_UPTIME="$(awk '{print int($1/3600)"h"}' /proc/uptime 2>/dev/null || echo "unknown")"; fi

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

  say "${FG_PINK}--- 基本信息 ---${RESET}"
  say "主机名   : $(mask_host "$B_HOST")"
  say "系统     : $B_OS"
  say "内核     : $B_KERN"
  say "运行时长 : ${B_UPTIME:-unknown}"
  say "虚拟化   : $B_VIRT"
  say "CPU      : $B_CPU（${B_CORES} 核）"
  say "内存/Swap: $B_RAM / $B_SWAP"
  say "磁盘 /   : $B_DISK"
  hr
}

# ---------- 公网信息 ----------
do_public(){
  P_IPV4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"

  P_CITY=""; P_REGION=""; P_COUNTRY=""; P_ASN=""; P_ISP=""
  if [[ -n "$P_IPV4" ]]; then
    local js org
    js="$(curl -fsS --max-time 8 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"
    if [[ -n "$js" ]]; then
      P_CITY="$(printf "%s" "$js" | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      P_REGION="$(printf "%s" "$js" | sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      P_COUNTRY="$(printf "%s" "$js" | sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      org="$(printf "%s" "$js" | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
      P_ASN="$(printf "%s" "$org" | awk '{print $1}')"
      P_ISP="$(printf "%s" "$org" | sed -E 's/^AS[0-9]+[ ]*//')"
    fi
  fi

  P_COUNTRY_ZH="$(country_zh "$P_COUNTRY")"
  if [[ -n "${P_CITY}${P_REGION}" ]]; then
    P_GEO_ZH="${P_COUNTRY_ZH} (${P_CITY:-unknown}, ${P_REGION:-unknown})"
  else
    P_GEO_ZH="${P_COUNTRY_ZH}"
  fi

  say "${FG_PINK}--- 公网信息 ---${RESET}"
  say "IPv4   : $(mask_ipv4 "${P_IPV4:-unknown}")"
  say "地区   : ${P_GEO_ZH:-未知}"
  say "ASN    : ${P_ASN:-unknown}"
  say "运营商 : ${P_ISP:-unknown}"
  hr
}

# ---------- Ping ----------
parse_ping_loss(){
  # stdin ping output -> loss number (e.g. 0.0)
  # 强制匹配 “% packet loss”
  awk '
    match($0, /([0-9.]+)%[ ]*packet loss/, m){print m[1]; exit}
  '
}
parse_ping_rtt(){
  # stdin ping output -> "min avg max mdev"
  awk '
    /rtt|round-trip/{
      split($0, a, "=")
      gsub(/^[ \t]+/, "", a[2])
      gsub(/[ \t]*ms.*/, "", a[2])
      split(a[2], b, "/")
      if (length(b[1]) && length(b[2]) && length(b[3]) && length(b[4])) {
        print b[1], b[2], b[3], b[4]
      }
      exit
    }
  '
}

ping_one(){
  local t="$1" out loss min avg max mdev
  out="$(LANG=C ping -n -c "$PING_COUNT" -q "$t" 2>/dev/null || true)"

  loss="$(printf "%s\n" "$out" | parse_ping_loss || true)"
  read -r min avg max mdev < <(printf "%s\n" "$out" | parse_ping_rtt || true)

  [[ -z "$loss" ]] && loss="未知"
  [[ -z "${avg:-}" ]] && avg="未知"
  [[ -z "${min:-}" ]] && min="未知"
  [[ -z "${max:-}" ]] && max="未知"
  [[ -z "${mdev:-}" ]] && mdev="-"

  say "${FG_PURPLE}--- Ping: ${t} (${PING_COUNT} 次) ---${RESET}"
  if [[ "$loss" == "未知" ]]; then
    say "丢包 : 未知"
  else
    say "丢包 : ${loss}%"
  fi
  say "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  # 评分
  local s=0
  if [[ "$loss" == "未知" || "$avg" == "未知" ]]; then
    s=40
  else
    # 丢包优先
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

  # 标签输出
  if [[ "$loss" != "未知" ]]; then
    if awk -v l="$loss" 'BEGIN{exit !(l<=1)}'; then
      say "${FG_GREEN}✅ 丢包：优秀（≤1%）${RESET}"
    elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}'; then
      say "${FG_YELLOW}⚠️  丢包：一般（≤5%）${RESET}"
    else
      say "${FG_RED}❌ 丢包：偏弱（>5%）${RESET}"
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
      say "${FG_GREEN}✅ 延迟：优秀（<80ms）${RESET}"
    elif awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
      say "${FG_YELLOW}⚠️  延迟：一般（<150ms）${RESET}"
    else
      say "${FG_RED}❌ 延迟：偏弱（≥150ms）${RESET}"
    fi
  fi

  # worst
  if [[ "$loss" != "未知" ]]; then
    if [[ -z "$PING_WORST_LOSS" ]]; then
      PING_WORST_LOSS="$loss"
    else
      awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}' && PING_WORST_LOSS="$loss"
    fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if [[ -z "$PING_WORST_AVG" ]]; then
      PING_WORST_AVG="$avg"
    else
      awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}' && PING_WORST_AVG="$avg"
    fi
  fi

  if (( s >= 90 )); then ((PING_GOOD++)); elif (( s >= 60 )); then ((PING_WARN++)); else ((PING_BAD++)); fi
  hr
}

do_ping_all(){
  PING_WORST_LOSS=""; PING_WORST_AVG=""
  PING_GOOD=0; PING_WARN=0; PING_BAD=0
  for t in "${TARGETS[@]}"; do
    ping_one "$t"
  done
  say "${FG_CYAN}ℹ️  Ping 小结：目标数=${#TARGETS[@]} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% 最差平均延迟=${PING_WORST_AVG:-未知}ms${RESET}"
  hr
}

# ---------- MTR ----------
do_mtr_install(){
  say "${FG_CYAN}ℹ️  正在安装 mtr...${RESET}"
  if ! exists apt-get; then
    say "${FG_RED}❌ 当前系统无 apt-get，无法自动安装 mtr${RESET}"
    hr
    return 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true

  # 依次尝试
  if apt-get install -y mtr-tiny >/dev/null 2>&1; then
    :
  elif apt-get install -y mtr >/dev/null 2>&1; then
    :
  else
    say "${FG_RED}❌ mtr 安装失败（你可以手动执行：apt-get update && apt-get install -y mtr-tiny）${RESET}"
    hr
    return 1
  fi

  if exists mtr; then
    say "${FG_GREEN}✅ mtr 安装成功：$(mtr --version 2>/dev/null | head -n1)${RESET}"
    hr
    return 0
  else
    say "${FG_RED}❌ mtr 安装后仍不可用${RESET}"
    hr
    return 1
  fi
}

do_mtr(){
  local t="${TARGETS[0]}"
  MTR_TARGET="$t"
  if ! exists mtr; then
    say "${FG_YELLOW}⚠️  MTR 未安装/不可用，跳过（可选 6 安装）${RESET}"
    hr
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=40
    return 1
  fi

  say "${FG_PURPLE}--- MTR: ${t} (${MTR_CYCLES} 轮) ---${RESET}"
  local out lastline loss avg
  out="$(LANG=C mtr -rwzbc "$MTR_CYCLES" "$t" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    say "${FG_YELLOW}⚠️  MTR 执行失败（可能被限制 ICMP）${RESET}"
    hr
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=40
    return 1
  fi

  # 显示前 20 行 + 末 8 行（中间省略）
  printf "%s\n" "$out" | sed -n '1,20p'
  if (( $(printf "%s\n" "$out" | wc -l) > 30 )); then
    say "${FG_GRAY}...(中间省略)...${RESET}"
    printf "%s\n" "$out" | tail -n 8
  fi

  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"
  loss="$(printf "%s\n" "$lastline" | awk '{print $(NF-6)}' | tr -d '%' )"
  avg="$(printf "%s\n" "$lastline" | awk '{print $(NF-4)}')"

  if [[ -z "$loss" || -z "$avg" ]]; then
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=40
    say "${FG_YELLOW}⚠️  终点数据解析失败（格式差异/ICMP 限速）${RESET}"
    hr
    return 1
  fi

  MTR_LAST_LOSS="$(f1 "$loss")"
  MTR_LAST_AVG="$(f1 "$avg")"

  if awk -v l="$loss" 'BEGIN{exit !(l<=0.5)}' && awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then
    MTR_SCORE=95
  elif awk -v l="$loss" 'BEGIN{exit !(l<=2)}' && awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then
    MTR_SCORE=80
  elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}' && awk -v a="$avg" 'BEGIN{exit !(a<250)}'; then
    MTR_SCORE=65
  else
    MTR_SCORE=40
  fi

  say
  say "终点（最后一跳）：丢包=${MTR_LAST_LOSS}%  平均=${MTR_LAST_AVG}ms"
  say "${FG_CYAN}ℹ️  提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。${RESET}"
  hr
}

# ---------- Disk dd ----------
do_dd(){
  say "${FG_PURPLE}--- 磁盘快速测试（dd 写入 ${DD_SIZE_MB}MB 到 /tmp）---${RESET}"
  local out last speed unit mbps
  # 注意：写入 /tmp（你原菜单就是写入 /tmp）
  out="$(LANG=C dd if=/dev/zero of="$TMPDIR/dd_test" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1 || true)"
  rm -f "$TMPDIR/dd_test" >/dev/null 2>&1 || true

  last="$(printf "%s\n" "$out" | tail -n 1)"
  # 末尾通常是：..., 0.163794 s, 1.6 GB/s
  speed="$(printf "%s\n" "$last" | awk '{print $(NF-1)}')"
  unit="$(printf "%s\n" "$last" | awk '{print $NF}')"

  if [[ -z "$speed" || -z "$unit" ]]; then
    DD_MBPS=""
    DD_SCORE=40
    say "${FG_RED}❌ dd 测试失败（无法解析速度）${RESET}"
    hr
    return 1
  fi

  if [[ "$unit" == "GB/s" ]]; then
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x*1024}')"
  else
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f", x}')"
  fi
  DD_MBPS="$mbps"

  # 评分
  if awk -v x="$mbps" 'BEGIN{exit !(x>=1500)}'; then
    DD_SCORE=90
    say "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    say "${FG_GREEN}✅ 磁盘：优秀（>=1500 MB/s）${RESET}"
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=500)}'; then
    DD_SCORE=80
    say "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    say "${FG_CYAN}✅ 磁盘：良好（>=500 MB/s）${RESET}"
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=200)}'; then
    DD_SCORE=65
    say "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    say "${FG_YELLOW}⚠️  磁盘：一般（>=200 MB/s）${RESET}"
  else
    DD_SCORE=40
    say "结果：${speed} ${unit}（约 ${mbps} MB/s）"
    say "${FG_RED}❌ 磁盘：偏弱（<200 MB/s）${RESET}"
  fi
  hr
}

# ---------- 流媒体（best-effort 简版，稳定不误判重定向） ----------
http_code(){
  # url -> code (follow redirect)
  curl -fsSL -o /dev/null -w "%{http_code}" --max-time 8 "$1" 2>/dev/null || echo "000"
}

do_media(){
  say "${FG_PURPLE}--- 流媒体解锁检测（best-effort）---${RESET}"

  local yt nf ds tk pr mx score=0
  # 这些检测只做“可访问/疑似限制”，最终以登录播放为准
  yt="$(http_code "https://www.youtube.com/premium")"
  nf="$(http_code "https://www.netflix.com/title/81215567")"
  ds="$(http_code "https://www.disneyplus.com/")"
  tk="$(http_code "https://www.tiktok.com/")"
  pr="$(http_code "https://www.primevideo.com/")"
  mx="$(http_code "https://play.max.com/")"

  # YouTube
  if [[ "$yt" == "200" || "$yt" == "302" || "$yt" == "301" ]]; then
    say "${FG_GREEN}✅ YouTube：可访问${RESET}"
    score=$((score+15))
  else
    say "${FG_RED}❌ YouTube：不可用（HTTP $yt）${RESET}"
  fi

  # Netflix
  if [[ "$nf" == "200" || "$nf" == "302" || "$nf" == "301" ]]; then
    say "${FG_GREEN}✅ Netflix：可访问（最终以登录播放为准）${RESET}"
    score=$((score+15))
  else
    say "${FG_RED}❌ Netflix：不可用（HTTP $nf）${RESET}"
  fi

  # Disney+
  if [[ "$ds" == "200" || "$ds" == "302" || "$ds" == "301" ]]; then
    say "${FG_GREEN}✅ Disney+：可访问（最终以登录播放为准）${RESET}"
    score=$((score+15))
  else
    say "${FG_RED}❌ Disney+：不可用（HTTP $ds）${RESET}"
  fi

  # TikTok
  if [[ "$tk" == "200" || "$tk" == "302" || "$tk" == "301" ]]; then
    say "${FG_YELLOW}⚠️  TikTok：可访问但易受风控/Cloudflare 影响（建议多测几次）${RESET}"
    score=$((score+10))
  else
    say "${FG_RED}❌ TikTok：不可用（HTTP $tk）${RESET}"
  fi

  # Prime
  if [[ "$pr" == "200" || "$pr" == "302" || "$pr" == "301" ]]; then
    say "${FG_GREEN}✅ Prime Video：可访问（片库看账号地区）${RESET}"
    score=$((score+15))
  else
    say "${FG_RED}❌ Prime Video：不可用（HTTP $pr）${RESET}"
  fi

  # Max
  if [[ "$mx" == "200" || "$mx" == "302" || "$mx" == "301" ]]; then
    say "${FG_GREEN}✅ Max(HBO)：可访问（最终以登录播放为准）${RESET}"
    score=$((score+15))
  else
    say "${FG_RED}❌ Max(HBO)：不可用（HTTP $mx）${RESET}"
  fi

  MEDIA_SCORE=$(( score * 100 / 85 ))
  (( MEDIA_SCORE > 100 )) && MEDIA_SCORE=100
  MEDIA_LINE="YouTube=${yt} | Netflix=${nf} | Disney+=${ds} | TikTok=${tk} | Prime=${pr} | Max=${mx}"

  say "${FG_CYAN}ℹ️  提示：Netflix/Disney+/Max/Prime 只能判断“可访问/疑似限制”，最终以登录播放为准。${RESET}"
  hr
}

# ---------- TCP 多源真实链路（curl 取 TLS/TTFB/速度，取中位数） ----------
tcp_url_of(){
  case "$1" in
    cloudflare) echo "https://speed.cloudflare.com/__down?bytes=$((TCP_RANGE_MB*1024*1024))" ;;
    hetzner)    echo "https://speed.hetzner.de/100MB.bin" ;;
    ovh)        echo "https://proof.ovh.net/files/100Mb.dat" ;;
    cachefly)   echo "https://cachefly.cachefly.net/100mb.test" ;;
    *)          echo "" ;;
  esac
}

tcp_test_one(){
  # src -> output: "src tls_ms ttfb_ms dl_mbps http_code ok(0/1)"
  local src="$1" url code t_app t_ttfb spd dl_mbps tls_ms ttfb_ms
  url="$(tcp_url_of "$src")"
  [[ -z "$url" ]] && echo "$src 0 0 0 000 0" && return 0

  # hetzner/ovh/cachefly：用 Range 取 16MB，避免跑满
  local range_end=$((TCP_RANGE_MB*1024*1024 - 1))
  local range_arg=()
  case "$src" in
    hetzner|ovh|cachefly) range_arg=(-r "0-${range_end}") ;;
    *) range_arg=() ;;
  esac

  # curl 输出：time_appconnect time_starttransfer speed_download http_code
  read -r t_app t_ttfb spd code < <(
    curl -L -sS -o /dev/null "${range_arg[@]}" \
      --connect-timeout 6 --max-time "$TCP_MAXTIME" \
      -w "%{time_appconnect} %{time_starttransfer} %{speed_download} %{http_code}" \
      "$url" 2>/dev/null || echo "0 0 0 000"
  )

  if [[ "$code" == "200" || "$code" == "206" ]]; then
    # 秒 -> ms
    tls_ms="$(awk -v x="$t_app" 'BEGIN{printf "%.0f", x*1000}')"
    ttfb_ms="$(awk -v x="$t_ttfb" 'BEGIN{printf "%.0f", x*1000}')"
    # bytes/s -> Mbps
    dl_mbps="$(awk -v x="$spd" 'BEGIN{printf "%.2f", (x*8)/1000000}')"
    echo "$src $tls_ms $ttfb_ms $dl_mbps $code 1"
  else
    echo "$src 0 0 0 $code 0"
  fi
}

do_tcp(){
  say "${FG_PURPLE}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${RESET}"
  say "${FG_CYAN}ℹ️  范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速（能测几个算几个）${RESET}"

  local tls_list="$TMPDIR/tls.list"
  local ttfb_list="$TMPDIR/ttfb.list"
  local dl_list="$TMPDIR/dl.list"
  : >"$tls_list"; : >"$ttfb_list"; : >"$dl_list"

  TCP_OK_SAMPLES=0
  TCP_BEST_SRC=""
  local best_dl=0

  for s in "${TCP_SOURCES[@]}"; do
    local line src tls ttfb dl code ok
    line="$(tcp_test_one "$s")"
    src="$(echo "$line" | awk '{print $1}')"
    tls="$(echo "$line" | awk '{print $2}')"
    ttfb="$(echo "$line" | awk '{print $3}')"
    dl="$(echo "$line" | awk '{print $4}')"
    code="$(echo "$line" | awk '{print $5}')"
    ok="$(echo "$line" | awk '{print $6}')"

    if [[ "$ok" == "1" ]]; then
      say "• ${FG_GREEN}${src}${RESET}: TLS=${tls}ms  TTFB=${ttfb}ms  下载=${dl}Mbps  code=${code}"
      echo "$tls" >>"$tls_list"
      echo "$ttfb" >>"$ttfb_list"
      echo "$dl" >>"$dl_list"
      TCP_OK_SAMPLES=$((TCP_OK_SAMPLES+1))
      awk -v a="$dl" -v b="$best_dl" 'BEGIN{exit !(a>b)}' && best_dl="$dl" && TCP_BEST_SRC="$src"
    else
      # 跳过原因：code 000/超时/失败
      if [[ "$code" == "000" ]]; then
        say "• ${FG_GRAY}${src}${RESET}: 失败/超时（跳过）"
      else
        say "• ${FG_GRAY}${src}${RESET}: HTTP ${code}（跳过）"
      fi
    fi
  done

  if (( TCP_OK_SAMPLES == 0 )); then
    TCP_TLS_MS="未知"; TCP_TTFB_MS="未知"; TCP_DL_MBPS="未知"
    TCP_SCORE=40
    say "${FG_YELLOW}⚠️  TCP：有效样本=0（可能被限速/风控/超时），建议换时间多测几次。${RESET}"
    hr
    return 1
  fi

  TCP_TLS_MS="$(cat "$tls_list" | median_of_list)"
  TCP_TTFB_MS="$(cat "$ttfb_list" | median_of_list)"
  TCP_DL_MBPS="$(cat "$dl_list" | median_of_list)"

  # 评分：以中位数下载为主，辅以 TTFB
  local s=0
  local dlm="$TCP_DL_MBPS"
  local ttfbm="$TCP_TTFB_MS"
  # dlm/ttfbm 可能为空
  if [[ -z "$dlm" || -z "$ttfbm" ]]; then
    s=60
  else
    if awk -v d="$dlm" 'BEGIN{exit !(d>=200)}'; then s=90
    elif awk -v d="$dlm" 'BEGIN{exit !(d>=50)}'; then s=80
    elif awk -v d="$dlm" 'BEGIN{exit !(d>=10)}'; then s=70
    else s=55
    fi
    # ttfb 过高扣一点
    if awk -v t="$ttfbm" 'BEGIN{exit !(t>=1500)}'; then s=$((s-15)); fi
    if awk -v t="$ttfbm" 'BEGIN{exit !(t>=800)}'; then s=$((s-8)); fi
    (( s < 40 )) && s=40
    (( s > 100 )) && s=100
  fi
  TCP_SCORE="$s"

  say
  say "${FG_CYAN}中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳源=${TCP_BEST_SRC:-unknown} ${best_dl}Mbps）${RESET}"
  if (( TCP_OK_SAMPLES < 2 )); then
    say "${FG_YELLOW}⚠️  TCP：有效样本不足（${TCP_OK_SAMPLES} 个），建议换时间多测几次。${RESET}"
  fi
  if (( s >= 90 )); then
    say "${FG_GREEN}✅ TCP 体验：优秀${RESET}"
  elif (( s >= 75 )); then
    say "${FG_CYAN}✅ TCP 体验：良好${RESET}"
  elif (( s >= 60 )); then
    say "${FG_YELLOW}⚠️  TCP 体验：一般${RESET}"
  else
    say "${FG_RED}❌ TCP 体验：偏弱${RESET}"
  fi
  hr
}

# ---------- 总结 ----------
do_summary(){
  # 网络分数：用 Ping 最差丢包 + 最差延迟粗略
  local net_score=0
  local worst_loss="${PING_WORST_LOSS:-}"
  local worst_avg="${PING_WORST_AVG:-}"

  if [[ -n "$worst_loss" && -n "$worst_avg" ]]; then
    if awk -v l="$worst_loss" 'BEGIN{exit !(l<=1)}' && awk -v a="$worst_avg" 'BEGIN{exit !(a<80)}'; then net_score=95
    elif awk -v l="$worst_loss" 'BEGIN{exit !(l<=3)}' && awk -v a="$worst_avg" 'BEGIN{exit !(a<150)}'; then net_score=80
    elif awk -v l="$worst_loss" 'BEGIN{exit !(l<=5)}' && awk -v a="$worst_avg" 'BEGIN{exit !(a<250)}'; then net_score=65
    else net_score=55
    fi
  else
    net_score=60
  fi

  local mtr_loss="${MTR_LAST_LOSS:-未知}"
  local mtr_avg="${MTR_LAST_AVG:-未知}"
  local mtr_grade="未知"
  if [[ "$mtr_loss" != "未知" && "$mtr_avg" != "未知" ]]; then
    mtr_grade="$(grade_label "$MTR_SCORE")"
  fi

  local tcp_grade="$(grade_label "$TCP_SCORE")"
  local dd_grade="$(grade_label "$DD_SCORE")"
  local media_grade="$(grade_label "$MEDIA_SCORE")"

  # 总评：简单加权
  local total=$(( (net_score*25 + MTR_SCORE*15 + TCP_SCORE*25 + DD_SCORE*15 + MEDIA_SCORE*20) / 100 ))
  (( total > 100 )) && total=100
  local total_grade="$(grade_label "$total")"

  hr2
  say "✅ ${FG_PINK}VPS 体检总结报告${RESET}"
  hr2

  say "${FG_PINK}[基础信息]${RESET}"
  say "Host : $(mask_host "$B_HOST")"
  say "OS   : $B_OS"
  say "Kern : $B_KERN | Virt=$B_VIRT"
  say "CPU  : $B_CPU | 核数=$B_CORES | 内存=$B_RAM | Swap=$B_SWAP"
  say "Disk : / $B_DISK"
  say "IPv4 : $(mask_ipv4 "${P_IPV4:-unknown}")"
  say "地区 : ${P_GEO_ZH:-未知}"
  say "ASN  : ${P_ASN:-unknown}"
  say "运营商: ${P_ISP:-unknown}"
  hr

  say "${FG_PINK}[网络]${RESET}  ${net_score}/100（$(grade_label "$net_score")）  $(bar "$net_score")"
  say "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_BAD} | 最差丢包=${PING_WORST_LOSS:-未知}% | 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  say "MTR  : 目标=${TARGETS[0]} | 终点丢包=${mtr_loss}% | 终点平均=${mtr_avg}ms | 评级=${mtr_grade}"
  hr

  say "${FG_PINK}[TCP真实链路]${RESET}  ${TCP_SCORE}/100（${tcp_grade}）  $(bar "$TCP_SCORE")"
  say "TLS  : ${TCP_TLS_MS:-未知} ms | TTFB=${TCP_TTFB_MS:-未知} ms"
  say "下载 : ${TCP_DL_MBPS:-未知} Mbps（中位数，${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
  say "样本 : ${TCP_OK_SAMPLES} 个 | 最佳源=${TCP_BEST_SRC:-unknown}"
  hr

  say "${FG_PINK}[磁盘]${RESET}  ${DD_SCORE}/100（${dd_grade}）  $(bar "$DD_SCORE")"
  if [[ -n "$DD_MBPS" ]]; then
    say "dd   : 约 ${DD_MBPS} MB/s（写入 /tmp ${DD_SIZE_MB}MB）"
  else
    say "dd   : 未知"
  fi
  hr

  say "${FG_PINK}[流媒体]${RESET}  ${MEDIA_SCORE}/100（${media_grade}）  $(bar "$MEDIA_SCORE")"
  say "$MEDIA_LINE"
  hr

  say "${FG_PINK}[总评]${RESET}  ${total}/100（${total_grade}）  $(bar "$total")"
  if (( total >= 80 )); then
    say "${FG_GREEN}✅ 结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。${RESET}"
  elif (( total >= 65 )); then
    say "${FG_CYAN}✅ 结论：整体不错，日常中转/落地够用。${RESET}"
  else
    say "${FG_YELLOW}⚠️  结论：整体一般，建议多测不同时间段，必要时换机房/线路。${RESET}"
  fi

  say
  say "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${RESET}"
  hr2
}

# ---------- 菜单 ----------
menu(){
  say "${FG_PINK}==================== VPS 一键体检 菜单 ====================${RESET}"
  say "Targets: ${FG_PURPLE}${TARGETS[*]}${RESET}  ${FG_GRAY}(MTR 默认用第一个 Target)${RESET}"
  say
  say "1) 设置测试目标（Targets）"
  say "2) 基本信息（系统/CPU/内存/磁盘/虚拟化）"
  say "3) 公网信息（IPv4 / 地区(中文) / ASN / ISP）"
  say "4) 网络 Ping 测试（所有 Targets）"
  say "5) 路由 MTR 测试（仅第一个 Target）"
  say "6) 安装 mtr（Debian/Ubuntu）"
  say "7) 磁盘 dd 测速（写入 /tmp）"
  say "8) 流媒体检测（best-effort）"
  say "9) 一键全跑（2~8+10）并输出最终总结（显示全过程）"
  say "10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
  say "R) 后台静默全跑（2~8+10），只输出最终 ✅ 总结（不刷屏）"
  say "0) 退出"
  hr
}

set_targets(){
  say "${FG_CYAN}请输入 Targets（空格分隔），例如：1.1.1.1 8.8.8.8 www.google.com${RESET}"
  read -r -p "Targets> " line || true
  if [[ -n "${line// /}" ]]; then
    # shellcheck disable=SC2206
    TARGETS=($line)
    say "${FG_GREEN}✅ 已更新 Targets：${TARGETS[*]}${RESET}"
  else
    say "${FG_YELLOW}⚠️  未修改${RESET}"
  fi
  hr
}

run_all_verbose(){
  do_basic || true
  do_public || true
  do_ping_all || true
  do_mtr || true
  do_dd || true
  do_media || true
  do_tcp || true
  do_summary || true
}

run_all_silent(){
  # 静默执行，最后只输出总结
  do_basic >/dev/null 2>&1 || true
  do_public >/dev/null 2>&1 || true
  do_ping_all >/dev/null 2>&1 || true
  do_mtr >/dev/null 2>&1 || true
  do_dd >/dev/null 2>&1 || true
  do_media >/dev/null 2>&1 || true
  do_tcp >/dev/null 2>&1 || true
  do_summary || true
}

# ---------- main ----------
while true; do
  menu
  read -r -p "选择 [0-10/R]: " c || true
  case "${c^^}" in
    1) set_targets ;;
    2) do_basic ;;
    3) do_public ;;
    4) do_ping_all ;;
    5) do_mtr ;;
    6) do_mtr_install ;;
    7) do_dd ;;
    8) do_media ;;
    9) run_all_verbose ;;
    10) do_tcp ;;
    R) say "${FG_CYAN}ℹ️  正在后台静默执行检测（2~8+10），完成后输出最终 ✅ 总结...${RESET}"; run_all_silent ;;
    0) exit 0 ;;
    *) say "${FG_YELLOW}⚠️  无效选择${RESET}" ;;
  esac
  read -r -p "回车继续..." _ || true
done
