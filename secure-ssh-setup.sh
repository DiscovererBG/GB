#!/usr/bin/env bash
set -euo pipefail

# =========================
# Secure SSH Setup (Public-safe)
# - Menu + colors
# - One-line pubkey paste (ENTER to finish)
# - No "server generate private key" mode (removed)
# - Backup/validate/rollback
# - Firewall helper (ufw/firewalld/iptables)
# - Optional /etc/hosts fix for sudo resolve host
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
[[ ${EUID:-0} -eq 0 ]] || die "请用 root 运行（sudo -i）"

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
    die "找不到 sshd。请先安装 openssh-server（Ubuntu: apt-get install -y openssh-server）"
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

# Set directive key->value, remove all existing (commented/uncommented) key lines, append one clean line.
set_directive_single() {
  local key="$1" value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" '
    BEGIN{IGNORECASE=1}
    {
      line=$0
      # remove any line starting with optional spaces, optional #, then key
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
  local want_users=("$@") # array
  [[ ${#want_users[@]} -gt 0 ]] || die "AllowUsers 用户列表不能为空"

  # get existing AllowUsers (may appear multiple times) -> merge
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
    # add mode: union (preserve existing + add new unique)
    local all=()
    # shellcheck disable=SC2206
    all=($existing "${want_users[@]}")
    # unique
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

  # remove all AllowUsers lines, append single
  set_directive_single "AllowUsers" "$merged"
}

valid_username() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }
valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1<=10#$1 && 10#$1<=65535 )); }

ensure_user() {
  local u="$1"
  if id -u "$u" >/dev/null 2>&1; then
    ok "用户已存在：$u"
  else
    adduser --disabled-password --gecos "" "$u"
    ok "已创建用户：$u"
  fi

  # Ubuntu/Debian: sudo group
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

  # trim
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
  local allow_users_list=("$@") # may be empty if off

  local bk
  bk="$(backup_cfg)"
  ok "已备份 sshd_config：$bk"

  set_directive_single "PermitRootLogin" "no"
  set_directive_single "PubkeyAuthentication" "yes"

  # only change password auth if requested
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
  if [[ "$allowusers_mode" != "off" ]]; then
    msg="$msg + AllowUsers(${allowusers_mode})"
  fi
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
      # try nft backend too; do minimal, idempotent-ish
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
      # remove first matching rule
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
    info "建议菜单里选择：7) 修复 /etc/hosts（可选）"
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
    echo
    echo "${CBOLD}${CBLU}[C] 加固与维护${C0}"
    echo "  5) 加固：禁 root SSH + 可选禁密码 + 可选 AllowUsers（防锁外确认）"
    echo "  6) 查看 SSH/配置状态"
    echo "  7) 修复 /etc/hosts（解决 sudo: unable to resolve host，可选）"
    echo "  8) 回滚 sshd_config 备份"
    echo
    echo "  0) 退出"
    echo "${CBOLD}${CCYA}==============================================================${C0}"
    read -r -p "请选择 (0-8): " c

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

        # password disable default decision
        local disable_pass_default="no"
        authorized_keys_has_key "$target_user" && disable_pass_default="yes"

        local disable_pass
        read -r -p "是否禁用 SSH 密码登录？(yes/no) [默认 ${disable_pass_default}]: " disable_pass
        disable_pass="${disable_pass:-$disable_pass_default}"
        [[ "$disable_pass" == "yes" || "$disable_pass" == "no" ]] || die "输入必须是 yes 或 no"

        # AllowUsers options
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
      6)
        show_status
        read -r -p "回车继续..." _
        ;;
      7)
        fix_hosts
        read -r -p "回车继续..." _
        ;;
      8)
        rollback_menu
        read -r -p "回车继续..." _
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
