#!/usr/bin/env bash
set -euo pipefail

# 这个插件会提供一个主函数：nezha_agent_menu
# 主脚本会通过 declare -F 检测它是否存在，然后调用

nezha_agent_menu() {
  while true; do
    echo
    hr
    echo "${CBOLD}${CCYA}哪吒 Agent 管理${C0}"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    echo "  1) 状态（占位）"
    echo "  2) 安装/更新（占位）"
    echo "  3) 启动（占位）"
    echo "  4) 停止（占位）"
    echo "  5) 重启（占位）"
    echo "  6) 查看日志（占位）"
    echo "  7) 备份（占位）"
    echo "  8) 恢复（占位）"
    echo "  9) 卸载（占位）"
    echo
    echo "  0) 返回上级菜单"
    echo "${CBOLD}${CCYA}============================================================${C0}"
    read -r -p "请选择 (0-9): " c

    case "$c" in
      1) echo "TODO: status" ;;
      2) echo "TODO: install/update" ;;
      3) echo "TODO: start" ;;
      4) echo "TODO: stop" ;;
      5) echo "TODO: restart" ;;
      6) echo "TODO: logs" ;;
      7) echo "TODO: backup" ;;
      8) echo "TODO: restore" ;;
      9) echo "TODO: uninstall" ;;
      0) return 0 ;;
      *) warn "无效选择" ;;
    esac

    read -r -p "回车继续..." _
  done
}
