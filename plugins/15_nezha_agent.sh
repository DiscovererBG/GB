#!/usr/bin/env bash
set -euo pipefail

NEZHA_SERVICE="nezha-agent"
NEZHA_BACKUP_DIR="/root/nezha-backups"

nezha_detect_unit() {
  if systemctl list-unit-files 2>/dev/null | grep -qE '^nezha-agent\.service'; then
    NEZHA_SERVICE="nezha-agent"
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^nezha\.service'; then
    NEZHA_SERVICE="nezha"
  else
    NEZHA_SERVICE="nezha-agent"
  fi
}

nezha_status() {
  hr
  echo "${CBOLD}${CCYA}哪吒 Agent 状态${C0}"
  hr

  nezha_detect_unit

  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "${NEZHA_SERVICE}.service" --no-pager 2>/dev/null || true
    echo
    echo "---- 最近日志（50行） ----"
    journalctl -u "${NEZHA_SERVICE}.service" -n 50 --no-pager 2>/dev/null || true
  else
    ps -ef | grep -E 'nezha-agent' | grep -v grep || true
  fi
}

nezha_logs() {
  hr
  echo "${CBOLD}${CCYA}哪吒 Agent 日志（最近 200 行）${C0}"
  hr

  nezha_detect_unit
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "${NEZHA_SERVICE}.service" -n 200 --no-pager 2>/dev/null || warn "journalctl 读取失败"
  else
    warn "系统无 journalctl（非 systemd），请用 ps 查看或检查 /var/log"
  fi
}

nezha_start() {
  nezha_detect_unit
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start "${NEZHA_SERVICE}.service" || true
    systemctl enable "${NEZHA_SERVICE}.service" >/dev/null 2>&1 || true
    ok "已启动并设置开机自启：${NEZHA_SERVICE}.service"
  else
    warn "非 systemd 系统，无法 systemctl start；请用你的启动方式运行 agent"
  fi
}

nezha_stop() {
  nezha_detect_unit
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${NEZHA_SERVICE}.service" || true
    systemctl disable "${NEZHA_SERVICE}.service" >/dev/null 2>&1 || true
    ok "已停止并取消自启：${NEZHA_SERVICE}.service"
  else
    warn "非 systemd 系统，无法 systemctl stop"
  fi
}

nezha_restart() {
  nezha_detect_unit
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "${NEZHA_SERVICE}.service" || true
    ok "已重启：${NEZHA_SERVICE}.service"
  else
    warn "非 systemd 系统，无法 systemctl restart"
  fi
}

nezha_install_or_update() {
  hr
  echo "${CBOLD}${CCYA}安装/更新 哪吒 Agent（推荐：粘贴面板 Install Command）${C0}"
  hr
  echo "请去 Dashboard：Servers 页面 -> Install Command 复制整条命令"
  echo "把整条命令粘贴到下面这一行（只一行），回车执行。"
  echo "（你不需要手动填 server/client_secret/uuid）"
  hr
  read -r -p "粘贴 Install Command： " cmd
  cmd="$(echo "$cmd" | sed -e 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
  [[ -n "$cmd" ]] || die "命令不能为空"

  warn "即将执行你粘贴的命令（来源：你的 Nezha Dashboard）"
  read -r -p "输入 YES 才执行: " yn
  [[ "$yn" == "YES" ]] || { warn "已取消"; return 0; }

  bash -c "$cmd"
  ok "安装/更新命令已执行完成（请回到 Dashboard 查看是否上线）"
}

nezha_guess_paths() {
  cat <<EOF2
/etc/systemd/system/nezha-agent.service
/etc/systemd/system/nezha.service
/opt/nezha
/opt/nezha/agent
/usr/local/bin/nezha-agent
/usr/bin/nezha-agent
EOF2
}

nezha_backup() {
  hr
  echo "${CBOLD}${CCYA}备份 哪吒 Agent${C0}"
  hr

  mkdir -p "$NEZHA_BACKUP_DIR"

  local ts out tmp
  ts="$(date +%F_%H%M%S)"
  out="${NEZHA_BACKUP_DIR}/nezha-agent_${ts}.tar.gz"
  tmp="/tmp/nezha-agent-backup-${ts}"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  while IFS= read -r p; do
    [[ -e "$p" ]] || continue
    mkdir -p "${tmp}$(dirname "$p")"
    cp -a "$p" "${tmp}${p}"
  done < <(nezha_guess_paths)

  if command -v systemctl >/dev/null 2>&1; then
    nezha_detect_unit
    systemctl cat "${NEZHA_SERVICE}.service" > "${tmp}/SYSTEMD_UNIT_${NEZHA_SERVICE}.txt" 2>/dev/null || true
  fi

  tar -czf "$out" -C "$tmp" .
  rm -rf "$tmp"

  ok "备份完成：$out"
  echo "提示：恢复时需要这个 tar.gz 文件路径"
}

nezha_restore() {
  hr
  echo "${CBOLD}${CCYA}恢复 哪吒 Agent${C0}"
  hr
  echo "把你之前备份的文件路径粘贴进来，例如："
  echo "  ${NEZHA_BACKUP_DIR}/nezha-agent_2026-01-23_120000.tar.gz"
  read -r -p "备份文件路径： " f
  [[ -f "$f" ]] || die "找不到备份文件：$f"

  warn "将覆盖恢复到系统路径（/etc/systemd/system、/opt/nezha 等），请确认。"
  read -r -p "输入 YES 才继续恢复: " yn
  [[ "$yn" == "YES" ]] || { warn "已取消"; return 0; }

  tar -xzf "$f" -C /
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi

  ok "恢复完成。你可以在菜单里执行：启动/重启，然后看日志/状态。"
}

nezha_uninstall() {
  hr
  echo "${CBOLD}${CCYA}卸载 哪吒 Agent（谨慎）${C0}"
  hr
  warn "这会停止服务，并尝试移除常见安装路径。"
  read -r -p "输入 YES 才卸载: " yn
  [[ "$yn" == "YES" ]] || { warn "已取消"; return 0; }

  nezha_stop || true

  rm -f /etc/systemd/system/nezha-agent.service /etc/systemd/system/nezha.service 2>/dev/null || true
  rm -rf /opt/nezha/agent /opt/nezha 2>/dev/null || true
  rm -f /usr/local/bin/nezha-agent /usr/bin/nezha-agent 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
  fi

  ok "卸载动作已执行（如你是自定义路径安装，可能还需手动清理）"
}

nezha_agent_menu() {
  while true; do
    echo
    hr
    echo "${CBOLD}${CCYA}哪吒 Agent 管理${C0}"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    echo "  1) 状态"
    echo "  2) 安装/更新（粘贴 Dashboard Install Command）"
    echo "  3) 启动"
    echo "  4) 停止"
    echo "  5) 重启"
    echo "  6) 查看日志"
    echo "  7) 备份（打包常见路径）"
    echo "  8) 恢复（从备份 tar.gz 恢复）"
    echo "  9) 卸载"
    echo
    echo "  0) 返回上级菜单"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    read -r -p "请选择 (0-9): " c

    case "$c" in
      1) nezha_status; read -r -p "回车继续..." _ ;;
      2) nezha_install_or_update; read -r -p "回车继续..." _ ;;
      3) nezha_start; read -r -p "回车继续..." _ ;;
      4) nezha_stop; read -r -p "回车继续..." _ ;;
      5) nezha_restart; read -r -p "回车继续..." _ ;;
      6) nezha_logs; read -r -p "回车继续..." _ ;;
      7) nezha_backup; read -r -p "回车继续..." _ ;;
      8) nezha_restore; read -r -p "回车继续..." _ ;;
      9) nezha_uninstall; read -r -p "回车继续..." _ ;;
      0) return 0 ;;
      *) warn "无效选择"; read -r -p "回车继续..." _ ;;
    esac
  done
}
