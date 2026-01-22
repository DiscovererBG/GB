#!/usr/bin/env bash
# ============================================================
# VPS Step1 (Public-safe)
# ------------------------------------------------------------
# What it does (SAFE defaults):
#  1) Create or reuse a user
#  2) Prepare ~/.ssh/authorized_keys for that user
#  3) Optionally add the user to sudo group (password required)
#  4) Optionally change SSH port (with backup + sshd -t + rollback)
#  5) Print the "next step on Mac" instructions
#
# What it DOES NOT do by default:
#  - Does NOT disable root SSH
#  - Does NOT disable password login
#  - Does NOT touch firewall/security-group automatically
#
# Why: This script is intended for public sharing and safer onboarding.
# ============================================================

set -euo pipefail

die(){ echo "❌ $*" >&2; exit 1; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*" >&2; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "请用 root 运行：sudo bash secure-ssh-setup.sh 或 sudo ./secure-ssh-setup.sh"
}

valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( $1 >= 1 && $1 <= 65535 ))
}

detect_sshd_config() {
  if [[ -f /etc/ssh/sshd_config ]]; then
    echo "/etc/ssh/sshd_config"
  else
    die "找不到 /etc/ssh/sshd_config，请确认已安装 OpenSSH Server"
  fi
}

detect_sshd_bin() {
  if [[ -x /usr/sbin/sshd ]]; then
    echo "/usr/sbin/sshd"
  elif command -v sshd >/dev/null 2>&1; then
    command -v sshd
  else
    die "找不到 sshd，可尝试安装 openssh-server"
  fi
}

restart_ssh() {
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

get_current_port() {
  local cfg="$1"
  local p
  p="$(awk 'tolower($1)=="port"{print $2}' "$cfg" | tail -n1 || true)"
  echo "${p:-22}"
}

backup_file() {
  local f="$1"
  local bk="${f}.bak.$(date +%F_%H%M%S)"
  cp "$f" "$bk"
  echo "$bk"
}

prepare_user_and_ssh() {
  local user="$1"

  if id -u "$user" >/dev/null 2>&1; then
    ok "用户已存在：$user"
  else
    adduser --disabled-password --gecos "" "$user"
    ok "已创建用户：$user"
  fi

  install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
  touch "/home/$user/.ssh/authorized_keys"
  chmod 600 "/home/$user/.ssh/authorized_keys"
  chown "$user:$user" "/home/$user/.ssh/authorized_keys"
  ok "已准备：/home/$user/.ssh/authorized_keys（等待写入公钥）"
}

maybe_add_sudo() {
  local user="$1"
  read -r -p "是否将用户加入 sudo 组？(yes/no) [建议 yes]: " ans
  ans="${ans:-yes}"
  if [[ "$ans" == "yes" ]]; then
    if getent group sudo >/dev/null 2>&1; then
      usermod -aG sudo "$user"
      ok "已将 $user 加入 sudo 组（默认 sudo 仍需输入密码）"
    elif getent group wheel >/dev/null 2>&1; then
      usermod -aG wheel "$user"
      ok "已将 $user 加入 wheel 组"
    else
      warn "未发现 sudo/wheel 组（可能系统不同或未安装 sudo）"
    fi
  else
    ok "已跳过 sudo 组设置"
  fi
}

maybe_change_port() {
  local cfg="$1"
  local sshd_bin="$2"
  local old_port="$3"

  read -r -p "是否要更改 SSH 端口？(yes/no) [默认 no]: " chg
  chg="${chg:-no}"
  if [[ "$chg" != "yes" ]]; then
    echo "$old_port"
    return 0
  fi

  local new_port=""
  while true; do
    read -r -p "输入新的 SSH 端口（1-65535，避免常见端口）: " new_port
    valid_port "$new_port" || { warn "端口不合法"; continue; }
    if [[ "$new_port" == "$old_port" ]]; then
      warn "新端口与旧端口相同，无需更改"
      echo "$old_port"
      return 0
    fi
    break
  done

  local bk
  bk="$(backup_file "$cfg")"
  ok "已备份 sshd_config：$bk"

  sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "$cfg"
  echo "Port $new_port" >> "$cfg"

  if ! "$sshd_bin" -t; then
    cp "$bk" "$cfg"
    die "sshd 配置校验失败，已回滚到备份：$bk"
  fi

  restart_ssh
  ok "SSH 端口已更改为：$new_port"

  echo "$new_port"
}

print_next_steps() {
  local user="$1"
  local port="$2"

  echo
  echo "================= 下一步（在 Mac 上执行）================="
  echo "1) 在 Mac 生成密钥（若你还没有）："
  echo "   ssh-keygen -t ed25519"
  echo
  echo "2) 查看公钥并复制："
  echo "   cat ~/.ssh/id_ed25519.pub"
  echo
  echo "3) 把公钥写入 VPS（手动粘贴方式）："
  echo "   ssh -p ${port} ${user}@<VPS_IP> 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
  echo "   # 然后粘贴公钥那一整行，回车，再 Ctrl+D 结束输入"
  echo
  echo "4) 测试登录："
  echo "   ssh -p ${port} ${user}@<VPS_IP>"
  echo
  echo "重要提醒："
  echo " - 如果你改了 SSH 端口，务必在云厂商安全组/防火墙放行 ${port}/tcp"
  echo " - 建议确认新用户+公钥能登录后，再做“禁 root/禁密码”的加固"
  echo "=========================================================="
  echo
}

main() {
  require_root
  local cfg sshd_bin old_port new_port user

  cfg="$(detect_sshd_config)"
  sshd_bin="$(detect_sshd_bin)"
  old_port="$(get_current_port "$cfg")"

  echo "当前 SSH 端口：$old_port"
  echo

  while true; do
    read -r -p "输入要创建/使用的用户名（例 trqbg）: " user
    [[ -n "$user" ]] || { warn "用户名不能为空"; continue; }
    valid_username "$user" || { warn "用户名不合法/不安全（仅小写字母数字 _ -，小写开头）"; continue; }
    break
  done

  prepare_user_and_ssh "$user"
  maybe_add_sudo "$user"
  new_port="$(maybe_change_port "$cfg" "$sshd_bin" "$old_port")"
  print_next_steps "$user" "$new_port"

  ok "Step1 完成 ✅"
}

main "$@"
