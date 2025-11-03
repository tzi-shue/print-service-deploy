#!/usr/bin/env bash
# =============================================================================
# 打印服务部署脚本（含Nginx+PHP）
# =============================================================================
set -e

# -------------------- 颜色配置 --------------------
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; FONT="\033[0m"

# -------------------- 核心变量 --------------------
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
FRP_NAME="frpc"; FRP_VERSION="0.61.0"; FRP_PATH="/usr/local/frp"
PROXY_URL="https://ghproxy.cfd/"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"
PRINT_QR_SCRIPT="/usr/local/bin/printurl"  
WEB_ROOT="/var/www/html"
PRINT_PHP="$WEB_ROOT/print.php"
NGINX_CONF="/etc/nginx/sites-available/print-service"

# -------------------- 工具函数 --------------------
info()  { echo -e "${GREEN}=== $1 ===${FONT}"; }
warn()  { echo -e "${YELLOW}$1${FONT}"; }
err()   { echo -e "${RED}$1${FONT}"; exit 1; }
cmdx()  { command -v "$1" >/dev/null 2>&1; }

# -------------------- 依赖安装 --------------------
clean_cache() {
    cmdx apt-get && { apt-get clean >/dev/null 2>&1; apt-get autoremove -y >/dev/null 2>&1; }
}

install_nginx_php() {
    # 安装Nginx
    if systemctl is-active --quiet nginx; then
        info "Nginx 已运行，跳过"
    else
        info "安装 Nginx"
        if cmdx apt-get; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update || warn "更新列表失败，继续安装"
            apt-get install -y --no-install-recommends nginx || { clean_cache; apt-get install -y --no-install-recommends nginx || err "Nginx 安装失败"; }
        elif cmdx yum; then
            yum install -y nginx || err "Nginx 安装失败"
        else
            err "不支持的包管理器，无法安装 Nginx"
        fi
        systemctl enable nginx && systemctl start nginx
    fi

    # 安装PHP（≥7.4）
    local PHP_VER=""
    for v in 8.2 8.1 8.0 7.4; do
        if cmdx php$v; then
            PHP_VER=$v
            break
        fi
    done
    if [ -n "$PHP_VER" ]; then
        info "检测到 PHP $PHP_VER，跳过"
    else
        info "安装 PHP7.4"
        if cmdx apt-get; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y --no-install-recommends php7.4-fpm php7.4-cli php7.4-common php7.4-json php7.4-opcache php7.4-readline || { clean_cache; apt-get install -y --no-install-recommends php7.4-fpm php7.4-cli php7.4-common php7.4-json php7.4-opcache php7.4-readline || err "PHP 安装失败"; }
            systemctl enable php7.4-fpm && systemctl start php7.4-fpm
            PHP_VER="7.4"
        elif cmdx yum; then
            yum install -y epel-release
            yum install -y php php-fpm || err "PHP 安装失败"
            systemctl enable php-fpm && systemctl start php-fpm
            PHP_VER="7.4"
        else
            err "不支持的包管理器，无法安装 PHP"
        fi
    fi

    info "配置 Nginx 解析 PHP"
    local PHP_SOCKET="/run/php/php${PHP_VER}-fpm.sock"
    [ -f "/run/php-fpm/www.sock" ] && PHP_SOCKET="/run/php-fpm/www.sock"
    
    mkdir -p "$(dirname "$NGINX_CONF")"
    cat >"$NGINX_CONF" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root $WEB_ROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }
    location ~ /\.ht {
        deny all;
    }
}
EOF
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/print-service
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx || warn "Nginx 配置重载失败，需手动检查"
}

install_cups() {
    cmdx cupsd || systemctl is-active --quiet cups 2>/dev/null || [ -f /usr/sbin/cupsd ] && { info "CUPS 已安装，跳过"; return 0; }
    info "安装 CUPS 打印服务"
    if cmdx apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || warn "更新列表失败，继续安装"
        apt-get install -y --no-install-recommends cups cups-filters ghostscript || { clean_cache; apt-get install -y --no-install-recommends cups cups-filters ghostscript || err "CUPS 安装失败"; }
        apt-get install -y --no-install-recommends printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || { clean_cache; apt-get install -y --no-install-recommends printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || warn "部分打印机驱动安装失败"; }
    elif cmdx yum; then
        yum install -y cups cups-filters ghostscript printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || err "CUPS 安装失败"
    else err "不支持的包管理器"; fi
    cupsctl --remote-any || warn "CUPS 远程访问配置失败"
}

install_lo() {
    cmdx soffice && { info "LibreOffice 已安装，跳过"; return 0; }
    info "安装 LibreOffice"
    if cmdx apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || { clean_cache; apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || err "LibreOffice 安装失败"; }
    elif cmdx yum; then
        yum install -y libreoffice-core libreoffice-writer libreoffice-calc || err "LibreOffice 安装失败"
    fi
}

install_base() {
    info "安装基础工具"
    if cmdx apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends wget curl qrencode || { clean_cache; apt-get install -y --no-install-recommends wget curl qrencode || err "基础工具安装失败"; }
    else yum install -y wget curl qrencode || err "基础工具安装失败"; fi
}

# -------------------- 服务配置 --------------------
config_print() {
    info "配置打印网页接口"
    TD=$(mktemp -d) && cd "$TD" || err "创建临时目录失败"
    curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || err "下载 cupsd.conf 失败"
    curl -fsSL -o print.php "${REPO_URL}/configs/print.php"   || err "下载 print.php 失败"
    cp cupsd.conf /etc/cups/cupsd.conf && chown root:lp /etc/cups/cupsd.conf && chmod 640 /etc/cups/cupsd.conf || err "替换 cupsd.conf 失败"
    mkdir -p "$WEB_ROOT" && cp print.php "$PRINT_PHP" && chmod 644 "$PRINT_PHP" || err "部署 print.php 失败"
    rm -rf "$TD"
}

check_printers() {
    local PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    [ -z "$PRINTERS" ] && err "当前系统未配置打印机！请先连接打印机并添加队列后重新执行"
    info "已发现打印机：$(echo "$PRINTERS" | tr '\n' ' ')"
}

install_frp() {
    [ -f "${FRP_PATH}/${FRP_NAME}" ] && { info "FRP 已安装，跳过"; return 0; }
    info "安装 FRP 客户端"
    local PLATFORM=""
    case $(uname -m) in
        x86_64)  PLATFORM="amd64" ;;
        aarch64) PLATFORM="arm64" ;;
        armv7l|armhf) PLATFORM="arm" ;;
        *) err "不支持的架构: $(uname -m)" ;;
    esac
    local FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
    local DOWNLOAD_URL="${PROXY_URL}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"

    wget -q "$DOWNLOAD_URL" -O - | tar -zxf - -C /tmp || err "FRP 下载解压失败"
    mkdir -p "${FRP_PATH}"
    mv "/tmp/${FILE_NAME}/${FRP_NAME}" "${FRP_PATH}" || err "移动 FRP 二进制失败"
    rm -rf "/tmp/${FILE_NAME}"

    local CURRENT_DATE=$(date +%m%d)
    local RANDOM_SUFFIX=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 2)
    SERVICE_NAME="${CURRENT_DATE}${RANDOM_SUFFIX}"
    local REMOTE_PORT_SSH=$((RANDOM % 3001 + 3000))

    mkdir -p "$(dirname "${FRP_CONFIG_FILE}")"
    cat >"${FRP_CONFIG_FILE}" <<EOL
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
    systemctl start "${FRP_NAME}" && systemctl enable "${FRP_NAME}" || err "FRP 启动失败"
}

# -------------------- 静默安装轻量查询工具 --------------------
install_printurl() {
    info "安装轻量查询工具 printurl"  
    sudo tee "$PRINT_QR_SCRIPT" > /dev/null 2>&1 << 'INNER_EOF'
#!/usr/bin/env bash
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; FONT="\033[0m"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"
warn()  { echo -e "${YELLOW}$1${FONT}"; }
err()   { echo -e "${RED}$1${FONT}"; exit 1; }
cmdx()  { command -v "$1" >/dev/null 2>&1; }

main() {
    SUB_DOMAIN=$(grep -oP 'subdomain\s*=\s*"\K[^"]+' "$FRP_CONFIG_FILE" 2>/dev/null | head -n1)
    [ -z "$SUB_DOMAIN" ] && err "FRP配置缺失：$FRP_CONFIG_FILE 或 subdomain解析失败"
    
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    [ -z "$PRINTERS" ] && warn "当前系统无可用打印机" && exit 0
    
    echo -e "${GREEN}远程打印链接：${FONT}"
    for pr in $PRINTERS; do
        URL="http://${SUB_DOMAIN}.frp.tzishue.tk/print.php?printer=${pr}"
        echo -e "${GREEN}● $pr${FONT}\n$URL"
        cmdx qrencode && qrencode -t ANSIUTF8 "$URL" || echo -e "${YELLOW}(qrencode未安装，无法显示二维码)${FONT}"
        echo
    done
}
main
INNER_EOF
    chmod +x "$PRINT_QR_SCRIPT" > /dev/null 2>&1 || warn "printurl 权限配置失败，请手动执行：chmod +x $PRINT_QR_SCRIPT"
}

# -------------------- 主部署流程 --------------------
main_deploy() {
    info "开始打印服务部署（含Nginx+PHP）"
    clean_cache
    install_base
    install_nginx_php  
    install_cups
    install_lo
    config_print
    check_printers
    install_frp
    install_printurl 

    info "部署完成！首次查询结果如下："
    "$PRINT_QR_SCRIPT"

    systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || warn "CUPS重启失败，请手动执行：systemctl restart cups"
    systemctl restart nginx 2>/dev/null || service nginx restart 2>/dev/null || warn "Nginx重启失败，请手动执行：systemctl restart nginx"
    echo -e "\n${GREEN}后续查询直接执行命令：printurl${FONT}"
    echo -e "${GREEN}Nginx重启命令：systemctl restart nginx | PHP-FPM重启命令：systemctl restart php7.4-fpm（或php-fpm）${FONT}"
}

main_deploy
