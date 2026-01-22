cat > ~/vps-step1.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

die(){ echo "❌ $*" >&2; exit 1; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*" >&2; }

[[ $EUID -eq 0 ]] || die "请用 root 运行"

CFG="/etc/ssh/sshd_config"
SSHD_BIN="/usr/sbin/sshd"

cur_port="$(awk 'tolower($1)=="port"{print $2}' "$CFG" | tail -n1 || true)"
cur_port="${cur_port:-22}"

echo "当前 SSH 端口：$cur_port"
read -r -p "你要创建/使用的登录用户名（例如 trqbg）: " TARGET_USER
[[ -n "${TARGET_USER}" ]] || die "用户名不能为空"

read -r -p "是否要改 SSH 端口？(yes/no) " chg
NEW_PORT="$cur_port"
if [[ "${chg}" == "yes" ]]; then
  read -r -p "输入新 SSH 端口（1-65535）: " NEW_PORT
  [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && ((NEW_PORT>=1 && NEW_PORT<=65535)) || die "端口不合法"
fi

# 1) 创建用户（若不存在）
if id -u "$TARGET_USER" >/dev/null 2>&1; then
  ok "用户已存在：$TARGET_USER"
else
  adduser --disabled-password --gecos "" "$TARGET_USER"
  ok "已创建用户：$TARGET_USER"
fi

# 2) 赋予 sudo（保守做法：给 sudo，后续你想收回再收）
if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "$TARGET_USER"
  ok "已将 $TARGET_USER 加入 sudo 组"
else
  warn "未发现 sudo 组（某些系统不同），如后续 sudo 不可用请手工处理"
fi

# 3) 准备 .ssh 目录（等待 Mac 写入公钥）
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "/home/$TARGET_USER/.ssh"
touch "/home/$TARGET_USER/.ssh/authorized_keys"
chmod 600 "/home/$TARGET_USER/.ssh/authorized_keys"
chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.ssh/authorized_keys"
ok "已准备：/home/$TARGET_USER/.ssh/authorized_keys（等待写入公钥）"

# 4) 可选：改端口（安全：备份 + sshd -t）
if [[ "$NEW_PORT" != "$cur_port" ]]; then
  BK="${CFG}.bak.step1.$(date +%F_%H%M%S)"
  cp "$CFG" "$BK"
  ok "已备份 sshd_config：$BK"

  sed -i -E '/^[[:space:]]*Port[[:space:]]+/d' "$CFG"
  echo "Port $NEW_PORT" >> "$CFG"

  $SSHD_BIN -t || { cp "$BK" "$CFG"; die "sshd 校验失败，已回滚"; }

  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH 端口已设置为：$NEW_PORT（旧：$cur_port）"
fi

echo
echo "================= 下一步（在 Mac 上执行）================="
echo "你要用到的信息："
echo "  VPS_IP=<你的VPS公网IP>"
echo "  VPS_PORT=$NEW_PORT"
echo "  TARGET_USER=$TARGET_USER"
echo
echo "在 Mac 运行 Step2："
echo "  VPS_IP=你的IP VPS_PORT=$NEW_PORT TARGET_USER=$TARGET_USER ~/Documents/vpsbg/mac-step2.sh"
echo "=========================================================="
EOF

chmod +x ~/vps-step1.sh
sudo ~/vps-step1.sh
