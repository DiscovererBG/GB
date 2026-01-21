#!/usr/bin/env bash
# ============================================================
#  Secure VPS SSH Setup Script (Public-safe)
#  ------------------------------------------------------------
#  Features:
#   1) Create a sudo user (safe username validation)
#   2) Install LOCAL SSH PUBLIC key into authorized_keys
#   3) Safe SSH port change:
#        - backup sshd_config
#        - firewall pre-allow new+old port
#        - sshd -t validation
#        - rollback on failure
#   4) Stage-2 hardening (optional, explicit confirmation):
#        - disable root SSH login
#        - optionally disable password login
#
#  IMPORTANT (put in your README):
#   - Ensure you have cloud Console/VNC access before changing SSH settings.
#   - Generate SSH KEYPAIR locally; DO NOT share your private key.
#   - Only run Stage-2 hardening after you confirmed key-login works.
# ============================================================

set -euo pipefail

# ---------- UI ----------
SCRIPT_NAME="BING CONTROL (SECURE)"
COLOR_CYAN="\e[1;36m"
COLOR_RESET="\e[0m"

# ---------- Helpers ----------
die() { echo "❌ $*" >&2; exit 1; }
info() { echo "✅ $*"; }
warn() { echo "⚠️  $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行此脚本。"
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr() {
  if command_exists apt-get; then echo "apt"
  elif command_exists dnf; then echo "dnf"
  elif command_exists yum; then echo "yum"
  elif command_exists pacman; then echo "pacman"
  else echo "unknown"
  fi
}

install_dependencies() {
  local mgr; mgr="$(detect_pkg_mgr)"
  info "正在检测系统并安装必要依赖…(pkg=${mgr})"

  case "${mgr}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      # 如果 dpkg 被中断，先尝试修复，避免 apt/ufw 安装失败
      dpkg --configure -a >/dev/null 2>&1 || true
      apt-get update -y
      apt-get install -y curl sudo openssh-server ufw fail2ban \
        -o Dpkg::Options::="--force-confold"
      ;;
    yum)
      yum install -y curl sudo openssh-server firewalld || true
      yum install -y fail2ban || true
      ;;
    dnf)
      dnf install -y curl sudo openssh-server firewalld || true
      dnf install -y fail2ban || true
      ;;
    pacman)
      pacman -Syu --noconfirm curl sudo openssh ufw fail2ban
      ;;
    *)
      die "无法检测到支持的包管理器，请手动安装：curl sudo openssh-server 以及 ufw/firewalld。"
      ;;
  esac

  info "依赖项安装完成。"
}

ensure_deps() {
  local need=0
  for bin in curl sshd; do
    if ! command_exists "${bin}"; then need=1; fi
  done
  if [[ "${need}" -eq 1 ]]; then
    warn "检测到缺少依赖，开始安装…"
    install_dependencies
  fi
}

display_logo() {
  echo -e "${COLOR_CYAN}"
  echo "╔═════════════════════════════════════════╗"
  echo "║                                         ║"
  echo "║            ${SCRIPT_NAME}               ║"
  echo "║         SAFE SSH USER/KEY/HARDEN        ║"
  echo "║                                         ║"
  echo "╚═════════════════════════════════════════╝"
  echo -e "${COLOR_RESET}"
}

valid_username() {
  # 仅允许：小写字母/下划线开头，后续小写字母数字下划线短横线，长度 1-31
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

valid_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

get_public_ip() {
  curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || true
}

get_current_ssh_port() {
  local cfg="/etc/ssh/sshd_config"
  local p=""
  if [[ -f "${cfg}" ]]; then
    p="$(awk 'tolower($1)=="port"{print $2}' "${cfg}" | tail -n1 || true)"
  fi
  if [[ -z "${p}" ]]; then
    p="$(ss -lntp 2>/dev/null | awk '/sshd/{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | head -n1 || true)"
  fi
  echo "${p:-22}"
}

restart_ssh_service() {
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

backup_file() {
  local f="$1"
  [[ -f "${f}" ]] || die "找不到文件：${f}"
  local bk="${f}.bak.$(date +%F_%H%M%S)"
  cp "${f}" "${bk}"
  echo "${bk}"
}

sshd_config_test() {
  /usr/sbin/sshd -t
}

enable_firewall_if_possible() {
  if command_exists ufw; then
    ufw --force enable >/dev/null 2>&1 || true
  fi
  if command_exists firewall-cmd; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
  fi
}

firewall_allow_port() {
  local port="$1"
  if command_exists ufw; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command_exists firewall-cmd; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

firewall_remove_port() {
  local port="$1"
  if command_exists ufw; then
    # ufw remove by rule number is safer; we provide guidance only
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command_exists firewall-cmd; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

firewall_status_hint() {
  if command_exists ufw; then
    ufw status numbered || true
  fi
  if command_exists firewall-cmd; then
    firewall-cmd --list-ports || true
  fi
}

ensure_sudoers_file() {
  local user="$1"
  local mode="$2"  # "withpass" | "nopass"
  local f="/etc/sudoers.d/${user}"
  if [[ "${mode}" == "nopass" ]]; then
    echo "${user} ALL=(ALL) NOPASSWD:ALL" > "${f}"
  else
    echo "${user} ALL=(ALL) ALL" > "${f}"
  fi
  chmod 440 "${f}"
  if command_exists visudo; then
    visudo -cf "${f}" >/dev/null || die "sudoers 语法校验失败：${f}（请修复）"
  fi
}

print_login_hint() {
  local user="$1"
  local port="$2"
  local ip; ip="$(get_public_ip)"
  echo
  echo "================== 登录提示 =================="
  if [[ -n "${ip}" ]]; then
    echo "服务器公网 IP: ${ip}"
  else
    echo "服务器公网 IP: （无法自动获取）"
  fi
  echo "SSH 端口: ${port}"
  echo "建议登录命令（在你本地 Mac 终端）："
  echo "  ssh -p ${port} ${user}@<服务器IP>"
  echo "================================================"
  echo
}

# ---------- Actions ----------
create_user_and_install_pubkey() {
  local username=""
  while true; do
    read -r -p "请输入新用户名（仅小写字母/数字/_/-，小写字母开头）: " username
    [[ -n "${username}" ]] || { warn "用户名不能为空。"; continue; }
    valid_username "${username}" || { warn "用户名格式不安全/不合法。示例：sgbg / admin_01 / user-a"; continue; }
    if id -u "${username}" >/dev/null 2>&1; then
      warn "用户 ${username} 已存在，将继续配置 sudo/公钥。"
      break
    fi
    adduser --disabled-password --gecos "" "${username}"
    info "用户 ${username} 创建成功。"
    break
  done

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "${username}"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "${username}"
  else
    warn "未找到 sudo/wheel 组，可能需要先安装 sudo。"
  fi

  while true; do
    read -r -p "使用 sudo 时需要输入密码吗？(yes/no) [建议 yes]: " sudo_choice
    case "${sudo_choice}" in
      yes|"")
        ensure_sudoers_file "${username}" "withpass"
        info "已配置：sudo 需要输入密码。"
        break
        ;;
      no)
        read -r -p "你选择了 sudo 免密（风险更高）。确认输入 YES 继续: " c2
        [[ "${c2}" == "YES" ]] || { warn "已取消免密设置，改为需要密码。"; ensure_sudoers_file "${username}" "withpass"; break; }
        ensure_sudoers_file "${username}" "nopass"
        warn "已配置：sudo 免密（安全性更低）。"
        break
        ;;
      *)
        warn "无效输入，请输入 yes 或 no。"
        ;;
    esac
  done

  while true; do
    read -r -p "是否为该用户设置登录密码（可选）？(yes/no): " setpass
    case "${setpass}" in
      yes)
        local p1="" p2=""
        read -r -s -p "请输入用户密码: " p1; echo
        read -r -s -p "请再次输入用户密码: " p2; echo
        [[ "${p1}" == "${p2}" ]] || { warn "两次密码不一致。"; continue; }
        echo "${username}:${p1}" | chpasswd
        info "密码设置成功。"
        break
        ;;
      no)
        info "已跳过密码设置（推荐后续仅用公钥登录）。"
        break
        ;;
      *)
        warn "无效输入，请输入 yes 或 no。"
        ;;
    esac
  done

  echo
  echo "请粘贴你【本地 Mac mini】生成的 SSH 公钥（一整行，以 ssh-ed25519/ssh-rsa 开头），然后回车："
  echo "Mac 查看公钥：cat ~/.ssh/id_ed25519.pub"
  local pubkey=""
  read -r pubkey
  [[ -n "${pubkey}" ]] || die "公钥不能为空。"
  [[ "${pubkey}" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]] ]] || die "公钥格式不正确：必须以 ssh-ed25519/ssh-rsa/ssh-ecdsa 开头。"

  local sshdir="/home/${username}/.ssh"
  local ak="${sshdir}/authorized_keys"
  install -d -m 700 -o "${username}" -g "${username}" "${sshdir}"
  touch "${ak}"
  chmod 600 "${ak}"
  chown "${username}:${username}" "${ak}"

  if grep -qxF "${pubkey}" "${ak}"; then
    info "公钥已存在于 ${ak}，无需重复写入。"
  else
    echo "${pubkey}" >> "${ak}"
    info "公钥已写入：${ak}"
  fi

  local port; port="$(get_current_ssh_port)"
  print_login_hint "${username}" "${port}"

  info "建议：先在本地开新终端测试登录成功，再做端口修改/加固。"
}

safe_change_ssh_port() {
  local old_port; old_port="$(get_current_ssh_port)"
  echo "当前检测到 SSH 端口为：${old_port}"

  local new_port=""
  while true; do
    read -r -p "请输入新的 SSH 端口号（1-65535）: " new_port
    valid_port "${new_port}" || { warn "端口不合法。"; continue; }
    if [[ "${new_port}" == "${old_port}" ]]; then
      warn "新端口与旧端口相同，无需更改。"
      return 0
    fi
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${new_port}$"; then
      warn "端口 ${new_port} 已被占用，请换一个。"
      continue
    fi
    break
  done

  local cfg="/etc/ssh/sshd_config"
  local backup; backup="$(backup_file "${cfg}")"
  info "已备份 sshd_config：${backup}"

  enable_firewall_if_possible
  firewall_allow_port "${new_port}"
  firewall_allow_port "${old_port}"

  # 更稳：删除所有 Port 行，再追加一行
  sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "${cfg}"
  echo "Port ${new_port}" >> "${cfg}"

  if ! sshd_config_test 2>/tmp/sshd_test_err; then
    warn "sshd 配置校验失败，正在回滚到备份…"
    cat /tmp/sshd_test_err >&2 || true
    cp "${backup}" "${cfg}"
    die "已回滚。请修复配置后再试。"
  fi

  restart_ssh_service

  echo
  info "SSH 端口已更改为：${new_port}"
  warn "重要：请【不要关闭当前会话】。请在本地开一个新终端测试："
  echo "   ssh -p ${new_port} <用户名>@<服务器IP>"
  echo
  warn "确认新端口可登录后，可选移除旧端口（防火墙）：${old_port}"
  info "当前防火墙端口列表（如有）："
  firewall_status_hint
}

stage2_hardening() {
  echo
  warn "【第二阶段加固】将降低爆破风险，但做错会锁外。"
  warn "务必先确认：你已经能用【新用户 + 公钥】正常 SSH 登录。"
  echo
  read -r -p "你已确认可用新用户+公钥登录成功了吗？输入 YES 继续: " confirm
  [[ "${confirm}" == "YES" ]] || { warn "未确认，已取消。"; return 0; }

  local cfg="/etc/ssh/sshd_config"
  local backup; backup="$(backup_file "${cfg}")"
  info "已备份 sshd_config：${backup}"

  sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' "${cfg}"
  if ! grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+' "${cfg}"; then
    echo "PermitRootLogin no" >> "${cfg}"
  fi

  while true; do
    read -r -p "是否禁用 SSH 密码登录（强烈建议）？(yes/no): " ans
    case "${ans}" in
      yes)
        sed -i -E 's/^[#[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' "${cfg}"
        if ! grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+' "${cfg}"; then
          echo "PasswordAuthentication no" >> "${cfg}"
        fi
        break
        ;;
      no)
        info "已选择保留密码登录（安全性更低）。"
        break
        ;;
      *)
        warn "无效输入，请输入 yes 或 no。"
        ;;
    esac
  done

  sed -i -E 's/^[#[:space:]]*PubkeyAuthentication[[:space:]]+.*/PubkeyAuthentication yes/' "${cfg}"
  if ! grep -qE '^[[:space:]]*PubkeyAuthentication[[:space:]]+' "${cfg}"; then
    echo "PubkeyAuthentication yes" >> "${cfg}"
  fi

  if ! sshd_config_test 2>/tmp/sshd_test_err; then
    warn "sshd 配置校验失败，正在回滚到备份…"
    cat /tmp/sshd_test_err >&2 || true
    cp "${backup}" "${cfg}"
    die "已回滚。"
  fi

  restart_ssh_service
  info "加固完成：root SSH 已禁用；（如选择）密码登录已禁用。"
}

close_port_39515() {
  local port="39515"
  warn "将尝试关闭 ${port}/tcp（防火墙层）。注意：云厂商安全组也要同步关闭。"
  if command_exists ufw; then
    ufw deny "${port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    info "UFW 已处理 ${port}/tcp。"
  fi
  if command_exists firewall-cmd; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "firewalld 已处理 ${port}/tcp。"
  fi
  info "当前防火墙端口列表："
  firewall_status_hint
}

show_status() {
  local port; port="$(get_current_ssh_port)"
  echo "==== SSH 状态 ===="
  echo "SSH Port: ${port}"
  echo "sshd_config test:"
  if sshd_config_test >/dev/null 2>&1; then
    echo "  ✅ sshd -t OK"
  else
    echo "  ❌ sshd -t FAILED"
    /usr/sbin/sshd -t || true
  fi
  echo
  echo "Systemd service:"
  systemctl --no-pager -l status ssh 2>/dev/null || systemctl --no-pager -l status sshd 2>/dev/null || true
  echo
  echo "Listening ports (sshd):"
  ss -lntp 2>/dev/null | grep -E 'sshd|:22|:'"${port}" || true
  echo
  echo "Firewall (if any):"
  firewall_status_hint
}

show_menu() {
  while true; do
    echo
    echo "================================="
    echo "       主程序控制面板（安全版）  "
    echo "================================="
    echo "1) 创建用户 + 配置 sudo + 安装本地公钥"
    echo "2) 安全更改 SSH 端口（先放行防火墙 + 校验 + 可回滚）"
    echo "3) 第二阶段加固（禁用 root SSH / 可选禁用密码登录）"
    echo "4) 关闭 39515 端口（防火墙层）"
    echo "5) 查看 SSH/防火墙状态"
    echo "0) 退出"
    echo "================================="
    read -r -p "请选择一个操作 (0-5): " choice
    case "${choice}" in
      1) create_user_and_install_pubkey ;;
      2) safe_change_ssh_port ;;
      3) stage2_hardening ;;
      4) close_port_39515 ;;
      5) show_status ;;
      0) echo "退出程序。"; exit 0 ;;
      *) warn "无效选项，请重新选择。" ;;
    esac
  done
}

# ---------- Entry ----------
require_root
ensure_deps
display_logo
show_menu
