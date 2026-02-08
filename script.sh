#!/bin/bash
# ===============================
# VPS 全量备份与恢复菜单脚本
# 安全、隐私、可靠
# ===============================

# 备份目录
BACKUP_DIR="/root/vps-backups"

# 排除目录
EXCLUDE_DIRS="/proc /sys /dev /tmp /run /mnt /media /lost+found"

# 确保备份目录存在
mkdir -p "$BACKUP_DIR"

# 生成备份文件名
generate_backup_name() {
    echo "$BACKUP_DIR/vps-backup-$(date +%F-%H%M%S).tar.gz"
}

# 全量备份函数
backup_vps() {
    BACKUP_FILE=$(generate_backup_name)
    echo "开始备份 VPS 根目录..."
    echo "排除目录: $EXCLUDE_DIRS"
    tar -czpf "$BACKUP_FILE" --exclude=$EXCLUDE_DIRS /
    if [ $? -eq 0 ]; then
        echo "备份完成！文件存储在: $BACKUP_FILE"
    else
        echo "备份失败，请检查权限和空间"
    fi
    read -p "按回车返回菜单..."
}

# 列出已有备份
list_backups() {
    echo "现有备份文件列表:"
    ls -lh "$BACKUP_DIR" | grep "vps-backup-"
}

# 恢复函数
restore_vps() {
    list_backups
    echo
    read -p "请输入要恢复的备份文件名（完整路径或相对 $BACKUP_DIR）: " FILE
    if [ ! -f "$FILE" ]; then
        echo "备份文件不存在！"
        read -p "按回车返回菜单..."
        return
    fi

    echo "恢复操作不可逆！确认要从 $FILE 恢复 VPS 吗？(y/n)"
    read CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "已取消恢复"
        read -p "按回车返回菜单..."
        return
    fi

    echo "开始恢复 VPS..."
    tar -xzpf "$FILE" -C /
    if [ $? -eq 0 ]; then
        echo "恢复完成！"
    else
        echo "恢复失败，请检查权限和空间"
    fi
    read -p "按回车返回菜单..."
}

# 主菜单
while true; do
    clear
    echo "====================================="
    echo "       VPS 备份与恢复菜单脚本        "
    echo "====================================="
    echo "1) 备份整个 VPS"
    echo "2) 查看已有备份"
    echo "3) 恢复 VPS"
    echo "0) 退出"
    echo "====================================="
    read -p "请选择操作 [0-3]: " choice

    case "$choice" in
        1) backup_vps ;;
        2) list_backups; read -p "按回车返回菜单..." ;;
        3) restore_vps ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项，请重新选择"; sleep 1 ;;
    esac
done
