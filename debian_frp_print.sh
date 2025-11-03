#!/bin/bash
# ============================================================================
# Debian 9 stretch 打印服务一键部署脚本
# ============================================================================
set -e

# -------------------- 颜色 --------------------
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; FONT="\033[0m"
info()  { echo -e "${GREEN}=== $1 ===${FONT}"; }
warn()  { echo -e "${YELLOW}$1${FONT}"; }
error_exit() { echo -e "${RED}$1${FONT}"; echo -e "${RED}有问题联系开发者 VX:nmydzf${FONT}"; exit 1; }

# -------------------- 变量 --------------------
FRP_VERSION="0.61.0"
FRP_PATH="/usr/local/frp"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"

# -------------------- 0  必须是 root --------------------
[ "$(id -u)" -ne 0 ] && error_exit "请用 root 运行本脚本"

# -------------------- 1  装软件 --------------------
info "2/8 安装 CUPS / LibreOffice / 工具"
apt-get install -y --no-install-recommends \
  cups cups-filters ghostscript \
  printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine \
  libreoffice-core libreoffice-writer libreoffice-calc \
  wget curl qrencode

# -------------------- 2  CUPS 远程访问 --------------------
info "3-8 下载并替换 cupsd.conf"
TEMP_DIR=$(mktemp -d) || error_exit "创建临时目录失败"
curl -fsSL -o "${TEMP_DIR}/cupsd.conf" "${REPO_URL}/configs/cupsd.conf" || error_exit "下载 cupsd.conf 失败"
cp "${TEMP_DIR}/cupsd.conf" /etc/cups/cupsd.conf && chown root:lp /etc/cups/cupsd.conf && chmod 640 /etc/cups/cupsd.conf || error_exit "替换 cupsd.conf 失败"
rm -rf "${TEMP_DIR}"
systemctl restart cups

# -------------------- 3  Web 打印入口 --------------------
info "4/8 部署 print.php"
mkdir -p /var/www/html
wget -q -O /var/www/html/print.php "${REPO_URL}/configs/print.php" || error_exit "下载 print.php 失败"
chmod 644 /var/www/html/print.php

# -------------------- 4  检查打印机 --------------------
info "5/8 检测已添加打印机"
PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
[ -z "$PRINTERS" ] && error_exit "当前系统尚未配置任何打印机，请先连接并添加打印机后再运行本脚本！"
DEFAULT_PRINTER=$(echo "$PRINTERS" | head -n1)
info "已发现打印机：$(echo "$PRINTERS" | tr '\n' ' ')"

# -------------------- 5  安装 FRP --------------------
info "6/8 安装 FRP ${FRP_VERSION}"
case $(uname -m) in
  x86_64)  PLATFORM="amd64" ;;
  aarch64) PLATFORM="arm64" ;;
  armv7l|armhf) PLATFORM="arm" ;;
  *) error_exit "不支持的架构: $(uname -m)" ;;
esac
FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
DOWNLOAD_URL="https://ghproxy.cfd/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"
mkdir -p /usr/local/frp
wget -qO- "$DOWNLOAD_URL" | tar -zxf - -C /tmp
mv /tmp/${FILE_NAME}/frpc ${FRP_PATH}/
chmod +x ${FRP_PATH}/frpc
rm -rf /tmp/${FILE_NAME}

# -------------------- 6  生成配置 & systemd --------------------
info "7/8 生成 FRP 配置与 systemd 服务"
CURRENT_DATE=$(date +%m%d)
RANDOM_SUFFIX=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 2)
SERVICE_NAME="${CURRENT_DATE}${RANDOM_SUFFIX}"
REMOTE_PORT_SSH=$((RANDOM % 3001 + 3000))

mkdir -p "$(dirname ${FRP_CONFIG_FILE})"
cat >${FRP_CONFIG_FILE} <<EOL
serverAddr = "frps.tzishue.tk"
serverPort = 7000
auth.token = "12345"

[[proxies]]
name = "print-ssh-${SERVICE_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = ${REMOTE_PORT_SSH}

[[proxies]]
name = "print-web-${SERVICE_NAME}"
type = "http"
localIP = "127.0.0.1"
localPort = 80
subdomain = "nas-${SERVICE_NAME}"
EOL

cat >/etc/systemd/system/frpc.service <<EOF
[Unit]
Description=Frp Client
After=network.target

[Service]
ExecStart=${FRP_PATH}/frpc -c ${FRP_CONFIG_FILE}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frpc || error_exit "FRP 启动失败"

# -------------------- 7  输出远程地址 & 二维码 --------------------
info "8/8 生成远程打印地址与二维码"
REMOTE_PRINT_ADDR="http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php?printer=${DEFAULT_PRINTER}"
echo -e "\n${GREEN}配置完成！${FONT}"
echo -e "远程打印地址: ${REMOTE_PRINT_ADDR}\n"
qrencode -t ANSIUTF8 "${REMOTE_PRINT_ADDR}"

if [ "$(echo "$PRINTERS" | wc -l)" -gt 1 ]; then
  info "全部打印机链接:"
  echo "$PRINTERS" | while read -r p; do
    echo "  - $p: http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php?printer=${p}"
  done
fi

# -------------------- 8  常用命令提示 --------------------
echo -e "\n常用命令:"
echo "  重启 FRP : systemctl restart frpc"
echo "  重启 CUPS: systemctl restart cups"
echo -e "${GREEN}有问题联系开发者 VX:nmydzf${FONT}"
