#!/bin/bash
# ==============================================
# VPS 全量备份与恢复脚本（安全版+美化菜单+自动创建目录+自动清理旧备份+手动清理）
# ==============================================
# 备份保存到 /home/backup，非 root，方便下载
# 可通过 Web 访问：http://<VPS_IP>/backup/
# ==============================================

# ===============================
# 配置
# ===============================
BACKUP_DIR="/home/backup"
DATE=$(date +%F)

# 自动创建备份目录，权限安全
if [ ! -d "$BACKUP_DIR" ]; then
    echo "备份目录 $BACKUP_DIR 不存在，正在创建..."
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    echo "目录创建完成！"
fi

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# ===============================
# 全量备份函数
# ===============================
backup() {
    FILE="$BACKUP_DIR/vps-backup-$DATE.tar.gz"
    echo -e "${BLUE}开始备份 VPS 到 ${FILE} ...${NC}"
    tar -czpf "$FILE" \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/tmp \
        --exclude=/run \
        --one-file-system \
        / 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}备份完成！${NC}"
        echo "备份文件位置：$FILE"
        ls -lh "$FILE"

        # 自动清理 2 天前的备份
        echo -e "${YELLOW}正在清理 2 天前的旧备份...${NC}"
        find "$BACKUP_DIR" -type f -name "vps-backup-*.tar.gz" -mtime +1 -exec rm -f {} \;
        echo "清理完成！"
    else
        echo -e "${RED}备份失败，请检查日志。${NC}"
    fi
}

# ===============================
# 恢复函数
# ===============================
restore() {
    echo -e "${YELLOW}请输入要恢复的备份文件完整路径（例如 /home/backup/vps-backup-2026-02-08.tar.gz）：${NC}"
    read -r RESTORE_FILE

    RESTORE_DIR=$(dirname "$RESTORE_FILE")
    if [ ! -d "$RESTORE_DIR" ]; then
        echo "备份文件所在目录 $RESTORE_DIR 不存在，正在创建..."
        mkdir -p "$RESTORE_DIR"
        chmod 700 "$RESTORE_DIR"
        echo "目录创建完成！"
    fi

    if [ ! -f "$RESTORE_FILE" ]; then
        echo -e "${RED}错误：备份文件不存在！${NC}"
        return
    fi

    echo -e "${RED}⚠️ 警告：恢复会覆盖现有文件，请确保 VPS 处于单用户模式或维护状态！${NC}"
    read -p "确认继续恢复？(yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "取消恢复"
        return
    fi

    tar -xzpf "$RESTORE_FILE" -C /
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}恢复完成！${NC}"
    else
        echo -e "${RED}恢复失败，请检查文件完整性。${NC}"
    fi
}

# ===============================
# 手动清理备份函数
# ===============================
clean_backups() {
    echo -e "${RED}⚠️ 警告：此操作会删除 $BACKUP_DIR 下所有备份文件！${NC}"
    read -p "确认继续删除？(yes/NO): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "取消删除"
        return
    fi

    find "$BACKUP_DIR" -type f -name "vps-backup-*.tar.gz" -exec rm -f {} \;
    echo -e "${GREEN}所有备份文件已删除！${NC}"
}

# ===============================
# 菜单函数
# ===============================
menu() {
    while true; do
        clear
        echo -e "${BLUE}=============================================${NC}"
        echo -e "${GREEN}          VPS 备份与恢复菜单${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo "1) 备份整个 VPS"
        echo "2) 恢复 VPS"
        echo "3) 查看最近备份文件"
        echo "4) 立即清理备份文件"
        echo "0) 退出"
        echo -e "${BLUE}=============================================${NC}"
        echo -n "请选择操作 [0-4]: "
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
            3)
                echo -e "${YELLOW}最近备份文件列表：${NC}"
                ls -lh "$BACKUP_DIR" | sort -r
                echo "按回车返回菜单..."
                read -r
                ;;
            4)
                clean_backups
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

# ===============================
# 入口
# ===============================
menu
