
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
# - View logs helper (auto detect auth.log / secure / journalctl)
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

# ---------- plugins ----------
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${BASE_DIR}/plugins"

load_plugins() {
  # 1) 优先从“脚本所在目录”的 plugins 加载（适配 git clone 运行）
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
  local plugin_dir="${script_dir}/plugins"

  # 2) curl 方式运行时，BASH_SOURCE[0] 往往是 /dev/fd/xx，plugins 不存在
  #    fallback：从 GitHub 拉取 plugins/plugins.list，下载到 /tmp 再加载
  if [[ ! -d "$plugin_dir" ]]; then
    plugin_dir="/tmp/secure-ssh-setup-plugins"
    mkdir -p "$plugin_dir"

    local base="https://raw.githubusercontent.com/DiscovererBG/GB/main/plugins"
    local list_url="https://raw.githubusercontent.com/DiscovererBG/GB/main/plugins/plugins.list"
    local list_tmp="${plugin_dir}/plugins.list"

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$list_url" -o "$list_tmp"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$list_tmp" "$list_url"
    else
      die "缺少 curl/wget，无法下载插件列表：plugins/plugins.list"
    fi

    # 读取插件列表（忽略空行/注释，兼容 CRLF）
    mapfile -t files < <(grep -vE "^\s*($|#)" "$list_tmp" | tr -d "\r" || true)
    [[ ${#files[@]} -gt 0 ]] || die "插件列表为空：plugins/plugins.list"

    local f
    for f in "${files[@]}"; do
      # 允许：12_xxx.sh
      [[ "$f" =~ ^[0-9]{1,3}_[A-Za-z0-9._-]+\.sh$ ]] || die "插件名不合法：$f"
      if [[ ! -s "${plugin_dir}/${f}" ]]; then
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL "${base}/${f}" -o "${plugin_dir}/${f}"
        else
          wget -qO "${plugin_dir}/${f}" "${base}/${f}"
        fi
        chmod +x "${plugin_dir}/${f}" 2>/dev/null || true
      fi
    done
  fi

  # 3) 加载 plugins 下的所有 .sh
  if [[ -d "$plugin_dir" ]]; then
    local pf
    for pf in "$plugin_dir"/*.sh; do
      [[ -f "$pf" ]] || continue
      # shellcheck disable=SC1090
      source "$pf"
    done
  fi
}

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
# 12) 查看日志（SSH/登录认证/失败登录/实时跟踪）—— 不用记命令
# ============================================================

detect_auth_log_file() {
  # 输出：文件路径；没有则输出空
  if [[ -f /var/log/auth.log ]]; then
    echo "/var/log/auth.log"
    return 0
  fi
  if [[ -f /var/log/secure ]]; then
    echo "/var/log/secure"
    return 0
  fi
  echo ""
}

view_logs_menu() {
  while true; do
    echo
    hr
    echo "${CBOLD}${CCYA}查看日志（SSH/登录认证/失败登录）${C0}"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    echo "说明：不同系统日志位置不同，本菜单会自动识别："
    echo "  - Debian/Ubuntu 常见：/var/log/auth.log"
    echo "  - CentOS/RHEL 常见：/var/log/secure"
    echo "  - 若没有文件日志：改用 journalctl（systemd journal）"
    echo
    echo "  1) 查看 SSH 服务日志（最近 200 行）"
    echo "  2) 查看 登录认证日志（最近 200 行）"
    echo "  3) 查看 失败登录/爆破痕迹（最近 200 行）"
    echo "  4) 实时跟踪（tail/journalctl -f，按 Ctrl+C 退出）"
    echo
    echo "  0) 返回上级菜单"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    read -r -p "请选择 (0-4): " c

    local auth_file
    auth_file="$(detect_auth_log_file)"

    case "$c" in
      1)
        echo
        hr
        echo "${CBOLD}${CBLU}SSH 服务日志（最近 200 行）${C0}"
        hr
        if command -v journalctl >/dev/null 2>&1; then
          # 用 systemd unit 更稳：ssh.service 或 sshd.service
          journalctl -u "${SERVICE_NAME}.service" -n 200 --no-pager 2>/dev/null \
            || journalctl -u ssh -n 200 --no-pager 2>/dev/null \
            || journalctl -u sshd -n 200 --no-pager 2>/dev/null \
            || warn "journalctl 读取失败（可能不是 systemd 或权限/单位名不同）"
        else
          warn "系统无 journalctl（非 systemd）。建议用选项 2/3 看文件日志。"
        fi
        read -r -p "回车继续..." _
        ;;
      2)
        echo
        hr
        echo "${CBOLD}${CBLU}登录认证日志（最近 200 行）${C0}"
        hr
        if [[ -n "$auth_file" ]]; then
          info "使用文件日志：$auth_file"
          tail -n 200 "$auth_file" 2>/dev/null || true
        else
          warn "未找到 /var/log/auth.log 或 /var/log/secure，改用 journalctl"
          if command -v journalctl >/dev/null 2>&1; then
            # 尽量过滤 sshd 相关
            journalctl -n 200 --no-pager 2>/dev/null | grep -Ei 'sshd|ssh' || true
          else
            warn "系统无 journalctl，无法读取认证日志（建议检查系统日志配置 rsyslog/journald）"
          fi
        fi
        read -r -p "回车继续..." _
        ;;
      3)
        echo
        hr
        echo "${CBOLD}${CBLU}失败登录/爆破痕迹（最近 200 行）${C0}"
        hr
        echo "筛选关键字：Failed password / Invalid user / authentication failure / Failed publickey"
        echo
        if [[ -n "$auth_file" ]]; then
          info "使用文件日志：$auth_file"
          tail -n 2000 "$auth_file" 2>/dev/null | grep -Ei 'Failed password|Invalid user|authentication failure|Failed publickey' | tail -n 200 || true
        else
          warn "未找到文件日志，改用 journalctl"
          if command -v journalctl >/dev/null 2>&1; then
            journalctl -n 2000 --no-pager 2>/dev/null | grep -Ei 'Failed password|Invalid user|authentication failure|Failed publickey|sshd' | tail -n 200 || true
          else
            warn "系统无 journalctl，无法筛选失败登录日志"
          fi
        fi
        read -r -p "回车继续..." _
        ;;
      4)
        echo
        hr
        echo "${CBOLD}${CBLU}实时跟踪（按 Ctrl+C 退出）${C0}"
        hr
        if [[ -n "$auth_file" ]]; then
          info "tail -f $auth_file"
          tail -f "$auth_file"
        else
          warn "未找到文件日志，改用 journalctl -f（需要 systemd）"
          if command -v journalctl >/dev/null 2>&1; then
            journalctl -u "${SERVICE_NAME}.service" -f --no-pager 2>/dev/null \
              || journalctl -u ssh -f --no-pager 2>/dev/null \
              || journalctl -u sshd -f --no-pager 2>/dev/null \
              || journalctl -f --no-pager 2>/dev/null
          else
            warn "系统无 journalctl，无法实时跟踪"
          fi
        fi
        read -r -p "回车继续..." _
        ;;
      0)
        return 0
        ;;
      *)
        warn "无效选择"
        read -r -p "回车继续..." _
        ;;
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
  load_plugins
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
    echo " 12) 查看日志（SSH/登录认证/失败登录/实时跟踪）"
    echo " 13) 拓展口（生成未来新增工具/脚本的模板文本）"
    echo " 14) SWAP/虚拟内存 管理（创建/删除/调优）"
    echo " 15) 哪吒 Agent 管理（安装/启动/日志/备份恢复）"
    echo "  0) 退出"
    echo "${CBOLD}${CCYA}==============================================================${C0}"
    read -r -p "请选择 (0-15): " c

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
        view_logs_menu
        ;;
      13)
        expansion_slot_generate_template
        ;;
      14)
        if declare -F swap_menu >/dev/null 2>&1; then
          swap_menu
        else
          die "未加载 swap 插件：plugins/14_swap.sh（请确认文件存在且 load_plugins 已执行）"
        fi
        ;;
       15)
        if declare -F nezha_agent_menu >/dev/null 2>&1; then
          nezha_agent_menu
        else
          die "未加载 nezha 插件：plugins/15_nezha_agent.sh（请确认文件存在且 load_plugins 已执行）"
        fi
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
