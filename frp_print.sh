#!/bin/bash

# 字体颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
GREEN_BG="\033[42;37m"
FONT="\033[0m"

# 全局变量
SERVICE_NAME=""
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"  
FRP_NAME="frpc"
FRP_VERSION="0.61.0"
FRP_PATH="/usr/local/frp"
PROXY_URL="https://ghproxy.cfd/"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"

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

# 第一步：检查并安装依赖软件
info "开始检查并安装依赖软件"

# 定义需要安装的软件
CUPS_PACKAGE="cups"
LIBREOFFICE_PACKAGE="libreoffice"
PHP_PACKAGE="php"
# Web服务器优先级：apache2 > nginx > httpd
WEB_PACKAGES=("apache2" "nginx" "httpd")

# 检查包管理器
if type apt-get >/dev/null 2>&1; then
    PM="apt-get"
    PM_UPDATE="apt-get update -y"
    PM_INSTALL="apt-get install -y"
elif type yum >/dev/null 2>&1; then
    PM="yum"
    PM_UPDATE="yum update -y"
    PM_INSTALL="yum install -y"
else
    error_exit "不支持的包管理器"
fi

# 先更新包索引
info "更新包索引"
eval $PM_UPDATE || error_exit "更新包索引失败"

# 检查并安装CUPS
if ! command_exists cupsd; then
    info "安装CUPS"
    $PM_INSTALL $CUPS_PACKAGE || error_exit "安装CUPS失败"
    systemctl start cups || error_exit "启动CUPS失败"
    systemctl enable cups || error_exit "设置CUPS开机启动失败"
else
    info "CUPS已安装，跳过"
fi

# 检查并安装LibreOffice
if ! command_exists soffice; then
    info "安装LibreOffice"
    $PM_INSTALL $LIBREOFFICE_PACKAGE || error_exit "安装LibreOffice失败"
else
    info "LibreOffice已安装，跳过"
fi

# 检查并安装PHP
if ! command_exists php; then
    info "安装PHP"
    $PM_INSTALL $PHP_PACKAGE || error_exit "安装PHP失败"
else
    info "PHP已安装，跳过"
fi

# 检查并安装Web服务器
WEB_INSTALLED=0
for web in "${WEB_PACKAGES[@]}"; do
    if command_exists $web; then
        info "$web已安装，跳过"
        WEB_INSTALLED=1
        break
    fi
done

if [ $WEB_INSTALLED -eq 0 ]; then
    # 安装第一个可用的Web服务器
    info "安装Web服务器(${WEB_PACKAGES[0]})"
    $PM_INSTALL ${WEB_PACKAGES[0]} || error_exit "安装${WEB_PACKAGES[0]}失败"
    systemctl start ${WEB_PACKAGES[0]} || error_exit "启动${WEB_PACKAGES[0]}失败"
    systemctl enable ${WEB_PACKAGES[0]} || error_exit "设置${WEB_PACKAGES[0]}开机启动失败"
fi

# 第二步：执行打印服务配置
info "开始执行打印服务配置"

# 创建临时目录并进入（全局临时目录，供FRP步骤使用）
TEMP_DIR=$(mktemp -d) || error_exit "创建临时目录失败"
info "创建临时工作目录: $TEMP_DIR"
cd "$TEMP_DIR" || error_exit "进入临时目录失败"

# 下载配置文件
info "下载配置文件"
curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || error_exit "下载cupsd.conf失败"
curl -fsSL -o print.php "${REPO_URL}/configs/print.php" || error_exit "下载print.php失败"

# 备份并替换CUPS配置
info "替换CUPS配置文件"
[ -f "/etc/cups/cupsd.conf" ] && cp /etc/cups/cupsd.conf "/etc/cups/cupsd.conf.backup.$(date +%Y%m%d_%H%M%S)"
cp cupsd.conf /etc/cups/cupsd.conf || error_exit "替换cupsd.conf失败"
chown root:lp /etc/cups/cupsd.conf
chmod 640 /etc/cups/cupsd.conf

# 备份并替换PHP接口
info "替换PHP打印接口"
mkdir -p /var/www/html
[ -f "/var/www/html/print.php" ] && cp /var/www/html/print.php "/var/www/html/print.php.backup.$(date +%Y%m%d_%H%M%S)"
cp print.php /var/www/html/print.php || error_exit "替换print.php失败"
chmod 644 /var/www/html/print.php

# 重启相关服务
info "重启服务"
systemctl restart cups || error_exit "重启cups服务失败"
systemctl restart apache2 2>/dev/null || systemctl restart nginx 2>/dev/null || systemctl restart httpd 2>/dev/null

info "打印服务配置完成"
echo -e "${GREEN}CUPS配置: /etc/cups/cupsd.conf${FONT}"
echo -e "${GREEN}PHP接口: /var/www/html/print.php${FONT}"


# 第三步：执行FRP内网穿透配置
info "开始执行FRP内网穿透配置"

# 检查FRP是否已安装
if [ -f "${FRP_PATH}/${FRP_NAME}" ] || [ -f "${FRP_PATH}/${FRP_NAME}.toml" ] || [ -f "/lib/systemd/system/${FRP_NAME}.service" ]; then
    echo -e "${GREEN}=========================================================================${FONT}"
    error_exit "检测到已安装${FRP_NAME}，请删除以下文件后重试：
    ${FRP_PATH}/${FRP_NAME}
    ${FRP_PATH}/${FRP_NAME}.toml
    /lib/systemd/system/${FRP_NAME}.service"
fi

# 停止现有FRP进程
while pgrep -x "${FRP_NAME}" >/dev/null; do
    warn "正在停止现有${FRP_NAME}进程..."
    pkill -x "${FRP_NAME}" && sleep 1
done

# 安装依赖
info "安装依赖工具"
if type apt-get >/dev/null 2>&1; then
    apt-get install -y wget curl qrencode || error_exit "APT安装依赖失败"
elif type yum >/dev/null 2>&1; then
    yum install -y wget curl qrencode || error_exit "YUM安装依赖失败"
else
    error_exit "不支持的包管理器"
fi

# 检查网络可用性
check_network() {
    local url=$1
    curl -o /dev/null --connect-timeout 5 --max-time 8 -s --head -w "%{http_code}" "$url"
}

GOOGLE_HTTP_CODE=$(check_network "https://www.google.com")
PROXY_HTTP_CODE=$(check_network "${PROXY_URL}")

# 检查系统架构
case $(uname -m) in
    x86_64) PLATFORM="amd64" ;;
    aarch64) PLATFORM="arm64" ;;
    armv7|armv7l|armhf) PLATFORM="arm" ;;
    *) error_exit "不支持的系统架构: $(uname -m)" ;;
esac

FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
FRP_TAR_FILE="${TEMP_DIR}/${FILE_NAME}.tar.gz"  # 使用全局临时目录存储下载文件

# 下载FRP
info "下载FRP客户端"
if [ "$GOOGLE_HTTP_CODE" -eq 200 ]; then
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"
elif [ "$PROXY_HTTP_CODE" -eq 200 ]; then
    DOWNLOAD_URL="${PROXY_URL}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"
else
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"
    warn "检测到代理失效，将使用官方地址下载"
fi

# 关键修复：使用统一临时目录下载并指定完整路径
wget "$DOWNLOAD_URL" -O "$FRP_TAR_FILE" || error_exit "下载FRP失败"

# 解压并安装（使用临时目录的完整路径）
info "解压FRP客户端"
tar -zxvf "$FRP_TAR_FILE" -C "$TEMP_DIR" || error_exit "解压FRP失败"
mkdir -p "${FRP_PATH}"
mv "${TEMP_DIR}/${FILE_NAME}/${FRP_NAME}" "${FRP_PATH}" || error_exit "移动FRP文件失败"

# 生成服务名称
CURRENT_DATE=$(date +%m%d)
RANDOM_SUFFIX=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 2)
SERVICE_NAME="${CURRENT_DATE}${RANDOM_SUFFIX}"

# 检查root权限
if [ "$EUID" -ne 0 ]; then
    error_exit "请使用root权限运行脚本（sudo）"
fi

# 生成FRP配置文件
info "生成FRP配置文件"
mkdir -p "$(dirname "${FRP_CONFIG_FILE}")"
cat <<EOL > "${FRP_CONFIG_FILE}"
serverAddr = "frps.tzishue.tk"
serverPort = 7000
auth.method = "token"
auth.token = "12345"

[[proxies]]
name = "print-web-${SERVICE_NAME}"
type = "http"
localIP = "127.0.0.1"
localPort = 80
subdomain = "nas-${SERVICE_NAME}"
# customDomains = ["hinas.yourdomain.com"]
EOL

# 配置systemd服务
cat >"/lib/systemd/system/${FRP_NAME}.service" <<EOF
[Unit]
Description=Frp Client Service
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=${FRP_PATH}/${FRP_NAME} -c ${FRP_CONFIG_FILE}

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl start "${FRP_NAME}" || error_exit "启动FRP服务失败"
systemctl enable "${FRP_NAME}" || error_exit "设置FRP开机启动失败"

# 清理临时文件（所有操作完成后清理）
info "清理临时文件"
rm -rf "$TEMP_DIR"

info "FRP内网穿透配置完成"


# 第四步：显示结果信息
echo -e "\n${GREEN_BG}===== 所有配置已完成 =====${FONT}"

# 生成地址信息
INTRANET_ADDR="nas-${SERVICE_NAME}.frpc.tzishue.tk"
REMOTE_PRINT_ADDR="https://${INTRANET_ADDR}/print.php"

echo -e "\n${YELLOW}内网穿透地址: ${INTRANET_ADDR}${FONT}"
echo -e "${YELLOW}远程打印机地址: ${REMOTE_PRINT_ADDR}${FONT}"

# 生成二维码
echo -e "\n${GREEN}远程打印机地址二维码:${FONT}"
qrencode -t ANSIUTF8 "${REMOTE_PRINT_ADDR}"

echo -e "\n${GREEN}提示: 若无法访问，请检查配置并重启服务:${FONT}"
echo -e "${RED}vi ${FRP_CONFIG_FILE}${FONT}"
echo -e "${RED}systemctl restart ${FRP_NAME}${FONT}"
