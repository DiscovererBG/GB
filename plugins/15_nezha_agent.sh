#!/usr/bin/env bash
set -euo pipefail

type die  >/dev/null 2>&1 || die(){  echo "❌ $*" >&2; exit 1; }
type ok   >/dev/null 2>&1 || ok(){   echo "✅ $*" >&2; }
type warn >/dev/null 2>&1 || warn(){ echo "⚠️  $*" >&2; }
type info >/dev/null 2>&1 || info(){ echo "ℹ️  $*" >&2; }
type hr   >/dev/null 2>&1 || hr(){ printf "%s\n" "------------------------------------------------------------"; }

need_root(){ [[ ${EUID:-0} -eq 0 ]] || die "请用 root 运行"; }

nezha_service_name() {
  if command -v systemctl >/dev/null 2>&1; then
    for n in nezha-agent nezha nezha_agent; do
      systemctl list-unit-files 2>/dev/null | grep -qE "^${n}\.service" && { echo "$n"; return 0; }
    done
  fi
  echo "nezha-agent"
}

nezha_install_dir() {
  [[ -d /opt/nezha-agent ]] && { echo /opt/nezha-agent; return 0; }
  [[ -d /opt/nezha ]] && { echo /opt/nezha; return 0; }
  echo /opt/nezha-agent
}

nezha_bin_path() {
  local d; d="$(nezha_install_dir)"
  [[ -x "${d}/nezha-agent" ]] && { echo "${d}/nezha-agent"; return 0; }
  command -v nezha-agent >/dev/null 2>&1 && { command -v nezha-agent; return 0; }
  echo ""
}

nezha_status() {
  need_root
  local svc; svc="$(nezha_service_name)"
  hr; echo "哪吒 Agent 状态"; hr

  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "${svc}.service" --no-pager 2>/dev/null || true
  else
    pgrep -af "nezha-agent" || echo "未发现 nezha-agent 进程"
  fi

  echo
  echo "二进制：$(nezha_bin_path || true)"
  echo "目录：$(nezha_install_dir)"
}

nezha_logs() {
  need_root
  local svc; svc="$(nezha_service_name)"
  hr; echo "哪吒 Agent 日志（最近 200 行）"; hr
  if command -v journalctl >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    journalctl -u "${svc}.service" -n 200 --no-pager 2>/dev/null || \
    journalctl -n 200 --no-pager 2>/dev/null | grep -Ei "nezha|agent" || true
  else
    # 非 systemd：尽力从 syslog/messages 里捞
    (tail -n 500 /var/log/syslog 2>/dev/null || true; tail -n 500 /var/log/messages 2>/dev/null || true) | \
      grep -Ei "nezha|agent" | tail -n 200 || true
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

install_deps() {
  if need_cmd unzip && (need_cmd curl || need_cmd wget); then return 0; fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl ca-certificates || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y unzip curl ca-certificates || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y unzip curl ca-certificates || true
  fi
  need_cmd unzip || die "缺少 unzip，且自动安装失败"
  (need_cmd curl || need_cmd wget) || die "缺少 curl/wget，且自动安装失败"
}

arch_asset() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "linux_amd64" ;;
    aarch64|arm64) echo "linux_arm64" ;;
    armv7l|armv7) echo "linux_arm" ;;
    i386|i686) echo "linux_386" ;;
    *) die "不支持的架构：$m" ;;
  esac
}

download_file() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  else
    wget -qO "$out" "$url"
  fi
}

nezha_install_or_update() {
  need_root
  install_deps

  local d; d="$(nezha_install_dir)"
  mkdir -p "$d"

  hr
  echo "安装/更新 哪吒 Agent"
  hr
  echo "你需要准备 3 个东西："
  echo "1) server：面板里“Agent 对接地址(域名/IP:端口)” 例如 data.example.com:8008"
  echo "2) client_secret：Dashboard 配置里的 agentsecretkey（或面板生成的安装信息里给的）"
  echo "3) uuid：唯一标识（留空自动生成）"
  echo

  read -r -p "server (例如 data.example.com:8008): " server
  [[ -n "${server:-}" ]] || die "server 不能为空"

  read -r -p "client_secret: " secret
  [[ -n "${secret:-}" ]] || die "client_secret 不能为空"

  read -r -p "tls 是否启用？(yes/no) [默认 no]: " tls
  tls="${tls:-no}"
  [[ "$tls" == "yes" || "$tls" == "no" ]] || die "tls 只能 yes/no"

  local uuid=""
  if command -v uuidgen >/dev/null 2>&1; then
    uuid="$(uuidgen)"
  else
    uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  fi
  read -r -p "uuid [默认自动生成 ${uuid}]: " u2
  uuid="${u2:-$uuid}"

  local asset; asset="$(arch_asset)"
  local zip="/tmp/nezha-agent_${asset}.zip"
  local url="https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_${asset}.zip"

  info "下载：$url"
  download_file "$url" "$zip"

  info "解压到：$d"
  rm -f "${d}/nezha-agent" 2>/dev/null || true
  unzip -o "$zip" -d "$d" >/dev/null
  chmod +x "${d}/nezha-agent"

  info "写入配置：${d}/config.yml"
  cat > "${d}/config.yml" <<YAML
client_secret: ${secret}
server: ${server}
uuid: ${uuid}
tls: ${tls}
debug: false
disable_auto_update: false
YAML

  if command -v systemctl >/dev/null 2>&1; then
    info "写入 systemd 服务：/etc/systemd/system/nezha-agent.service"
    cat > /etc/systemd/system/nezha-agent.service <<UNIT
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${d}/nezha-agent -c ${d}/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable nezha-agent >/dev/null 2>&1 || true
    systemctl restart nezha-agent >/dev/null 2>&1 || systemctl start nezha-agent >/dev/null 2>&1 || true
    ok "安装/更新完成，已启动 nezha-agent"
  else
    warn "系统无 systemd：已安装二进制与 config.yml。你需要手动后台运行："
    echo "${d}/nezha-agent -c ${d}/config.yml &"
  fi
}

nezha_start(){ need_root; local svc; svc="$(nezha_service_name)"; systemctl start "${svc}.service" 2>/dev/null || true; ok "已尝试启动 ${svc}"; }
nezha_stop(){ need_root; local svc; svc="$(nezha_service_name)"; systemctl stop "${svc}.service" 2>/dev/null || true; ok "已尝试停止 ${svc}"; }
nezha_restart(){ need_root; local svc; svc="$(nezha_service_name)"; systemctl restart "${svc}.service" 2>/dev/null || true; ok "已尝试重启 ${svc}"; }

backup_dir(){ echo "/root/nezha-agent-backups"; }

nezha_backup() {
  need_root
  local d; d="$(nezha_install_dir)"
  local svc="/etc/systemd/system/nezha-agent.service"
  local outd; outd="$(backup_dir)"
  mkdir -p "$outd"
  local ts; ts="$(date +%F_%H%M%S)"
  local out="${outd}/nezha-agent_backup_${ts}.tar.gz"

  hr; echo "备份 哪吒 Agent"; hr
  tar -czf "$out" \
    "$d" \
    $( [[ -f "$svc" ]] && echo "$svc" ) \
    2>/dev/null || die "打包失败"

  ok "备份完成：$out"
}

nezha_restore() {
  need_root
  local outd; outd="$(backup_dir)"
  hr; echo "恢复 哪吒 Agent"; hr
  ls -1t "${outd}"/nezha-agent_backup_*.tar.gz 2>/dev/null | head -n 10 || { die "没找到备份：${outd}/nezha-agent_backup_*.tar.gz"; }
  echo
  read -r -p "把要恢复的备份文件完整路径粘贴出来: " f
  [[ -f "$f" ]] || die "文件不存在：$f"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop nezha-agent 2>/dev/null || true
  fi

  tar -xzf "$f" -C / 2>/dev/null || die "解压失败"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable nezha-agent >/dev/null 2>&1 || true
    systemctl restart nezha-agent >/dev/null 2>&1 || true
  fi
  ok "恢复完成"
}

nezha_uninstall() {
  need_root
  hr; echo "卸载 哪吒 Agent"; hr
  read -r -p "输入 YES 才卸载: " yn
  [[ "$yn" == "YES" ]] || { warn "已取消"; return 0; }

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop nezha-agent 2>/dev/null || true
    systemctl disable nezha-agent 2>/dev/null || true
  fi
  rm -f /etc/systemd/system/nezha-agent.service 2>/dev/null || true
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true

  local d; d="$(nezha_install_dir)"
  rm -rf "$d" 2>/dev/null || true

  ok "已卸载（配置与二进制已删除；备份保留在 /root/nezha-agent-backups）"
}

nezha_menu() {
  while true; do
    echo
    hr
    echo "哪吒 Agent 管理"
    echo "============================================================"
    echo "  1) 状态"
    echo "  2) 安装/更新（下载最新 Agent + 写 config.yml + 建服务）"
    echo "  3) 启动"
    echo "  4) 停止"
    echo "  5) 重启"
    echo "  6) 查看日志"
    echo "  7) 备份"
    echo "  8) 恢复"
    echo "  9) 卸载"
    echo
    echo "  0) 返回上级菜单"
    echo "============================================================"
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
