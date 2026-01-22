#!/usr/bin/env bash
set -euo pipefail

die(){ echo "❌ $*" >&2; exit 1; }
ok(){  echo "✅ $*" >&2; }
warn(){ echo "⚠️  $*" >&2; }

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo -i）"

CFG="/etc/ssh/sshd_config"
SSHD_BIN=""
SERVICE_NAME="ssh"

# -------- core detect --------
detect_sshd() {
  if [[ -x /usr/sbin/sshd ]]; then
    SSHD_BIN="/usr/sbin/sshd"
  elif command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
  else
    die "找不到 sshd，请先安装 openssh-server"
  fi
}

detect_service() {
  if systemctl list-unit-files | grep -qE '^ssh\.service'; then
    SERVICE_NAME="ssh"
  elif systemctl list-unit-files | grep -qE '^sshd\.service'; then
    SERVICE_NAME="sshd"
  else
    SERVICE_NAME="ssh"
  fi
}

restart_ssh() {
  systemctl restart "$SERVICE_NAME" 2>/dev/null \
    || systemctl restart ssh 2>/dev/null \
    || systemctl restart sshd 2>/dev/null \
    || true
}

sshd_test() { "$SSHD_BIN" -t; }

# -------- helpers --------
get_current_port() {
  local p
  p="$(awk 'tolower($1)=="port"{print $2}' "$CFG" | tail -n1 || true)"
  echo "${p:-22}"
}

backup_cfg() {
  local bk="${CFG}.bak.$(date +%F_%H%M%S)"
  cp "$CFG" "$bk"
  echo "$bk"
}

valid_username() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }
valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1<=10#$1 && 10#$1<=65535 )); }

maybe_fix_hostname() {
  # 可选：修复 sudo: unable to resolve host
  # 只提示，不强改（避免改错）
  local hn
  hn="$(hostname)"
  if ! grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+$hn(\b|$)" /etc/hosts 2>/dev/null; then
    warn "检测到 /etc/hosts 可能缺少 127.0.1.1 hostname 映射（可能会出现 sudo: unable to resolve host）"
    warn "可选修复：echo \"127.0.1.1 $hn\" >> /etc/hosts"
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

  # Ubuntu/Debian：sudo 组
  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$u" || true
    ok "已将 $u 加入 sudo 组（默认 sudo 仍需输入密码）"
  fi

  install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
  touch "/home/$u/.ssh/authorized_keys"
  chmod 600 "/home/$u/.ssh/authorized_keys"
  chown "$u:$u" "/home/$u/.ssh/authorized_keys"
  ok "已准备：/home/$u/.ssh/authorized_keys"
}

install_pubkey_by_paste() {
  local u="$1"
  echo
  echo "请粘贴【你的 SSH 公钥】（一整行，以 ssh-ed25519 或 ssh-rsa 开头）"
  echo "粘贴后回车，然后 Ctrl+D 结束："
  echo "----------------------------------------"
  local tmp="/tmp/pubkey.$$"
  cat > "$tmp"
  echo "----------------------------------------"

  [[ -s "$tmp" ]] || die "未检测到公钥内容"
  grep -qE '^ssh-(ed25519|rsa)[[:space:]]' "$tmp" || die "公钥格式不对（应以 ssh-ed25519 或 ssh-rsa 开头）"

  local pub
  pub="$(tr -d '\r' < "$tmp" | head -n1)"

  if grep -qxF "$pub" "/home/$u/.ssh/authorized_keys"; then
    ok "公钥已存在，跳过写入"
  else
    echo "$pub" >> "/home/$u/.ssh/authorized_keys"
    ok "公钥已写入：/home/$u/.ssh/authorized_keys"
  fi
  rm -f "$tmp"
}

generate_key_on_vps() {
  local u="$1"
  local outdir="/root/ssh_keys/$u"
  mkdir -p "$outdir"
  chmod 700 "$outdir"

  local key="$outdir/${u}_ed25519"
  if [[ -f "$key" ]]; then
    warn "检测到已存在私钥：$key（跳过生成）"
  else
    ssh-keygen -t ed25519 -f "$key" -N "" -C "$u@$(hostname)-generated"
    chmod 600 "$key"
    chmod 644 "$key.pub"
    ok "已生成密钥文件：$key 与 $key.pub"
  fi

  local pub
  pub="$(cat "$key.pub")"
  if grep -qxF "$pub" "/home/$u/.ssh/authorized_keys"; then
    ok "authorized_keys 已包含该公钥"
  else
    echo "$pub" >> "/home/$u/.ssh/authorized_keys"
    ok "公钥已写入：/home/$u/.ssh/authorized_keys"
  fi

  echo
  echo "================= 重要：请取回私钥 ================="
  echo "私钥路径（务必下载保存好，不要公开）："
  echo "  $key"
  echo
  echo "在你本地 Mac 执行（把 <VPS_IP> 换成你的公网 IP）："
  echo "  scp -P $(get_current_port) root@<VPS_IP>:$key ~/Desktop/"
  echo "  chmod 600 ~/Desktop/${u}_ed25519"
  echo "  ssh -i ~/Desktop/${u}_ed25519 -p $(get_current_port) $u@<VPS_IP>"
  echo "===================================================="
}

set_ssh_port() {
  local new_port="$1"
  local old_port
  old_port="$(get_current_port)"
  [[ "$new_port" != "$old_port" ]] || { ok "端口未变化：$old_port"; return 0; }

  local bk
  bk="$(backup_cfg)"
  ok "已备份 sshd_config：$bk"

  # 删除所有 Port 行，最后追加一个
  sed -i -E '/^[[:space:]]*Port[[:space:]]+[0-9]+/d' "$CFG"
  echo "Port $new_port" >> "$CFG"

  sshd_test || { cp "$bk" "$CFG"; die "sshd 校验失败，已回滚：$bk"; }
  restart_ssh
  ok "SSH 端口已更改为：$new_port（旧：$old_port）"
}

harden_ssh() {
  local disable_pass="$1"   # yes/no
  local allow_users="$2"    # yes/no
  local user="$3"

  local bk
  bk="$(backup_cfg)"
  ok "已备份 sshd_config：$bk"

  # 禁 root
  if grep -qE '^[#[:space:]]*PermitRootLogin' "$CFG"; then
    sed -i -E 's/^[#[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' "$CFG"
  else
    echo "PermitRootLogin no" >> "$CFG"
  fi

  # 开启公钥认证
  if grep -qE '^[#[:space:]]*PubkeyAuthentication' "$CFG"; then
    sed -i -E 's/^[#[:space:]]*PubkeyAuthentication[[:space:]]+.*/PubkeyAuthentication yes/' "$CFG"
  else
    echo "PubkeyAuthentication yes" >> "$CFG"
  fi

  # 可选禁密码
  if [[ "$disable_pass" == "yes" ]]; then
    if grep -qE '^[#[:space:]]*PasswordAuthentication' "$CFG"; then
      sed -i -E 's/^[#[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' "$CFG"
    else
      echo "PasswordAuthentication no" >> "$CFG"
    fi
  fi

  # 可选 AllowUsers（默认不启用，避免误锁）
  if [[ "$allow_users" == "yes" ]]; then
    if grep -qE '^[[:space:]]*AllowUsers' "$CFG"; then
      sed -i -E "s/^[[:space:]]*AllowUsers.*/AllowUsers $user/" "$CFG"
    else
      echo "AllowUsers $user" >> "$CFG"
    fi
  fi

  sshd_test || { cp "$bk" "$CFG"; die "sshd 校验失败，已回滚：$bk"; }
  restart_ssh
  ok "加固完成：禁 root SSH + $( [[ "$disable_pass" == "yes" ]] && echo "禁密码" || echo "保留密码") + $( [[ "$allow_users" == "yes" ]] && echo "AllowUsers=$user" || echo "不限制 AllowUsers")"
}

maybe_install_ufw() {
  if command -v ufw >/dev/null 2>&1; then return 0; fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y ufw
  fi
}
ufw_allow_port() {
  local p="$1"
  maybe_install_ufw || true
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$p"/tcp || true
    ok "已尝试放行 ufw 端口：$p/tcp"
    warn "注意：云厂商安全组也要放行 $p/tcp"
  else
    warn "未安装 ufw，已跳过（你需要在云安全组/iptables 放行端口）"
  fi
}

show_status() {
  echo "---- SSH 监听端口 ----"
  ss -lntp | grep -E 'sshd' || true
  echo "---- sshd_config 关键项 ----"
  grep -nE '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers)' "$CFG" || true
  echo "----------------------"
}

main_menu() {
  detect_sshd
  detect_service
  maybe_fix_hostname

  local target_user=""
  local new_port=""
  local disable_pass="yes"
  local allow_users_only="no"

  while true; do
    echo
    echo "================= 安全 SSH 一体化脚本（VPS端） ================="
    echo "当前 SSH 端口：$(get_current_port)"
    echo "1) 创建/指定用户 + 安装公钥（手动粘贴公钥）"
    echo "2) 创建/指定用户 + 服务器生成密钥（私钥保存在 /root/ssh_keys/）"
    echo "3) 更改 SSH 端口（带备份/校验/回滚）"
    echo "4) 放行端口（UFW，如无则提示你去云安全组放行）"
    echo "5) 加固：禁 root SSH + 可选禁密码 + 可选 AllowUsers"
    echo "6) 查看 SSH 状态/配置"
    echo "0) 退出"
    echo "==============================================================="
    read -r -p "请选择 (0-6): " c

    case "$c" in
      1)
        read -r -p "输入目标用户名（新建/已存在都行）: " target_user
        valid_username "$target_user" || die "用户名不合法（小写字母数字 _ -，小写开头）"
        ensure_user "$target_user"
        install_pubkey_by_paste "$target_user"
        ;;
      2)
        read -r -p "输入目标用户名（新建/已存在都行）: " target_user
        valid_username "$target_user" || die "用户名不合法（小写字母数字 _ -，小写开头）"
        ensure_user "$target_user"
        generate_key_on_vps "$target_user"
        ;;
      3)
        read -r -p "输入新 SSH 端口（1-65535）: " new_port
        valid_port "$new_port" || die "端口不合法"
        set_ssh_port "$new_port"
        ;;
      4)
        read -r -p "输入要放行的端口（例如 33333）: " new_port
        valid_port "$new_port" || die "端口不合法"
        ufw_allow_port "$new_port"
        ;;
      5)
        [[ -n "$target_user" ]] || read -r -p "输入要加固关联的目标用户名（例如 bgbg）: " target_user
        valid_username "$target_user" || die "用户名不合法"

        read -r -p "是否禁用 SSH 密码登录？(yes/no) [默认 yes]: " disable_pass
        disable_pass="${disable_pass:-yes}"

        read -r -p "是否设置 AllowUsers 只允许 ${target_user} 登录？(yes/no) [默认 no]: " allow_users_only
        allow_users_only="${allow_users_only:-no}"

        echo
        echo "⚠️  强提醒：请先确认你已经能用【该用户 + 公钥】在新端口登录成功，否则可能锁外！"
        read -r -p "输入 YES 继续加固: " sure
        [[ "$sure" == "YES" ]] || { warn "已取消加固"; continue; }

        harden_ssh "$disable_pass" "$allow_users_only" "$target_user"
        ;;
      6)
        show_status
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择"
        ;;
    esac
  done
}

main_menu
