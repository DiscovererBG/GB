#!/usr/bin/env bash
# =========================================================
#  fzb - Fail2ban 菜单式工具箱（单文件版 / 全中文显示优先 / 彩色美化增强版）
# ---------------------------------------------------------
# 设计原则：
#   1) 下载一次 -> 本地 sudo fzb 就能调出菜单
#   2) 默认不联网；只有“更新脚本”才访问 GitHub
#   3) 只管理 fail2ban（安装/配置/白名单/封禁/日志/参数）
#
# 会改动的文件（可控）：
#   - 安装：/opt/fzb/fzb.sh  +  /usr/local/sbin/fzb(软链接)
#   - 配置：/etc/fail2ban/jail.local（写入/更新时会覆盖写入）
#   - 备份：/root/fzb_backups/...
#
# 不会做的事：
#   - 不改 sshd_config
#   - 不改 UFW/Firewalld 的配置文件
#   - fail2ban 封禁会动态写内核防火墙规则（这是正常工作方式）
#
# ✅ 本版本修复：
#   - 顶部“规则组”显示 ? 的问题：兼容 “Number of jail:      1”（冒号后多空格）
#   - 所有 “Jail” 文案统一中文 “规则组”
# =========================================================

set -euo pipefail

# -------------------- 基本信息 --------------------
APP_NAME="fzb"
INSTALL_DIR="/opt/${APP_NAME}"
INSTALLED_SCRIPT="${INSTALL_DIR}/${APP_NAME}.sh"
BIN_PATH="/usr/local/sbin/${APP_NAME}"

# ✅ 仅“更新脚本”会用到这个地址（已按你提供的填好）
REPO_RAW_URL="https://raw.githubusercontent.com/DiscovererBG/GB/refs/heads/main/fzb.sh"

# -------------------- 颜色/输出（tput 优先，失败则 ANSI） --------------------
supports_tput=false
if command -v tput >/dev/null 2>&1; then
  if tput colors >/dev/null 2>&1; then supports_tput=true; fi
fi

if $supports_tput; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_MAGENTA="$(tput setaf 5)"
  C_CYAN="$(tput setaf 6)"
  C_GRAY="$(tput setaf 7)"
else
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_MAGENTA="\033[35m"
  C_CYAN="\033[36m"
  C_GRAY="\033[90m"
fi

ok(){   echo -e "${C_GREEN}${C_BOLD}✅${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}${C_BOLD}⚠️${C_RESET}  $*"; }
err(){  echo -e "${C_RED}${C_BOLD}❌${C_RESET} $*"; }
info(){ echo -e "${C_CYAN}${C_BOLD}ℹ️${C_RESET}  $*"; }
hr(){   echo -e "${C_GRAY}─────────────────────────────────────────────────────────${C_RESET}"; }
pause(){ read -r -p "回车继续..." _; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 运行：sudo -i 或 sudo fzb"
    exit 1
  fi
}

has_cmd(){ command -v "$1" >/dev/null 2>&1; }
timestamp(){ date +%Y%m%d%H%M%S; }

# -------------------- 路径 --------------------
JAIL_LOCAL="/etc/fail2ban/jail.local"
F2B_DIR="/etc/fail2ban"
BACKUP_DIR="/root/fzb_backups"
ensure_dirs(){ mkdir -p "$BACKUP_DIR"; }

# -------------------- 系统/服务辅助 --------------------
detect_pkg_mgr(){
  if has_cmd apt-get; then echo "apt"
  elif has_cmd dnf; then echo "dnf"
  elif has_cmd yum; then echo "yum"
  elif has_cmd pacman; then echo "pacman"
  else echo "unknown"
  fi
}

svc(){
  local action="$1"
  if has_cmd systemctl; then
    case "$action" in
      start) systemctl start fail2ban ;;
      stop) systemctl stop fail2ban ;;
      restart) systemctl restart fail2ban ;;
      status) systemctl --no-pager -l status fail2ban || true ;;
      enable) systemctl enable fail2ban ;;
      disable) systemctl disable fail2ban || true ;;
    esac
  else
    case "$action" in
      start) service fail2ban start || true ;;
      stop) service fail2ban stop || true ;;
      restart) service fail2ban restart || true ;;
      status) service fail2ban status || true ;;
      enable|disable) true ;;
    esac
  fi
}

f2b_installed(){ has_cmd fail2ban-client; }

detect_ssh_port(){
  local port=""
  if has_cmd ss; then
    port="$(ss -ltnp 2>/dev/null | awk "/sshd/ {print \$4}" | sed -n "s/.*:\([0-9][0-9]*\)$/\1/p" | head -n1 || true)"
  fi
  if [ -z "$port" ] && [ -f /etc/ssh/sshd_config ]; then
    port="$(awk "tolower(\$1)==\"port\"{print \$2}" /etc/ssh/sshd_config | tail -n1 || true)"
  fi
  echo "${port:-22}"
}

f2b_version(){
  if ! f2b_installed; then echo "-"; return; fi
  local v=""
  v="$(fail2ban-client -V 2>/dev/null | head -n1 | sed 's/[^0-9.].*//g' || true)"
  if [ -z "$v" ] && has_cmd fail2ban-server; then
    v="$(fail2ban-server -V 2>/dev/null | head -n1 | sed 's/[^0-9.].*//g' || true)"
  fi
  echo "${v:-?}"
}

# ✅ 彻底修复：兼容冒号后多个空格，避免顶部“规则组: ?”
jail_count(){
  if ! f2b_installed; then echo "-"; return; fi

  local n=""
  n="$(fail2ban-client status 2>/dev/null \
      | sed -n 's/.*Number of jail:[[:space:]]*//p' \
      | head -n1 \
      | tr -d '[:space:]' || true)"

  if [ -z "${n:-}" ]; then
    sleep 0.2
    n="$(fail2ban-client status 2>/dev/null \
        | sed -n 's/.*Number of jail:[[:space:]]*//p' \
        | head -n1 \
        | tr -d '[:space:]' || true)"
  fi

  if [ -z "${n:-}" ]; then
    echo "?"
  else
    echo "$n"
  fi
}

sshd_banned_now(){
  if ! f2b_installed; then echo "-"; return; fi
  if fail2ban-client status sshd >/dev/null 2>&1; then
    local n=""
    n="$(fail2ban-client status sshd 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*//p' | head -n1 | tr -d '[:space:]' || true)"
    echo "${n:-0}"
  else
    echo "-"
  fi
}

sshd_banned_24h(){
  local log="/var/log/fail2ban.log"
  [ -f "$log" ] || { echo "-"; return; }

  local now_epoch since_epoch
  now_epoch="$(date +%s 2>/dev/null || echo "")"
  [ -n "$now_epoch" ] || { echo "-"; return; }
  since_epoch="$((now_epoch - 24*3600))"

  local cnt="0"
  cnt="$(awk -v since="$since_epoch" '
    function to_epoch(d, t,   cmd, r){
      gsub(/T/," ",t)
      cmd="date -d \"" d " " t "\" +%s 2>/dev/null"
      cmd | getline r
      close(cmd)
      return r
    }
    {
      date=$1
      time=$2
      gsub(/,.*/,"",time)
      if (date ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ && time ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/){
        epoch=to_epoch(date, time)
        if (epoch != "" && epoch+0 >= since+0){
          if ($0 ~ /sshd/ && $0 ~ /Ban /) c++
        }
      }
    }
    END{ print c+0 }
  ' "$log" 2>/dev/null || echo "0")"

  echo "${cnt:-0}"
}

has_ignoreip(){
  if [ -f "$JAIL_LOCAL" ] && grep -qiE '^\s*ignoreip\s*=' "$JAIL_LOCAL"; then echo "已设置"; else echo "未设置"; fi
}

summary_line(){
  local ssh_port v j bnow b24 ign
  ssh_port="$(detect_ssh_port || echo "?")"
  v="$(f2b_version)"
  j="$(jail_count)"
  bnow="$(sshd_banned_now)"
  b24="$(sshd_banned_24h)"
  ign="$(has_ignoreip)"

  echo -e "${C_DIM}SSH端口:${C_RESET} ${C_BOLD}${ssh_port}${C_RESET}   ${C_DIM}Fail2ban:${C_RESET} ${C_BOLD}${v}${C_RESET}   ${C_DIM}规则组:${C_RESET} ${C_BOLD}${j}${C_RESET}   ${C_DIM}封禁(现在/24h):${C_RESET} ${C_BOLD}${bnow}/${b24}${C_RESET}   ${C_DIM}白名单:${C_RESET} ${C_BOLD}${ign}${C_RESET}"
}

# -------------------- 备份 --------------------
backup_f2b(){
  ensure_dirs
  local ts dst
  ts="$(timestamp)"
  dst="${BACKUP_DIR}/fail2ban_${ts}"
  mkdir -p "$dst"
  if [ -d "$F2B_DIR" ]; then
    cp -a "$F2B_DIR" "$dst/" 2>/dev/null || true
    ok "已备份 ${F2B_DIR} -> ${dst}/fail2ban"
  else
    warn "未找到 ${F2B_DIR}，跳过备份。"
  fi
}

# -------------------- 安装 fail2ban --------------------
install_fail2ban(){
  local pm; pm="$(detect_pkg_mgr)"
  if [ "$pm" = "unknown" ]; then
    err "未识别包管理器（apt/dnf/yum/pacman）。"
    return
  fi
  if f2b_installed; then ok "fail2ban 已安装。"; return; fi

  info "正在安装 fail2ban（包管理器：$pm）..."
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y fail2ban
      ;;
    dnf) dnf install -y fail2ban ;;
    yum)
      yum install -y epel-release || true
      yum install -y fail2ban
      ;;
    pacman) pacman -Sy --noconfirm fail2ban ;;
  esac
  ok "fail2ban 安装完成。"
}

# -------------------- 写入/更新 jail.local（启用 SSH 防爆破） --------------------
write_jail_local(){
  local ssh_port; ssh_port="$(detect_ssh_port)"
  echo
  info "检测到 SSH 端口：${C_BOLD}${ssh_port}${C_RESET}"
  read -r -p "是否使用这个端口作为 SSH 防爆破保护端口？[Y/n] " yn || true
  yn="${yn:-Y}"
  if [[ "$yn" =~ ^[Nn]$ ]]; then
    read -r -p "请输入你的 SSH 端口（例如 22 或 26463）: " ssh_port
    ssh_port="${ssh_port:-22}"
  fi

  echo
  info "下面是防爆破参数（回车=使用默认值）"
  local bantime="1h" findtime="10m" maxretry="5" mode="aggressive"
  read -r -p "封禁时长 bantime（默认 1h）: " v || true; bantime="${v:-$bantime}"
  read -r -p "统计窗口 findtime（默认 10m）: " v || true; findtime="${v:-$findtime}"
  read -r -p "失败次数 maxretry（默认 5）: " v || true; maxretry="${v:-$maxretry}"
  read -r -p "强度 mode（normal/aggressive，默认 aggressive）: " v || true; mode="${v:-$mode}"

  backup_f2b
  mkdir -p "$F2B_DIR"

  cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
# 封禁时长：例如 30m / 1h / 24h
bantime  = ${bantime}
# 统计窗口：例如 5m / 10m
findtime = ${findtime}
# 在统计窗口内失败多少次就封
maxretry = ${maxretry}
# systemd 日志后端（Debian/Ubuntu 常见）
backend  = systemd

[sshd]
enabled  = true
# SSH 实际端口（脚本已检测/询问）
port     = ${ssh_port}
# aggressive 更严格；normal 更温和（误封概率更低）
mode     = ${mode}
EOF

  ok "已写入配置：${JAIL_LOCAL}"
  svc enable
  svc restart
  ok "fail2ban 已启用并重启。"
}

ensure_sshd_group(){
  if [ ! -f "$JAIL_LOCAL" ]; then warn "${JAIL_LOCAL} 不存在：请先执行“写入/更新配置”。"; return 1; fi
  if ! grep -qi "^\[sshd\]" "$JAIL_LOCAL"; then warn "${JAIL_LOCAL} 中没有 [sshd]：请先写入/更新配置。"; return 1; fi
  return 0
}

# -------------------- 查看状态（服务 + 规则组） --------------------
show_status(){
  if ! f2b_installed; then err "fail2ban 未安装。"; return; fi
  echo
  info "【服务状态】fail2ban.service："
  svc status
  echo
  info "【总状态】当前启用的规则组（fail2ban 原始输出）："
  fail2ban-client status || true
  echo
  info "【sshd 规则组状态】（fail2ban 原始输出）："
  fail2ban-client status sshd || true
}

# -------------------- 封禁/解封/查看封禁 --------------------
show_banned(){
  ensure_sshd_group || return
  echo
  info "【sshd 规则组】封禁情况（原始输出）："
  fail2ban-client status sshd || true
}

ban_ip(){
  ensure_sshd_group || return
  read -r -p "输入要封禁的 IP: " ip
  [ -z "${ip:-}" ] && { warn "IP 不能为空"; return; }
  fail2ban-client set sshd banip "$ip" || { err "封禁失败"; return; }
  ok "已封禁：$ip"
}

unban_ip(){
  ensure_sshd_group || return
  read -r -p "输入要解封的 IP: " ip
  [ -z "${ip:-}" ] && { warn "IP 不能为空"; return; }
  fail2ban-client set sshd unbanip "$ip" || { err "解封失败"; return; }
  ok "已解封：$ip"
}

# -------------------- 白名单：查看 / 设置 --------------------
show_whitelist(){
  if ! f2b_installed; then err "fail2ban 未安装。"; return; fi
  echo
  info "【运行时生效】sshd 规则组 ignoreip 白名单："
  if fail2ban-client get sshd ignoreip >/dev/null 2>&1; then
    fail2ban-client get sshd ignoreip || true
  else
    warn "读取运行时 ignoreip 失败（可能 sshd 规则组未加载或版本差异）。"
  fi

  echo
  info "【配置文件】${JAIL_LOCAL} 中的 ignoreip："
  if [ -f "$JAIL_LOCAL" ]; then
    grep -nEi '^\s*ignoreip\s*=' "$JAIL_LOCAL" 2>/dev/null || echo "(未设置)"
  else
    echo "(${JAIL_LOCAL} 不存在)"
  fi
}

set_whitelist(){
  ensure_sshd_group || return

  echo
  info "当前配置文件里的 ignoreip："
  grep -nEi '^\s*ignoreip\s*=' "$JAIL_LOCAL" 2>/dev/null || echo "(未设置)"

  hr
  echo "请输入要加入白名单的 IP/网段（空格分隔），例如："
  echo "  127.0.0.1/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
  echo
  read -r -p "ignoreip = " add
  [ -z "${add:-}" ] && { warn "未输入，取消。"; return; }

  backup_f2b

  local cur=""
  cur="$(awk 'tolower($1)=="ignoreip" && $2=="="{for(i=3;i<=NF;i++) printf $i" "; print ""}' "$JAIL_LOCAL" | tail -n1 | sed 's/[[:space:]]*$//' || true)"

  if grep -qiE '^\s*ignoreip\s*=' "$JAIL_LOCAL"; then
    local merged=""
    merged="$(printf "%s %s" "${cur:-}" "$add" | tr " " "\n" | awk 'NF{print}' | awk '!seen[$0]++' | tr "\n" " " | sed 's/[[:space:]]*$//')"
    perl -0777 -i -pe "s/^\s*ignoreip\s*=.*?\$/ignoreip = ${merged}/mi" "$JAIL_LOCAL"
    ok "已合并并更新 ignoreip。"
  else
    awk -v ins="ignoreip = ${add}" '
      BEGIN{done=0}
      /^\[DEFAULT\]/{print; if(!done){print ins; done=1; next}}
      {print}
      END{ if(!done){print "[DEFAULT]"; print ins} }
    ' "$JAIL_LOCAL" > "${JAIL_LOCAL}.tmp" && mv "${JAIL_LOCAL}.tmp" "$JAIL_LOCAL"
    ok "已新增 ignoreip。"
  fi

  svc restart
  ok "fail2ban 已重启，白名单已生效。"
}

# -------------------- 一键调参（温和/默认/狠点） --------------------
tune_params_quick(){
  ensure_sshd_group || return
  echo
  echo "请选择预设（只改 [DEFAULT] 的 3 个参数，不改其它）："
  echo "  1) 温和（更不易误封）: maxretry=8  findtime=10m  bantime=30m"
  echo "  2) 默认（平衡）      : maxretry=5  findtime=10m  bantime=1h"
  echo "  3) 狠点（更强力）    : maxretry=3  findtime=5m   bantime=24h"
  read -r -p "选择 [1/2/3]: " n

  local bantime findtime maxretry
  case "$n" in
    1) bantime="30m"; findtime="10m"; maxretry="8" ;;
    2) bantime="1h";  findtime="10m"; maxretry="5" ;;
    3) bantime="24h"; findtime="5m";  maxretry="3" ;;
    *) warn "无效选择"; return ;;
  esac

  backup_f2b

  set_kv(){
    local key="$1" val="$2"
    if grep -qiE "^\s*${key}\s*=" "$JAIL_LOCAL"; then
      perl -0777 -i -pe "s/^\s*${key}\s*=.*?\$/${key}  = ${val}/mi" "$JAIL_LOCAL"
    else
      awk -v ins="${key}  = ${val}" '
        BEGIN{done=0}
        /^\[DEFAULT\]/{print; if(!done){print ins; done=1; next}}
        {print}
        END{ if(!done){print "[DEFAULT]"; print ins} }
      ' "$JAIL_LOCAL" > "${JAIL_LOCAL}.tmp" && mv "${JAIL_LOCAL}.tmp" "$JAIL_LOCAL"
    fi
  }

  set_kv "bantime" "$bantime"
  set_kv "findtime" "$findtime"
  set_kv "maxretry" "$maxretry"

  ok "参数已更新：bantime=${bantime}, findtime=${findtime}, maxretry=${maxretry}"
  svc restart
  ok "fail2ban 已重启。"
}

# -------------------- 查看日志 --------------------
view_logs(){
  if ! f2b_installed; then err "fail2ban 未安装。"; return; fi
  echo
  echo "选择要查看的日志："
  echo "  1) fail2ban 服务日志（journalctl，最近 200 行）"
  echo "  2) /var/log/fail2ban.log（最近 200 行）"
  echo "  3) SSH 登录日志（auth.log 或 secure，最近 200 行）"
  read -r -p "选择 [1/2/3]: " n

  case "$n" in
    1) has_cmd journalctl && journalctl -u fail2ban --no-pager -n 200 || warn "没有 journalctl" ;;
    2) [ -f /var/log/fail2ban.log ] && tail -n 200 /var/log/fail2ban.log || warn "fail2ban.log 不存在" ;;
    3)
      if [ -f /var/log/auth.log ]; then tail -n 200 /var/log/auth.log
      elif [ -f /var/log/secure ]; then tail -n 200 /var/log/secure
      else warn "未找到 auth.log/secure"
      fi
      ;;
    *) warn "无效选择" ;;
  esac
}

# -------------------- 自安装（不联网） --------------------
self_install(){
  need_root
  mkdir -p "$INSTALL_DIR"

  local src="${1:-}"
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  fi
  [ -f "$src" ] || { err "找不到脚本本体，无法安装。"; exit 1; }

  install -m 755 "$src" "$INSTALLED_SCRIPT"
  ln -sf "$INSTALLED_SCRIPT" "$BIN_PATH"

  ok "安装完成：以后直接运行 sudo ${APP_NAME}"
  info "安装路径：${INSTALLED_SCRIPT}"
  info "命令路径：${BIN_PATH}"
  info "提示：正常运行不联网；只有“更新脚本”才联网。"
}

# -------------------- 更新脚本（唯一联网项） --------------------
self_update_from_github(){
  need_root
  has_cmd curl || { err "缺少 curl，请先安装 curl 再更新。"; exit 1; }

  mkdir -p "$INSTALL_DIR"
  local ts tmp
  ts="$(timestamp)"
  tmp="/tmp/${APP_NAME}.sh.${ts}"

  echo
  warn "即将联网从 GitHub 拉取最新脚本（唯一联网动作）："
  echo -e "  ${C_DIM}${REPO_RAW_URL}${C_RESET}"
  read -r -p "确认更新？输入 YES 继续: " yn
  [ "${yn:-}" = "YES" ] || { warn "取消更新。"; return; }

  info "开始下载更新..."
  curl -fL "$REPO_RAW_URL" -o "$tmp"
  chmod +x "$tmp"

  if [ -f "$INSTALLED_SCRIPT" ]; then
    cp -a "$INSTALLED_SCRIPT" "${INSTALLED_SCRIPT}.bak.${ts}"
    ok "已备份旧版本 -> ${INSTALLED_SCRIPT}.bak.${ts}"
  fi

  mv "$tmp" "$INSTALLED_SCRIPT"
  ln -sf "$INSTALLED_SCRIPT" "$BIN_PATH"
  ok "更新完成。"
}

# -------------------- 美化菜单 --------------------
banner(){
  clear || true
  echo -e "${C_MAGENTA}${C_BOLD}"
  echo "  ███████╗███████╗██████╗ "
  echo "  ██╔════╝╚══███╔╝██╔══██╗"
  echo "  █████╗    ███╔╝ ██████╔╝"
  echo "  ██╔══╝   ███╔╝  ██╔══██╗"
  echo "  ██║     ███████╗██████╔╝"
  echo "  ╚═╝     ╚══════╝╚═════╝ "
  echo -e "${C_RESET}"
  echo -e "${C_GRAY}Fail2ban 工具箱（默认不联网；只有“更新脚本”才访问 GitHub）${C_RESET}"
  echo -e "$(summary_line)"
  hr
}

menu_item(){
  local key="$1"; shift
  local text="$*"
  printf "  %s%s%s) %s\n" "${C_CYAN}${C_BOLD}" "${key}" "${C_RESET}" "${text}"
}

menu_item2(){
  local key="$1"; shift
  local text="$*"
  printf "  %s%s%s  %s\n" "${C_YELLOW}${C_BOLD}" "${key}" "${C_RESET}" "${text}"
}

print_menu(){
  banner
  menu_item "1"  "安装 fail2ban"
  menu_item "2"  "写入/更新配置 jail.local（启用 SSH 防爆破）"
  menu_item "3"  "查看状态（服务 + 规则组）"
  menu_item "4"  "查看封禁列表（sshd 规则组）"
  menu_item "5"  "手动封禁 IP（sshd 规则组）"
  menu_item "6"  "手动解封 IP（sshd 规则组）"
  menu_item "7"  "查看白名单 ignoreip（sshd 规则组）"
  menu_item "8"  "设置/追加白名单 ignoreip（sshd 规则组）"
  menu_item "9"  "一键调参（温和/默认/狠点）"
  menu_item "10" "查看日志（fail2ban / SSH）"
  hr
  menu_item2 "u" "更新脚本（唯一联网项）"
  menu_item2 "0" "退出"
  hr
}

menu_loop(){
  need_root
  while true; do
    print_menu
    echo -ne "${C_BOLD}请选择${C_RESET} (${C_CYAN}1-10${C_RESET}/${C_YELLOW}u${C_RESET}/${C_GRAY}0${C_RESET}): "
    read -r choice
    case "$choice" in
      1) install_fail2ban; pause ;;
      2) install_fail2ban; write_jail_local; pause ;;
      3) show_status; pause ;;
      4) show_banned; pause ;;
      5) ban_ip; pause ;;
      6) unban_ip; pause ;;
      7) show_whitelist; pause ;;
      8) set_whitelist; pause ;;
      9) tune_params_quick; pause ;;
      10) view_logs; pause ;;
      u|U) self_update_from_github; pause ;;
      0) ok "退出。"; exit 0 ;;
      *) warn "无效选择：$choice"; pause ;;
    esac
  done
}

# -------------------- 入口 --------------------
case "${1:-}" in
  install) self_install "$0" ;;
  update)  self_update_from_github ;;
  *)       menu_loop ;;
esac
