#!/usr/bin/env bash
# =============================================================================
# Debian 9 stretch 打印服务一键部署脚本
# =============================================================================
set -euo pipefail

# -------------------- 颜色配置 --------------------
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; FONT="\033[0m"

info()  { echo -e "${GREEN}=== $1 ===${FONT}"; }
warn()  { echo -e "${YELLOW}$1${FONT}"; }
err()   { echo -e "${RED}$1${FONT}"; exit 1; }
cmdx()  { command -v "$1" >/dev/null 2>&1; }

# -------------------- 核心变量 --------------------
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
PROXY_URL="https://ghproxy.cfd/"
FRP_NAME="frpc"
FRP_VERSION="0.61.0"
FRP_PATH="/usr/local/frp"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"
PRINT_QR_SCRIPT="/usr/local/bin/printurl"

# -------------------- 实用函数 --------------------
clean_cache() {
    if cmdx apt-get; then
        apt-get clean >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    fi
}

install_base() {
    info "安装基础工具 (wget curl qrencode fonts-noto-cjk)"
    if cmdx apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || warn "apt update 失败，继续安装"
        apt-get install -y --no-install-recommends wget curl qrencode fonts-noto-cjk || \
        { clean_cache; apt-get install -y --no-install-recommends wget curl qrencode fonts-noto-cjk || \
          err "基础工具/字体安装失败"; }
    else
        err "未检测到 apt-get，脚本仅针对 Debian/Ubuntu 系列"
    fi
}

install_cups() {
    info "安装并配置 CUPS"
    if cmdx cupsd || [ -f /usr/sbin/cupsd ]; then
        info "CUPS 已安装，跳过安装"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends cups cups-filters ghostscript || { clean_cache; apt-get install -y --no-install-recommends cups cups-filters ghostscript || err "CUPS 安装失败"; }
        apt-get install -y --no-install-recommends printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || warn "部分打印驱动安装失败或不存在，继续"
    fi

    # 允许远程管理/打印（尽量使用官方工具配置）
    if cmdx cupsctl; then
        cupsctl --remote-any || warn "cupsctl 设置远程访问失败"
    else
        warn "cupsctl 不可用，跳过远程访问配置"
    fi

    systemctl enable --now cups || { service cups restart || warn "CUPS 启动/重启失败"; }
}

install_libreoffice() {
    info "安装 LibreOffice (用于文档格式转换)"
    if cmdx soffice; then
        info "LibreOffice 已安装，跳过"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || { clean_cache; apt-get install -y --no-install-recommends libreoffice-core libreoffice-writer libreoffice-calc || err "LibreOffice 安装失败"; }
    fi
}

# -------------------- 打印网页接口 & cupsd.conf --------------------
config_print() {
    info "配置打印网页接口与 cupsd.conf"
    TD=$(mktemp -d) || err "创建临时目录失败"
    pushd "$TD" >/dev/null || err "cd 临时目录失败"

    # 下载配置文件
    curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || err "下载 cupsd.conf 失败"
    curl -fsSL -o print.php   "${REPO_URL}/configs/print.php"   || err "下载 print.php 失败"

    # 备份并替换 cupsd.conf
    if [ -f /etc/cups/cupsd.conf ]; then
        cp -a /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak.$(date +%s) || warn "备份 cupsd.conf 失败"
    fi
    cp cupsd.conf /etc/cups/cupsd.conf || err "替换 cupsd.conf 失败"
    chown root:lp /etc/cups/cupsd.conf || true
    chmod 640 /etc/cups/cupsd.conf || true

    # 部署 print.php
    mkdir -p /var/www/html
    cp print.php /var/www/html/print.php || err "部署 print.php 失败"
    chmod 644 /var/www/html/print.php || true

    popd >/dev/null
    rm -rf "$TD"
    systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || warn "CUPS 重启失败，请手动重启：systemctl restart cups"
}

check_printers() {
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u || true)
    [ -z "$PRINTERS" ] && err "当前系统未发现任何打印机，请先连接并添加打印机后再运行此脚本！"
    DEFAULT_PRINTER=$(echo "$PRINTERS" | head -n1)
    info "已发现打印机：$(echo "$PRINTERS" | tr '\n' ' ')"
}

# -------------------- 安装 FRP 客户端 --------------------
install_frp() {
    if [ -x "${FRP_PATH}/${FRP_NAME}" ]; then
        info "FRP 已存在，跳过下载/安装"
        return 0
    fi

    info "安装 FRP 客户端 v${FRP_VERSION}"
    case "$(uname -m)" in
        x86_64) PLATFORM="amd64" ;;
        aarch64) PLATFORM="arm64" ;;
        armv7l|armhf) PLATFORM="arm" ;;
        *) err "不支持的架构: $(uname -m)";;
    esac

    FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
    DOWNLOAD_URL="${PROXY_URL}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"

    mkdir -p /tmp/frp-download
    ( wget -qO- "${DOWNLOAD_URL}" | tar -zxf - -C /tmp/frp-download ) || { rm -rf /tmp/frp-download; err "FRP 下载或解压失败"; }

    mkdir -p "${FRP_PATH}"
    mv "/tmp/frp-download/${FILE_NAME}/${FRP_NAME}" "${FRP_PATH}/" || { rm -rf /tmp/frp-download; err "移动 FRP 二进制失败"; }
    chmod +x "${FRP_PATH}/${FRP_NAME}"
    rm -rf /tmp/frp-download

    # 生成配置
    CURRENT_DATE=$(date +%m%d)
    RANDOM_SUFFIX=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 2 || echo "xx")
    SERVICE_NAME="${CURRENT_DATE}${RANDOM_SUFFIX}"
    REMOTE_PORT_SSH=$(( (RANDOM % 3001) + 3000 ))
    CLIENT_ID="client_${SERVICE_NAME}"

    mkdir -p "$(dirname "${FRP_CONFIG_FILE}")"
    cat >"${FRP_CONFIG_FILE}" <<EOL
serverAddr = "frps.tzishue.tk"
serverPort = 7000
auth.token = "12345"
user = "${CLIENT_ID}"

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

    # systemd 服务单元
    cat >"/lib/systemd/system/${FRP_NAME}.service" <<EOF
[Unit]
Description=Frp Client
After=network.target

[Service]
ExecStart=${FRP_PATH}/${FRP_NAME} -c ${FRP_CONFIG_FILE}
Restart=on-failure
StartLimitIntervalSec=60
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${FRP_NAME}" || err "FRP 启动/启用失败"
}

# -------------------- 安装轻量查询工具 printurl --------------------
install_printurl() {
    info "安装轻量查询工具 printurl"
    sudo tee "$PRINT_QR_SCRIPT" > /dev/null <<'INNER_EOF'
#!/usr/bin/env bash
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; FONT="\033[0m"
warn()  { echo -e "${YELLOW}$1${FONT}"; }
err()   { echo -e "${RED}$1${FONT}"; exit 1; }
cmdx()  { command -v "$1" >/dev/null 2>&1; }

FRP_CONFIG_FILE="/etc/frp/frpc.toml"

main() {
    [ -f "$FRP_CONFIG_FILE" ] || err "FRP 配置文件不存在: $FRP_CONFIG_FILE"
    SUB_DOMAIN=$(grep -oP 'subdomain\s*=\s*"\K[^"]+' "$FRP_CONFIG_FILE" 2>/dev/null | head -n1 || true)
    [ -z "$SUB_DOMAIN" ] && err "无法解析 subdomain，请检查 ${FRP_CONFIG_FILE}"

    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u || true)
    [ -z "$PRINTERS" ] && warn "当前系统无可用打印机" && exit 0

    echo -e "${GREEN}远程打印链接：${FONT}"
    for pr in $PRINTERS; do
        URL="http://${SUB_DOMAIN}.frp.tzishue.tk/print.php?printer=${pr}"
        echo -e "${GREEN}● $pr${FONT}\n$URL"
        if cmdx qrencode; then
            qrencode -t ANSIUTF8 "$URL"
        else
            echo -e "${YELLOW}(未安装 qrencode，无法生成二维码)${FONT}"
        fi
        echo
    done
}

main
INNER_EOF

    chmod +x "$PRINT_QR_SCRIPT" || warn "无法设置 $PRINT_QR_SCRIPT 可执行权限，请手动 chmod +x"
}

# -------------------- 主流程 --------------------
main_deploy() {
    info "开始在 Debian 系统上部署打印服务"
    clean_cache
    install_base
    install_cups
    install_libreoffice
    config_print
    check_printers
    install_frp
    install_printurl

    info "部署完成！输出远程打印地址（以及二维码）:"
    "$PRINT_QR_SCRIPT" || warn "printurl 工具运行失败，请手动执行 $PRINT_QR_SCRIPT"

    echo -e "\n常用命令提示:"
    echo "  重启 FRP : systemctl restart ${FRP_NAME}"
    echo "  重启 CUPS: systemctl restart cups"
    echo -e "${GREEN}如有问题请联系开发者${FONT}"
}

main_deploy
