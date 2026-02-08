#!/bin/bash
# =========================================
# VPS 全量备份与恢复菜单脚本 (安全版)
# 可备份整个 VPS 根目录，安全隐私
# =========================================
set -e

# 默认备份存放目录
BACKUP_DIR="/root/vps_backups"

# 创建备份目录（如果不存在）
mkdir -p "$BACKUP_DIR"

# 获取当前日期
DATE=$(date +%F)

# --------------------------
# 函数：备份 VPS
# --------------------------
backup_vps() {
    BACKUP_FILE="$BACKUP_DIR/vps-backup-$DATE.tar.gz"
    echo "正在备份整个 VPS 根目录..."
    echo "注意：备份会排除 /proc /sys /dev /tmp /run 和备份目录本身"
    echo "请耐心等待，视 VPS 数据量大小而定..."

    tar -czpf "$BACKUP_FILE" \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/tmp \
        --exclude=/run \
        --exclude="$BACKUP_DIR" \
        /

    echo
    echo "✅ 备份完成！"
    echo "备份文件已保存到：$BACKUP_FILE"
}

# --------------------------
# 函数：恢复 VPS
# --------------------------
restore_vps() {
    echo "可用备份文件列表："
    ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null || { echo "没有找到备份文件！"; return; }

    read -rp "请输入要恢复的备份文件名（完整路径或文件名）: " FILE
    # 自动补全路径
    [[ ! "$FILE" =~ ^/ ]] && FILE="$BACKUP_DIR/$FILE"

    if [[ ! -f "$FILE" ]]; then
        echo "❌ 备份文件不存在！"
        return
    fi

    echo "⚠️ 注意：恢复操作会覆盖 VPS 当前文件！"
    read -rp "确认恢复？输入 yes 继续: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "已取消恢复"
        return
    fi

    echo "正在恢复..."
    tar -xzpf "$FILE" -C /
    echo "✅ 恢复完成！"
    echo "建议重启 VPS 以确保系统正常运行"
}

# --------------------------
# 主菜单循环
# --------------------------
while true; do
    echo "==============================="
    echo "      VPS 备份与恢复管理       "
    echo "==============================="
    echo "1) 备份整个 VPS"
    echo "2) 恢复 VPS"
    echo "3) 查看备份文件列表"
    echo "4) 退出"
    read -rp "请输入选项: " CHOICE
    case "$CHOICE" in
        1) backup_vps ;;
        2) restore_vps ;;
        3) ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "没有备份文件" ;;
        4) exit 0 ;;
        *) echo "❌ 无效选项，请重新输入" ;;
    esac
done
