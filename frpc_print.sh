#!/bin/bash
# ==========================================================
#  增强版：先保证 Nginx + PHP 环境，再放 print.php
# ==========================================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
FONT="\033[0m"

SERVICE_NAME=""
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
FRP_NAME="frpc"
FRP_VERSION="0.61.0"
FRP_PATH="/usr/local/frp"
PROXY_URL="https://ghproxy.cfd/"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"
WEB_ROOT="/var/www/html"
PRINT_PHP="$WEB_ROOT/print.php"

info()  { echo -e "${GREEN}=== $1 ===${FONT}"; }
warn()  { echo -e "${YELLOW}$1${FONT}"; }
error_exit() { echo -e "${RED}$1${FONT}"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------
# 1. 检测并安装 Nginx + PHP
# ----------------------------------------------------------
install_nginx_php() {
    # 1.1 检测 Nginx
    if systemctl is-active --quiet nginx; then
        info "Nginx 已运行"
    else
        info "安装 Nginx"
        if type apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends nginx
        elif type yum >/dev/null 2>&1; then
            yum install -y nginx
        else
            error_exit "不支持的包管理器，无法安装 Nginx"
        fi
        systemctl enable nginx && systemctl start nginx
    fi

    # 1.2 检测 PHP（≥7.4）
    PHP_VER=""
    for v in 8.2 8.1 8.0 7.4; do
        if command_exists php$v; then
            PHP_VER=$v
            break
        fi
    done
    if [ -n "$PHP_VER" ]; then
        info "检测到 PHP $PHP_VER"
    else
        info "安装 PHP7.4"
        if type apt-get >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends php7.4-fpm php7.4-cli php7.4-common php7.4-json php7.4-opcache php7.4-readline
            systemctl enable php7.4-fpm && systemctl start php7.4-fpm
            PHP_VER="7.4"
        elif type yum >/dev/null 2>&1; then
            yum install -y epel-release
            yum install -y php php-fpm
            systemctl enable php-fpm && systemctl start php-fpm
            PHP_VER="7.4"   # yum 默认即 7.4 左右
        else
            error_exit "不支持的包管理器，无法安装 PHP"
        fi
    fi

    # 1.3 配置 Nginx 解析 PHP
    NGINX_CONF="/etc/nginx/sites-available/print-service"
    mkdir -p "$(dirname "$NGINX_CONF")"
    cat >"$NGINX_CONF" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        # 根据系统实际 socket 调整
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;
        # 若 yum 安装可能是  /run/php-fpm/www.sock
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
    # 软链生效
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/print-service
    # 删除默认站点，防止 80 冲突
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx
}

# ----------------------------------------------------------
# 2. 后续流程与原版一致（仅把放 print.php 的时机挪到 Nginx 配置之后）
# ----------------------------------------------------------
clean_cache() {
    if type apt-get >/dev/null 2>&1; then
        info "清理系统缓存释放空间"
        apt-get clean >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
    fi
}

install_cups_if_needed() {
    if command_exists cupsd || systemctl status cups >/dev/null 2>&1 || [ -f /usr/sbin/cupsd ]; then
        info "CUPS已安装，跳过安装"
        return 0
    fi

    info "安装CUPS打印服务"
    if type apt-get >/dev/null 2>&1; then
        PM="apt-get"
        PM_INSTALL="apt-get install -y --no-install-recommends"
        export DEBIAN_FRONTEND=noninteractive
    elif type yum >/dev/null 2>&1; then
        PM="yum"
        PM_INSTALL="yum install -y"
    else
        error_exit "不支持的包管理器"
    fi

    $PM update || warn "更新软件包列表失败，继续安装"

    info "安装CUPS核心组件"
    $PM_INSTALL cups cups-filters ghostscript || {
        clean_cache
        $PM_INSTALL cups cups-filters ghostscript || error_exit "安装CUPS失败"
    }

    info "安装打印机驱动"
    $PM_INSTALL printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || {
        clean_cache
        $PM_INSTALL printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || warn "部分打印机驱动安装失败"
    }

    info "安装HP打印机插件"
    HP_PLUGIN_DIR="/tmp/hp_plugin_$$"
    mkdir -p "$HP_PLUGIN_DIR"
    cd "$HP_PLUGIN_DIR" || error_exit "进入HP插件目录失败"

    wget -q https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-3.20.3-plugin.run || warn "下载HP插件失败"
    wget -q https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-3.20.3-plugin.run.asc || warn "下载HP插件签名失败"
    wget -q https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hp_laserjet_1020.plugin || warn "下载HP LaserJet插件失败"

    if [ -f "hplip-3.20.3-plugin.run" ]; then
        sh hplip-3.20.3-plugin.run --noexec --target ./hplip-extract
        echo "p" | hp-plugin -p 2>/dev/null || warn "HP插件安装可能存在问题，继续执行"
    else
        warn "HP插件下载失败，跳过安装"
    fi

    cd /
    rm -rf "$HP_PLUGIN_DIR"

    info "配置CUPS远程访问"
    cupsctl --remote-any || warn "CUPS远程访问配置失败"
}

# ----------------------------------------------------------
# 主流程
# ----------------------------------------------------------
clean_cache
install_nginx_php   # <<<< 新增：先保证 Web 环境
install_cups_if_needed

if command_exists soffice; then
    info "LibreOffice已安装"
else
    info "安装LibreOffice"
    if type apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || {
            clean_cache
            apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || error_exit "安装LibreOffice失败"
        }
    elif type yum >/dev/null 2>&1; then
        yum install -y libreoffice-core libreoffice-writer libreoffice-calc || error_exit "安装LibreOffice失败"
    fi
fi

info "安装基础工具"
if type apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends wget curl qrencode || {
        clean_cache
        apt-get install -y --no-install-recommends wget curl qrencode || error_exit "安装工具失败"
    }
else
    yum install -y wget curl qrencode || error_exit "安装工具失败"
fi

info "配置打印服务"
TEMP_DIR=$(mktemp -d) || error_exit "创建临时目录失败"
cd "$TEMP_DIR" || error_exit "进入临时目录失败"

curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || error_exit "下载cupsd.conf失败"
curl -fsSL -o print.php "${REPO_URL}/configs/print.php" || error_exit "下载print.php失败"

cp cupsd.conf /etc/cups/cupsd.conf && chown root:lp /etc/cups/cupsd.conf && chmod 640 /etc/cups/cupsd.conf || error_exit "替换cupsd.conf失败"
mkdir -p "$WEB_ROOT" && cp print.php "$PRINT_PHP" && chmod 644 "$PRINT_PHP" || error_exit "放置print.php失败"

rm -rf "$TEMP_DIR"

info "配置FRP内网穿透"
if [ -f "${FRP_PATH}/${FRP_NAME}" ]; then
    info "FRP已安装"
else
    case $(uname -m) in
        x86_64) PLATFORM="amd64" ;;
        aarch64) PLATFORM="arm64" ;;
        armv7l|armhf) PLATFORM="arm" ;;
        *) error_exit "不支持的架构: $(uname -m)" ;;
    esac

    FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"
    DOWNLOAD_URL="${PROXY_URL}${DOWNLOAD_URL}"

    info "下载并安装FRP"
    wget -q "$DOWNLOAD_URL" -O - | tar -zxf - -C /tmp || error_exit "FRP安装失败"
    mkdir -p "${FRP_PATH}"
    mv "/tmp/${FILE_NAME}/${FRP_NAME}" "${FRP_PATH}" || error_exit "移动FRP文件失败"
    rm -rf "/tmp/${FILE_NAME}"

    CURRENT_DATE=$(date +%m%d)
    RANDOM_SUFFIX=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 2)
    SERVICE_NAME="${CURRENT_DATE}${RANDOM_SUFFIX}"
    REMOTE_PORT_SSH=$((RANDOM % 3001 + 3000))

    mkdir -p "$(dirname "${FRP_CONFIG_FILE}")"
    cat <<EOL > "${FRP_CONFIG_FILE}"
serverAddr = "frps.tzishue.tk"
serverPort = 7000
auth.token = "12345"
[[proxies]]
name = "print-ssh-$SERVICE_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $REMOTE_PORT_SSH
[[proxies]]
name = "print-web-${SERVICE_NAME}"
type = "http"
localIP = "127.0.0.1"
localPort = 80
subdomain = "nas-${SERVICE_NAME}"
EOL

    cat >"/lib/systemd/system/${FRP_NAME}.service" <<EOF
[Unit]
Description=Frp Client
After=network.target
[Service]
ExecStart=${FRP_PATH}/${FRP_NAME} -c ${FRP_CONFIG_FILE}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl start "${FRP_NAME}" && systemctl enable "${FRP_NAME}" || error_exit "启动FRP失败"
fi

info "重启CUPS服务"
systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || warn "CUPS服务重启失败，请手动检查"

echo -e "\n${GREEN}配置完成${FONT}"
REMOTE_PRINT_ADDR="http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php"
echo -e "远程打印机地址: ${REMOTE_PRINT_ADDR}"

echo -e "\n二维码:"
qrencode -t ANSIUTF8 "${REMOTE_PRINT_ADDR}"

echo -e "\n重启FRP命令: systemctl restart ${FRP_NAME}"
echo -e "重启CUPS命令: systemctl restart cups"
