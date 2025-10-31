#!/bin/bash
# ============================================================================
# 打印服务一键部署脚本
# ============================================================================
set -e

# -------------------- 颜色定义 --------------------
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
FONT="\033[0m"

# -------------------- 变量默认值 --------------------
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
FRP_NAME="frpc"
FRP_VERSION="0.61.0"
FRP_PATH="/usr/local/frp"
PROXY_URL="https://ghproxy.cfd/"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"

# -------------------- 工具函数 --------------------
info()  { echo -e "${GREEN}=== $1 ===${FONT}"; }
warn()  { echo -e "${YELLOW}$1${FONT}"; }
error_exit() { echo -e "${RED}$1${FONT}"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# -------------------- 缓存清理 --------------------
clean_cache() {
    if type apt-get >/dev/null 2>&1; then
        info "清理系统缓存释放空间"
        apt-get clean >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
    fi
}

# -------------------- CUPS 安装 --------------------
install_cups_if_needed() {
    if command_exists cupsd || systemctl status cups >/dev/null 2>&1 || [ -f /usr/sbin/cupsd ]; then
        info "CUPS 已安装，跳过安装"
        return 0
    fi

    info "安装 CUPS 打印服务"
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

    info "安装 CUPS 核心组件"
    $PM_INSTALL cups cups-filters ghostscript || {
        clean_cache
        $PM_INSTALL cups cups-filters ghostscript || error_exit "安装 CUPS 失败"
    }

    info "安装常用打印机驱动"
    $PM_INSTALL printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || {
        clean_cache
        $PM_INSTALL printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || warn "部分驱动安装失败"
    }

    info "配置 CUPS 远程访问"
    cupsctl --remote-any || warn "CUPS 远程访问配置失败"
}

# -------------------- LibreOffice 安装 --------------------
install_libreoffice_if_needed() {
    if command_exists soffice; then
        info "LibreOffice 已安装"
    else
        info "安装 LibreOffice"
        if type apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || {
                clean_cache
                apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || error_exit "安装 LibreOffice 失败"
            }
        elif type yum >/dev/null 2>&1; then
            yum install -y libreoffice-core libreoffice-writer libreoffice-calc || error_exit "安装 LibreOffice 失败"
        fi
    fi
}

# -------------------- 基础工具安装 --------------------
install_base_tools() {
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
}

# -------------------- 打印服务配置 --------------------
config_print_service() {
    info "配置打印服务"
    TEMP_DIR=$(mktemp -d) || error_exit "创建临时目录失败"
    cd "$TEMP_DIR" || error_exit "进入临时目录失败"

    curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || error_exit "下载 cupsd.conf 失败"
    curl -fsSL -o print.php "${REPO_URL}/configs/print.php"   || error_exit "下载 print.php 失败"

    cp cupsd.conf /etc/cups/cupsd.conf && chown root:lp /etc/cups/cupsd.conf && chmod 640 /etc/cups/cupsd.conf || error_exit "替换 cupsd.conf 失败"
    mkdir -p /var/www/html && cp print.php /var/www/html/print.php && chmod 644 /var/www/html/print.php || error_exit "部署 print.php 失败"

    rm -rf "$TEMP_DIR"
}


check_printer_or_exit() {
    info "检测已添加的打印机队列"
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)

    if [ -z "$PRINTERS" ]; then
        error_exit "当前系统尚未配置任何打印机，请先连接并添加打印机后再运行本脚本！"
    fi

    DEFAULT_PRINTER=$(echo "$PRINTERS" | head -n1)
    info "已发现打印机队列：$(echo "$PRINTERS" | tr '\n' ' ')"
    info "默认将使用：$DEFAULT_PRINTER"
}

# -------------------- FRP 安装 --------------------
install_frp_if_needed() {
    [ -f "${FRP_PATH}/${FRP_NAME}" ] && { info "FRP 已安装"; return 0; }

    case $(uname -m) in
        x86_64) PLATFORM="amd64" ;;
        aarch64) PLATFORM="arm64" ;;
        armv7l|armhf) PLATFORM="arm" ;;
        *) error_exit "不支持的架构: $(uname -m)" ;;
    esac

    FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
    DOWNLOAD_URL="${PROXY_URL}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"

    info "下载并安装 FRP"
    wget -q "$DOWNLOAD_URL" -O - | tar -zxf - -C /tmp || error_exit "FRP 安装失败"
    mkdir -p "${FRP_PATH}"
    mv "/tmp/${FILE_NAME}/${FRP_NAME}" "${FRP_PATH}" || error_exit "移动 FRP 文件失败"
    rm -rf "/tmp/${FILE_NAME}"

    CURRENT_DATE=$(date +%m%d)
    RANDOM_SUFFIX=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 2)
    SERVICE_NAME="${CURRENT_DATE}${RANDOM_SUFFIX}"
    REMOTE_PORT_SSH=$((RANDOM % 3001 + 3000))

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
    systemctl start "${FRP_NAME}" && systemctl enable "${FRP_NAME}" || error_exit "启动 FRP 失败"
}


detect_printers_and_show_urls() {
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    DEFAULT_PRINTER=$(echo "$PRINTERS" | head -n1)
    REMOTE_PRINT_ADDR="http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php?printer=${DEFAULT_PRINTER}"

    echo -e "\n${GREEN}配置完成${FONT}"
    echo -e "远程打印地址: ${REMOTE_PRINT_ADDR}"

    echo -e "\n二维码:"
    qrencode -t ANSIUTF8 "${REMOTE_PRINT_ADDR}"

    if [ "$(echo "$PRINTERS" | wc -l)" -gt 1 ]; then
        info "全部打印机链接:"
        echo "$PRINTERS" | while read -r printer; do
            echo "  - $printer: http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php?printer=${printer}"
        done
    fi
}


clean_cache
install_cups_if_needed
install_libreoffice_if_needed
install_base_tools
config_print_service

check_printer_or_exit  

install_frp_if_needed

info "重启 CUPS 服务"
systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || warn "CUPS 服务重启失败，请手动检查"

detect_printers_and_show_urls

echo -e "\n常用命令:"
echo "  重启 FRP: systemctl restart ${FRP_NAME}"
echo "  重启 CUPS: systemctl restart cups"
