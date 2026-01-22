#!/usr/bin/env bash
set -euo pipefail

# =========================
# Secure SSH Setup (Public-safe)
# - Menu + colors
# - One-line pubkey paste (ENTER to finish)
# - Backup/validate/rollback
# - Firewall helper (ufw/firewalld/iptables)
# - Optional /etc/hosts fix for sudo resolve host
# - Sudo setup helper (install sudo if missing, optional NOPASSWD, or set user password)
# - Install/Enable UFW helper
# - System update helper
# - Show firewall allowed rules/ports + offer to enable if inactive (UFW)
# - Fail2ban submenu (8 options): install/fix/start, status, show config, tune, whitelist, unban, ban list & logs, banaction switch
# - Expansion slot: generate template text for future tools/scripts
# =========================

# ---------- colors ----------
supports_color() { [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; }
if supports_color; then
  C0="$(tput sgr0)"
  CRED="$(tput setaf 1)"
  CGRN="$(tput setaf 2)"
  CYEL="$(tput setaf 3)"
  CBLU="$(tput setaf 4)"
  CCYA="$(tput setaf 6)"
  CBOLD="$(tput bold)"
else
  C0=""; CRED=""; CGRN=""; CYEL=""; CBLU=""; CCYA=""; CBOLD=""
fi

# ---------- output helpers ----------
die(){ echo "${CRED}❌ $*${C0}" >&2; exit 1; }
ok(){  echo "${CGRN}✅ $*${C0}" >&2; }
warn(){ echo "${CYEL}⚠️  $*${C0}" >&2; }
info(){ echo "${CCYA}ℹ️  $*${C0}" >&2; }

hr(){ printf "%s\n" "------------------------------------------------------------"; }

# ---------- root check ----------
[[ ${EUID:-0} -eq 0 ]] || die "请用 root 运行（sudo -i / su - / 直接 root 登录）"

CFG="/etc/ssh/sshd_config"
SSHD_BIN=""
SERVICE_NAME="ssh"

# ---------- detection ----------
detect_sshd() {
  if [[ -x /usr/sbin/sshd ]]; then
    SSHD_BIN="/usr/sbin/sshd"
  elif command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
  else
    die "找不到 sshd。请先安装 openssh-server（Ubuntu/Debian: apt-get install -y openssh-server）"
  fi
}
detect_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service'; then
      SERVICE_NAME="ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -qE '^sshd\.service'; then
      SERVICE_NAME="sshd"
    else
      SERVICE_NAME="ssh"
    fi
  else
    SERVICE_NAME="ssh"
  fi
}
restart_ssh() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME" 2>/dev/null \
      || systemctl restart ssh 2>/dev/null \
      || systemctl restart sshd 2>/dev/null \
      || true
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi
}
sshd_test() { "$SSHD_BIN" -t; }

# ---------- config helpers ----------
timestamp(){ date +%F_%H%M%S; }

backup_cfg() {
  local bk="${CFG}.bak.$(timestamp)"
  cp -a "$CFG" "$bk"
  echo "$bk"
}

get_current_port() {
  local p
  p="$(awk 'tolower($1)=="port"{print $2}' "$CFG" | tail -n1 || true)"
  echo "${p:-22}"
}

# Set directive key->value, remove all existing key lines (commented/uncommented), append one clean line.
set_directive_single() {
  local key="$1" value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" '
    BEGIN{IGNORECASE=1}
    {
      line=$0
      if (match(line, "^[ \t]*#?[ \t]*" k "[ \t]+")) next
      print $0
    }
  ' "$CFG" > "$tmp"
  printf "%s %s\n" "$key" "$value" >> "$tmp"
  cp "$tmp" "$CFG"
  rm -f "$tmp"
}

# AllowUsers merge: add users to existing list (optional override)
set_allowusers() {
  local mode="$1" # add|replace
  shift
  local want_users=("$@")
  [[ ${#want_users[@]} -gt 0 ]] || die "AllowUsers 用户列表不能为空"

  local existing=""
  existing="$(awk '
    BEGIN{IGNORECASE=1}
    tolower($1)=="allowusers"{
      for(i=2;i<=NF;i++) printf $i " "
    }
  ' "$CFG" | xargs || true)"

  local merged=""
  if [[ "$mode" == "replace" || -z "$existing" ]]; then
    merged="$(printf "%s " "${want_users[@]}" | xargs)"
  else
    local all=()
    # shellcheck disable=SC2206
    all=($existing "${want_users[@]}")
    local uniq=()
    local u
    for u in "${all[@]}"; do
      [[ -n "$u" ]] || continue
      if [[ ! " ${uniq[*]} " =~ " ${u} " ]]; then
        uniq+=("$u")
      fi
    done
    merged="$(printf "%s " "${uniq[@]}" | xargs)"
  fi

  set_directive_single "AllowUsers" "$merged"
}

valid_username() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }
valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1<=10#$1 && 10#$1<=65535 )); }

# ---------- sudo + user password helpers ----------
ensure_sudo_installed() {
  if command -v sudo >/dev/null 2>&1; then
    return 0
  fi

  warn "检测到系统未安装 sudo，正在尝试安装…"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo || die "sudo 安装失败（apt-get）。请先修复系统包管理（例如 dpkg/apt 错误）"
    ok "已安装 sudo"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo || die "sudo 安装失败（yum）"
    ok "已安装 sudo"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo || die "sudo 安装失败（dnf）"
    ok "已安装 sudo"
  else
    warn "无法自动安装 sudo（未识别包管理器）。你需要手动安装 sudo。"
    return 1
  fi
}

user_has_usable_password() {
  local u="$1"
  if passwd -S "$u" >/dev/null 2>&1; then
    local st
    st="$(passwd -S "$u" 2>/dev/null | awk '{print $2}' || true)"
    [[ "$st" == "P" ]] && return 0
    return 1
  fi
  local hash
  hash="$(awk -F: -v u="$u" '$1==u{print $2}' /etc/shadow 2>/dev/null || true)"
  [[ -z "$hash" ]] && return 1
  [[ "$hash" == "!"* || "$hash" == "*"* ]] && return 1
  return 0
}

set_user_password_interactive() {
  local u="$1"
  echo
  hr
  echo "${CBOLD}${CBLU}给用户【$u】设置系统密码（用于 sudo 验证）${C0}"
  echo "说明：这是 VPS 上该用户的系统密码，不是你本地 SSH 密钥 passphrase。"
  echo "接下来会让你输入两次新密码（输入时不显示）。"
  hr
  passwd "$u"
  ok "已为 $u 设置系统密码（sudo 会用这个密码验证）"
}

maybe_setup_sudo_for_user() {
  local u="$1"

  ensure_sudo_installed || true

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$u" || true
    ok "已将 $u 加入 sudo 组"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "$u" || true
    ok "已将 $u 加入 wheel 组"
  else
    warn "系统未找到 sudo/wheel 组，将使用 /etc/sudoers.d 授权"
    echo "$u ALL=(ALL) ALL" > "/etc/sudoers.d/$u"
    chmod 440 "/etc/sudoers.d/$u"
    ok "已写入 /etc/sudoers.d/$u（sudo 默认需要该用户密码）"
  fi

  echo
  echo "${CBOLD}${CBLU}sudo 验证方式（给用户 $u）${C0}"
  echo "  1) sudo 需要输入 $u 的系统密码（推荐）"
  echo "  2) sudo 免密（NOPASSWD，更方便但安全性略降）"
  read -r -p "请选择 (1/2) [默认 1]: " m
  m="${m:-1}"

  if [[ "$m" == "2" ]]; then
    echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$u"
    chmod 440 "/etc/sudoers.d/$u"
    ok "已设置：$u sudo 免密（/etc/sudoers.d/$u）"
  else
    if ! user_has_usable_password "$u"; then
      warn "检测到 $u 目前没有可用系统密码（未设置或锁定）"
      read -r -p "现在就为 $u 设置系统密码吗？(yes/no) [默认 yes]: " yn
      yn="${yn:-yes}"
      if [[ "$yn" == "yes" ]]; then
        set_user_password_interactive "$u"
      else
        warn "你选择不设置密码：如果 $u 仍无密码，后续 sudo 会一直失败。"
      fi
    else
      ok "检测到 $u 已有系统密码（sudo 可用）"
    fi
  fi
}

ensure_user() {
  local u="$1"
  if id -u "$u" >/dev/null 2>&1; then
    ok "用户已存在：$u"
  else
    adduser --disabled-password --gecos "" "$u"
    ok "已创建用户：$u"
  fi

  maybe_setup_sudo_for_user "$u"

  install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
  touch "/home/$u/.ssh/authorized_keys"
  chmod 600 "/home/$u/.ssh/authorized_keys"
  chown "$u:$u" "/home/$u/.ssh/authorized_keys"
  ok "已准备：/home/$u/.ssh/authorized_keys"
}

# ---------- pubkey input (one line, ENTER to finish) ----------
install_pubkey_one_line() {
  local u="$1"
  local pub=""

  echo
  hr
  echo "${CBOLD}${CBLU}请粘贴你的 SSH 公钥（一整行），然后直接回车即可${C0}"
  echo "Mac 查看公钥：cat ~/.ssh/id_ed25519.pub"
  hr
  read -r pub

  pub="$(echo "$pub" | sed -e 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
  [[ -n "$pub" ]] || die "公钥不能为空"
  echo "$pub" | grep -qE '^ssh-(ed25519|rsa)[[:space:]]' || die "公钥格式不对（应以 ssh-ed25519 或 ssh-rsa 开头）"

  if grep -qxF "$pub" "/home/$u/.ssh/authorized_keys"; then
    ok "公钥已存在，跳过写入"
  else
    echo "$pub" >> "/home/$u/.ssh/authorized_keys"
    ok "公钥已写入：/home/$u/.ssh/authorized_keys"
  fi
}

# ---------- port change ----------
set_ssh_port() {
  local new_port="$1"
  local old_port
  old_port="$(get_current_port)"
  [[ "$new_port" != "$old_port" ]] || { ok "端口未变化：$old_port"; return 0; }

  local bk
  bk="$(backup_cfg)"
  ok "已备份 sshd_config：$bk"

  set_directive_single "Port" "$new_port"

  sshd_test || { cp -a "$bk" "$CFG"; die "sshd 配置校验失败，已回滚到：$bk"; }
  restart_ssh
  ok "SSH 端口已更改为：$new_port（旧：$old_port）"
}

# ---------- hardening ----------
authorized_keys_has_key() {
  local u="$1"
  [[ -s "/home/$u/.ssh/authorized_keys" ]]
}

harden_ssh() {
  local user="$1"
  local disable_pass="$2"    # yes/no
  local allowusers_mode="$3" # off/add/replace
  shift 3
  local allow_users_list=("$@")

  local bk
  bk="$(backup_cfg)"
  ok "已备份 sshd_config：$bk"

  set_directive_single "PermitRootLogin" "no"
  set_directive_single "PubkeyAuthentication" "yes"

  if [[ "$disable_pass" == "yes" ]]; then
    set_directive_single "PasswordAuthentication" "no"
  fi

  if [[ "$allowusers_mode" != "off" ]]; then
    [[ ${#allow_users_list[@]} -gt 0 ]] || die "你选择了 AllowUsers，但没有提供用户列表"
    set_allowusers "$allowusers_mode" "${allow_users_list[@]}"
  fi

  sshd_test || { cp -a "$bk" "$CFG"; die "sshd 配置校验失败，已回滚到：$bk"; }
  restart_ssh

  local msg="加固完成：禁 root SSH + 公钥认证已启用"
  [[ "$disable_pass" == "yes" ]] && msg="$msg + 已禁用密码登录"
  [[ "$allowusers_mode" != "off" ]] && msg="$msg + AllowUsers(${allowusers_mode})"
  ok "$msg"
}

# ---------- firewall helpers ----------
detect_firewall() {
  if command -v ufw >/dev/null 2>&1; then echo "ufw"; return 0; fi
  if command -v firewall-cmd >/dev/null 2>&1; then echo "firewalld"; return 0; fi
  if command -v iptables >/dev/null 2>&1; then echo "iptables"; return 0; fi
  echo "none"
}

firewall_allow_port() {
  local p="$1"
  valid_port "$p" || die "端口不合法"

  local fw
  fw="$(detect_firewall)"
  case "$fw" in
    ufw)
      ufw allow "${p}/tcp" || true
      ok "已执行：ufw allow ${p}/tcp"
      ;;
    firewalld)
      firewall-cmd --permanent --add-port="${p}/tcp" || true
      firewall-cmd --reload || true
      ok "已执行：firewalld 放行 ${p}/tcp"
      ;;
    iptables)
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
      ok "已执行：iptables 放行 ${p}/tcp（注意：重启可能丢失，需你自行持久化）"
      ;;
    none)
      warn "未检测到 ufw/firewalld/iptables。请到云厂商安全组放行 ${p}/tcp"
      ;;
  esac

  warn "重要：无论本机防火墙如何，云厂商安全组/防火墙也必须放行 ${p}/tcp"
}

firewall_close_port() {
  local p="$1"
  valid_port "$p" || die "端口不合法"

  local fw
  fw="$(detect_firewall)"
  case "$fw" in
    ufw)
      ufw delete allow "${p}/tcp" 2>/dev/null || ufw deny "${p}/tcp" 2>/dev/null || true
      ok "已尝试：ufw 删除/阻止 ${p}/tcp"
      ;;
    firewalld)
      firewall-cmd --permanent --remove-port="${p}/tcp" || true
      firewall-cmd --reload || true
      ok "已尝试：firewalld 移除 ${p}/tcp"
      ;;
    iptables)
      local line
      line="$(iptables -L INPUT -n --line-numbers | awk -v p="$p" '$0~"tcp" && $0~("dpt:"p){print $1; exit}' || true)"
      if [[ -n "$line" ]]; then
        iptables -D INPUT "$line" || true
        ok "已尝试：iptables 移除 INPUT 第 ${line} 条（dport ${p}）"
      else
        warn "iptables 未找到 dport ${p} 的 ACCEPT 规则（可能未放行或规则在别链）"
      fi
      ;;
    none)
      warn "未检测到本机防火墙工具。关闭端口请到云厂商安全组操作。"
      ;;
  esac
}

# ---------- show allowed rules/ports + offer enable if inactive ----------
firewall_show_rules_menu() {
  echo
  hr
  echo "${CBOLD}${CBLU}查看已放行端口/规则（ufw/firewalld/iptables）${C0}"
  hr

  local fw
  fw="$(detect_firewall)"
  echo "检测到防火墙: $fw"
  echo

  case "$fw" in
    ufw)
      if ! command -v ufw >/dev/null 2>&1; then
        warn "未安装 ufw"
        read -r -p "回车继续..." _
        return 0
      fi

      local st
      st="$(ufw status 2>/dev/null | head -n1 || true)"
      echo "${CCYA}ℹ️  UFW 状态：${C0}${st}"
      echo

      # 方法一：在查看时如果 inactive，就提示并可一键启用（并放行当前 SSH 端口）
      if echo "$st" | grep -qi "inactive"; then
        warn "UFW 当前未启用（inactive）"
        echo "你可以选择现在启用（会自动放行当前 SSH 端口：$(get_current_port)/tcp）"
        read -r -p "输入 YES 立即启用 UFW（其它跳过）: " ans
        if [[ "$ans" == "YES" ]]; then
          local p
          p="$(get_current_port)"
          info "放行当前 SSH 端口：${p}/tcp"
          ufw allow "${p}/tcp" >/dev/null 2>&1 || true
          ufw default deny incoming >/dev/null 2>&1 || true
          ufw default allow outgoing >/dev/null 2>&1 || true
          ufw --force enable >/dev/null 2>&1 || true
          ok "UFW 已启用"
          echo
        fi
      fi

      echo "${CCYA}ℹ️  UFW 规则（含已放行端口）：${C0}"
      ufw status numbered 2>/dev/null || ufw status verbose 2>/dev/null || true

      echo
      echo "${CCYA}ℹ️  已添加但未必启用的规则（show added）：${C0}"
      ufw show added 2>/dev/null || true
      ;;
    firewalld)
      echo "${CCYA}ℹ️  firewalld 状态：${C0}"
      systemctl is-active firewalld 2>/dev/null || true
      echo
      echo "${CCYA}ℹ️  开放端口：${C0}"
      firewall-cmd --list-ports 2>/dev/null || true
      echo
      echo "${CCYA}ℹ️  详细规则：${C0}"
      firewall-cmd --list-all 2>/dev/null || true
      ;;
    iptables)
      echo "${CCYA}ℹ️  iptables INPUT（含行号）：${C0}"
      iptables -L INPUT -n --line-numbers 2>/dev/null || true
      ;;
    none)
      warn "未检测到 ufw/firewalld/iptables。请到云厂商安全组/防火墙查看放行端口。"
      ;;
  esac

  echo
  warn "重要：即使本机已放行，云厂商安全组/防火墙也必须放行对应端口。"
  read -r -p "回车继续..." _
}

# ---------- UFW installer ----------
install_ufw_menu() {
  echo
  hr
  echo "${CBOLD}${CBLU}安装/启用 UFW（会自动放行当前 SSH 端口）${C0}"
  hr

  if ! command -v apt-get >/dev/null 2>&1; then
    warn "当前脚本仅对 Debian/Ubuntu 的 apt 安装 UFW 做了自动化。"
    warn "你的系统不是 apt 系，建议手动安装 ufw 或使用 firewalld。"
    read -r -p "回车继续..." _
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    info "开始安装 ufw…"
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw || die "ufw 安装失败（apt）"
    ok "ufw 已安装"
  else
    ok "ufw 已安装"
  fi

  local p
  p="$(get_current_port)"
  info "将放行当前 SSH 端口：${p}/tcp"
  ufw allow "${p}/tcp" >/dev/null 2>&1 || true

  echo
  echo "是否启用 UFW？"
  echo "  - 启用后：默认会阻止未允许的入站"
  echo "  - 注意：云安全组也必须放行 SSH 端口"
  read -r -p "输入 YES 启用（其它跳过）: " ans
  if [[ "$ans" == "YES" ]]; then
    ufw --force enable || true
    ok "UFW 已启用"
    ufw status verbose || true
  else
    warn "已跳过启用（仅安装/放行规则已写入）"
  fi

  read -r -p "回车继续..." _
}

# ---------- system update ----------
system_update_menu() {
  echo
  hr
  echo "${CBOLD}${CBLU}更新当前系统（自动识别 apt/yum/dnf）${C0}"
  hr
  warn "提示：更新可能耗时；过程中不要断开 SSH。"

  read -r -p "确认要更新？输入 YES 开始: " ans
  [[ "$ans" == "YES" ]] || { warn "已取消更新"; read -r -p "回车继续..." _; return 0; }

  if command -v apt-get >/dev/null 2>&1; then
    info "执行：apt-get update && apt-get upgrade -y"
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
    ok "apt 更新完成（如有内核更新，建议后续择机重启）"
  elif command -v dnf >/dev/null 2>&1; then
    info "执行：dnf upgrade -y"
    dnf upgrade -y || true
    ok "dnf 更新完成"
  elif command -v yum >/dev/null 2>&1; then
    info "执行：yum update -y"
    yum update -y || true
    ok "yum 更新完成"
  else
    warn "未识别系统包管理器（apt/yum/dnf）。请手动更新。"
  fi

  read -r -p "回车继续..." _
}

# ---------- status ----------
show_status() {
  echo
  hr
  echo "${CBOLD}${CBLU}SSH 监听与关键配置${C0}"
  hr
  ss -lntp 2>/dev/null | grep -E 'sshd' || true
  echo
  grep -nE '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers)' "$CFG" || true
  hr
}

# ---------- /etc/hosts fix ----------
fix_hosts() {
  local hn
  hn="$(hostname)"
  hr
  echo "${CBOLD}${CBLU}修复 sudo: unable to resolve host（可选）${C0}"
  hr
  echo "当前 hostname: $hn"
  echo "将追加一行到 /etc/hosts："
  echo "  127.0.1.1 $hn"
  read -r -p "输入 YES 才执行: " ans
  [[ "$ans" == "YES" ]] || { warn "已取消"; return 0; }

  if grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+$hn(\b|$)" /etc/hosts 2>/dev/null; then
    ok "/etc/hosts 已包含映射，无需修改"
  else
    echo "127.0.1.1 $hn" >> /etc/hosts
    ok "已追加到 /etc/hosts"
  fi
}

warn_hosts_if_needed() {
  local hn
  hn="$(hostname)"
  if ! grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+$hn(\b|$)" /etc/hosts 2>/dev/null; then
    warn "检测到 /etc/hosts 可能缺少 127.0.1.1 hostname 映射（可能出现 sudo: unable to resolve host）"
    info "建议菜单里选择：8) 修复 /etc/hosts（可选）"
  fi
}

# ---------- rollback ----------
list_backups() {
  ls -1t "${CFG}.bak."* 2>/dev/null | head -n 20 || true
}

rollback_menu() {
  hr
  echo "${CBOLD}${CBLU}回滚 sshd_config 备份（最多显示 20 个）${C0}"
  hr
  local bks
  bks="$(list_backups)"
  [[ -n "$bks" ]] || { warn "未找到备份文件：${CFG}.bak.*"; return 0; }

  local i=1
  local arr=()
  while IFS= read -r line; do
    arr+=("$line")
    printf "%2d) %s\n" "$i" "$line"
    i=$((i+1))
  done <<< "$bks"

  echo
  read -r -p "输入要回滚的编号（或 0 取消）: " n
  [[ "$n" =~ ^[0-9]+$ ]] || { warn "输入无效"; return 0; }
  (( n==0 )) && { warn "已取消"; return 0; }
  (( n>=1 && n<=${#arr[@]} )) || { warn "编号超范围"; return 0; }

  local chosen="${arr[$((n-1))]}"
  cp -a "$chosen" "$CFG"
  sshd_test || { warn "回滚后 sshd -t 仍失败，请检查：$chosen"; return 1; }
  restart_ssh
  ok "已回滚到：$chosen 并重启 SSH 服务"
}

# ============================================================
# 12) FAIL2BAN 子菜单（8 选项）—— 你以后不用记命令
# ============================================================

F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"
F2B_MARK_BEGIN="# ==== managed by Secure SSH Setup (Fail2ban) BEGIN ===="
F2B_MARK_END="# ==== managed by Secure SSH Setup (Fail2ban) END ===="

# ---- 简单校验：IP 或 CIDR（够用版）----
valid_ip_or_cidr() {
  local s="${1:-}"
  [[ -n "$s" ]] || return 1
  # IPv4
  if [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
    return 0
  fi
  # IPv6（宽松）
  if [[ "$s" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]; then
    return 0
  fi
  return 1
}

# ---- 检测日志来源：优先 auth.log / secure，否则 systemd journal ----
f2b_detect_log_mode() {
  # 返回两项：mode|logpath
  # mode: file-authlog / file-secure / systemd
  # logpath: 对应 logpath 值
  if [[ -f /var/log/auth.log ]]; then
    echo "file-authlog|/var/log/auth.log"
    return 0
  fi
  if [[ -f /var/log/secure ]]; then
    echo "file-secure|/var/log/secure"
    return 0
  fi
  # 关键：很多 Debian 新系统没写 auth.log，而是进 journal，所以要这样写
  echo "systemd|%(systemd_journal)s"
}

# ---- 安装 fail2ban（自动识别 apt/yum/dnf；偏向 Debian/Ubuntu）----
f2b_install_if_needed() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    ok "fail2ban 已安装"
    return 0
  fi

  warn "未检测到 fail2ban，开始安装…"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban || die "fail2ban 安装失败（apt）"
    ok "fail2ban 已安装（apt）"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y fail2ban || die "fail2ban 安装失败（dnf）"
    ok "fail2ban 已安装（dnf）"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y fail2ban || die "fail2ban 安装失败（yum）"
    ok "fail2ban 已安装（yum）"
  else
    die "未识别包管理器（apt/yum/dnf），无法自动安装 fail2ban"
  fi
}

# ---- 确保 jail.local 存在（不乱改用户其他配置）----
f2b_ensure_jail_local() {
  if [[ -f "$F2B_JAIL_LOCAL" ]]; then
    ok "已存在 jail.local：$F2B_JAIL_LOCAL"
    return 0
  fi

  # 如果不存在，生成一个最小 jail.local
  cat > "$F2B_JAIL_LOCAL" <<'EOF'
[DEFAULT]
# 这是 fail2ban 的本地配置文件（优先级高于 jail.conf）
# 你手动加的配置也可以写在这里。
EOF
  ok "已创建 jail.local：$F2B_JAIL_LOCAL"
}

# ---- 写入“受控区块”配置（只改这段，别的都不动）----
f2b_write_managed_block() {
  local port="$1"
  local backend="$2"
  local logpath="$3"
  local maxretry="$4"
  local findtime="$5"
  local bantime="$6"
  local ignoreip="$7"
  local banaction="$8"

  # 1) 先把旧的受控区块删掉（如果存在）
  local tmp
  tmp="$(mktemp)"
  awk -v b="$F2B_MARK_BEGIN" -v e="$F2B_MARK_END" '
    BEGIN{inblk=0}
    {
      if ($0==b) {inblk=1; next}
      if ($0==e) {inblk=0; next}
      if (!inblk) print $0
    }
  ' "$F2B_JAIL_LOCAL" > "$tmp"

  # 2) 追加新的受控区块
  {
    echo ""
    echo "$F2B_MARK_BEGIN"
    echo "# 这段由脚本维护：用于 sshd 防爆破（你以后不需要记命令）"
    echo "# 如果你要自己深度定制 fail2ban，请写到本文件其它区域；脚本不会动你其它配置"
    echo ""
    echo "[DEFAULT]"
    echo "# 白名单：避免你自己被误封（建议把你常用固定出口 IP 也加进来）"
    echo "ignoreip = ${ignoreip}"
    echo ""
    echo "[sshd]"
    echo "enabled = true"
    echo "# 自动读取你 SSH 当前端口（不是写死 22）"
    echo "port = ${port}"
    echo "# 日志来源：file 或 systemd（脚本自动识别）"
    echo "backend = ${backend}"
    echo "logpath = ${logpath}"
    echo ""
    echo "# 防爆破强度（可在菜单里改）："
    echo "maxretry = ${maxretry}"
    echo "findtime = ${findtime}"
    echo "bantime  = ${bantime}"
    echo ""
    echo "# 封禁动作：默认 iptables-multiport；如果你用 ufw，也可切换 banaction=ufw"
    echo "banaction = ${banaction}"
    echo "$F2B_MARK_END"
    echo ""
  } >> "$tmp"

  cp "$tmp" "$F2B_JAIL_LOCAL"
  rm -f "$tmp"
  ok "已写入 Fail2ban 受控配置到 jail.local（只维护 BEGIN/END 区块）"
}

# ---- 从受控区块读取当前参数（读不到就给默认）----
f2b_get_managed_value() {
  local key="$1"
  local def="$2"
  local v=""
  v="$(awk -v b="$F2B_MARK_BEGIN" -v e="$F2B_MARK_END" -v k="$key" '
    BEGIN{inblk=0}
    $0==b{inblk=1; next}
    $0==e{inblk=0; next}
    inblk==1{
      # 支持 key = value 或 key=value
      gsub(/^[ \t]+|[ \t]+$/, "", $0)
      if ($0 ~ ("^" k "[ \t]*=")) {
        sub("^" k "[ \t]*=[ \t]*", "", $0)
        print $0
        exit
      }
    }
  ' "$F2B_JAIL_LOCAL" 2>/dev/null || true)"
  if [[ -n "$v" ]]; then
    echo "$v"
  else
    echo "$def"
  fi
}

# ---- 计算默认 ignoreip（含 IPv6 loopback）----
f2b_default_ignoreip() {
  echo "127.0.0.1/8 ::1"
}

# ---- 确保 fail2ban 启动并打印状态 ----
f2b_restart_and_show() {
  info "尝试启动/重启 fail2ban…"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
  else
    service fail2ban restart >/dev/null 2>&1 || true
  fi

  echo
  hr
  echo "${CBOLD}${CBLU}状态输出${C0}"
  hr
  echo "${CCYA}ℹ️  service 状态：${C0}"
  systemctl status fail2ban --no-pager 2>/dev/null || true

  echo
  echo "${CCYA}ℹ️  fail2ban-client status：${C0}"
  fail2ban-client status 2>/dev/null || true

  echo
  echo "${CCYA}ℹ️  sshd jail：${C0}"
  fail2ban-client status sshd 2>/dev/null || true
}

# ---- (12-1) 一键安装/修复/启动：核心入口 ----
f2b_one_click_fix_start() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：一键安装/修复/启动（推荐）${C0}"
  hr

  f2b_install_if_needed
  f2b_ensure_jail_local

  # 识别日志源
  local mode_log
  mode_log="$(f2b_detect_log_mode)"
  local mode="${mode_log%%|*}"
  local logpath="${mode_log##*|}"

  if [[ "$mode" == "file-authlog" ]]; then
    ok "检测到日志文件：/var/log/auth.log"
    local backend="auto"
  elif [[ "$mode" == "file-secure" ]]; then
    ok "检测到日志文件：/var/log/secure"
    local backend="auto"
  else
    warn "未检测到 /var/log/auth.log 或 /var/log/secure"
    warn "将自动切换为 systemd journal 模式：backend=systemd + logpath=%(systemd_journal)s"
    local backend="systemd"
  fi

  # 读取 SSH 端口（你改过 Port 就跟着走）
  local port
  port="$(get_current_port)"

  # 若已有受控区块，尽量沿用用户改过的参数；没有就用默认
  local maxretry findtime bantime ignoreip banaction
  maxretry="$(f2b_get_managed_value "maxretry" "5")"
  findtime="$(f2b_get_managed_value "findtime" "10m")"
  bantime="$(f2b_get_managed_value "bantime"  "1h")"
  ignoreip="$(f2b_get_managed_value "ignoreip" "$(f2b_default_ignoreip)")"
  banaction="$(f2b_get_managed_value "banaction" "iptables-multiport")"

  # 写入受控区块
  f2b_write_managed_block "$port" "$backend" "$logpath" "$maxretry" "$findtime" "$bantime" "$ignoreip" "$banaction"

  # 启动并展示
  f2b_restart_and_show

  echo
  warn "提示：即使你已禁用 SSH 密码登录，fail2ban 仍有意义（挡扫描/爆破/异常连接）。"
  read -r -p "回车继续..." _
}

# ---- (12-2) 查看状态 ----
f2b_show_status() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：查看状态（service + jail）${C0}"
  hr

  echo "${CCYA}ℹ️  service 状态：${C0}"
  systemctl status fail2ban --no-pager 2>/dev/null || true

  echo
  echo "${CCYA}ℹ️  fail2ban-client status：${C0}"
  fail2ban-client status 2>/dev/null || true

  echo
  echo "${CCYA}ℹ️  sshd jail：${C0}"
  fail2ban-client status sshd 2>/dev/null || true

  read -r -p "回车继续..." _
}

# ---- (12-3) 查看当前关键配置（让你一眼看懂）----
f2b_show_config_summary() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：查看当前配置摘要（关键参数）${C0}"
  hr

  [[ -f "$F2B_JAIL_LOCAL" ]] || { warn "未找到 $F2B_JAIL_LOCAL（建议先跑 12-1）"; read -r -p "回车继续..." _; return 0; }

  local port backend logpath maxretry findtime bantime ignoreip banaction
  port="$(f2b_get_managed_value "port" "$(get_current_port)")"
  backend="$(f2b_get_managed_value "backend" "auto")"
  logpath="$(f2b_get_managed_value "logpath" "/var/log/auth.log")"
  maxretry="$(f2b_get_managed_value "maxretry" "5")"
  findtime="$(f2b_get_managed_value "findtime" "10m")"
  bantime="$(f2b_get_managed_value "bantime" "1h")"
  ignoreip="$(f2b_get_managed_value "ignoreip" "$(f2b_default_ignoreip)")"
  banaction="$(f2b_get_managed_value "banaction" "iptables-multiport")"

  echo "${CCYA}ℹ️  jail.local 文件：${C0}${F2B_JAIL_LOCAL}"
  echo "${CCYA}ℹ️  SSH 端口：${C0}${port}"
  echo "${CCYA}ℹ️  backend：${C0}${backend}"
  echo "${CCYA}ℹ️  logpath：${C0}${logpath}"
  echo "${CCYA}ℹ️  maxretry：${C0}${maxretry}"
  echo "${CCYA}ℹ️  findtime：${C0}${findtime}"
  echo "${CCYA}ℹ️  bantime ：${C0}${bantime}"
  echo "${CCYA}ℹ️  ignoreip：${C0}${ignoreip}"
  echo "${CCYA}ℹ️  banaction：${C0}${banaction}"

  echo
  echo "${CBOLD}${CBLU}受控区块内容（只维护这一段）${C0}"
  hr
  awk -v b="$F2B_MARK_BEGIN" -v e="$F2B_MARK_END" '
    $0==b{in=1}
    in==1{print}
    $0==e{in=0}
  ' "$F2B_JAIL_LOCAL" 2>/dev/null || true

  read -r -p "回车继续..." _
}

# ---- (12-4) 调整防爆破强度（maxretry/findtime/bantime）----
f2b_tune_strength() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：调整防爆破强度（maxretry/findtime/bantime）${C0}"
  hr

  f2b_install_if_needed
  f2b_ensure_jail_local

  # 先确保受控区块存在（没有就先跑一键）
  if ! grep -qF "$F2B_MARK_BEGIN" "$F2B_JAIL_LOCAL" 2>/dev/null; then
    warn "未检测到受控配置区块（建议先跑 12-1 一键安装/修复/启动）"
    read -r -p "现在直接跑 12-1 吗？输入 YES 继续: " ans
    [[ "$ans" == "YES" ]] || { warn "已取消"; read -r -p "回车继续..." _; return 0; }
    f2b_one_click_fix_start
    return 0
  fi

  local cur_max cur_find cur_ban
  cur_max="$(f2b_get_managed_value "maxretry" "5")"
  cur_find="$(f2b_get_managed_value "findtime" "10m")"
  cur_ban="$(f2b_get_managed_value "bantime" "1h")"

  echo "当前值：maxretry=${cur_max}, findtime=${cur_find}, bantime=${cur_ban}"
  echo
  echo "输入建议："
  echo "  - maxretry：数字（例如 5）"
  echo "  - findtime：例如 10m / 5m / 1h"
  echo "  - bantime ：例如 1h / 6h / 1d"
  echo

  local maxretry findtime bantime
  read -r -p "maxretry [默认 ${cur_max}]: " maxretry
  read -r -p "findtime [默认 ${cur_find}]: " findtime
  read -r -p "bantime  [默认 ${cur_ban}]: " bantime
  maxretry="${maxretry:-$cur_max}"
  findtime="${findtime:-$cur_find}"
  bantime="${bantime:-$cur_ban}"

  # 沿用其它参数
  local port backend logpath ignoreip banaction
  port="$(f2b_get_managed_value "port" "$(get_current_port)")"
  backend="$(f2b_get_managed_value "backend" "auto")"
  logpath="$(f2b_get_managed_value "logpath" "/var/log/auth.log")"
  ignoreip="$(f2b_get_managed_value "ignoreip" "$(f2b_default_ignoreip)")"
  banaction="$(f2b_get_managed_value "banaction" "iptables-multiport")"

  f2b_write_managed_block "$port" "$backend" "$logpath" "$maxretry" "$findtime" "$bantime" "$ignoreip" "$banaction"
  f2b_restart_and_show
  read -r -p "回车继续..." _
}

# ---- (12-5) 白名单 ignoreip 管理（避免你自己被封）----
f2b_manage_whitelist() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：白名单（ignoreip）管理${C0}"
  hr

  f2b_install_if_needed
  f2b_ensure_jail_local

  # 如果没受控区块，先引导一键
  if ! grep -qF "$F2B_MARK_BEGIN" "$F2B_JAIL_LOCAL" 2>/dev/null; then
    warn "未检测到受控配置区块（建议先跑 12-1）"
    read -r -p "现在直接跑 12-1 吗？输入 YES 继续: " ans
    [[ "$ans" == "YES" ]] || { warn "已取消"; read -r -p "回车继续..." _; return 0; }
    f2b_one_click_fix_start
    return 0
  fi

  local ignoreip
  ignoreip="$(f2b_get_managed_value "ignoreip" "$(f2b_default_ignoreip)")"

  echo "${CCYA}ℹ️  当前 ignoreip：${C0}${ignoreip}"
  echo
  echo "  1) 添加一个 IP/CIDR（推荐把你常用固定出口 IP 加进来）"
  echo "  2) 恢复默认（127.0.0.1/8 ::1）"
  echo "  0) 返回"
  read -r -p "请选择: " c

  case "$c" in
    1)
      local add
      read -r -p "输入要加入白名单的 IP/CIDR（例如 1.2.3.4 或 1.2.3.0/24）: " add
      valid_ip_or_cidr "$add" || { warn "格式不对（不是 IP/CIDR）"; read -r -p "回车继续..." _; return 0; }

      # 去重追加
      if [[ " $ignoreip " == *" $add "* ]]; then
        ok "已存在：$add（无需重复添加）"
      else
        ignoreip="${ignoreip} ${add}"
        ok "已添加到 ignoreip：$add"
      fi
      ;;
    2)
      ignoreip="$(f2b_default_ignoreip)"
      ok "已恢复默认 ignoreip"
      ;;
    0)
      return 0
      ;;
    *)
      warn "无效选择"
      read -r -p "回车继续..." _
      return 0
      ;;
  esac

  # 写回配置（沿用其它参数）
  local port backend logpath maxretry findtime bantime banaction
  port="$(f2b_get_managed_value "port" "$(get_current_port)")"
  backend="$(f2b_get_managed_value "backend" "auto")"
  logpath="$(f2b_get_managed_value "logpath" "/var/log/auth.log")"
  maxretry="$(f2b_get_managed_value "maxretry" "5")"
  findtime="$(f2b_get_managed_value "findtime" "10m")"
  bantime="$(f2b_get_managed_value "bantime" "1h")"
  banaction="$(f2b_get_managed_value "banaction" "iptables-multiport")"

  f2b_write_managed_block "$port" "$backend" "$logpath" "$maxretry" "$findtime" "$bantime" "$ignoreip" "$banaction"
  f2b_restart_and_show
  read -r -p "回车继续..." _
}

# ---- (12-6) 解封 IP（unban）----
f2b_unban_ip() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：解封 IP（unban）${C0}"
  hr

  f2b_install_if_needed

  local ip
  read -r -p "输入要解封的 IP: " ip
  valid_ip_or_cidr "$ip" || { warn "格式不对（不是 IP）"; read -r -p "回车继续..." _; return 0; }

  # 这里必须用 fail2ban-client 对 sshd jail 解封
  fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1 || warn "解封命令执行失败（可能 jail 未启用/不存在/服务未运行）"
  ok "已尝试解封：$ip"

  echo
  echo "${CCYA}ℹ️  当前 sshd ban 列表：${C0}"
  fail2ban-client get sshd banip 2>/dev/null || true

  read -r -p "回车继续..." _
}

# ---- (12-7) 查看被封列表 + 最近 fail2ban 日志 ----
f2b_show_bans_and_logs() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：查看被封列表 + 最近封禁日志${C0}"
  hr

  f2b_install_if_needed

  echo "${CCYA}ℹ️  sshd ban 列表：${C0}"
  fail2ban-client get sshd banip 2>/dev/null || true

  echo
  echo "${CCYA}ℹ️  最近 fail2ban 日志（journalctl -u fail2ban -n 80）：${C0}"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u fail2ban -n 80 --no-pager 2>/dev/null || true
  else
    warn "系统没有 journalctl，跳过日志查看"
  fi

  read -r -p "回车继续..." _
}

# ---- (12-8) 选择封禁方式 banaction（iptables 或 ufw）----
f2b_switch_banaction() {
  echo
  hr
  echo "${CBOLD}${CBLU}Fail2ban：选择封禁方式（banaction）${C0}"
  hr

  f2b_install_if_needed
  f2b_ensure_jail_local

  # 确保受控区块存在
  if ! grep -qF "$F2B_MARK_BEGIN" "$F2B_JAIL_LOCAL" 2>/dev/null; then
    warn "未检测到受控配置区块（建议先跑 12-1）"
    read -r -p "现在直接跑 12-1 吗？输入 YES 继续: " ans
    [[ "$ans" == "YES" ]] || { warn "已取消"; read -r -p "回车继续..." _; return 0; }
    f2b_one_click_fix_start
    return 0
  fi

  local cur
  cur="$(f2b_get_managed_value "banaction" "iptables-multiport")"
  echo "当前 banaction：${cur}"
  echo

  # 检测 ufw 是否可用且 active
  local ufw_ok="no"
  if command -v ufw >/dev/null 2>&1; then
    local st
    st="$(ufw status 2>/dev/null | head -n1 || true)"
    if echo "$st" | grep -qi "active"; then
      ufw_ok="yes"
    fi
  fi

  echo "请选择："
  echo "  1) iptables-multiport（推荐默认，适用最广）"
  if [[ "$ufw_ok" == "yes" ]]; then
    echo "  2) ufw（检测到 ufw 为 active，可用）"
  else
    echo "  2) ufw（未检测到 ufw active，不推荐/可能无效）"
  fi
  echo "  0) 返回"
  read -r -p "请选择: " c

  local banaction="$cur"
  case "$c" in
    1) banaction="iptables-multiport" ;;
    2) banaction="ufw" ;;
    0) return 0 ;;
    *) warn "无效选择"; read -r -p "回车继续..." _; return 0 ;;
  esac

  # 写回配置（沿用其它参数）
  local port backend logpath maxretry findtime bantime ignoreip
  port="$(f2b_get_managed_value "port" "$(get_current_port)")"
  backend="$(f2b_get_managed_value "backend" "auto")"
  logpath="$(f2b_get_managed_value "logpath" "/var/log/auth.log")"
  maxretry="$(f2b_get_managed_value "maxretry" "5")"
  findtime="$(f2b_get_managed_value "findtime" "10m")"
  bantime="$(f2b_get_managed_value "bantime" "1h")"
  ignoreip="$(f2b_get_managed_value "ignoreip" "$(f2b_default_ignoreip)")"

  f2b_write_managed_block "$port" "$backend" "$logpath" "$maxretry" "$findtime" "$bantime" "$ignoreip" "$banaction"
  f2b_restart_and_show
  read -r -p "回车继续..." _
}

# ---- 12) Fail2ban 子菜单入口（8 选项）----
fail2ban_menu() {
  while true; do
    echo
    hr
    echo "${CBOLD}${CCYA}Fail2ban（一键安装/修复/配置/排障）${C0}"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    echo "  1) 一键安装/修复/启动（推荐）"
    echo "  2) 查看状态（service + jail）"
    echo "  3) 查看当前配置摘要（关键参数）"
    echo "  4) 调整防爆破强度（maxretry/findtime/bantime）"
    echo "  5) 白名单 ignoreip 管理（避免自己被误封）"
    echo "  6) 解封 IP（unban）"
    echo "  7) 查看被封列表 + 最近 fail2ban 日志"
    echo "  8) 选择封禁方式 banaction（iptables / ufw）"
    echo
    echo "  0) 返回上级菜单"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    read -r -p "请选择 (0-8): " c

    case "$c" in
      1) f2b_one_click_fix_start ;;
      2) f2b_show_status ;;
      3) f2b_show_config_summary ;;
      4) f2b_tune_strength ;;
      5) f2b_manage_whitelist ;;
      6) f2b_unban_ip ;;
      7) f2b_show_bans_and_logs ;;
      8) f2b_switch_banaction ;;
      0) return 0 ;;
      *) warn "无效选择"; read -r -p "回车继续..." _ ;;
    esac
  done
}

# ============================================================
# 13) 拓展口：生成未来新增工具/脚本模板文本
# ============================================================

expansion_slot_generate_template() {
  echo
  hr
  echo "${CBOLD}${CBLU}拓展口：生成未来新增工具/脚本的模板文本${C0}"
  hr

  local out="/root/secure-ssh-setup_extension_template_$(date +%F_%H%M%S).txt"
  cat > "$out" <<'EOF'
# =========================
# 扩展模板（把你以后要加的新功能按这个格式写）
# =========================
#
# 1) 先新增一个函数：my_new_tool_menu() 或 my_new_tool_run()
# 2) 在主菜单 [D] 工具里加一个序号入口
# 3) 在 case "$c" 里加对应分支，调用你的函数
# 4) 所有写文件操作都建议使用“受控区块”（BEGIN/END），避免覆盖用户手动配置
#
# ---- 示例 ----
# my_new_tool_menu() {
#   echo "这里写你的新工具逻辑"
# }
#
# 在 main_menu 里加：
#   echo " 14) 我的新工具（说明）"
# 在 case 里加：
#   14) my_new_tool_menu ;;
EOF

  ok "已生成模板：$out"
  echo "你可以把这个文件内容复制到 ChatGPT，让我按模板帮你追加新工具。"
  read -r -p "回车继续..." _
}

# ---------- menu ----------
menu_header() {
  clear 2>/dev/null || true
  echo "${CBOLD}${CCYA}================= Secure SSH Setup（公共安全版）=================${C0}"
  echo "当前 SSH 端口: ${CBOLD}$(get_current_port)${C0}"
  echo "检测防火墙: ${CBOLD}$(detect_firewall)${C0}"
  echo "${CBOLD}${CCYA}==============================================================${C0}"
}

main_menu() {
  detect_sshd
  detect_service
  warn_hosts_if_needed

  local target_user=""

  while true; do
    menu_header
    echo "${CBOLD}${CBLU}[A] 用户与公钥${C0}"
    echo "  1) 创建/指定用户 + 安装公钥（粘贴一行后回车）"
    echo
    echo "${CBOLD}${CBLU}[B] 端口与防火墙${C0}"
    echo "  2) 更改 SSH 端口（备份/校验/可回滚）"
    echo "  3) 放行端口（自动检测 ufw/firewalld/iptables）"
    echo "  4) 关闭端口（自动检测 ufw/firewalld/iptables）"
    echo "  5) 查看已放行端口/规则（ufw/firewalld/iptables）"
    echo
    echo "${CBOLD}${CBLU}[C] 加固与维护${C0}"
    echo "  6) 加固：禁 root SSH + 可选禁密码 + 可选 AllowUsers（防锁外确认）"
    echo "  7) 查看 SSH/配置状态"
    echo "  8) 修复 /etc/hosts（解决 sudo: unable to resolve host，可选）"
    echo "  9) 回滚 sshd_config 备份"
    echo
    echo "${CBOLD}${CBLU}[D] 工具（新增）${C0}"
    echo " 10) 安装/启用 UFW（自动放行当前 SSH 端口）"
    echo " 11) 更新当前系统（apt/yum/dnf 自动识别）"
    echo " 12) Fail2ban（一键安装/修复/启动，自动识别日志来源）"
    echo " 13) 拓展口（生成未来新增工具/脚本的模板文本）"
    echo
    echo "  0) 退出"
    echo "${CBOLD}${CCYA}==============================================================${C0}"
    read -r -p "请选择 (0-13): " c

    case "$c" in
      1)
        read -r -p "输入目标用户名（新建/已存在都行）: " target_user
        valid_username "$target_user" || die "用户名不合法（小写字母数字 _ -，小写开头）"
        ensure_user "$target_user"
        install_pubkey_one_line "$target_user"

        echo
        hr
        echo "${CBOLD}${CGRN}下一步建议：${C0}"
        echo "1) 先在本地新开终端测试能否用该用户+公钥登录"
        echo "2) 再去做改端口/加固（禁密码/禁root）"
        hr
        read -r -p "回车继续..." _
        ;;
      2)
        local new_port
        read -r -p "输入新 SSH 端口（1-65535）: " new_port
        valid_port "$new_port" || die "端口不合法"
        set_ssh_port "$new_port"

        echo
        hr
        echo "${CBOLD}${CYEL}重要：请不要关闭当前会话！${C0}"
        echo "请在本地新开一个终端测试："
        echo "  ssh -p ${new_port} <user>@<VPS_IP>"
        echo "并确保云安全组也放行：${new_port}/tcp"
        hr
        read -r -p "回车继续..." _
        ;;
      3)
        local p
        read -r -p "输入要放行的端口（例如 33333）: " p
        firewall_allow_port "$p"
        read -r -p "回车继续..." _
        ;;
      4)
        local p
        read -r -p "输入要关闭的端口（例如 22 或 39515）: " p
        firewall_close_port "$p"
        read -r -p "回车继续..." _
        ;;
      5)
        firewall_show_rules_menu
        ;;
      6)
        [[ -n "$target_user" ]] || read -r -p "输入要加固关联的目标用户名（例如 bgbg）: " target_user
        valid_username "$target_user" || die "用户名不合法"

        if ! authorized_keys_has_key "$target_user"; then
          warn "检测到 /home/${target_user}/.ssh/authorized_keys 为空或不存在"
          warn "如果你现在就禁密码/禁root，极易锁外！请先安装公钥并测试登录。"
        fi

        echo
        hr
        echo "${CBOLD}${CYEL}强提醒（防锁外）：${C0}"
        echo "1) 你必须已经确认：使用【${target_user} + 公钥】并在【新端口】能登录成功"
        echo "2) 建议你本地新开一个终端测试通过后，再继续"
        hr
        read -r -p "输入 I_CAN_LOGIN_WITH_KEY 才继续: " confirm
        [[ "$confirm" == "I_CAN_LOGIN_WITH_KEY" ]] || { warn "未确认，已取消加固"; read -r -p "回车继续..." _; continue; }

        local disable_pass_default="no"
        authorized_keys_has_key "$target_user" && disable_pass_default="yes"

        local disable_pass
        read -r -p "是否禁用 SSH 密码登录？(yes/no) [默认 ${disable_pass_default}]: " disable_pass
        disable_pass="${disable_pass:-$disable_pass_default}"
        [[ "$disable_pass" == "yes" || "$disable_pass" == "no" ]] || die "输入必须是 yes 或 no"

        echo
        echo "${CBOLD}${CBLU}AllowUsers（可选）${C0}"
        echo "  0) 不启用（推荐默认）"
        echo "  1) 追加模式（add）：在现有 AllowUsers 基础上追加用户"
        echo "  2) 覆盖模式（replace）：只允许你指定的用户（更危险，别手滑）"
        read -r -p "选择 (0/1/2) [默认 0]: " au
        au="${au:-0}"

        local allow_mode="off"
        local allow_list=()
        case "$au" in
          0) allow_mode="off" ;;
          1) allow_mode="add" ;;
          2) allow_mode="replace" ;;
          *) die "无效选择" ;;
        esac

        if [[ "$allow_mode" != "off" ]]; then
          echo
          echo "输入允许登录的用户列表（空格分隔），例如："
          echo "  ${target_user}"
          echo "  ${target_user} opsadmin"
          read -r -p "AllowUsers 列表: " line
          # shellcheck disable=SC2206
          allow_list=($line)
          [[ ${#allow_list[@]} -gt 0 ]] || die "AllowUsers 列表不能为空"
        fi

        harden_ssh "$target_user" "$disable_pass" "$allow_mode" "${allow_list[@]}"

        echo
        hr
        echo "${CBOLD}${CGRN}加固完成后建议你立刻再验证一次：${C0}"
        echo "COMMAND:"
        echo "ssh -p $(get_current_port) ${target_user}@<VPS_IP>"
        hr
        read -r -p "回车继续..." _
        ;;
      7)
        show_status
        read -r -p "回车继续..." _
        ;;
      8)
        fix_hosts
        read -r -p "回车继续..." _
        ;;
      9)
        rollback_menu
        read -r -p "回车继续..." _
        ;;
      10)
        install_ufw_menu
        ;;
      11)
        system_update_menu
        ;;
      12)
        # 这里改成“子菜单”，你以后不用记任何命令
        fail2ban_menu
        ;;
      13)
        expansion_slot_generate_template
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择"
        read -r -p "回车继续..." _
        ;;
    esac
  done
}

main_menu
