#!/bin/bash

set -e

# 字体颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
FONT="\033[0m"

# 函数：打印信息
info() {
    echo -e "${GREEN}=== $1 ===${FONT}"
}

# 函数：打印警告
warn() {
    echo -e "${YELLOW}$1${FONT}"
}

# 函数：打印错误并退出
error_exit() {
    echo -e "${RED}$1${FONT}"
    exit 1
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    error_exit "请使用root权限运行脚本（sudo）"
fi

info "从GitHub拉取打印服务文件并替换"

# GitHub仓库文件URL
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
CUPS_URL="$REPO_URL/configs/cupsd.conf"
PHP_URL="$REPO_URL/configs/print.php"

# 检查依赖工具
info "检查必要工具"
if ! command_exists curl; then
    warn "未找到curl，尝试安装..."
    if type apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null && apt-get install -y curl >/dev/null || error_exit "安装curl失败"
    elif type yum >/dev/null 2>&1; then
        yum install -y curl >/dev/null || error_exit "安装curl失败"
    else
        error_exit "未找到curl且无法自动安装，请手动安装后重试"
    fi
fi

# 创建临时目录
info "创建临时工作目录"
TEMP_DIR=$(mktemp -d) || error_exit "创建临时目录失败"
info "使用临时目录: $TEMP_DIR"
cd "$TEMP_DIR" || error_exit "无法进入临时目录"

# 下载配置文件
info "下载配置文件"
if ! curl -fsSL -o cupsd.conf "$CUPS_URL"; then
    error_exit "下载cupsd.conf失败，请检查网络连接或URL是否有效"
fi

if ! curl -fsSL -o print.php "$PHP_URL"; then
    error_exit "下载print.php失败，请检查网络连接或URL是否有效"
fi

# 备份并替换CUPS配置
info "处理CUPS配置文件"
if [ -f "/etc/cups/cupsd.conf" ]; then
    BACKUP_FILE="/etc/cups/cupsd.conf.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/cups/cupsd.conf "$BACKUP_FILE" || error_exit "备份CUPS配置文件失败"
    info "已创建CUPS配置备份: $BACKUP_FILE"
else
    warn "未找到现有CUPS配置文件，将直接创建新文件"
fi

cp cupsd.conf /etc/cups/cupsd.conf || error_exit "替换cupsd.conf失败"
chown root:lp /etc/cups/cupsd.conf || error_exit "设置cupsd.conf所有者失败"
chmod 640 /etc/cups/cupsd.conf || error_exit "设置cupsd.conf权限失败"

# 备份并替换PHP接口
info "处理PHP打印接口"
mkdir -p /var/www/html || error_exit "创建网站目录失败"

if [ -f "/var/www/html/print.php" ]; then
    PHP_BACKUP="/var/www/html/print.php.backup.$(date +%Y%m%d_%H%M%S)"
    cp /var/www/html/print.php "$PHP_BACKUP" || error_exit "备份print.php失败"
    info "已创建PHP接口备份: $PHP_BACKUP"
else
    warn "未找到现有print.php，将直接创建新文件"
fi

cp print.php /var/www/html/print.php || error_exit "替换print.php失败"
chmod 644 /var/www/html/print.php || error_exit "设置print.php权限失败"

# 重启相关服务
info "重启服务使配置生效"
if ! systemctl restart cups; then
    warn "重启cups服务失败，可能需要手动重启"
else
    info "cups服务重启成功"
fi

# 尝试重启web服务器
WEB_RESTARTED=0
for web_service in apache2 nginx httpd; do
    if systemctl is-active --quiet "$web_service"; then
        if systemctl restart "$web_service"; then
            info "$web_service服务重启成功"
            WEB_RESTARTED=1
            break
        else
            warn "重启$web_service服务失败"
        fi
    fi
done

if [ $WEB_RESTARTED -eq 0 ]; then
    warn "未检测到运行中的web服务器，跳过web服务重启"
fi

# 清理临时文件
info "清理临时文件"
rm -rf "$TEMP_DIR" || warn "清理临时文件时发生错误"

info "文件替换完成"
echo -e "${GREEN}CUPS配置文件路径: /etc/cups/cupsd.conf${FONT}"
echo -e "${GREEN}PHP打印接口路径: /var/www/html/print.php${FONT}"
echo -e "${YELLOW}提示: 若服务未正常工作，请检查相关服务状态或配置文件权限${FONT}"
