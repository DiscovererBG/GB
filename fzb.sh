#!/usr/bin/env bash
# =========================================================
# fzb - Fail2ban 菜单式工具箱（单文件版）
# 目标：下载一次 -> 本地运行 fzb 出菜单；默认不联网；仅“更新”才拉 GitHub
# =========================================================
set -euo pipefail

APP_NAME="fzb"
INSTALL_DIR="/opt/${APP_NAME}"
INSTALLED_SCRIPT="${INSTALL_DIR}/${APP_NAME}.sh"
BIN_PATH="/usr/local/sbin/${APP_NAME}"

# =========================
# ✅ 你只需要改这一行（改成你自己的 GitHub Raw 地址）
REPO_RAW_URL="https://raw.githubusercontent.com/你的用户名/你的仓库/main/fzb.sh"
# =========================

# ---------- UI ----------
c_green="\033[1;32m"; c_yellow="\033[1;33m"; c_red="\033[1;31m"; c_blue="\033[1;34m"; c_reset="\033[0m"
ok(){ echo -e "${c_green}[OK]${c_reset} $*"; }
warn(){ echo -e "${c_yellow}[WARN]${c_reset} $*"; }
err(){ echo -e "${c_red}[ERR]${c_reset} $*"; }
info(){ echo -e "${c_blue}[INFO]${c_reset} $*"; }
pause(){ read -r -p "回车继续..." _; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 运行：sudo -i 或 sudo fzb"
    exit 1
  fi
}

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

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

timestamp(){ date +%Y%m%d%H%M%S; }

JAIL_LOCAL="/etc/fail2ban/jail.local"
F2B_DIR="/etc/fail2ban"
BACKUP_DIR="/root/fzb_backups"

ensure_dirs(){ mkdir -p "$BACKUP_DIR"; }

backup_f2b(){
  ensure_dirs
  local ts; ts="$(timestamp)"
  local dst="${BACKUP_DIR}/fail2ban_${ts}"
  mkdir -p "$dst"
  if [ -d "$F2B_DIR" ]; then
    cp -a "$F2B_DIR" "$dst/" 2>/dev/null || true
    ok "已备份 ${F2B_DIR} -> ${dst}/fail2ban"
  else
    warn "未找到 ${F2B_DIR}，跳过备份。"
  fi
}

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

write_jail_local(){
  local ssh_port; ssh_port="$(detect_ssh_port)"
  read -r -p "检测到 SSH 端口 ${ssh_port}，使用它？[Y/n] " yn || true
  yn="${yn:-Y}"
  if [[ "$yn" =~ ^[Nn]$ ]]; then
    read -r -p "请输入你的 SSH 端口: " ssh_port
    ssh_port="${ssh_port:-22}"
  fi

  local bantime="1h" findtime="10m" maxretry="5" mode="aggressive"
  echo
  read -r -p "bantime（默认 1h）: " v || true; bantime="${v:-$bantime}"
  read -r -p "findtime（默认 10m）: " v || true; findtime="${v:-$findtime}"
  read -r -p "maxretry（默认 5）: " v || true; maxretry="${v:-$maxretry}"
  read -r -p "mode（normal/aggressive，默认 aggressive）: " v || true; mode="${v:-$mode}"

  backup_f2b
  mkdir -p "$F2B_DIR"

  cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
backend  = systemd

[sshd]
enabled  = true
port     = ${ssh_port}
mode     = ${mode}
EOF

  ok "已写入 ${JAIL_LOCAL}"
  svc enable
  svc restart
  ok "fail2ban 已重启。"
}

show_status(){
  if ! f2b_installed; then err "fail2ban 未安装。"; return; fi
  echo
  info "service 状态："
  svc status
  echo
  info "fail2ban 总状态："
  fail2ban-client status || true
  echo
  info "sshd jail 状态："
  fail2ban-client status sshd || true
}

ensure_sshd_jail(){
  if [ ! -f "$JAIL_LOCAL" ]; then warn "$JAIL_LOCAL 不存在，先执行“写入/更新配置”。"; return 1; fi
  if ! grep -qi "^\[sshd\]" "$JAIL_LOCAL"; then warn "$JAIL_LOCAL 没有 [sshd]，先写入配置。"; return 1; fi
  return 0
}

show_banned(){
  ensure_sshd_jail || return
  fail2ban-client status sshd || true
}

ban_ip(){
  ensure_sshd_jail || return
  read -r -p "输入要封禁的 IP: " ip
  [ -z "${ip:-}" ] && { warn "IP 不能为空"; return; }
  fail2ban-client set sshd banip "$ip" || { err "封禁失败"; return; }
  ok "已封禁：$ip"
}

unban_ip(){
  ensure_sshd_jail || return
  read -r -p "输入要解封的 IP: " ip
  [ -z "${ip:-}" ] && { warn "IP 不能为空"; return; }
  fail2ban-client set sshd unbanip "$ip" || { err "解封失败"; return; }
  ok "已解封：$ip"
}

edit_ignoreip(){
  ensure_sshd_jail || return
  local cur=""
  cur="$(awk 'tolower($1)=="ignoreip"{for(i=3;i<=NF;i++) printf $i" "; print ""}' "$JAIL_LOCAL" | tail -n1 | sed 's/[[:space:]]*$//' || true)"
  echo "当前 ignoreip: ${cur:-<未设置>}"
  echo "输入要加入白名单的 IP/CIDR（多个用空格分隔）："
  read -r add
  [ -z "${add:-}" ] && { warn "未输入，取消。"; return; }

  backup_f2b

  if grep -qiE '^[# ]*ignoreip[[:space:]]*=' "$JAIL_LOCAL"; then
    local merged=""
    merged="$(printf "%s %s" "${cur:-}" "$add" | tr " " "\n" | awk 'NF{print}' | awk '!seen[$0]++' | tr "\n" " " | sed 's/[[:space:]]*$//')"
    perl -0777 -i -pe "s/^[# ]*ignoreip[\\t ]*=.*?\$/ignoreip = ${merged}/mi" "$JAIL_LOCAL"
  else
    awk -v ins="ignoreip = ${add}" '
      BEGIN{done=0}
      /^\[DEFAULT\]/{print; if(!done){print ins; done=1; next}}
      {print}
      END{ if(!done){print "[DEFAULT]"; print ins} }
    ' "$JAIL_LOCAL" > "${JAIL_LOCAL}.tmp" && mv "${JAIL_LOCAL}.tmp" "$JAIL_LOCAL"
  fi

  ok "已更新白名单 ignoreip"
  svc restart
  ok "fail2ban 已重启。"
}

tune_params_quick(){
  ensure_sshd_jail || return
  echo "快速预设："
  echo "1) 温和：maxretry=8 findtime=10m bantime=30m"
  echo "2) 默认：maxretry=5 findtime=10m bantime=1h"
  echo "3) 狠点：maxretry=3 findtime=5m  bantime=24h"
  read -r -p "选择: " n

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
    if grep -qiE "^[# ]*${key}[[:space:]]*=" "$JAIL_LOCAL"; then
      perl -0777 -i -pe "s/^[# ]*${key}[\\t ]*=.*?\$/${key}  = ${val}/mi" "$JAIL_LOCAL"
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

  ok "已更新参数：bantime=${bantime}, findtime=${findtime}, maxretry=${maxretry}"
  svc restart
  ok "fail2ban 已重启。"
}

view_logs(){
  if ! f2b_installed; then err "fail2ban 未安装。"; return; fi
  echo "1) journalctl -u fail2ban（最近 200 行）"
  echo "2) /var/log/fail2ban.log（最近 200 行）"
  echo "3) SSH 登录日志 auth.log/secure（最近 200 行）"
  read -r -p "选择: " n
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

# ----------------- 安装/更新逻辑（关键：默认不联网） -----------------
self_install(){
  need_root
  mkdir -p "$INSTALL_DIR"
  # 复制当前脚本到安装目录（不联网）
  local src="${1:-}"
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    # 尝试用 BASH_SOURCE 取当前脚本路径
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  fi

  if [ ! -f "$src" ]; then
    err "找不到脚本文件本体，无法安装。"
    exit 1
  fi

  install -m 755 "$src" "$INSTALLED_SCRIPT"
  ln -sf "$INSTALLED_SCRIPT" "$BIN_PATH"
  ok "安装完成：以后直接运行 sudo ${APP_NAME}"
  info "安装路径：${INSTALLED_SCRIPT}"
  info "命令路径：${BIN_PATH}"
}

self_update_from_github(){
  need_root
  if ! has_cmd curl; then
    err "缺少 curl，先安装 curl 再更新。"
    exit 1
  fi
  if [ "$REPO_RAW_URL" = "https://raw.githubusercontent.com/你的用户名/你的仓库/main/fzb.sh" ]; then
    err "你还没把 REPO_RAW_URL 改成你自己的仓库地址。"
    exit 1
  fi

  mkdir -p "$INSTALL_DIR"
  local ts; ts="$(timestamp)"
  local tmp="/tmp/${APP_NAME}.sh.${ts}"

  info "开始从 GitHub 拉取更新（仅此动作联网）..."
  curl -fL "$REPO_RAW_URL" -o "$tmp"
  chmod +x "$tmp"

  # 备份旧版本
  if [ -f "$INSTALLED_SCRIPT" ]; then
    cp -a "$INSTALLED_SCRIPT" "${INSTALLED_SCRIPT}.bak.${ts}"
    ok "已备份旧版本 -> ${INSTALLED_SCRIPT}.bak.${ts}"
  fi

  mv "$tmp" "$INSTALLED_SCRIPT"
  ln -sf "$INSTALLED_SCRIPT" "$BIN_PATH"
  ok "更新完成。"
}

# ---------- Menu ----------
print_menu(){
  clear || true
  echo -e "${c_blue}================= fzb 工具箱（fail2ban）=================${c_reset}"
  echo "默认不联网；只有“更新”才会访问 GitHub"
  echo "---------------------------------------------------------"
  echo "1) 安装 fail2ban"
  echo "2) 写入/更新 jail.local（启用 sshd 防爆破）"
  echo "3) 查看状态（总状态 + sshd jail）"
  echo "4) 查看封禁列表（sshd）"
  echo "5) 手动封禁 IP（sshd）"
  echo "6) 手动解封 IP（sshd）"
  echo "7) 设置白名单 ignoreip（IP/CIDR）"
  echo "8) 一键调参（温和/默认/狠点）"
  echo "9) 查看日志（fail2ban / ssh）"
  echo "u) 从 GitHub 更新脚本（唯一联网项）"
  echo "0) 退出"
  echo "---------------------------------------------------------"
}

menu_loop(){
  need_root
  while true; do
    print_menu
    read -r -p "请选择: " choice
    case "$choice" in
      1) install_fail2ban; pause ;;
      2) install_fail2ban; write_jail_local; pause ;;
      3) show_status; pause ;;
      4) show_banned; pause ;;
      5) ban_ip; pause ;;
      6) unban_ip; pause ;;
      7) edit_ignoreip; pause ;;
      8) tune_params_quick; pause ;;
      9) view_logs; pause ;;
      u|U) self_update_from_github; pause ;;
      0) ok "退出。"; exit 0 ;;
      *) warn "无效选择"; pause ;;
    esac
  done
}

# ---------- Entry ----------
case "${1:-}" in
  install)
    # 你第一次下载到本地后跑：sudo -i bash ./fzb.sh install
    self_install "$0"
    ;;
  update)
    # 也支持命令行更新（同样会联网）：sudo fzb update
    self_update_from_github
    ;;
  *)
    # 正常运行：sudo fzb（不联网）
    menu_loop
    ;;
esac