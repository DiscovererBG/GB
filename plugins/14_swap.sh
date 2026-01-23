#!/usr/bin/env bash
# plugins/14_swap.sh
# Swap / 虚拟内存管理插件（适配 Debian/Ubuntu/CentOS/RHEL 系）
# 依赖主脚本提供：die/ok/warn/info/hr

swap_show_status() {
  echo
  hr
  echo "${CBOLD}${CBLU}SWAP/虚拟内存状态${C0}"
  hr
  free -h || true
  echo
  echo "${CBOLD}${CBLU}/proc/swaps${C0}"
  cat /proc/swaps 2>/dev/null || true
  echo
  echo "${CBOLD}${CBLU}swapon --show${C0}"
  swapon --show 2>/dev/null || true
  echo
  read -r -p "回车继续..." _
}

swap_recommend_size_mb() {
  # 简单建议：<=2GB: 2x; 2-8GB: =RAM; >8GB: 4GB
  local mem_mb
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
  if (( mem_mb <= 2048 )); then
    echo $((mem_mb * 2))
  elif (( mem_mb <= 8192 )); then
    echo "$mem_mb"
  else
    echo 4096
  fi
}

swap_remove_existing_fstab_line() {
  # 移除 /etc/fstab 中关于 /swapfile 的旧行
  [[ -f /etc/fstab ]] || return 0
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%F_%H%M%S)"
  sed -i.bak '/^[^#].*\s\/swapfile\s\+swap\s\+/d' /etc/fstab 2>/dev/null || true
  sed -i '/^[^#].*\s\/swapfile\s\+swap\s\+/d' /etc/fstab 2>/dev/null || true
}

swap_create_swapfile() {
  local size_mb="$1"
  [[ "$size_mb" =~ ^[0-9]+$ ]] || die "SWAP 大小必须是数字（MB）"
  (( size_mb >= 128 )) || die "SWAP 太小了（至少 128MB）"

  if swapon --show 2>/dev/null | grep -q '/swapfile'; then
    warn "检测到 /swapfile 已启用。将先关闭并重建。"
    swap_off_swapfile
  fi

  # 如果存在旧文件，先删
  if [[ -f /swapfile ]]; then
    warn "检测到已有 /swapfile，将删除后重建"
    rm -f /swapfile
  fi

  info "创建 /swapfile 大小：${size_mb}MB"
  # 优先 fallocate；不支持则用 dd
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${size_mb}M" /swapfile || true
  fi
  if [[ ! -s /swapfile ]]; then
    dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=progress
  fi

  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile

  swap_remove_existing_fstab_line
  echo "/swapfile none swap sw 0 0" >> /etc/fstab

  ok "SWAP 已创建并启用：/swapfile（${size_mb}MB），并已写入 /etc/fstab 开机挂载"
}

swap_off_swapfile() {
  if swapon --show 2>/dev/null | grep -q '/swapfile'; then
    info "关闭 /swapfile..."
    swapoff /swapfile || true
  fi
}

swap_delete_swapfile() {
  swap_off_swapfile
  if [[ -f /swapfile ]]; then
    rm -f /swapfile
    ok "已删除 /swapfile"
  else
    warn "未找到 /swapfile"
  fi
  swap_remove_existing_fstab_line
  ok "已清理 /etc/fstab 中 /swapfile 相关行（如存在）"
}

swap_set_swappiness() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+$ ]] || die "swappiness 必须是 0-100 的数字"
  (( val >= 0 && val <= 100 )) || die "swappiness 范围 0-100"

  sysctl -w "vm.swappiness=${val}" >/dev/null || true
  mkdir -p /etc/sysctl.d
  echo "vm.swappiness=${val}" > /etc/sysctl.d/99-swappiness.conf
  ok "已设置 swappiness=${val}（即时生效 + 写入 /etc/sysctl.d/99-swappiness.conf）"
}

swap_menu() {
  while true; do
    echo
    hr
    echo "${CBOLD}${CCYA}SWAP/虚拟内存管理${C0}"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    echo "  1) 查看当前 SWAP 状态"
    echo "  2) 一键创建/重建 SWAP（/swapfile）"
    echo "  3) 关闭并删除 SWAP（/swapfile）"
    echo "  4) 设置 swappiness（0-100，推荐 10~30）"
    echo
    echo "  0) 返回上级菜单"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    read -r -p "请选择 (0-4): " c

    case "$c" in
      1)
        swap_show_status
        ;;
      2)
        local rec
        rec="$(swap_recommend_size_mb)"
        echo
        info "建议 SWAP 大小：${rec}MB（你也可以自定义）"
        read -r -p "输入 SWAP 大小（MB）[默认 ${rec}]: " size_mb
        size_mb="${size_mb:-$rec}"

        warn "提示：将创建 /swapfile 并写入 /etc/fstab（开机自动挂载）"
        read -r -p "输入 YES 继续创建/重建: " yn
        [[ "$yn" == "YES" ]] || { warn "已取消"; continue; }

        swap_create_swapfile "$size_mb"
        swap_show_status
        ;;
      3)
        warn "将关闭并删除 /swapfile，并清理 /etc/fstab"
        read -r -p "输入 DELETE 继续: " yn
        [[ "$yn" == "DELETE" ]] || { warn "已取消"; continue; }
        swap_delete_swapfile
        swap_show_status
        ;;
      4)
        local v
        read -r -p "输入 swappiness (0-100) [推荐 10~30]: " v
        swap_set_swappiness "$v"
        ;;
      0)
        return 0
        ;;
      *)
        warn "无效选择"
        ;;
    esac
  done
}
