#!/bin/bash
# 一键安装脚本 - 直接复制执行即可

set -e

echo "正在下载并安装打印服务..."
bash <(curl -fsSL https://raw.githubusercontent.com/your-username/print-service-deploy/main/deploy-print-service.sh)