#!/bin/bash
# ============================================
#      打印客户端一键安装配置脚本
# 适用于: Debian/Ubuntu/Armbian 系统
# 功能: 检查环境、安装依赖、配置打印服务
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置变量
INSTALL_DIR="/opt/websocket_printer"
SERVICE_NAME="websocket-printer"
LOG_FILE="/var/log/websocket_printer.log"
DEFAULT_SERVER="ws://xinprint.zyshare.top:8089"  

# 远程文件地址
REMOTE_BASE_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main/configs"
REMOTE_FILES=(
    "printer_client.php"
    "printer-client.service"
    "generate_qrcode.sh"
)

# 打印带颜色的消息
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

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        print_msg "使用: sudo bash install.sh"
        exit 1
    fi
}

# 检测系统类型
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
    
    # 检测架构
    ARCH=$(uname -m)
    print_msg "架构: $ARCH"
    
    # 检测内存
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    print_msg "内存: ${TOTAL_MEM}MB"
    
    if [ "$TOTAL_MEM" -lt 256 ]; then
        print_warn "内存较小，可能影响 LibreOffice 转换性能"
    fi
}

# 更新系统包
update_system() {
    print_step "更新系统包列表"
    apt-get update -y
    print_msg "系统包列表已更新"
}

# 安装基础依赖
install_base_deps() {
    print_step "安装基础依赖"
    
    PACKAGES="curl wget git unzip"
    
    for pkg in $PACKAGES; do
        if ! command -v $pkg &> /dev/null; then
            print_msg "安装 $pkg..."
            apt-get install -y $pkg
        else
            print_msg "$pkg 已安装"
        fi
    done
}

# 安装PHP及扩展
install_php() {
    print_step "检查 PHP 环境"
    
    REQUIRED_EXTS="curl mbstring json sockets"
    NEED_INSTALL=false
    MISSING_EXTS=""
    
    # 检查PHP是否已安装
    if command -v php &> /dev/null; then
        PHP_VERSION=$(php -v | head -n 1 | cut -d ' ' -f 2 | cut -d '.' -f 1,2)
        print_msg "PHP 已安装: $PHP_VERSION"
        
        # 检查扩展是否完整
        for ext in $REQUIRED_EXTS; do
            if ! php -m | grep -qi "^$ext$"; then
                MISSING_EXTS="$MISSING_EXTS $ext"
                NEED_INSTALL=true
            fi
        done
        
        if [ "$NEED_INSTALL" = false ]; then
            print_msg "所有必要扩展已安装，跳过"
            # 显示已安装的扩展
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
    
    # 安装PHP和扩展
    if [ "$NEED_INSTALL" = true ]; then
        if ! command -v php &> /dev/null; then
            print_msg "安装 PHP..."
            apt-get install -y php php-cli 2>/dev/null || apt-get install -y php7.4 php7.4-cli 2>/dev/null
        fi
        
        # 安装缺少的扩展
        print_msg "安装 PHP 扩展..."
        for ext in $REQUIRED_EXTS; do
            if ! php -m | grep -qi "^$ext$"; then
                print_msg "  安装 php-$ext..."
                apt-get install -y php-$ext 2>/dev/null || apt-get install -y php7.4-$ext 2>/dev/null || true
            fi
        done
    fi
    
    # 最终验证
    print_msg "验证 PHP 扩展..."
    for ext in $REQUIRED_EXTS; do
        if php -m | grep -qi "^$ext$"; then
            print_msg "  ✓ $ext"
        else
            print_warn "  ✗ $ext (安装失败，可能影响功能)"
        fi
    done
}

# 安装CUPS打印系统
install_cups() {
    print_step "安装 CUPS 打印系统"
    
    if command -v lpstat &> /dev/null; then
        print_msg "CUPS 已安装"
    else
        print_msg "安装 CUPS..."
        apt-get install -y cups cups-client cups-bsd
    fi
    
    # 启动CUPS服务
    print_msg "启动 CUPS 服务..."
    systemctl enable cups
    systemctl start cups
    
    # 配置CUPS允许远程管理（可选）
    if [ -f /etc/cups/cupsd.conf ]; then
        # 备份配置
        cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
        
        # 允许本地网络访问
        if ! grep -q "Allow @LOCAL" /etc/cups/cupsd.conf; then
            print_msg "配置 CUPS 允许本地网络访问..."
            sed -i 's/Listen localhost:631/Listen 0.0.0.0:631/' /etc/cups/cupsd.conf
            sed -i '/<Location \/>/,/<\/Location>/s/Order allow,deny/Order allow,deny\n  Allow @LOCAL/' /etc/cups/cupsd.conf
            systemctl restart cups
        fi
    fi
    
    print_msg "CUPS 状态: $(systemctl is-active cups)"
}

# 安装打印机驱动
install_printer_drivers() {
    print_step "安装打印机驱动"
    
    print_msg "安装通用打印机驱动..."
    apt-get install -y printer-driver-all 2>/dev/null || apt-get install -y printer-driver-gutenprint
    
    # 安装常见品牌驱动
    print_msg "安装品牌驱动..."
    
    # HP打印机
    apt-get install -y hplip 2>/dev/null || print_warn "HP驱动安装跳过"
    
    # 三星/施乐打印机 (使用splix)
    apt-get install -y printer-driver-splix 2>/dev/null || print_warn "Samsung/Xerox驱动安装跳过"
    
    # Brother打印机
    apt-get install -y printer-driver-brlaser 2>/dev/null || print_warn "Brother驱动安装跳过"
    
    # Epson打印机
    apt-get install -y printer-driver-escpr 2>/dev/null || print_warn "Epson驱动安装跳过"
    
    # Canon打印机
    apt-get install -y printer-driver-cnijfilter2 2>/dev/null || print_warn "Canon驱动安装跳过"
    
    # PostScript/PDF支持
    apt-get install -y printer-driver-cups-pdf 2>/dev/null || true
    
    print_msg "打印机驱动安装完成"
}

# 安装LibreOffice（用于文档转换）
install_libreoffice() {
    print_step "安装 LibreOffice (文档转换)"
    
    if command -v libreoffice &> /dev/null; then
        LO_VERSION=$(libreoffice --version | head -n 1)
        print_msg "LibreOffice 已安装: $LO_VERSION"
    else
        print_msg "安装 LibreOffice (这可能需要几分钟)..."
        
        # 根据内存大小选择安装方式
        if [ "$TOTAL_MEM" -lt 512 ]; then
            print_warn "内存较小，安装精简版..."
            apt-get install -y libreoffice-writer-nogui libreoffice-calc-nogui 2>/dev/null || \
            apt-get install -y libreoffice-writer libreoffice-calc
        else
            apt-get install -y libreoffice-writer libreoffice-calc libreoffice-impress
        fi
    fi
    
    # 创建LibreOffice临时目录
    mkdir -p /tmp/.libreoffice
    chmod 777 /tmp/.libreoffice
}

# 下载远程文件
download_files() {
    print_step "下载客户端文件"
    
    # 创建安装目录
    mkdir -p $INSTALL_DIR
    
    for file in "${REMOTE_FILES[@]}"; do
        print_msg "下载 $file..."
        if curl -sSL -o "$INSTALL_DIR/$file" "$REMOTE_BASE_URL/$file"; then
            print_msg "  ✓ $file 下载成功"
        else
            # 尝试从本地复制
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$SCRIPT_DIR/$file" ]; then
                cp "$SCRIPT_DIR/$file" "$INSTALL_DIR/"
                print_msg "  ✓ $file 从本地复制"
            else
                print_warn "  ✗ $file 下载失败"
            fi
        fi
    done
    
    # 验证必要文件
    if [ ! -f "$INSTALL_DIR/printer_client.php" ]; then
        print_error "printer_client.php 下载失败"
        exit 1
    fi
    
    # 设置权限
    chmod +x "$INSTALL_DIR/printer_client.php"
    chmod +x "$INSTALL_DIR/generate_qrcode.sh" 2>/dev/null || true
    
    # 创建日志文件
    touch $LOG_FILE
    chmod 666 $LOG_FILE
    
    print_msg "文件下载完成"
}

# 安装WebSocket客户端（兼容旧函数名）
install_websocket_client() {
    download_files
}

# 配置服务器地址
configure_server() {
    print_step "配置服务器连接"
    
    # 读取当前配置（从$WS_SERVER变量）
    CURRENT_SERVER=$(grep -oP "\\\$WS_SERVER = '\K[^']+" "$INSTALL_DIR/printer_client.php" 2>/dev/null || echo "")
    
    # 如果已有有效配置，跳过
    if [ -n "$CURRENT_SERVER" ] && [ "$CURRENT_SERVER" != "ws://your-server:8089" ]; then
        print_msg "服务器地址已配置: $CURRENT_SERVER"
        print_msg "如需修改，请编辑: $INSTALL_DIR/printer_client.php"
        return
    fi
    
    # 使用默认服务器地址
    print_msg "使用默认服务器: $DEFAULT_SERVER"
}

# 配置设备ID
configure_device_id() {
    print_step "配置设备ID"
    
    # 读取当前配置
    CURRENT_ID=$(grep -oP "private \\\$deviceId = '\K[^']+" "$INSTALL_DIR/printer_client.php" 2>/dev/null || echo "")
    
    # 自动生成设备ID（基于机器ID，保证唯一且重装后不变）
    if [ -f /etc/machine-id ]; then
        MACHINE_HASH=$(cat /etc/machine-id | md5sum | cut -c1-8)
    else
        MACHINE_HASH=$(hostname | md5sum | cut -c1-8)
    fi
    AUTO_ID="printer_${MACHINE_HASH}"
    
    # 如果已有有效ID，保持不变
    if [ -n "$CURRENT_ID" ] && [ "$CURRENT_ID" != "your_device_id" ] && [ "$CURRENT_ID" != "" ]; then
        print_msg "保持现有设备ID: $CURRENT_ID"
        return
    fi
    
    # 使用自动生成的ID
    DEVICE_ID=$AUTO_ID
    
    # 更新配置文件
    sed -i "s|private \$deviceId = '.*'|private \$deviceId = '$DEVICE_ID'|" "$INSTALL_DIR/printer_client.php"
    print_msg "设备ID已自动生成: $DEVICE_ID"
    print_msg "（基于机器唯一标识，重装系统后保持不变）"
}

# 创建systemd服务
create_service() {
    print_step "创建系统服务"
    
    # 如果下载了service文件，使用它
    if [ -f "$INSTALL_DIR/printer-client.service" ]; then
        print_msg "使用下载的服务配置文件"
        # 更新路径
        sed -i "s|/opt/printer-client|$INSTALL_DIR|g" "$INSTALL_DIR/printer-client.service"
        cp "$INSTALL_DIR/printer-client.service" /etc/systemd/system/${SERVICE_NAME}.service
    else
        # 否则创建默认配置
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

# 环境变量
Environment=HOME=/tmp
Environment=SHELL=/bin/bash

[Install]
WantedBy=multi-user.target
EOF
    fi

    # 重载systemd
    systemctl daemon-reload
    
    # 启用服务
    systemctl enable $SERVICE_NAME
    
    print_msg "服务已创建: $SERVICE_NAME"
}

# 检测已连接的打印机
detect_printers() {
    print_step "检测打印机"
    
    print_msg "已配置的打印机:"
    echo ""
    lpstat -a 2>/dev/null || echo "  (无)"
    echo ""
    
    print_msg "默认打印机:"
    lpstat -d 2>/dev/null || echo "  (未设置)"
    echo ""
    
    # 检测USB打印机
    print_msg "USB 设备:"
    lsusb 2>/dev/null | grep -i "print\|samsung\|hp\|canon\|epson\|brother" || echo "  (未检测到打印机USB设备)"
    echo ""
}

# 添加打印机向导
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
            # USB打印机
            print_msg "检测 USB 打印机..."
            lpinfo -v 2>/dev/null | grep usb || echo "未检测到USB打印机"
            echo ""
            read -p "请输入打印机URI (如 usb://...): " PRINTER_URI
            read -p "请输入打印机名称: " PRINTER_NAME
            
            if [ -n "$PRINTER_URI" ] && [ -n "$PRINTER_NAME" ]; then
                # 查找驱动
                print_msg "查找驱动..."
                lpinfo -m | head -20
                echo ""
                read -p "请输入驱动名称 (如 drv:///...): " DRIVER
                
                lpadmin -p "$PRINTER_NAME" -v "$PRINTER_URI" -m "$DRIVER" -E
                print_msg "打印机 $PRINTER_NAME 已添加"
            fi
            ;;
        3)
            # 网络打印机
            read -p "请输入打印机IP地址: " PRINTER_IP
            read -p "请输入打印机名称: " PRINTER_NAME
            read -p "协议 [ipp/lpd/socket] (默认ipp): " PROTOCOL
            PROTOCOL=${PROTOCOL:-ipp}
            
            case $PROTOCOL in
                ipp)
                    PRINTER_URI="ipp://$PRINTER_IP/ipp/print"
                    ;;
                lpd)
                    PRINTER_URI="lpd://$PRINTER_IP/queue"
                    ;;
                socket)
                    PRINTER_URI="socket://$PRINTER_IP:9100"
                    ;;
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

# 生成设备二维码
generate_qrcode() {
    print_step "生成设备二维码"
    
    # 检查是否有generate_qrcode.sh
    if [ -f "$INSTALL_DIR/generate_qrcode.sh" ]; then
        print_msg "使用 generate_qrcode.sh 生成二维码..."
        chmod +x "$INSTALL_DIR/generate_qrcode.sh"
        bash "$INSTALL_DIR/generate_qrcode.sh"
        return
    fi
    
    # 获取设备ID
    DEVICE_ID=$(grep -oP "private \\\$deviceId = '\K[^']+" "$INSTALL_DIR/printer_client.php" 2>/dev/null || echo "")
    
    if [ -z "$DEVICE_ID" ]; then
        print_error "无法获取设备ID"
        return
    fi
    
    QR_CONTENT="device://$DEVICE_ID"
    print_msg "设备ID: $DEVICE_ID"
    print_msg "二维码内容: $QR_CONTENT"
    
    # 检查是否安装了qrencode
    if command -v qrencode &> /dev/null; then
        # 生成二维码图片
        QR_FILE="/tmp/device_qr_$DEVICE_ID.png"
        qrencode -o "$QR_FILE" -s 10 "$QR_CONTENT"
        print_msg "二维码图片已保存: $QR_FILE"
        
        # 在终端显示
        echo ""
        qrencode -t ANSIUTF8 "$QR_CONTENT"
        echo ""
    else
        print_warn "未安装 qrencode，无法生成二维码图片"
        echo ""
        read -p "是否安装 qrencode? [y/N]: " INSTALL_QR
        if [ "$INSTALL_QR" = "y" ] || [ "$INSTALL_QR" = "Y" ]; then
            apt-get install -y qrencode
            generate_qrcode
        else
            print_msg "请手动使用以下内容生成二维码:"
            echo ""
            echo "  $QR_CONTENT"
            echo ""
        fi
    fi
}

# 启动服务
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

# 显示安装摘要
show_summary() {
    print_step "安装完成"
    
    echo ""
    echo "============================================"
    echo "           打印客户端安装完成!"
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
    
    # 显示当前状态
    echo "当前服务状态:"
    systemctl status $SERVICE_NAME --no-pager -l | head -10
}

# 卸载函数
uninstall() {
    print_step "卸载 WebSocket 打印客户端"
    
    read -p "确定要卸载吗? [y/N]: " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_msg "取消卸载"
        exit 0
    fi
    
    # 停止并禁用服务
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true
    
    # 删除服务文件
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    
    # 删除安装目录
    rm -rf $INSTALL_DIR
    
    # 删除日志
    rm -f $LOG_FILE
    
    print_msg "卸载完成"
}

# 主菜单
show_menu() {
    echo ""
    echo "============================================"
    echo "           打印客户端安装脚本"
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

# 完整安装流程
full_install() {
    check_root
    detect_system
    update_system
    install_base_deps
    install_php
    install_cups
    install_printer_drivers
    install_libreoffice
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
    
    # 生成二维码
    echo ""
    read -p "是否生成设备二维码? [Y/n]: " GEN_QR
    if [ "$GEN_QR" != "n" ] && [ "$GEN_QR" != "N" ]; then
        generate_qrcode
    fi
}

# 脚本入口
main() {
    # 检查参数
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
