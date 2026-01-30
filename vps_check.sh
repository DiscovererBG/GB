#!/usr/bin/env bash
# VPS 一键体检（最终修复版）
# ✅ 一键全跑不会中断（任何一步失败只提示并继续）
# ✅ 进度条：彩色“█” + 灰色“·”（不再用 '='，也不会出现 ?????）
# ✅ 修复 ANSI 残留（不会再显示 \033[0m）
# ✅ TCP 多源中位数：不依赖 awk asort（兼容 mawk）
# ✅ Ping RTT 解析修复（不会出现 min=mdev 之类乱串）
# ✅ 流媒体 HTTP code 解析修复（不会出现 403000）
# ✅ MTR 安装/执行更稳（自动 apt-get，失败不崩）
# ✅ 公网信息自动识别国家（中文国家名 + 城市/区域）

set -Eeuo pipefail

# ---------- Locale：尽量避免乱码 ----------
export LANG=C.UTF-8 LC_ALL=C.UTF-8
if command -v locale >/dev/null 2>&1; then
  if ! locale -a 2>/dev/null | grep -qiE 'c\.utf-8|en_US\.utf-8'; then
    export LANG=C LC_ALL=C
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

REDACT=0
[[ "${1:-}" == "--redact" ]] && REDACT=1

# ---------- Helpers ----------
println(){ printf "%b\n" "$*"; }
hr(){  println "${FG_PINK}---------------------------------------------------------${RESET}"; }
hr2(){ println "${FG_PINK}=========================================================${RESET}"; }
pause(){ read -r -p "回车继续..." _; }
exists(){ command -v "$1" >/dev/null 2>&1; }

mask_ipv4(){
  local ip="${1:-unknown}"
  if [[ "$REDACT" -eq 0 ]]; then printf "%s" "$ip"; return; fi
  printf "%s" "$ip" | awk -F. 'NF==4{print $1"."$2".*.*"; next}{print "*.*.*.*"}'
}
mask_host(){
  local h="${1:-unknown}"
  if [[ "$REDACT" -eq 0 ]]; then printf "%s" "$h"; return; fi
  printf "%s" "$h" | sed -E 's/^(.).*(.)$/\1***\2/'
}

# 安全执行：任何一步失败也不中断全跑
run_step(){
  local name="$1"; shift
  println "${FG_CYAN}ℹ️  开始：${name}${RESET}"
  set +e
  "$@"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    println "${FG_YELLOW}⚠️  跳过：${name}（返回码=$rc）${RESET}"
  fi
  hr
  return 0
}

# 分数 -> 评级（中文）
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

# 进度条：█ + ·（不会出现 ?????，不使用 '='）
bar(){
  local score="${1:-0}"
  local width="${2:-28}"
  (( score < 0 )) && score=0
  (( score > 100 )) && score=100
  local filled=$(( score * width / 100 ))
  local rest=$(( width - filled ))
  local fg; fg="$(grade_fg "$score")"

  printf "%b" "${fg}[${RESET}"
  if (( filled > 0 )); then
    printf "%b" "${fg}"; printf "%*s" "$filled" "" | tr ' ' '█'
    printf "%b" "${RESET}"
  fi
  if (( rest > 0 )); then
    printf "%b" "${FG_GRAY}${DIM}"; printf "%*s" "$rest" "" | tr ' ' '·'
    printf "%b" "${RESET}"
  fi
  printf "%b" "${fg}]${RESET}"
}

# 取中位数（不依赖 asort）
median_of_list(){
  mapfile -t _arr < <(awk 'NF{print $1}' | sort -n)
  local n="${#_arr[@]}"
  (( n == 0 )) && { printf ""; return 0; }
  local mid=$(( n/2 ))
  if (( n % 2 == 1 )); then
    printf "%s" "${_arr[$mid]}"
  else
    awk -v a="${_arr[$((mid-1))]}" -v b="${_arr[$mid]}" 'BEGIN{printf "%.2f",(a+b)/2}'
  fi
}

ms_i(){
  # seconds -> ms integer
  awk -v x="${1:-0}" 'BEGIN{printf "%d", (x+0)*1000}'
}
mbps_f(){
  # bytes/s -> Mbps float
  awk -v bps="${1:-0}" 'BEGIN{printf "%.2f", (bps*8)/1000000}'
}

# ---------- 国家码 -> 中文 ----------
country_zh(){
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
    TR) echo "土耳其" ;;
    RU) echo "俄罗斯" ;;
    IN) echo "印度" ;;
    ID) echo "印尼" ;;
    MY) echo "马来西亚" ;;
    TH) echo "泰国" ;;
    VN) echo "越南" ;;
    PH) echo "菲律宾" ;;
    BR) echo "巴西" ;;
    MX) echo "墨西哥" ;;
    ES) echo "西班牙" ;;
    IT) echo "意大利" ;;
    SE) echo "瑞典" ;;
    NO) echo "挪威" ;;
    FI) echo "芬兰" ;;
    CH) echo "瑞士" ;;
    *) echo "$cc" ;;
  esac
}

# ---------- Global vars ----------
B_HOST=""; B_OS=""; B_KERN=""; B_UPTIME=""; B_VIRT=""; B_CPU=""; B_CORES=""; B_RAM=""; B_SWAP=""; B_DISK=""
P_IPV4=""; P_CITY=""; P_REGION=""; P_COUNTRY=""; P_COUNTRY_ZH=""; P_ORG=""; P_ASN=""; P_ISP=""

PING_WORST_LOSS=""; PING_WORST_AVG=""
PING_GOOD=0; PING_WARN=0; PING_WEAK=0
PING_SCORE=0

MTR_TARGET=""
MTR_LAST_LOSS=""; MTR_LAST_AVG=""
MTR_SCORE=0

DD_MBPS=""
DD_SCORE=0

MEDIA_SCORE=0
MEDIA_LINE=""

TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""
TCP_OK_SAMPLES=0
TCP_BEST_SRC=""
TCP_SCORE=0
TCP_NOTE=""

# ---------- Basic ----------
do_basic(){
  B_HOST="$(hostname 2>/dev/null || echo "unknown")"
  if [[ -r /etc/os-release ]]; then
    B_OS="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
  else
    B_OS="Linux"
  fi
  B_KERN="$(uname -r 2>/dev/null || echo "unknown")"
  B_UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //')"
  [[ -z "$B_UPTIME" ]] && B_UPTIME="unknown"

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
  println "主机名   : $(mask_host "$B_HOST")"
  println "系统     : $B_OS"
  println "内核     : $B_KERN"
  println "运行时长 : $B_UPTIME"
  println "虚拟化   : $B_VIRT"
  println "CPU      : $B_CPU（${B_CORES} 核）"
  println "内存/Swap: $B_RAM / $B_SWAP"
  println "磁盘 /   : $B_DISK"
}

# ---------- Public ----------
do_public(){
  P_IPV4="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [[ -z "$P_IPV4" ]] && P_IPV4="unknown"

  local js
  js="$(curl -fsS --max-time 8 "https://ipinfo.io/${P_IPV4}/json" 2>/dev/null || true)"

  P_CITY="$(printf "%s" "$js"   | sed -n 's/.*"city":[ ]*"\([^"]*\)".*/\1/p'   | head -n1)"
  P_REGION="$(printf "%s" "$js" | sed -n 's/.*"region":[ ]*"\([^"]*\)".*/\1/p' | head -n1)"
  P_COUNTRY="$(printf "%s" "$js"| sed -n 's/.*"country":[ ]*"\([^"]*\)".*/\1/p'| head -n1)"
  P_ORG="$(printf "%s" "$js"    | sed -n 's/.*"org":[ ]*"\([^"]*\)".*/\1/p'    | head -n1)"

  [[ -z "$P_COUNTRY" ]] && P_COUNTRY="--"
  P_COUNTRY_ZH="$(country_zh "$P_COUNTRY")"

  # org: "AS20473 The Constant Company, LLC"
  P_ASN="$(printf "%s" "$P_ORG" | awk '{print $1}' )"
  [[ -z "$P_ASN" ]] && P_ASN="unknown"
  P_ISP="$(printf "%s" "$P_ORG" | sed -E 's/^AS[0-9]+[ ]*//' )"
  [[ -z "$P_ISP" ]] && P_ISP="unknown"

  [[ -z "$P_CITY" ]] && P_CITY="unknown"
  [[ -z "$P_REGION" ]] && P_REGION="unknown"

  println "${FG_PINK}--- 公网信息 ---${RESET}"
  println "IPv4   : $(mask_ipv4 "$P_IPV4")"
  println "地区   : ${P_COUNTRY_ZH}（${P_CITY}, ${P_REGION}）"
  println "ASN    : ${P_ASN}"
  println "运营商 : ${P_ISP}"
}

# ---------- Ping ----------
ping_one(){
  local t="$1"
  local out loss rtt_line min avg max mdev

  out="$(ping -c "$PING_COUNT" -q "$t" 2>/dev/null || true)"

  # 丢包：用 packet loss 行稳定提取
  loss="$(printf "%s\n" "$out" | awk -F',' '/packet loss/{
    for(i=1;i<=NF;i++){
      if($i ~ /packet loss/){
        gsub(/.* /,"",$i); gsub(/% packet loss.*/,"",$i); print $i; exit
      }
    }}')"
  [[ -z "$loss" ]] && loss="未知"

  # RTT 行：Linux 常见：rtt min/avg/max/mdev = a/b/c/d ms
  rtt_line="$(printf "%s\n" "$out" | awk '/rtt min\/avg\/max\/mdev|round-trip min\/avg\/max\/stddev/ {print; exit}')"
  if [[ -n "$rtt_line" ]]; then
    # 提取等号后面的 a/b/c/d
    local vals
    vals="$(printf "%s" "$rtt_line" | awk -F'=' '{gsub(/^[ \t]+/,"",$2); gsub(/[ \t]*ms.*/,"",$2); print $2}')"
    min="$(printf "%s" "$vals" | awk -F'/' '{print $1}')"
    avg="$(printf "%s" "$vals" | awk -F'/' '{print $2}')"
    max="$(printf "%s" "$vals" | awk -F'/' '{print $3}')"
    mdev="$(printf "%s" "$vals" | awk -F'/' '{print $4}')"
  fi
  [[ -z "${min:-}" ]] && min="未知"
  [[ -z "${avg:-}" ]] && avg="未知"
  [[ -z "${max:-}" ]] && max="未知"
  [[ -z "${mdev:-}" ]] && mdev="-"

  println "${FG_PURPLE}--- Ping: ${t}（${PING_COUNT} 次）---${RESET}"
  println "丢包 : ${loss}%"
  println "RTT  : min=${min}ms  avg=${avg}ms  max=${max}ms  mdev=${mdev}ms"

  # 评分（丢包优先，其次 avg）
  local s=0
  if [[ "$loss" == "未知" || "$avg" == "未知" ]]; then
    s=0
  else
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
    if [[ -z "$PING_WORST_LOSS" ]]; then PING_WORST_LOSS="$loss"
    else awk -v a="$loss" -v b="$PING_WORST_LOSS" 'BEGIN{exit !(a>b)}' && PING_WORST_LOSS="$loss"; fi
  fi
  if [[ "$avg" != "未知" ]]; then
    if [[ -z "$PING_WORST_AVG" ]]; then PING_WORST_AVG="$avg"
    else awk -v a="$avg" -v b="$PING_WORST_AVG" 'BEGIN{exit !(a>b)}' && PING_WORST_AVG="$avg"; fi
  fi

  if (( s >= 90 )); then ((PING_GOOD++))
  elif (( s >= 60 )); then ((PING_WARN++))
  else ((PING_WEAK++)); fi
}

do_ping_all(){
  PING_WORST_LOSS=""; PING_WORST_AVG=""
  PING_GOOD=0; PING_WARN=0; PING_WEAK=0

  for t in "${TARGETS[@]}"; do
    ping_one "$t"
    hr
  done

  println "${FG_CYAN}ℹ️  Ping 小结：目标数=${#TARGETS[@]} | 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_WEAK} | 最差丢包=${PING_WORST_LOSS:-未知}% 最差平均延迟=${PING_WORST_AVG:-未知}ms${RESET}"

  # Ping 综合分：按最差 avg / 丢包简单算
  if [[ -n "${PING_WORST_LOSS:-}" && -n "${PING_WORST_AVG:-}" && "${PING_WORST_LOSS}" != "未知" && "${PING_WORST_AVG}" != "未知" ]]; then
    local l="$PING_WORST_LOSS" a="$PING_WORST_AVG"
    if awk -v l="$l" 'BEGIN{exit !(l<=1)}' && awk -v a="$a" 'BEGIN{exit !(a<80)}'; then PING_SCORE=100
    elif awk -v l="$l" 'BEGIN{exit !(l<=3)}' && awk -v a="$a" 'BEGIN{exit !(a<150)}'; then PING_SCORE=85
    elif awk -v l="$l" 'BEGIN{exit !(l<=5)}' && awk -v a="$a" 'BEGIN{exit !(a<250)}'; then PING_SCORE=70
    else PING_SCORE=50; fi
  else
    PING_SCORE=0
  fi
}

# ---------- MTR ----------
do_mtr_install(){
  println "${FG_CYAN}ℹ️  正在安装 mtr...${RESET}"
  if exists apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y mtr-tiny >/dev/null 2>&1 || apt-get install -y mtr >/dev/null 2>&1 || true
  fi
  if exists mtr; then
    println "${FG_GREEN}✅ mtr 已可用${RESET}"
    return 0
  fi
  println "${FG_RED}❌ mtr 安装失败（可手动执行：apt-get update && apt-get install -y mtr-tiny）${RESET}"
  return 0
}

do_mtr(){
  local t="${TARGETS[0]}"
  MTR_TARGET="$t"

  if ! exists mtr; then
    println "${FG_YELLOW}⚠️  MTR 未安装/不可用，跳过（可选 6 安装）${RESET}"
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    return 0
  fi

  println "${FG_PURPLE}--- MTR: ${t}（${MTR_CYCLES} 轮）---${RESET}"
  local out
  out="$(mtr -rwzbc "$MTR_CYCLES" "$t" 2>/dev/null || true)"
  [[ -z "$out" ]] && { println "${FG_RED}❌ MTR 执行失败${RESET}"; MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0; return 0; }

  printf "%s\n" "$out" | sed -n '1,20p'
  if (( $(printf "%s\n" "$out" | wc -l) > 26 )); then
    println "${FG_GRAY}...(中间省略)...${RESET}"
    printf "%s\n" "$out" | tail -n 8
  fi

  local lastline loss avg
  lastline="$(printf "%s\n" "$out" | awk '/^[[:space:]]*[0-9]+\./{line=$0} END{print line}')"
  loss="$(printf "%s\n" "$lastline" | awk '{print $(NF-6)}' | tr -d '%')"
  avg="$(printf "%s\n" "$lastline" | awk '{print $(NF-4)}')"

  if [[ -z "$loss" || -z "$avg" ]]; then
    MTR_LAST_LOSS="未知"; MTR_LAST_AVG="未知"; MTR_SCORE=0
    println "${FG_YELLOW}⚠️  终点数据解析失败（可能 ICMP 限速/格式差异）${RESET}"
    return 0
  fi

  MTR_LAST_LOSS="$(awk -v x="$loss" 'BEGIN{printf "%.1f",x+0}')"
  MTR_LAST_AVG="$(awk -v x="$avg"  'BEGIN{printf "%.1f",x+0}')"

  if awk -v l="$loss" 'BEGIN{exit !(l<=0.5)}' && awk -v a="$avg" 'BEGIN{exit !(a<80)}'; then MTR_SCORE=95
  elif awk -v l="$loss" 'BEGIN{exit !(l<=2)}' && awk -v a="$avg" 'BEGIN{exit !(a<150)}'; then MTR_SCORE=80
  elif awk -v l="$loss" 'BEGIN{exit !(l<=5)}' && awk -v a="$avg" 'BEGIN{exit !(a<250)}'; then MTR_SCORE=65
  else MTR_SCORE=40; fi

  println
  println "终点（最后一跳）：丢包=${MTR_LAST_LOSS}%  平均=${MTR_LAST_AVG}ms"
  println "${FG_CYAN}ℹ️  提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包），通常不影响真实流量。${RESET}"
}

# ---------- Disk dd ----------
do_dd(){
  println "${FG_PURPLE}--- 磁盘快速测试（dd 写入 ${DD_SIZE_MB}MB 到 /tmp）---${RESET}"
  local out line speed unit mbps
  out="$(LANG=C dd if=/dev/zero of="$TMPDIR/dd_test" bs=1M count="$DD_SIZE_MB" conv=fdatasync 2>&1 || true)"
  rm -f "$TMPDIR/dd_test" >/dev/null 2>&1 || true

  line="$(printf "%s\n" "$out" | tail -n 1)"
  # 常见：... copied, 0.165 s, 1.6 GB/s
  speed="$(printf "%s\n" "$line" | awk -F',' '{print $3}' | awk '{print $1}')"
  unit="$(printf "%s\n" "$line" | awk -F',' '{print $3}' | awk '{print $2}')"

  if [[ -z "$speed" || -z "$unit" ]]; then
    DD_MBPS=""
    DD_SCORE=0
    println "${FG_RED}❌ dd 测试失败${RESET}"
    return 0
  fi

  if [[ "$unit" == "GB/s" ]]; then
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f",x*1024}')"
  else
    mbps="$(awk -v x="$speed" 'BEGIN{printf "%.2f",x}')"
  fi

  DD_MBPS="$mbps"

  if awk -v x="$mbps" 'BEGIN{exit !(x>=1500)}'; then DD_SCORE=90
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=500)}'; then DD_SCORE=80
  elif awk -v x="$mbps" 'BEGIN{exit !(x>=200)}'; then DD_SCORE=65
  else DD_SCORE=40; fi

  local glabel; glabel="$(grade_label "$DD_SCORE")"
  println "结果：${speed} ${unit}（约 ${DD_MBPS} MB/s）"
  if (( DD_SCORE >= 90 )); then println "${FG_GREEN}✅ 磁盘：优秀（>=1500 MB/s）${RESET}"
  elif (( DD_SCORE >= 80 )); then println "${FG_CYAN}✅ 磁盘：良好（>=500 MB/s）${RESET}"
  elif (( DD_SCORE >= 65 )); then println "${FG_YELLOW}⚠️  磁盘：一般（>=200 MB/s）${RESET}"
  else println "${FG_RED}❌ 磁盘：偏弱（<200 MB/s）${RESET}"; fi
}

# ---------- Media (best-effort) ----------
curl_code(){
  # 返回纯 3 位 http_code（不会出现 403000）
  local url="$1"
  curl -fsSL --max-time 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000"
}
do_media(){
  println "${FG_PURPLE}--- 流媒体解锁检测（best-effort）---${RESET}"

  local yt nf ds tt pv mx b

  # YouTube：用 Premium 轻量接口（国家码）
  yt="$(curl -fsSL --max-time 10 -o /dev/null -w "%{http_code}" "https://www.youtube.com/premium" 2>/dev/null || echo "000")"
  # Netflix / Disney / Prime / Max：只做可访问性（最终以登录播放为准）
  nf="$(curl_code "https://www.netflix.com/title/81215567")"
  ds="$(curl_code "https://www.disneyplus.com/")"
  pv="$(curl_code "https://www.primevideo.com/")"
  mx="$(curl_code "https://play.max.com/")"
  # TikTok：经常 CF/风控，只给提示
  tt="$(curl_code "https://www.tiktok.com/")"

  local ok=0 warn=0 bad=0

  # YouTube
  if [[ "$yt" == "200" || "$yt" == "301" || "$yt" == "302" ]]; then
    println "${FG_GREEN}✅ YouTube：可访问${RESET}"; ((ok++))
  else
    println "${FG_RED}❌ YouTube：不可用（HTTP $yt）${RESET}"; ((bad++))
  fi

  # Netflix
  if [[ "$nf" == "200" || "$nf" == "404" ]]; then
    println "${FG_GREEN}✅ Netflix：可访问（最终以登录播放为准）${RESET}"; ((ok++))
  else
    println "${FG_YELLOW}⚠️  Netflix：可能受限（HTTP $nf，最终以登录播放为准）${RESET}"; ((warn++))
  fi

  # Disney+
  if [[ "$ds" == "200" || "$ds" == "301" || "$ds" == "302" ]]; then
    println "${FG_GREEN}✅ Disney+：可访问（最终以登录播放为准）${RESET}"; ((ok++))
  else
    println "${FG_YELLOW}⚠️  Disney+：可能受限（HTTP $ds，最终以登录播放为准）${RESET}"; ((warn++))
  fi

  # TikTok
  if [[ "$tt" == "200" || "$tt" == "301" || "$tt" == "302" ]]; then
    println "${FG_YELLOW}⚠️  TikTok：可访问但易受风控/Cloudflare 影响（建议多测几次）${RESET}"; ((warn++))
  else
    println "${FG_YELLOW}⚠️  TikTok：可能受限/风控（HTTP $tt）${RESET}"; ((warn++))
  fi

  # Prime
  if [[ "$pv" == "200" || "$pv" == "301" || "$pv" == "302" ]]; then
    println "${FG_GREEN}✅ Prime Video：可访问（片库看账号地区）${RESET}"; ((ok++))
  else
    println "${FG_YELLOW}⚠️  Prime Video：可能受限（HTTP $pv）${RESET}"; ((warn++))
  fi

  # Max
  if [[ "$mx" == "200" || "$mx" == "301" || "$mx" == "302" ]]; then
    println "${FG_GREEN}✅ Max(HBO)：可访问（最终以登录播放为准）${RESET}"; ((ok++))
  else
    println "${FG_YELLOW}⚠️  Max(HBO)：可能受限（HTTP $mx）${RESET}"; ((warn++))
  fi

  # 评分
  local total=6
  # ok=满分，warn=半分
  MEDIA_SCORE="$(awk -v ok="$ok" -v w="$warn" -v t="$total" 'BEGIN{printf "%d", (ok + 0.5*w) / t * 100}')"
  # 展示行（给总结）
  MEDIA_LINE="YouTube=$( [[ "$yt" =~ ^(200|301|302)$ ]] && echo OK || echo NO ) | Netflix=$( [[ "$nf" == "200" || "$nf" == "404" ]] && echo OK || echo RISK ) | Disney+=$( [[ "$ds" =~ ^(200|301|302)$ ]] && echo OK || echo RISK ) | TikTok=$( [[ "$tt" =~ ^(200|301|302)$ ]] && echo OK || echo RISK ) | Prime=$( [[ "$pv" =~ ^(200|301|302)$ ]] && echo OK || echo RISK ) | Max=$( [[ "$mx" =~ ^(200|301|302)$ ]] && echo OK || echo RISK )"

  println
  println "${FG_CYAN}ℹ️  提示：Netflix/Disney+/Max/Prime 只能判断“可访问/疑似受限”，最终以登录播放为准。${RESET}"
  println "${FG_CYAN}ℹ️  TikTok 易受风控/Cloudflare 影响，建议多测几次综合判断。${RESET}"
}

# ---------- TCP (multi-source median) ----------
tcp_url(){
  local src="$1"
  local bytes=$(( TCP_RANGE_MB * 1024 * 1024 ))
  case "$src" in
    cloudflare) printf "https://speed.cloudflare.com/__down?bytes=%d" "$bytes" ;;
    hetzner)    printf "https://speed.hetzner.de/100MB.bin" ;;
    ovh)        printf "https://proof.ovh.net/files/100Mb.dat" ;;
    cachefly)   printf "https://speedtest.cachefly.net/100mb.test" ;;
    *)          printf "" ;;
  esac
}

tcp_probe_one(){
  local src="$1"
  local url; url="$(tcp_url "$src")"
  [[ -z "$url" ]] && return 1

  local bytes=$(( TCP_RANGE_MB * 1024 * 1024 ))
  local range_end=$(( bytes - 1 ))

  # 输出：code=xxx tls=sec ttfb=sec speed=bps
  local out
  out="$(curl -fsSL \
    --max-time "$TCP_MAXTIME" \
    -r "0-${range_end}" \
    -o /dev/null \
    -w "code=%{http_code} tls=%{time_appconnect} ttfb=%{time_starttransfer} speed=%{speed_download}\n" \
    "$url" 2>/dev/null || true)"

  local code tls_s ttfb_s speed_bps
  code="$(printf "%s" "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^code=/){sub("code=","",$i); print $i; exit}}')"
  tls_s="$(printf "%s" "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^tls=/){sub("tls=","",$i); print $i; exit}}')"
  ttfb_s="$(printf "%s" "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^ttfb=/){sub("ttfb=","",$i); print $i; exit}}')"
  speed_bps="$(printf "%s" "$out" | awk '{for(i=1;i<=NF;i++) if($i~/^speed=/){sub("speed=","",$i); print $i; exit}}')"

  [[ -z "$code" ]] && code="000"
  # 成功：200/206/301/302 视为有效
  if [[ "$code" != "200" && "$code" != "206" && "$code" != "301" && "$code" != "302" ]]; then
    return 1
  fi

  # 某些场景 time_appconnect 可能为 0（HTTP/复用），也允许
  local tls_ms ttfb_ms dl_mbps
  tls_ms="$(ms_i "${tls_s:-0}")"
  ttfb_ms="$(ms_i "${ttfb_s:-0}")"
  dl_mbps="$(mbps_f "${speed_bps:-0}")"

  printf "%s %s %s %s\n" "$tls_ms" "$ttfb_ms" "$dl_mbps" "$src"
  return 0
}

do_tcp(){
  println "${FG_PURPLE}--- TCP 真实链路测试（更贴近代理体验，多源取中位数）---${RESET}"
  println "${FG_CYAN}ℹ️  范围：${TCP_RANGE_MB}MB | 超时：${TCP_MAXTIME}s | 多源测速（能测几个算几个）${RESET}"

  local tls_list="$TMPDIR/tls.list"
  local ttfb_list="$TMPDIR/ttfb.list"
  local dl_list="$TMPDIR/dl.list"
  : >"$tls_list"; : >"$ttfb_list"; : >"$dl_list"

  TCP_OK_SAMPLES=0
  TCP_BEST_SRC=""
  local best_dl=0

  for s in "${TCP_SOURCES[@]}"; do
    local r
    if r="$(tcp_probe_one "$s")"; then
      local tls_ms ttfb_ms dl_mbps src
      tls_ms="$(printf "%s" "$r" | awk '{print $1}')"
      ttfb_ms="$(printf "%s" "$r" | awk '{print $2}')"
      dl_mbps="$(printf "%s" "$r" | awk '{print $3}')"
      src="$(printf "%s" "$r" | awk '{print $4}')"

      ((TCP_OK_SAMPLES++))
      printf "%s\n" "$tls_ms"  >>"$tls_list"
      printf "%s\n" "$ttfb_ms" >>"$ttfb_list"
      printf "%s\n" "$dl_mbps" >>"$dl_list"

      # best source by dl
      if awk -v a="$dl_mbps" -v b="$best_dl" 'BEGIN{exit !(a>b)}'; then
        best_dl="$dl_mbps"
        TCP_BEST_SRC="$src"
      fi

      println "• ${FG_GREEN}${src}${RESET}: TLS=${tls_ms}ms  TTFB=${ttfb_ms}ms  下载=${dl_mbps}Mbps"
    else
      println "• ${FG_GRAY}${s}${RESET}: 失败/超时（跳过）"
    fi
  done

  if (( TCP_OK_SAMPLES == 0 )); then
    TCP_TLS_MS="未知"; TCP_TTFB_MS="未知"; TCP_DL_MBPS="未知"
    TCP_SCORE=0
    TCP_NOTE="TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。"
    println "${FG_YELLOW}⚠️  ${TCP_NOTE}${RESET}"
    return 0
  fi

  local med_tls med_ttfb med_dl
  med_tls="$(cat "$tls_list"  | median_of_list)"
  med_ttfb="$(cat "$ttfb_list" | median_of_list)"
  med_dl="$(cat "$dl_list"   | median_of_list)"

  TCP_TLS_MS="$(awk -v x="$med_tls" 'BEGIN{printf "%.0f",x+0}')"
  TCP_TTFB_MS="$(awk -v x="$med_ttfb" 'BEGIN{printf "%.0f",x+0}')"
  TCP_DL_MBPS="$(awk -v x="$med_dl" 'BEGIN{printf "%.2f",x+0}')"

  # 评分：按中位数下载为主，TTFB/TLS轻微扣分
  local base
  base="$(awk -v d="$TCP_DL_MBPS" 'BEGIN{
    if(d>=300) print 95;
    else if(d>=80) print 85;
    else if(d>=20) print 70;
    else if(d>=5) print 55;
    else print 40;
  }')"
  # 延迟扣分（轻）
  local penalty=0
  penalty="$(awk -v t="$TCP_TTFB_MS" -v l="$TCP_TLS_MS" 'BEGIN{
    p=0;
    if(t>800) p+=10; else if(t>400) p+=5;
    if(l>800) p+=8;  else if(l>400) p+=4;
    if(p>20) p=20;
    print p;
  }')"
  TCP_SCORE="$(( base - penalty ))"
  (( TCP_SCORE < 0 )) && TCP_SCORE=0

  println
  println "${FG_CYAN}中位数结果：TLS=${TCP_TLS_MS}ms | TTFB=${TCP_TTFB_MS}ms | 下载=${TCP_DL_MBPS}Mbps（最佳源=${TCP_BEST_SRC:-unknown} ${best_dl}Mbps）${RESET}"

  local glabel; glabel="$(grade_label "$TCP_SCORE")"
  if (( TCP_OK_SAMPLES < 2 )); then
    TCP_NOTE="TCP：有效样本不足（可能被限速/风控/超时），建议换时间多测几次。"
    println "${FG_YELLOW}⚠️  ${TCP_NOTE}${RESET}"
  fi

  if (( TCP_SCORE >= 90 )); then println "${FG_GREEN}✅ TCP 体验：优秀${RESET}"
  elif (( TCP_SCORE >= 75 )); then println "${FG_CYAN}✅ TCP 体验：良好${RESET}"
  elif (( TCP_SCORE >= 60 )); then println "${FG_YELLOW}⚠️  TCP 体验：一般${RESET}"
  else println "${FG_RED}❌ TCP 体验：偏弱${RESET}"; fi
}

# ---------- Summary ----------
do_summary(){
  # 网络分（Ping + MTR 各半，MTR 不可用则只算 Ping）
  local net_score
  if [[ "${MTR_SCORE:-0}" -gt 0 ]]; then
    net_score="$(awk -v p="$PING_SCORE" -v m="$MTR_SCORE" 'BEGIN{printf "%d",(p*0.6+m*0.4)}')"
  else
    net_score="$PING_SCORE"
  fi

  local total
  total="$(awk -v n="$net_score" -v t="$TCP_SCORE" -v d="$DD_SCORE" -v m="$MEDIA_SCORE" 'BEGIN{
    # 权重：网络30 TCP30 磁盘20 流媒体20
    printf "%d", (n*0.30 + t*0.30 + d*0.20 + m*0.20)
  }')"

  println
  hr2
  println "${FG_PINK}✅ VPS 体检总结报告${RESET}"
  hr2
  println "${FG_PINK}[基础信息]${RESET}"
  println "Host : $(mask_host "$B_HOST")"
  println "OS   : $B_OS"
  println "Kern : $B_KERN | Virt=${B_VIRT}"
  println "CPU  : $B_CPU | 核数=${B_CORES} | 内存=${B_RAM} | Swap=${B_SWAP}"
  println "Disk : / ${B_DISK}"
  println "IPv4 : $(mask_ipv4 "$P_IPV4")"
  println "地区 : ${P_COUNTRY_ZH}（${P_CITY}, ${P_REGION}）"
  println "ASN  : ${P_ASN}"
  println "ISP  : ${P_ISP}"
  hr

  # 网络
  local net_label; net_label="$(grade_label "$net_score")"
  local net_fg; net_fg="$(grade_fg "$net_score")"
  println "${FG_PINK}[网络]${RESET}  ${net_score}/100 ${net_fg}(${net_label})${RESET}  $(bar "$net_score")"
  println "Ping : 优秀=${PING_GOOD} 一般=${PING_WARN} 偏弱=${PING_WEAK} | 最差丢包=${PING_WORST_LOSS:-未知}% | 最差平均延迟=${PING_WORST_AVG:-未知}ms"
  if [[ -n "${MTR_TARGET:-}" ]]; then
    println "MTR  : 目标=${MTR_TARGET} | 终点丢包=${MTR_LAST_LOSS:-未知}% | 终点平均=${MTR_LAST_AVG:-未知}ms | 评分=$( [[ "${MTR_SCORE:-0}" -gt 0 ]] && echo "$(grade_label "$MTR_SCORE")" || echo "未知")"
  else
    println "MTR  : 未测试/不可用"
  fi
  hr

  # TCP
  local tcp_label; tcp_label="$(grade_label "$TCP_SCORE")"
  local tcp_fg; tcp_fg="$(grade_fg "$TCP_SCORE")"
  println "${FG_PINK}[TCP真实链路]${RESET}  ${TCP_SCORE}/100 ${tcp_fg}(${tcp_label})${RESET}  $(bar "$TCP_SCORE")"
  println "TLS  : ${TCP_TLS_MS:-未知} ms | TTFB=${TCP_TTFB_MS:-未知} ms"
  println "下载 : ${TCP_DL_MBPS:-未知} Mbps（中位数，range=${TCP_RANGE_MB}MB，超时=${TCP_MAXTIME}s）"
  println "样本 : ${TCP_OK_SAMPLES:-0} 个 | 最佳源=${TCP_BEST_SRC:-unknown}"
  [[ -n "${TCP_NOTE:-}" ]] && println "${FG_YELLOW}⚠️  ${TCP_NOTE}${RESET}"
  hr

  # Disk
  local dd_label; dd_label="$(grade_label "$DD_SCORE")"
  local dd_fg; dd_fg="$(grade_fg "$DD_SCORE")"
  println "${FG_PINK}[磁盘]${RESET}  ${DD_SCORE}/100 ${dd_fg}(${dd_label})${RESET}  $(bar "$DD_SCORE")"
  println "dd   : ${DD_MBPS:-未知} MB/s（写入 /tmp ${DD_SIZE_MB}MB）"
  hr

  # Media
  local media_label; media_label="$(grade_label "$MEDIA_SCORE")"
  local media_fg; media_fg="$(grade_fg "$MEDIA_SCORE")"
  println "${FG_PINK}[流媒体]${RESET}  ${MEDIA_SCORE}/100 ${media_fg}(${media_label})${RESET}  $(bar "$MEDIA_SCORE")"
  println "${MEDIA_LINE:-未测试}"
  hr

  # Total
  local total_label; total_label="$(grade_label "$total")"
  local total_fg; total_fg="$(grade_fg "$total")"
  println "${FG_PINK}[总评]${RESET}  ${total}/100 ${total_fg}(${total_label})${RESET}  $(bar "$total")"
  if (( total >= 85 )); then
    println "${FG_GREEN}✅ 结论：整体素质很强，适合中转/落地/流媒体测试/轻量服务。${RESET}"
  elif (( total >= 70 )); then
    println "${FG_CYAN}✅ 结论：整体不错，日常中转/落地够用，关注路由与邻居波动。${RESET}"
  elif (( total >= 60 )); then
    println "${FG_YELLOW}⚠️  结论：整体一般，建议多测不同时间段，必要时换机房/线路。${RESET}"
  else
    println "${FG_RED}❌ 结论：整体偏弱，不建议跑关键业务，建议换线路/机房。${RESET}"
  fi

  println
  println "${FG_CYAN}ℹ️  公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）${RESET}"
  hr2
}

# ---------- Menu ----------
set_targets(){
  println "${FG_PINK}--- 设置测试目标（Targets）---${RESET}"
  println "当前：${TARGETS[*]}"
  println "请输入用空格分隔的目标（例如：1.1.1.1 8.8.8.8 www.google.com），直接回车保持不变："
  read -r line || true
  if [[ -n "${line// /}" ]]; then
    # shellcheck disable=SC2206
    TARGETS=($line)
  fi
  println "${FG_GREEN}✅ 已设置：${TARGETS[*]}${RESET}"
}

do_all(){
  run_step "基本信息" do_basic
  run_step "公网信息" do_public
  run_step "Ping 测试" do_ping_all
  run_step "MTR 测试" do_mtr
  run_step "磁盘 dd 测速" do_dd
  run_step "流媒体检测" do_media
  run_step "TCP 真实链路" do_tcp
  run_step "输出总结" do_summary
}

do_all_quiet(){
  # 静默全跑：只输出最终总结（中间不刷屏）
  run_step "基本信息" do_basic >/dev/null 2>&1 || true
  run_step "公网信息" do_public >/dev/null 2>&1 || true
  run_step "Ping 测试" do_ping_all >/dev/null 2>&1 || true
  run_step "MTR 测试" do_mtr >/dev/null 2>&1 || true
  run_step "磁盘 dd 测速" do_dd >/dev/null 2>&1 || true
  run_step "流媒体检测" do_media >/dev/null 2>&1 || true
  run_step "TCP 真实链路" do_tcp >/dev/null 2>&1 || true
  do_summary
}

main_menu(){
  while true; do
    println
    println "${FG_PINK}==================== VPS 一键体检 菜单 ====================${RESET}"
    println "Targets: ${FG_PURPLE}${TARGETS[0]}${RESET} ${FG_PURPLE}${TARGETS[1]:-}${RESET} ${FG_PURPLE}${TARGETS[2]:-}${RESET}  ${FG_GRAY}(MTR 默认用第一个 Target)${RESET}"
    println
    println " 1) 设置测试目标（Targets）"
    println " 2) 基本信息（系统/CPU/内存/磁盘/虚拟化）"
    println " 3) 公网信息（IPv4 / 地区(中文) / ASN / ISP）"
    println " 4) 网络 Ping 测试（所有 Targets）"
    println " 5) 路由 MTR 测试（仅第一个 Target）"
    println " 6) 安装 mtr（Debian/Ubuntu）"
    println " 7) 磁盘 dd 测速（写入 /tmp）"
    println " 8) 流媒体检测（best-effort）"
    println " 9) 一键全跑（2~8+10）并输出最终总结（显示全过程）"
    println "10) TCP 真实链路测试（TLS/TTFB/下载 Mbps，多源取中位数）"
    println " R) 后台静默全跑（2~8+10），只输出最终 ✅ 总结报告"
    println " 0) 退出"
    hr

    read -r -p "选择 [0-10/R]: " opt
    case "${opt^^}" in
      1) set_targets; pause ;;
      2) do_basic; hr; pause ;;
      3) do_public; hr; pause ;;
      4) do_ping_all; hr; pause ;;
      5) do_mtr; hr; pause ;;
      6) do_mtr_install; hr; pause ;;
      7) do_dd; hr; pause ;;
      8) do_media; hr; pause ;;
      9) do_all; pause ;;
      10) do_tcp; hr; pause ;;
      R) println "${FG_CYAN}ℹ️  正在后台静默执行检测（2~8+10），完成后输出最终 ✅ 总结...${RESET}"; do_all_quiet; pause ;;
      0) exit 0 ;;
      *) println "${FG_YELLOW}⚠️  无效选择${RESET}" ;;
    esac
  done
}

# ---------- Start ----------
main_menu
