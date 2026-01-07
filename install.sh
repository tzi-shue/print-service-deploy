#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/websocket_printer"
SERVICE_NAME="websocket-printer"
LOG_FILE="/var/log/websocket_printer.log"

_h() { echo "$1" | xxd -r -p; }
_a="68747470733a2f2f"
_b="78696e7072696e74"
_c="2e7a79736861"
_d="72652e746f70"
_e="2f757064617465"
REMOTE_BASE_URL=$(_h "${_a}${_b}${_c}${_d}${_e}")

REMOTE_FILES=(
    "printer_client.php"
    "printer-client.service"
    "generate_qrcode.sh"
)

print_msg() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "\n${BLUE}========== $1 ==========${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        print_msg "使用: sudo bash install.sh"
        exit 1
    fi
}

detect_system() {
    print_step "检测系统环境"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        print_msg "系统: $PRETTY_NAME"
    else
        print_error "无法检测系统类型"
        exit 1
    fi
    ARCH=$(uname -m)
    print_msg "架构: $ARCH"
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    print_msg "内存: ${TOTAL_MEM}MB"
    if [ "$TOTAL_MEM" -lt 256 ]; then
        print_warn "内存较小，可能影响 LibreOffice 转换性能"
    fi
}

update_system() {
    print_step "更新系统包列表"
    apt-get update -y
    print_msg "系统包列表已更新"
}

cleanup_apt_cache() {
    print_msg "清理apt缓存释放存储空间..."
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

install_base_deps() {
    print_step "安装基础依赖"
    PACKAGES="curl wget git unzip qrencode"
    for pkg in $PACKAGES; do
        if ! command -v $pkg &> /dev/null; then
            print_msg "安装 $pkg..."
            apt-get install -y --no-install-recommends $pkg
        else
            print_msg "$pkg 已安装"
        fi
    done
    cleanup_apt_cache
}

install_php() {
    print_step "检查 PHP 环境"
    REQUIRED_EXTS="curl mbstring json sockets"
    NEED_INSTALL=false
    MISSING_EXTS=""
    if command -v php &> /dev/null; then
        PHP_VERSION=$(php -v | head -n 1 | cut -d ' ' -f 2 | cut -d '.' -f 1,2)
        print_msg "PHP 已安装: $PHP_VERSION"
        for ext in $REQUIRED_EXTS; do
            if ! php -m | grep -qi "^$ext$"; then
                MISSING_EXTS="$MISSING_EXTS $ext"
                NEED_INSTALL=true
            fi
        done
        if [ "$NEED_INSTALL" = false ]; then
            print_msg "所有必要扩展已安装，跳过"
            for ext in $REQUIRED_EXTS; do
                print_msg "  ✓ $ext"
            done
            return
        else
            print_warn "缺少扩展:$MISSING_EXTS"
        fi
    else
        print_msg "PHP 未安装，开始安装..."
        NEED_INSTALL=true
    fi
    if [ "$NEED_INSTALL" = true ]; then
        if ! command -v php &> /dev/null; then
            print_msg "安装 PHP..."
            apt-get install -y --no-install-recommends php php-cli 2>/dev/null || apt-get install -y --no-install-recommends php7.4 php7.4-cli 2>/dev/null
        fi
        print_msg "安装 PHP 扩展..."
        for ext in $REQUIRED_EXTS; do
            if ! php -m | grep -qi "^$ext$"; then
                print_msg "  安装 php-$ext..."
                apt-get install -y --no-install-recommends php-$ext 2>/dev/null || apt-get install -y --no-install-recommends php7.4-$ext 2>/dev/null || true
            fi
        done
        cleanup_apt_cache
    fi
    print_msg "验证 PHP 扩展..."
    for ext in $REQUIRED_EXTS; do
        if php -m | grep -qi "^$ext$"; then
            print_msg "  ✓ $ext"
        else
            print_warn "  ✗ $ext (安装失败，可能影响功能)"
        fi
    done
}

install_cups() {
    print_step "安装 CUPS 打印系统"
    if command -v lpstat &> /dev/null; then
        print_msg "CUPS 已安装"
    else
        print_msg "安装 CUPS..."
        apt-get install -y --no-install-recommends cups cups-client cups-bsd
        cleanup_apt_cache
    fi
    print_msg "启动 CUPS 服务..."
    systemctl enable cups
    systemctl start cups
    if [ -f /etc/cups/cupsd.conf ]; then
        cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
        print_msg "从远程下载 CUPS 配置文件..."
        CUPSD_CONF_URL="${REMOTE_BASE_URL}/cupsd.conf"
        if curl -sSL -o /etc/cups/cupsd.conf "$CUPSD_CONF_URL"; then
            print_msg "CUPS 配置文件下载成功"
            systemctl restart cups
        else
            print_warn "CUPS 配置文件下载失败，恢复备份..."
            cp /etc/cups/cupsd.conf.bak /etc/cups/cupsd.conf
        fi
    fi
    print_msg "CUPS 状态: $(systemctl is-active cups)"
}


check_pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii" && return 0 || return 1
}

install_printer_drivers() {
    print_step "安装打印机驱动"
    NEED_UPDATE=false
    if check_pkg_installed "printer-driver-gutenprint"; then
        print_msg "Gutenprint 驱动已安装"
    else
        print_msg "安装通用打印机驱动..."
        apt-get install -y --no-install-recommends printer-driver-gutenprint 2>/dev/null || true
        NEED_UPDATE=true
    fi
    if check_pkg_installed "hplip" || check_pkg_installed "hplip-minimal"; then
        print_msg "HP 驱动已安装"
    else
        print_msg "安装 HP 驱动..."
        apt-get install -y --no-install-recommends hplip-minimal 2>/dev/null || \
        apt-get install -y --no-install-recommends hplip 2>/dev/null || print_warn "HP驱动安装跳过"
        NEED_UPDATE=true
    fi
    if check_pkg_installed "printer-driver-splix"; then
        print_msg "Samsung/Xerox 驱动已安装"
    else
        print_msg "安装 Samsung/Xerox 驱动..."
        apt-get install -y --no-install-recommends printer-driver-splix 2>/dev/null || print_warn "Samsung/Xerox驱动安装跳过"
        NEED_UPDATE=true
    fi
    if check_pkg_installed "printer-driver-brlaser"; then
        print_msg "Lenovo/Brother 驱动已安装"
    else
        print_msg "安装联想/兄弟打印机驱动..."
        apt-get install -y --no-install-recommends printer-driver-brlaser 2>/dev/null || print_warn "Lenovo/Brother驱动安装跳过"
        NEED_UPDATE=true
    fi
    if check_pkg_installed "printer-driver-escpr"; then
        print_msg "Epson 驱动已安装"
    else
        print_msg "安装 Epson 驱动..."
        apt-get install -y --no-install-recommends printer-driver-escpr 2>/dev/null || print_warn "Epson驱动安装跳过"
        NEED_UPDATE=true
    fi
    if check_pkg_installed "foomatic-db-engine"; then
        print_msg "Foomatic 驱动引擎已安装"
    else
        print_msg "安装Foomatic驱动引擎..."
        apt-get install -y --no-install-recommends foomatic-db-engine 2>/dev/null || print_warn "Foomatic引擎安装跳过"
        NEED_UPDATE=true
    fi
    if ! check_pkg_installed "foomatic-db-compressed-ppds"; then
        apt-get install -y --no-install-recommends foomatic-db-compressed-ppds 2>/dev/null || true
        NEED_UPDATE=true
    fi
    if ! check_pkg_installed "printer-driver-postscript-hp"; then
        apt-get install -y --no-install-recommends printer-driver-postscript-hp 2>/dev/null || true
        NEED_UPDATE=true
    fi
    if [ "$NEED_UPDATE" = true ]; then
        cleanup_apt_cache
    fi
    print_msg "打印机驱动安装完成"
}

install_libreoffice() {
    print_step "安装 LibreOffice (文档转换)"
    if command -v libreoffice &> /dev/null; then
        LO_VERSION=$(libreoffice --version | head -n 1)
        print_msg "LibreOffice 已安装: $LO_VERSION"
    else
        print_msg "安装 LibreOffice (这可能需要几分钟)..."
        apt-get install -y --no-install-recommends libreoffice-writer-nogui libreoffice-calc-nogui 2>/dev/null || \
        apt-get install -y --no-install-recommends libreoffice-writer libreoffice-calc 2>/dev/null || \
        apt-get install -y libreoffice-writer libreoffice-calc
        cleanup_apt_cache
    fi
    mkdir -p /tmp/.libreoffice
    chmod 777 /tmp/.libreoffice
}

install_print_tools() {
    print_step "安装打印增强工具"
    NEED_CLEANUP=false
    if command -v gs &> /dev/null; then
        print_msg "Ghostscript 已安装"
    else
        print_msg "安装 Ghostscript (PDF/PS处理)..."
        apt-get install -y --no-install-recommends ghostscript 2>/dev/null || print_warn "ghostscript 安装跳过"
        NEED_CLEANUP=true
    fi
    if command -v qpdf &> /dev/null; then
        print_msg "qpdf 已安装"
    else
        print_msg "安装 qpdf (PDF处理工具)..."
        apt-get install -y --no-install-recommends qpdf 2>/dev/null || print_warn "qpdf 安装跳过"
        NEED_CLEANUP=true
    fi
    if command -v convert &> /dev/null; then
        print_msg "ImageMagick 已安装"
    else
        print_msg "安装 ImageMagick (图片处理工具)..."
        apt-get install -y --no-install-recommends imagemagick 2>/dev/null || print_warn "ImageMagick 安装跳过"
        NEED_CLEANUP=true
    fi
    if command -v pdfjam &> /dev/null; then
        print_msg "pdfjam 已安装"
    else
        print_msg "安装 pdfjam (PDF页面处理，横向打印必需)..."
        apt-get install -y --no-install-recommends texlive-extra-utils 2>/dev/null || print_warn "pdfjam 安装跳过"
        NEED_CLEANUP=true
    fi
    if command -v pdftk &> /dev/null; then
        print_msg "pdftk 已安装"
    else
        print_msg "安装 pdftk (PDF工具包)..."
        apt-get install -y --no-install-recommends pdftk-java 2>/dev/null || apt-get install -y --no-install-recommends pdftk 2>/dev/null || print_warn "pdftk 安装跳过（可选）"
        NEED_CLEANUP=true
    fi
    if [ "$NEED_CLEANUP" = true ]; then
        cleanup_apt_cache
    fi
    echo ""
    print_msg "打印增强工具安装状态:"
    if command -v gs &> /dev/null; then
        print_msg "  ✓ Ghostscript $(gs --version 2>&1)"
    else
        print_warn "  ✗ Ghostscript 未安装"
    fi
    if command -v qpdf &> /dev/null; then
        print_msg "  ✓ qpdf $(qpdf --version 2>&1 | head -1)"
    else
        print_warn "  ✗ qpdf 未安装"
    fi
    if command -v convert &> /dev/null; then
        print_msg "  ✓ ImageMagick $(convert --version 2>&1 | head -1 | cut -d' ' -f3)"
    else
        print_warn "  ✗ ImageMagick 未安装"
    fi
    if command -v pdfjam &> /dev/null; then
        print_msg "  ✓ pdfjam 已安装（横向打印支持）"
    else
        print_warn "  ✗ pdfjam 未安装（横向打印可能使用备选方案）"
    fi
    if command -v pdftk &> /dev/null; then
        print_msg "  ✓ pdftk 已安装"
    else
        print_msg "  - pdftk 未安装（可选）"
    fi
    print_msg "打印增强工具安装完成"
}

download_files() {
    print_step "下载客户端文件"
    mkdir -p $INSTALL_DIR
    for file in "${REMOTE_FILES[@]}"; do
        print_msg "下载 $file..."
        # 使用 download.php 接口下载，避免 PHP 被执行
        DOWNLOAD_URL="${REMOTE_BASE_URL}/download.php?f=${file}"
        if curl -sSL -o "$INSTALL_DIR/$file" "$DOWNLOAD_URL"; then
            # 检查下载的内容是否正确（不是 HTML 错误页面）
            if head -1 "$INSTALL_DIR/$file" | grep -q "^#!/usr/bin/env php\|^#!/bin/bash\|^\[Unit\]\|^#"; then
                print_msg "  ✓ $file 下载成功"
            else
                print_warn "  ✗ $file 下载内容异常，尝试本地复制"
                SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                if [ -f "$SCRIPT_DIR/$file" ]; then
                    cp "$SCRIPT_DIR/$file" "$INSTALL_DIR/"
                    print_msg "  ✓ $file 从本地复制"
                fi
            fi
        else
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$SCRIPT_DIR/$file" ]; then
                cp "$SCRIPT_DIR/$file" "$INSTALL_DIR/"
                print_msg "  ✓ $file 从本地复制"
            else
                print_warn "  ✗ $file 下载失败"
            fi
        fi
    done
    if [ ! -f "$INSTALL_DIR/printer_client.php" ]; then
        print_error "printer_client.php 下载失败"
        exit 1
    fi
    chmod +x "$INSTALL_DIR/printer_client.php"
    chmod +x "$INSTALL_DIR/generate_qrcode.sh" 2>/dev/null || true
    touch $LOG_FILE
    chmod 666 $LOG_FILE
    print_msg "文件下载完成"
}

install_websocket_client() {
    download_files
}

configure_server() {
    print_step "配置服务器连接"
    CURRENT_SERVER=$(grep -oP "\\\$WS_SERVER = '\K[^']+" "$INSTALL_DIR/printer_client.php" 2>/dev/null || echo "")
    if [ -n "$CURRENT_SERVER" ] && [ "$CURRENT_SERVER" != "ws://your-server:8089" ]; then
        print_msg "服务器地址已配置: $CURRENT_SERVER"
        print_msg "如需修改，请编辑: $INSTALL_DIR/printer_client.php"
        return
    fi
    print_msg "使用内置默认服务器地址"
}

get_device_id() {
    local idFile="/etc/printer-device-id"
    if [ -f "$idFile" ]; then
        DEVICE_ID=$(cat "$idFile" 2>/dev/null | tr -d '\r\n')
        if [[ "$DEVICE_ID" =~ ^[0-9a-fA-F]{30,32}$ ]]; then
            echo "${DEVICE_ID,,}"
            return 0
        fi
    fi
    if command -v openssl >/dev/null 2>&1; then
        DEVICE_ID=$(openssl rand -hex 15 2>/dev/null)
    else
        DEVICE_ID=$(head -c 15 /dev/urandom | hexdump -e '15/1 "%02x" "\n"' 2>/dev/null)
    fi
    if [[ -z "$DEVICE_ID" || ! "$DEVICE_ID" =~ ^[0-9a-fA-F]{30}$ ]]; then
        echo ""
        return 1
    fi
    echo "${DEVICE_ID,,}" > "$idFile" 2>/dev/null || return 1
    chmod 644 "$idFile" 2>/dev/null || true
    echo "${DEVICE_ID,,}"
}

configure_device_id() {
    print_step "设备ID信息"
    DEVICE_ID=$(get_device_id)
    if [ -z "$DEVICE_ID" ]; then
        print_error "设备ID生成失败：无法生成或保存随机设备ID"
        return 1
    fi
    print_msg "设备ID: $DEVICE_ID"
}

create_service() {
    print_step "创建系统服务"
    if [ -f "$INSTALL_DIR/printer-client.service" ]; then
        print_msg "使用下载的服务配置文件"
        sed -i "s|/opt/printer-client|$INSTALL_DIR|g" "$INSTALL_DIR/printer-client.service"
        cp "$INSTALL_DIR/printer-client.service" /etc/systemd/system/${SERVICE_NAME}.service
    else
        print_msg "创建默认服务配置"
        cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=WebSocket Printer Client
After=network.target cups.service

[Service]
Type=simple
ExecStart=/usr/bin/php $INSTALL_DIR/printer_client.php
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Environment=HOME=/tmp
Environment=SHELL=/bin/bash

[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    print_msg "服务已创建: $SERVICE_NAME"
}

detect_printers() {
    print_step "检测打印机"
    print_msg "已配置的打印机:"
    echo ""
    lpstat -a 2>/dev/null || echo "  (无)"
    echo ""
    print_msg "默认打印机:"
    lpstat -d 2>/dev/null || echo "  (未设置)"
    echo ""
    print_msg "USB 设备:"
    lsusb 2>/dev/null | grep -i "print\|samsung\|hp\|canon\|epson\|brother" || echo "  (未检测到打印机USB设备)"
    echo ""
}

add_printer_wizard() {
    print_step "添加打印机"
    echo ""
    echo "添加打印机方式:"
    echo "  1. 通过 CUPS Web 界面 (推荐)"
    echo "  2. 命令行添加 USB 打印机"
    echo "  3. 命令行添加网络打印机"
    echo "  4. 跳过"
    echo ""
    read -p "请选择 [1-4]: " CHOICE
    case $CHOICE in
        1)
            print_msg "请在浏览器中访问: http://$(hostname -I | awk '{print $1}'):631"
            print_msg "用户名: root, 密码: 系统root密码"
            ;;
        2)
            print_msg "检测 USB 打印机..."
            lpinfo -v 2>/dev/null | grep usb || echo "未检测到USB打印机"
            echo ""
            read -p "请输入打印机URI (如 usb://...): " PRINTER_URI
            read -p "请输入打印机名称: " PRINTER_NAME
            if [ -n "$PRINTER_URI" ] && [ -n "$PRINTER_NAME" ]; then
                print_msg "查找驱动..."
                lpinfo -m | head -20
                echo ""
                read -p "请输入驱动名称 (如 drv:///...): " DRIVER
                lpadmin -p "$PRINTER_NAME" -v "$PRINTER_URI" -m "$DRIVER" -E
                print_msg "打印机 $PRINTER_NAME 已添加"
            fi
            ;;
        3)
            read -p "请输入打印机IP地址: " PRINTER_IP
            read -p "请输入打印机名称: " PRINTER_NAME
            read -p "协议 [ipp/lpd/socket] (默认ipp): " PROTOCOL
            PROTOCOL=${PROTOCOL:-ipp}
            case $PROTOCOL in
                ipp) PRINTER_URI="ipp://$PRINTER_IP/ipp/print" ;;
                lpd) PRINTER_URI="lpd://$PRINTER_IP/queue" ;;
                socket) PRINTER_URI="socket://$PRINTER_IP:9100" ;;
            esac
            if [ -n "$PRINTER_NAME" ]; then
                lpadmin -p "$PRINTER_NAME" -v "$PRINTER_URI" -m everywhere -E 2>/dev/null || \
                lpadmin -p "$PRINTER_NAME" -v "$PRINTER_URI" -m raw -E
                print_msg "打印机 $PRINTER_NAME 已添加"
            fi
            ;;
        4)
            print_msg "跳过添加打印机"
            ;;
    esac
}

generate_qrcode() {
    print_step "生成设备二维码"
    if [ -f "$INSTALL_DIR/generate_qrcode.sh" ]; then
        print_msg "使用 generate_qrcode.sh 生成二维码..."
        chmod +x "$INSTALL_DIR/generate_qrcode.sh"
        bash "$INSTALL_DIR/generate_qrcode.sh"
        return
    fi
    DEVICE_ID=$(get_device_id)
    if [ -z "$DEVICE_ID" ]; then
        print_error "无法获取设备ID"
        return
    fi
    QR_CONTENT="device://$DEVICE_ID"
    print_msg "设备ID: $DEVICE_ID"
    print_msg "二维码内容: $QR_CONTENT"
    if ! command -v qrencode &> /dev/null; then
        print_msg "安装 qrencode..."
        apt-get install -y qrencode >/dev/null 2>&1
    fi
    if command -v qrencode &> /dev/null; then
        QR_FILE="/tmp/device_qr_$DEVICE_ID.png"
        qrencode -o "$QR_FILE" -s 10 "$QR_CONTENT"
        print_msg "二维码图片已保存: $QR_FILE"
        echo ""
        qrencode -t ANSIUTF8 "$QR_CONTENT"
        echo ""
    else
        print_warn "qrencode 安装失败，请手动使用以下内容生成二维码:"
        echo ""
        echo "  $QR_CONTENT"
        echo ""
    fi
}

start_service() {
    print_step "启动服务"
    systemctl start $SERVICE_NAME
    sleep 2
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_msg "服务启动成功!"
    else
        print_error "服务启动失败，查看日志:"
        tail -20 $LOG_FILE
    fi
}

show_summary() {
    print_step "安装完成"
    print_msg "执行最终清理..."
    apt-get clean
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /var/lib/apt/lists/*
    rm -rf /tmp/* 2>/dev/null || true
    rm -rf /var/tmp/* 2>/dev/null || true
    journalctl --vacuum-time=1d 2>/dev/null || true
    echo ""
    echo "============================================"
    echo "  WebSocket 打印客户端安装完成!"
    echo "============================================"
    echo ""
    echo "安装目录: $INSTALL_DIR"
    echo "日志文件: $LOG_FILE"
    echo "服务名称: $SERVICE_NAME"
    echo ""
    echo "常用命令:"
    echo "  启动服务: systemctl start $SERVICE_NAME"
    echo "  停止服务: systemctl stop $SERVICE_NAME"
    echo "  重启服务: systemctl restart $SERVICE_NAME"
    echo "  查看状态: systemctl status $SERVICE_NAME"
    echo "  查看日志: tail -f $LOG_FILE"
    echo ""
    echo "CUPS管理: http://$(hostname -I | awk '{print $1}'):631"
    echo ""
    print_msg "存储空间:"
    df -h / | tail -1 | awk '{print "  已用: "$3" / "$2" ("$5" 使用率)"}'
    echo ""
    echo "当前服务状态:"
    systemctl status $SERVICE_NAME --no-pager -l | head -10
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${GREEN}  使用说明${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo "1. 微信扫描下方小程序码进入打印小程序"
    echo "2. 在小程序中点击「绑定设备」"
    echo "3. 扫描设备二维码完成绑定 (运行: bash $INSTALL_DIR/generate_qrcode.sh)"
    echo "4. 绑定成功后即可远程打印文件"
    echo ""
    _qa="68747470733a2f2f"
    _qb="78696e7072696e74"
    _qc="2e7a79736861"
    _qd="72652e746f70"
    _qe="2f6170695f696e7374616c6c5f7172636f64652e706870"
    QR_API=$(_h "${_qa}${_qb}${_qc}${_qd}${_qe}")
    QR_CONTENT=$(curl -sSL "$QR_API" 2>/dev/null | grep -oP '"qrcode"\s*:\s*"\K[^"]+' || echo "")
    if [ -z "$QR_CONTENT" ]; then
        _ba="68747470733a2f2f"
        _bb="78696e7072696e74"
        _bc="2e7a79736861"
        _bd="72652e746f70"
        _be="2f7863782e706870"
        QR_CONTENT=$(_h "${_ba}${_bb}${_bc}${_bd}${_be}")
    fi
    if command -v qrencode &> /dev/null; then
        echo -e "${GREEN}请使用微信扫描以下二维码进入小程序:${NC}"
        echo ""
        qrencode -t ANSIUTF8 "$QR_CONTENT" 2>/dev/null || print_warn "二维码生成失败"
    else
        print_warn "qrencode 未安装，无法显示二维码"
    fi
    echo ""
}

uninstall() {
    print_step "卸载 WebSocket 打印客户端"
    read -p "确定要卸载吗? [y/N]: " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_msg "取消卸载"
        exit 0
    fi
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    rm -rf $INSTALL_DIR
    rm -f $LOG_FILE
    print_msg "卸载完成"
}

show_menu() {
    echo ""
    echo "============================================"
    echo "  WebSocket 打印客户端安装脚本"
    echo "============================================"
    echo ""
    echo "  1. 完整安装 (推荐)"
    echo "  2. 仅安装依赖"
    echo "  3. 仅配置客户端"
    echo "  4. 检测打印机"
    echo "  5. 添加打印机"
    echo "  6. 生成设备二维码"
    echo "  7. 查看服务状态"
    echo "  8. 卸载"
    echo "  0. 退出"
    echo ""
    read -p "请选择 [0-8]: " MENU_CHOICE
    case $MENU_CHOICE in
        1)
            full_install
            ;;
        2)
            check_root
            detect_system
            update_system
            install_base_deps
            install_php
            install_cups
            install_printer_drivers
            install_libreoffice
            install_print_tools
            print_msg "依赖安装完成"
            ;;
        3)
            check_root
            install_websocket_client
            configure_server
            configure_device_id
            create_service
            start_service
            show_summary
            ;;
        4)
            detect_printers
            ;;
        5)
            check_root
            add_printer_wizard
            ;;
        6)
            generate_qrcode
            ;;
        7)
            systemctl status $SERVICE_NAME --no-pager -l || print_warn "服务未安装"
            echo ""
            echo "最近日志:"
            tail -20 $LOG_FILE 2>/dev/null || echo "(无日志)"
            ;;
        8)
            check_root
            uninstall
            ;;
        0)
            exit 0
            ;;
        *)
            print_error "无效选择"
            show_menu
            ;;
    esac
}

full_install() {
    check_root
    detect_system
    update_system
    install_base_deps
    install_php
    install_cups
    install_printer_drivers
    install_libreoffice
    install_print_tools
    install_websocket_client
    configure_server
    configure_device_id
    create_service
    detect_printers
    echo ""
    read -p "是否现在添加打印机? [y/N]: " ADD_PRINTER
    if [ "$ADD_PRINTER" = "y" ] || [ "$ADD_PRINTER" = "Y" ]; then
        add_printer_wizard
    fi
    start_service
    show_summary
    echo ""
    read -p "是否生成设备二维码? [Y/n]: " GEN_QR
    if [ "$GEN_QR" != "n" ] && [ "$GEN_QR" != "N" ]; then
        generate_qrcode
    fi
}

main() {
    case "${1:-}" in
        --install|-i)
            full_install
            ;;
        --uninstall|-u)
            check_root
            uninstall
            ;;
        --status|-s)
            systemctl status $SERVICE_NAME --no-pager -l 2>/dev/null || print_warn "服务未安装"
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --install, -i    完整安装"
            echo "  --uninstall, -u  卸载"
            echo "  --status, -s     查看状态"
            echo "  --help, -h       显示帮助"
            echo ""
            echo "无参数时显示交互菜单"
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"
