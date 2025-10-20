#!/bin/bash

set -e

echo "=== 从GitHub拉取打印服务文件并替换 ==="

# GitHub仓库文件URL
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
CUPS_URL="$REPO_URL/configs/cupsd.conf"
PHP_URL="$REPO_URL/configs/print.php"

# 创建临时目录
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo "下载配置文件..."
curl -fsSL -o cupsd.conf "$CUPS_URL"
curl -fsSL -o print.php "$PHP_URL"

echo "替换CUPS配置文件..."
cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
cp cupsd.conf /etc/cups/cupsd.conf
chown root:lp /etc/cups/cupsd.conf
chmod 640 /etc/cups/cupsd.conf

echo "替换PHP打印接口..."
mkdir -p /var/www/html
cp /var/www/html/print.php /var/www/html/print.php.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
cp print.php /var/www/html/print.php
chmod 644 /var/www/html/print.php

echo "重启服务..."
systemctl restart cups
systemctl restart apache2 2>/dev/null || systemctl restart nginx 2>/dev/null || systemctl restart httpd 2>/dev/null

# 清理临时文件
rm -rf "$TEMP_DIR"

echo "=== 文件替换完成 ==="
echo "CUPS配置: /etc/cups/cupsd.conf"
echo "PHP接口: /var/www/html/print.php"
