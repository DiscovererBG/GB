#!/usr/bin/env bash
# =========================================================
# VPS 一键体检（只读）+ 流媒体解锁 + TCP真实链路 - Menu Edition
# 修复点（针对你截图）：
# 1) MTR lastLoss/lastAvg 解析更稳（优先匹配 target 行，fallback 匹配 hop 行）
# 2) TCP 测试源必须 http_code=200/206（排除 404/403/5xx/000）
# 3) TCP 下载 Mbps 计算更稳（优先 curl speed_download，必要时用 bytes/time 计算）
# 4) 最终总结：进度条绿色，等级文字带颜色
# 5) 菜单：10) TCP；R) 后台静默全跑（2~8+10）
# 支持：--redact 打码 Host/IPv4
# =========================================================

set -u
set -o pipefail

# ---------- UI ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"; GRAY="\033[90m"; BOLD="\033[1m"; NC="\033[0m"
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
bad()  { echo -e "${RED}❌ $*${NC}"; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
hr()   { echo -e "${MAGENTA}---------------------------------------------------------${NC}"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- args ----------
REDACT=0
for a in "$@"; do
  [[ "$a" == "--redact" ]] && REDACT=1
done

mask_ip() {
  local ip="${1:-unknown}"
  if [[ "$REDACT" -ne 1 ]]; then echo "$ip"; return; fi
  if [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.*.*"
  else
    echo "$ip"
  fi
}
mask_host() {
  local h="${1:-unknown}"
  if [[ "$REDACT" -ne 1 ]]; then echo "$h"; return; fi
  local n=${#h}
  if (( n <= 2 )); then echo "*"; return; fi
  echo "${h:0:1}***${h:n-1:1}"
}

# ---------- defaults ----------
PING_COUNT=50
PING_INTERVAL=0.2
PING_INTERVAL_FALLBACK=0.5
MTR_COUNT=100
DISK_TEST_MB=256
CURL_TIMEOUT=10
DEFAULT_TARGETS=("1.1.1.1" "8.8.8.8" "www.google.com")

# TCP
TCP_MAXTIME=12
TCP_RANGE_BYTES=$((8*1024*1024))  # 8MB
TCP_SOURCES=(
  "hetzner|https://speed.hetzner.de/100MB.bin"
  "ovh|https://proof.ovh.net/files/100Mb.dat"
  "cachefly|https://speedtest.cachefly.net/100mb.test"
  "vultr|https://hnd-jp-ping.vultr.com/vultr.com.100MB.bin"
)

# ---------- numeric helpers ----------
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
safe_num() { local x="${1:-}"; if is_number "$x"; then echo "$x"; else echo ""; fi; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<=b)?0:1}'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a<b)?0:1}'; }
f_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a>=b)?0:1}'; }

sec_to_ms() {
  local s; s="$(safe_num "${1:-}")"
  [[ -z "$s" ]] && echo "" && return
  awk -v x="$s" 'BEGIN{printf "%.0f", x*1000}'
}
bytesps_to_mbps() {
  local bps; bps="$(safe_num "${1:-}")"
  [[ -z "$bps" ]] && echo "" && return
  awk -v x="$bps" 'BEGIN{printf "%.2f", (x*8)/1000000}'
}
bytes_and_time_to_mbps() {
  local bytes="${1:-}" sec="${2:-}"
  bytes="$(safe_num "$bytes")"; sec="$(safe_num "$sec")"
  [[ -z "$bytes" || -z "$sec" ]] && echo "" && return
  awk -v b="$bytes" -v s="$sec" 'BEGIN{ if(s<=0) exit 1; printf "%.2f", (b*8)/(s*1000000)}' 2>/dev/null || echo ""
}

# ---------- progress bar ----------
bar() {
  local score="${1:-0}" width="${2:-22}"
  score="$(safe_num "$score")"; [[ -z "$score" ]] && score=0
  local filled=$(( score*width/100 ))
  (( filled<0 )) && filled=0
  (( filled>width )) && filled=$width
  local i out=""
  for ((i=0;i<filled;i++)); do out+="█"; done
  for ((i=filled;i<width;i++)); do out+="░"; done
  echo -e "${GREEN}${out}${NC}"
}
grade_text() {
  local x; x="$(safe_num "${1:-0}")"; [[ -z "$x" ]] && x=0
  if (( x >= 85 )); then echo -e "${GREEN}优秀${NC}"
  elif (( x >= 70 )); then echo -e "${CYAN}良好${NC}"
  elif (( x >= 55 )); then echo -e "${YELLOW}一般${NC}"
  else echo -e "${RED}偏弱${NC}"
  fi
}

pause() { read -r -p "回车继续..." _ || true; }

# ---------- global state ----------
RUN_SYS=0 RUN_IP=0 RUN_PING=0 RUN_MTR=0 RUN_DISK=0 RUN_STREAM=0 RUN_TCP=0
HOSTNAME_=""; OS_=""; KERNEL_=""; UPTIME_=""; CPU_=""; CORES_=""; RAM_=""; SWAP_=""; LOAD_=""; VIRT_=""; DISKROOT_=""
IPV4_="unknown"; GEO_="unknown"; ASN_="unknown"; ORG_="unknown"
TARGETS=("${DEFAULT_TARGETS[@]}")

PING_TOTAL_TARGETS=0
PING_GOOD=0; PING_WARN=0; PING_BAD=0
PING_WORST_LOSS=""; PING_WORST_AVG=""

MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"

DISK_SPEED_RAW="unknown"; DISK_MBPS=""; DISK_RATING="unknown"

YT_CC="unknown"; YT_OK="unknown"
AG_STATUS="unknown"; NF_OK="unknown"; DP_OK="unknown"; TT_OK="unknown"; PV_OK="unknown"; MX_OK="unknown"

TCP_HTTP_CODE=""; TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""; TCP_SRC_USED=""; TCP_RATING="unknown"; TCP_SCORE=0

# ---------- menu helpers ----------
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

gather_system() {
  RUN_SYS=1
  HOSTNAME_="$(hostname 2>/dev/null || echo unknown)"
  UPTIME_="$(uptime -p 2>/dev/null || echo unknown)"
  OS_="$( (awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null) || echo unknown )"
  KERNEL_="$(uname -r 2>/dev/null || echo unknown)"
  CPU_="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || echo unknown)"
  CORES_="$(nproc 2>/dev/null || echo 1)"
  RAM_="$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  SWAP_="$(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "0 MB")"
  LOAD_="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//' || echo unknown)"
  VIRT_="unknown"
  if need_cmd systemd-detect-virt; then VIRT_="$(systemd-detect-virt 2>/dev/null || echo none)"; fi
  DISKROOT_="$(df -hP / 2>/dev/null | tail -n 1 | awk '{print $3"/"$2" ("$5")"}' || echo unknown)"
}

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
}

ping_once() { ping -c "${PING_COUNT}" -i "$2" -n "$1" 2>/dev/null; }

ping_test_one() {
  local target="$1"
  echo -e "${BLUE}${BOLD}--- Ping：${target} (${PING_COUNT} packets) ---${NC}"
  if ! need_cmd ping; then warn "没有 ping 命令，跳过。"; return 0; fi

  local out loss avg
  if ! out="$(ping_once "$target" "$PING_INTERVAL")"; then
    warn "ping 间隔 ${PING_INTERVAL}s 失败，降级到 ${PING_INTERVAL_FALLBACK}s..."
    out="$(ping_once "$target" "$PING_INTERVAL_FALLBACK" || true)"
  fi

  loss="$(echo "$out" | awk -F', ' '/packet loss/{print $3}' | awk '{print $1}' | tr -d '%')"
  avg="$(echo "$out" | awk -F'=' '/rtt|round-trip/{print $2}' | awk -F'/' '{print $2}' | awk '{print $1}')"
  loss="$(safe_num "$loss")"; avg="$(safe_num "$avg")"

  echo "Loss      : ${loss:-?}%"
  echo "Avg RTT   : ${avg:-?} ms"

  local rating="WARN"
  if [[ -n "${loss:-}" ]] && f_le "$loss" "1.0"; then rating="GOOD"
  elif [[ -n "${loss:-}" ]] && f_le "$loss" "5.0"; then rating="WARN"
  else rating="BAD"
  fi

  if [[ "$rating" == "GOOD" ]]; then ok "丢包：优秀（<=1%）"; ((PING_GOOD++)) || true
  elif [[ "$rating" == "WARN" ]]; then warn "丢包：一般（1%~5%）"; ((PING_WARN++)) || true
  else bad "丢包：偏高（>5%）"; ((PING_BAD++)) || true
  fi

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
  info "Ping 小结：Targets=${PING_TOTAL_TARGETS} | GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% worstAvg=${PING_WORST_AVG:-?}ms"
  hr
}

install_mtr() {
  if ! need_cmd apt; then warn "系统没有 apt（非 Debian/Ubuntu），跳过。"; return 0; fi
  info "将执行：apt update && apt install -y mtr-tiny"
  apt update && apt install -y mtr-tiny
  ok "mtr 安装完成。"
}

run_mtr() {
  RUN_MTR=1
  local target="${TARGETS[0]}"
  echo -e "${BLUE}${BOLD}--- MTR：${target} (${MTR_COUNT} cycles) ---${NC}"
  if ! need_cmd mtr; then
    warn "未安装 mtr。（可在菜单选择安装 mtr-tiny）"
    MTR_LASTLOSS=""; MTR_LASTAVG=""; MTR_RATING="unknown"
    hr; return 0
  fi

  local out last_line last_loss last_avg
  out="$(mtr -rwzbc "${MTR_COUNT}" "$target" 2>/dev/null || true)"

  # ✅ 更稳：优先找包含 target 的最后一行（1.1.1.1 or www.google.com）
  last_line="$(echo "$out" | awk -v t="$target" 'tolower($0) ~ tolower(t) {line=$0} END{print line}')"

  # fallback：找最后一个包含百分号的 hop 行（通常为 Loss% 那列）
  if [[ -z "${last_line:-}" ]]; then
    last_line="$(echo "$out" | awk '$0 ~ /%/ {line=$0} END{print line}')"
  fi

  # 解析列：Loss% 在第3列，Avg 在第6列（mtr -rwzbc 的标准表）
  last_loss="$(echo "$last_line" | awk '{print $3}' | tr -d '%')"
  last_avg="$(echo "$last_line" | awk '{print $6}')"
  last_loss="$(safe_num "$last_loss")"; last_avg="$(safe_num "$last_avg")"

  MTR_LASTLOSS="${last_loss:-}"; MTR_LASTAVG="${last_avg:-}"

  echo "终点(最后一跳) : Loss=${last_loss:-?}%  Avg=${last_avg:-?} ms"
  info "提示：中间跳丢包高但最后一跳 0% 多为 ICMP 限速（假丢包）。"

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

run_disk() {
  RUN_DISK=1
  echo -e "${BLUE}${BOLD}--- 磁盘快速测试（dd 写入 ${DISK_TEST_MB}MB 到 /tmp）---${NC}"
  if ! need_cmd dd; then warn "dd 不存在，跳过。"; DISK_RATING="unknown"; hr; return 0; fi

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
    [[ "$unit" == "GB/s" ]] && mbps="$(awk -v x="$mbps" 'BEGIN{printf "%.2f", x*1024}')"
    DISK_MBPS="$mbps"
    if f_ge "$mbps" "200"; then DISK_RATING="GOOD"; ok "磁盘：不错（>=200 MB/s）"
    elif f_ge "$mbps" "80"; then DISK_RATING="WARN"; warn "磁盘：一般（80~200 MB/s）"
    else DISK_RATING="BAD"; warn "磁盘：偏低（<80 MB/s）"
    fi
  else
    DISK_RATING="unknown"; warn "无法解析 dd 速度"
  fi
  hr
}

# ---------- streaming ----------
fetch()   { curl -L -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
head_req(){ curl -I -s --max-time "${CURL_TIMEOUT}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }
code_of() { curl -L -s -o /dev/null --max-time "${CURL_TIMEOUT}" -w "%{http_code}" -A "Mozilla/5.0" "$1" 2>/dev/null || true; }

run_streaming() {
  RUN_STREAM=1
  if ! need_cmd curl; then bad "缺少 curl，无法做流媒体检测。"; return 0; fi

  echo -e "${BLUE}${BOLD}--- 流媒体解锁检测（best-effort）---${NC}"

  local yt_code yt_html yt_cc
  yt_code="$(code_of "https://www.youtube.com/premium")"
  yt_html="$(fetch "https://www.youtube.com/premium")"
  yt_cc="$(echo "$yt_html" | grep -oE '"countryCode":"[A-Z]+"' | head -n1 | cut -d: -f2 | tr -d '"')"
  YT_CC="${yt_cc:-unknown}"
  [[ "$yt_code" == "200" || "$yt_code" == "302" ]] && YT_OK="OK" || YT_OK="BAD"

  local ag_code ag_html
  ag_code="$(code_of "https://ani.gamer.com.tw/")"
  ag_html="$(fetch "https://ani.gamer.com.tw/")"
  if echo "$ag_html" | grep -qiE "地區限制|地区限制|本動畫僅限台灣|僅限台灣|僅限臺灣|not available in your region"; then
    AG_STATUS="REGION_BLOCK"
  elif [[ "$ag_code" == "200" ]]; then
    AG_STATUS="OK"
  elif [[ "$ag_code" == "403" || "$ag_code" == "503" ]]; then
    AG_STATUS="WAF_OR_RISK"
  else
    AG_STATUS="UNKNOWN"
  fi

  local nf_code dp_code tt_code pv_code mx_code
  nf_code="$(code_of "https://www.netflix.com/title/80018499")"
  [[ "$nf_code" == "200" || "$nf_code" == "302" ]] && NF_OK="OK" || NF_OK="WARN"

  dp_code="$(code_of "https://www.disneyplus.com/")"
  [[ "$dp_code" == "200" || "$dp_code" == "301" || "$dp_code" == "302" ]] && DP_OK="OK" || DP_OK="WARN"

  tt_code="$(code_of "https://www.tiktok.com/")"
  [[ "$tt_code" == "200" || "$tt_code" == "302" ]] && TT_OK="OK" || [[ "$tt_code" == "403" ]] && TT_OK="BAD" || TT_OK="WARN"

  pv_code="$(code_of "https://www.primevideo.com/")"
  [[ "$pv_code" == "200" || "$pv_code" == "301" || "$pv_code" == "302" ]] && PV_OK="OK" || PV_OK="WARN"

  mx_code="$(code_of "https://play.max.com/")"
  [[ "$mx_code" == "200" || "$mx_code" == "301" || "$mx_code" == "302" ]] && MX_OK="OK" || MX_OK="WARN"

  hr
}

# ---------- TCP real link (FIXED) ----------
run_tcp() {
  RUN_TCP=1
  if ! need_cmd curl; then bad "缺少 curl，无法做 TCP 真实链路测试。"; TCP_RATING="BAD"; TCP_SCORE=0; hr; return 0; fi

  echo -e "${BLUE}${BOLD}--- TCP 真实链路测试（更贴近代理体验）---${NC}"

  local src_name src_url out code app ttfb spd size total_time
  local ok_found=0

  TCP_HTTP_CODE=""; TCP_TLS_MS=""; TCP_TTFB_MS=""; TCP_DL_MBPS=""; TCP_SRC_USED=""
  TCP_RATING="unknown"; TCP_SCORE=0

  for item in "${TCP_SOURCES[@]}"; do
    src_name="${item%%|*}"
    src_url="${item#*|}"

    # 额外取 size_download / time_total 以便 fallback 计算
    out="$(curl -L -sS --max-time "${TCP_MAXTIME}" \
      -A "Mozilla/5.0" \
      -r "0-$((TCP_RANGE_BYTES-1))" \
      -o /dev/null \
      -w "code=%{http_code} app=%{time_appconnect} ttfb=%{time_starttransfer} spd=%{speed_download} size=%{size_download} total=%{time_total}" \
      "$src_url" 2>/dev/null || true)"

    code="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^code=/){sub("code=","",$i); print $i}}')"
    app="$(echo "$out"  | awk '{for(i=1;i<=NF;i++) if($i ~ /^app=/){sub("app=","",$i); print $i}}')"
    ttfb="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^ttfb=/){sub("ttfb=","",$i); print $i}}')"
    spd="$(echo "$out"  | awk '{for(i=1;i<=NF;i++) if($i ~ /^spd=/){sub("spd=","",$i); print $i}}')"
    size="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^size=/){sub("size=","",$i); print $i}}')"
    total_time="$(echo "$out" | awk '{for(i=1;i<=NF;i++) if($i ~ /^total=/){sub("total=","",$i); print $i}}')"

    # ✅ 必须 200/206 才认为源可用（修复你截图里 404 被当成可用）
    if [[ "$code" != "200" && "$code" != "206" ]]; then
      continue
    fi

    TCP_SRC_USED="$src_name"
    TCP_HTTP_CODE="$code"
    TCP_TLS_MS="$(sec_to_ms "$app")"
    TCP_TTFB_MS="$(sec_to_ms "$ttfb")"

    # 下载 Mbps：优先 speed_download；若异常则用 size/time_total 计算
    local mbps1 mbps2
    mbps1="$(bytesps_to_mbps "$spd")"
    mbps2="$(bytes_and_time_to_mbps "$size" "$total_time")"

    # 选择更靠谱的（非空且 >0.5）
    if [[ -n "$mbps1" ]] && awk -v x="$mbps1" 'BEGIN{exit (x>0.5)?0:1}'; then
      TCP_DL_MBPS="$mbps1"
    elif [[ -n "$mbps2" ]] && awk -v x="$mbps2" 'BEGIN{exit (x>0.5)?0:1}'; then
      TCP_DL_MBPS="$mbps2"
    else
      # 允许输出 ?（但不会误判优秀）
      TCP_DL_MBPS=""
    fi

    ok_found=1
    break
  done

  if (( ok_found == 0 )); then
    echo "Handshake(TLS) : ? ms"
    echo "TTFB          : ? ms"
    echo "Download      : ? Mbps  (source=multi, range=8MB, maxtime=${TCP_MAXTIME}s, http_code!=200/206)"
    bad "TCP 体验：失败（测速源不可达/被风控/返回非200/206）"
    TCP_RATING="BAD"; TCP_SCORE=0
    hr
    return 0
  fi

  echo "Handshake(TLS) : ${TCP_TLS_MS:-?} ms"
  echo "TTFB          : ${TCP_TTFB_MS:-?} ms"
  echo "Download      : ${TCP_DL_MBPS:-?} Mbps  (source=${TCP_SRC_USED}, range=8MB, maxtime=${TCP_MAXTIME}s, http_code=${TCP_HTTP_CODE})"

  local tls="${TCP_TLS_MS:-}" ttf="${TCP_TTFB_MS:-}"

  TCP_SCORE=70
  TCP_RATING="WARN"

  # TLS/TTFB 缺失或为 0 -> 不可靠
  if [[ -z "$tls" || -z "$ttf" || "$tls" == "0" || "$ttf" == "0" ]]; then
    TCP_SCORE=40
    TCP_RATING="BAD"
    bad "TCP 体验：不可靠（TLS/TTFB 缺失或为 0）"
    hr
    return 0
  fi

  if (( tls <= 80 && ttf <= 120 )); then
    TCP_SCORE=90; TCP_RATING="GOOD"; ok "TCP 体验：优秀"
  elif (( tls <= 150 && ttf <= 250 )); then
    TCP_SCORE=80; TCP_RATING="GOOD"; ok "TCP 体验：良好"
  else
    TCP_SCORE=65; TCP_RATING="WARN"; warn "TCP 体验：一般（首包偏慢）"
  fi

  hr
}

# ---------- summary ----------
overall_summary() {
  echo -e "${MAGENTA}${BOLD}====================== ✅ VPS 体检总结报告 ======================${NC}"

  local show_host show_ip
  show_host="$(mask_host "$HOSTNAME_")"
  show_ip="$(mask_ip "$IPV4_")"

  # 网络评分
  local net_score=0
  if [[ "$RUN_PING" -eq 1 ]]; then
    local denom="$PING_TOTAL_TARGETS"; [[ "$denom" -lt 1 ]] && denom=1
    net_score="$(awk -v g="$PING_GOOD" -v w="$PING_WARN" -v d="$denom" 'BEGIN{printf "%.0f", (g*2+w*1)*50/d }')"
  fi
  if [[ "$RUN_MTR" -eq 1 ]]; then
    [[ "$MTR_RATING" == "GOOD" ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x+10}')"
    [[ "$MTR_RATING" == "BAD"  ]] && net_score="$(awk -v x="$net_score" 'BEGIN{printf "%.0f", x-10}')"
  fi
  net_score="$(awk -v x="$net_score" 'BEGIN{if(x<0)x=0; if(x>100)x=100; printf "%.0f", x}')"

  # TCP评分
  local tcp_score=0
  [[ "$RUN_TCP" -eq 1 ]] && tcp_score="${TCP_SCORE:-0}"

  # 磁盘评分
  local disk_score=0
  if [[ "$RUN_DISK" -eq 1 ]]; then
    [[ "$DISK_RATING" == "GOOD" ]] && disk_score=90
    [[ "$DISK_RATING" == "WARN" ]] && disk_score=70
    [[ "$DISK_RATING" == "BAD"  ]] && disk_score=50
  fi

  # 流媒体评分
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

  # 总分（按已执行项归一）
  local total=0 used=0
  local w_net=35 w_tcp=20 w_disk=15 w_stream=30
  if [[ "$RUN_PING" -eq 1 || "$RUN_MTR" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$net_score" -v w="$w_net" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_net)); fi
  if [[ "$RUN_TCP" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$tcp_score" -v w="$w_tcp" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_tcp)); fi
  if [[ "$RUN_DISK" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$disk_score" -v w="$w_disk" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_disk)); fi
  if [[ "$RUN_STREAM" -eq 1 ]]; then total="$(awk -v t="$total" -v x="$stream_score" -v w="$w_stream" 'BEGIN{printf "%.0f", t + x*w/100}')"; used=$((used+w_stream)); fi
  (( used > 0 )) && total="$(awk -v t="$total" -v u="$used" 'BEGIN{printf "%.0f", t*100/u}')" || total=0

  echo -e "${BOLD}[基础信息]${NC}"
  echo "Host : ${show_host}"
  echo "OS   : ${OS_}"
  echo "Kern : ${KERNEL_} | Virt=${VIRT_}"
  echo "CPU  : ${CPU_} | Cores=${CORES_} | RAM=${RAM_} | Swap=${SWAP_}"
  echo "Disk : / ${DISKROOT_}"
  echo "IPv4 : ${show_ip}"
  echo "Geo  : ${GEO_}"
  echo "ASN  : ${ASN_}"
  echo "ISP  : ${ORG_}"
  hr

  echo -e "${BOLD}[网络]${NC}  ${net_score}/100 ($(grade_text "$net_score"))  $(bar "$net_score")"
  echo "Ping : GOOD=${PING_GOOD} WARN=${PING_WARN} BAD=${PING_BAD} | worstLoss=${PING_WORST_LOSS:-?}% | worstAvg=${PING_WORST_AVG:-?}ms"
  echo "MTR  : target=${TARGETS[0]} | lastLoss=${MTR_LASTLOSS:-?}% | lastAvg=${MTR_LASTAVG:-?}ms | rating=${MTR_RATING}"
  hr

  echo -e "${BOLD}[TCP真实链路]${NC}  ${tcp_score}/100 ($(grade_text "$tcp_score"))  $(bar "$tcp_score")"
  echo "TLS  : ${TCP_TLS_MS:-?} ms | TTFB=${TCP_TTFB_MS:-?} ms"
  echo "DL   : ${TCP_DL_MBPS:-?} Mbps (source=${TCP_SRC_USED:-?}, http_code=${TCP_HTTP_CODE:-?})"
  echo "Eval : ${TCP_RATING}"
  hr

  echo -e "${BOLD}[磁盘]${NC}  ${disk_score}/100 ($(grade_text "$disk_score"))  $(bar "$disk_score")"
  echo "dd   : ${DISK_SPEED_RAW} | approx=${DISK_MBPS:-?} MB/s | rating=${DISK_RATING}"
  hr

  echo -e "${BOLD}[流媒体]${NC}  ${stream_score}/100 ($(grade_text "$stream_score"))  $(bar "$stream_score")"
  echo "YouTube=OK(CC=${YT_CC}) | 动画疯=${AG_STATUS} | Netflix=${NF_OK} | Disney+=${DP_OK} | TikTok=${TT_OK} | Prime=${PV_OK} | Max=${MX_OK}"
  hr

  echo -e "${BOLD}[总评]${NC}  ${total}/100 ($(grade_text "$total"))  $(bar "$total")"
  if (( total >= 85 )); then ok "结论：整体素质很强，适合做中转/落地/流媒体测试/轻量服务。"
  elif (( total >= 70 )); then ok "结论：整体不错，日常中转/落地够用。"
  elif (( total >= 55 )); then warn "结论：整体一般，建议降低用途预期或换机房。"
  else bad "结论：整体偏弱，不建议做关键落地或高稳定需求用途。"
  fi

  echo
  info "公开贴结果前建议打码：IPv4、Host（可用：./vps_check.sh --redact）"
  echo -e "${MAGENTA}${BOLD}================================================================${NC}"
}

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
  info "正在后台执行检测（2~8 + 10），完成后输出最终✅总结..."
  local tmp="/tmp/vps_check_silent.$$.log"; : > "$tmp"
  gather_system   >>"$tmp" 2>&1 || true
  gather_ip       >>"$tmp" 2>&1 || true
  run_ping_all    >>"$tmp" 2>&1 || true
  run_mtr         >>"$tmp" 2>&1 || true
  run_disk        >>"$tmp" 2>&1 || true
  run_streaming   >>"$tmp" 2>&1 || true
  run_tcp         >>"$tmp" 2>&1 || true
  overall_summary
  rm -f "$tmp" >/dev/null 2>&1 || true
}

# ---------- menu ----------
menu() {
  while true; do
    echo -e "${MAGENTA}${BOLD}====================== VPS 一键体检 菜单 ======================${NC}"
    echo -e "Targets: ${CYAN}${TARGETS[*]}${NC}  ${GRAY}(MTR 默认用第一个 Target)${NC}"
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
      2) gather_system; overall_summary; pause ;;
      3) gather_ip; overall_summary; pause ;;
      4) run_ping_all; overall_summary; pause ;;
      5) run_mtr; overall_summary; pause ;;
      6) install_mtr; pause ;;
      7) run_disk; overall_summary; pause ;;
      8) run_streaming; overall_summary; pause ;;
      9) run_all_verbose; pause ;;
      10) run_tcp; overall_summary; pause ;;
      r|R) run_all_silent; pause ;;
      0|q|Q) ok "Bye."; exit 0 ;;
      *) warn "无效选择：${c:-空}（请输入 0-10 或 R）"; pause ;;
    esac
  done
}

# ---------- entry ----------
menu
