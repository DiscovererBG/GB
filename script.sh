#!/bin/bash
# ===============================
# VPS 全量备份与恢复脚本（安全版）
# ===============================
# 注意：此脚本不会收集或上传敏感信息，仅在本地操作
# 备份保存到 /root/ 下
# ===============================

BACKUP_DIR="/root"
DATE=$(date +%F)

# 全量备份函数
backup() {
    FILE="$BACKUP_DIR/vps-backup-$DATE.tar.gz"
    echo "开始备份 VPS 到 $FILE ..."
    tar -czpf "$FILE" \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/tmp \
        --exclude=/run \
        /
    echo "备份完成！文件位置：$FILE"
}

# 恢复函数
restore() {
    echo "请输入要恢复的备份文件完整路径（例如 /root/vps-backup-2026-02-08.tar.gz）："
    read -r RESTORE_FILE
    if [ ! -f "$RESTORE_FILE" ]; then
        echo "错误：文件不存在！"
        exit 1
    fi
    echo "恢复中，请确保 VPS 处于单用户模式或维护状态..."
    tar -xzpf "$RESTORE_FILE" -C /
    echo "恢复完成！"
}

# 菜单函数
menu() {
    while true; do
        clear
        echo "===================================="
        echo "  VPS 备份与恢复菜单"
        echo "===================================="
        echo "1) 备份整个 VPS"
        echo "2) 恢复 VPS"
        echo "0) 退出"
        echo "===================================="
        echo -n "请选择操作 [0-2]: "
        read -r choice
        case "$choice" in
            1)
                backup
                echo "按回车返回菜单..."
                read -r
                ;;
            2)
                restore
                echo "按回车返回菜单..."
                read -r
                ;;
            0)
                echo "退出脚本."
                exit 0
                ;;
            *)
                echo "无效选择，请重新输入..."
                sleep 1
                ;;
        esac
    done
}

# 入口
menu
