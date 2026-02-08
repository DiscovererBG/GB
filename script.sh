#!/usr/bin/env bash
# ===============================
# VPS 一键备份与恢复脚本（安全版）
# GitHub 友好，无敏感信息
# ===============================

set -euo pipefail

# 备份存放目录
BACKUP_DIR="${BACKUP_DIR:-/root/vps-backup}"
mkdir -p "$BACKUP_DIR"

# 排除目录（包含敏感信息）
EXCLUDE_DIRS="--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/tmp --exclude=/run \
--exclude=/mnt --exclude=/media --exclude=/lost+found \
--exclude=/root/.ssh --exclude=/etc/ssl/private --exclude=$BACKUP_DIR"

function backup_vps() {
    DATE=$(date +%F-%H%M)
    BACKUP_FILE="$BACKUP_DIR/vps-backup-$DATE.tar.gz"

    echo "📦 正在备份 VPS 到 $BACKUP_FILE ..."

    # 备份防火墙配置
    iptables-save > "$BACKUP_DIR/iptables-backup-$DATE.rules"
    echo "🔥 防火墙配置已备份"

    # 备份 sysctl 配置
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl-backup-$DATE.conf"
    echo "⚙️ 系统内核参数已备份"

    # 全量系统备份
    tar -czpf "$BACKUP_FILE" $EXCLUDE_DIRS /
    
    echo "✅ VPS 备份完成: $BACKUP_FILE"
    echo "📂 防火墙规则和系统参数已单独保存"
}

function restore_vps() {
    if [ $# -lt 1 ]; then
        echo "请指定备份文件路径: $0 restore /path/to/vps-backup.tar.gz"
        exit 1
    fi

    BACKUP_FILE="$1"
    DATE=$(date +%F-%H%M)

    if [ ! -f "$BACKUP_FILE" ]; then
        echo "❌ 备份文件不存在: $BACKUP_FILE"
        exit 1
    fi

    echo "⚠️ 恢复操作会覆盖 VPS 文件系统！"
    read -p "输入 YES 执行恢复: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "已取消恢复"
        exit 0
    fi

    echo "📥 正在解压备份..."
    tar -xzpf "$BACKUP_FILE" -C /

    # 恢复 sysctl 配置
    SYSCTL_FILE=$(ls "$BACKUP_DIR"/sysctl-backup-*.conf | tail -n1 || true)
    if [ -f "$SYSCTL_FILE" ]; then
        cp "$SYSCTL_FILE" /etc/sysctl.conf
        sysctl -p
        echo "⚙️ 系统内核参数恢复完成"
    fi

    # 恢复防火墙
    IPT_FILE=$(ls "$BACKUP_DIR"/iptables-backup-*.rules | tail -n1 || true)
    if [ -f "$IPT_FILE" ]; then
        iptables-restore < "$IPT_FILE"
        echo "🔥 防火墙规则恢复完成"
    fi

    # 确保 IP 转发开启
    echo 1 > /proc/sys/net/ipv4/ip_forward
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -p
    echo "🔀 IP 转发已开启"

    echo "💾 恢复完成！请检查服务状态、网络和端口映射"
}

# 主程序
if [ $# -lt 1 ]; then
    echo "用法: $0 backup|restore [备份文件]"
    exit 1
fi

case "$1" in
    backup)
        backup_vps
        ;;
    restore)
        restore_vps "${2:-}"
        ;;
    *)
        echo "未知参数: $1"
        echo "用法: $0 backup|restore [备份文件]"
        exit 1
        ;;
esac