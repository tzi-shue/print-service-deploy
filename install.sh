#!/bin/bash
# ============================================
# WebSocket 打印客户端一键安装配置脚本
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
    
    PACKAGES="curl wget git unzip qrencode"
    
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
    
    # 配置CUPS（从远程拉取配置文件）
    if [ -f /etc/cups/cupsd.conf ]; then
        # 备份配置
        cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
        
        # 从远程下载cupsd.conf配置文件
        print_msg "从远程下载 CUPS 配置文件..."
        CUPSD_CONF_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main/configs/cupsd.conf"
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

# 配置服务器地址（使用内置配置，无需用户干预）
configure_server() {
    print_msg "服务器配置已内置，无需手动配置"
}

# 获取设备ID（由 printer_client.php 生成，这里只读取显示）
get_device_id() {
    if [ -f /etc/printer-device-id ]; then
        cat /etc/printer-device-id
    else
        echo "待生成"
    fi
}

# 显示设备ID信息
configure_device_id() {
    print_step "设备ID信息"
    
    DEVICE_ID=$(get_device_id)
    if [ "$DEVICE_ID" = "待生成" ]; then
        print_msg "设备ID将在服务首次启动时自动生成"
    else
        print_msg "设备ID: $DEVICE_ID"
    fi
}

# 收集硬件特征（仅收集CPU序列号）
collect_hw_features() {
    print_step "收集硬件特征"
    
    # 创建临时文件存储硬件特征
    HW_FEATURES_FILE=$(mktemp)
    
    # 仅收集CPU序列号
    print_msg "仅收集CPU序列号..."
    
    # CPU序列号
    CPU_SERIAL=$(grep -m 1 "Serial" /proc/cpuinfo 2>/dev/null | cut -d":" -f2 | tr -d '[:space:]')
    if [ -n "$CPU_SERIAL" ] && [ "$CPU_SERIAL" != "0000000000000000" ]; then
        echo "cpu:$CPU_SERIAL" > "$HW_FEATURES_FILE"
        print_msg "CPU序列号: $CPU_SERIAL"
    else
        # 如果无法获取CPU序列号，使用随机ID
        RANDOM_ID=$(cat /proc/sys/kernel/random/uuid)
        echo "random:$RANDOM_ID" > "$HW_FEATURES_FILE"
        print_warn "使用随机设备ID: $RANDOM_ID"
    fi
    
    echo "$HW_FEATURES_FILE"
}

# 创建systemd服务（修改版）
create_service() {
    print_step "创建系统服务"
    
    # 收集硬件特征
    HW_FEATURES_FILE=$(collect_hw_features)
    
    # 创建环境变量文件存储硬件特征
    ENV_FILE="/etc/printer-hw-features.conf"
    echo "$(cat "$HW_FEATURES_FILE")" > "$ENV_FILE"
    
    # 如果下载了service文件，使用它
    if [ -f "$INSTALL_DIR/printer-client.service" ]; then
        print_msg "使用下载的服务配置文件"
        # 更新路径
        sed -i "s|/opt/printer-client|$INSTALL_DIR|g" "$INSTALL_DIR/printer-client.service"
        # 添加环境变量文件
        sed -i "/\[Service\]/a EnvironmentFile=$ENV_FILE" "$INSTALL_DIR/printer-client.service"
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
EnvironmentFile=$ENV_FILE
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

# 启动服务（修改版）
start_service() {
    print_step "启动服务"
    
    # 检查硬件特征文件是否存在
    ENV_FILE="/etc/printer-hw-features.conf"
    if [ ! -f "$ENV_FILE" ]; then
        # 如果不存在，重新收集
        collect_hw_features > "$ENV_FILE"
    fi
    
    # 启动服务
    systemctl start $SERVICE_NAME
    sleep 2
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_msg "服务启动成功!"
    else
        print_error "服务启动失败，查看日志:"
        tail -20 $LOG_FILE
    fi
}

# 检测已连接的打印机
detect_printers() {
    print_step "检测打印机"
    
    # 显示菜单选项
    echo ""
    echo "请选择操作:"
    echo "  1. 检测打印机"
    echo "  2. 添加打印机"
    echo "  0. 跳过打印机设置"
    echo ""
    read -p "请选择 [0-2]: " CHOICE
    
    case $CHOICE in
        1)
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
            ;;
        2)
            # 添加打印机向导
            print_step "添加打印机"
            
            echo ""
            echo "添加打印机方式:"
            echo "  1. 通过 CUPS Web 界面 (推荐)"
            echo "  2. 命令行添加 USB 打印机"
            echo "  3. 命令行添加网络打印机"
            echo "  0. 返回上一级"
            echo ""
            read -p "请选择 [0-3]: " SUB_CHOICE
            
            case $SUB_CHOICE in
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
                0)
                    print_msg "返回上一级"
                    ;;
                *)
                    print_error "无效的选择"
                    ;;
            esac
            ;;
        0)
            print_msg "跳过打印机设置"
            ;;
        *)
            print_error "无效的选择"
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
    
    # 获取设备ID（使用与printer_client.php一致的逻辑）
    DEVICE_ID=$(get_device_id)
    
    if [ -z "$DEVICE_ID" ]; then
        print_error "无法获取设备ID"
        return
    fi
    
    QR_CONTENT="device://$DEVICE_ID"
    print_msg "设备ID: $DEVICE_ID"
    print_msg "二维码内容: $QR_CONTENT"
    
    # 检查是否安装了qrencode，没有则自动安装
    if ! command -v qrencode &> /dev/null; then
        print_msg "安装 qrencode..."
        apt-get install -y qrencode >/dev/null 2>&1
    fi
    
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
        print_warn "qrencode 安装失败，请手动使用以下内容生成二维码:"
        echo ""
        echo "  $QR_CONTENT"
        echo ""
    fi
}

# 主入口
main() {
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
    add_printer_wizard
    generate_qrcode
    start_service
}

main
