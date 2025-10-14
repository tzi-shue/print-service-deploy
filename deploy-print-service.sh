#!/bin/bash

# 小程序打印服务自动部署脚本
# GitHub: https://github.com/your-username/print-service-deploy

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用root权限运行此脚本: sudo bash $0"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        log "检测到操作系统: $OS $OS_VERSION"
    else
        error "无法检测操作系统类型"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    log "开始安装系统依赖..."
    
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        apt update
        apt install -y cups cups-filters ghostscript libreoffice-core libreoffice-writer libreoffice-calc \
                      php php-cli apache2 nginx curl wget
    elif [ "$OS" == "centos" ] || [ "$OS" == "rhel" ] || [ "$OS" == "fedora" ]; then
        if command -v dnf &> /dev/null; then
            dnf install -y cups cups-filters ghostscript libreoffice-core libreoffice-writer libreoffice-calc \
                          php php-cli httpd nginx curl wget
        else
            yum install -y cups cups-filters ghostscript libreoffice-core libreoffice-writer libreoffice-calc \
                          php php-cli httpd nginx curl wget
        fi
    else
        error "不支持的操作系统: $OS"
        exit 1
    fi
    
    log "系统依赖安装完成"
}

# 备份原有文件
backup_file() {
    local file_path=$1
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$file_path" "$backup_path"
        log "已备份 $file_path 到 $backup_path"
    fi
}

# 下载配置文件
download_configs() {
    log "下载配置文件..."
    
    # 创建临时目录
    local temp_dir="/tmp/print-service-$(date +%s)"
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # 从GitHub下载文件
    local repo_url="https://raw.githubusercontent.com/your-username/print-service-deploy/main"
    
    log "下载CUPS配置文件..."
    curl -fsSL -o cupsd.conf "$repo_url/configs/cupsd.conf"
    
    log "下载PHP打印接口文件..."
    curl -fsSL -o print.php "$repo_url/configs/print.php"
    
    log "下载Web服务器配置..."
    curl -fsSL -o print-service.conf "$repo_url/configs/print-service.conf"
    
    echo "$temp_dir"
}

# 替换CUPS配置文件
setup_cups() {
    local temp_dir=$1
    local cups_conf_source="$temp_dir/cupsd.conf"
    local cups_conf_target="/etc/cups/cupsd.conf"
    
    log "配置CUPS打印服务..."
    
    # 备份原配置文件
    backup_file "$cups_conf_target"
    
    # 复制新配置文件
    cp "$cups_conf_source" "$cups_conf_target"
    chown root:lp "$cups_conf_target"
    chmod 640 "$cups_conf_target"
    
    log "CUPS配置文件设置完成"
}

# 部署PHP文件
setup_php() {
    local temp_dir=$1
    local php_file_source="$temp_dir/print.php"
    
    log "部署PHP打印接口..."
    
    # 检测并选择Web服务器
    local web_root=""
    local web_service=""
    
    if [ -d "/var/www/html" ]; then
        web_root="/var/www/html"
        if systemctl is-active --quiet apache2; then
            web_service="apache2"
        elif systemctl is-active --quiet httpd; then
            web_service="httpd"
        fi
    elif [ -d "/usr/share/nginx/html" ]; then
        web_root="/usr/share/nginx/html"
        web_service="nginx"
    else
        # 创建Web根目录
        web_root="/var/www/html"
        mkdir -p "$web_root"
        web_service="apache2"
    fi
    
    local php_target="${web_root}/print.php"
    
    # 备份原文件（如果存在）
    backup_file "$php_target"
    
    # 复制PHP文件
    cp "$php_file_source" "$php_target"
    
    # 设置权限
    if [ "$web_service" == "nginx" ]; then
        chown nginx:nginx "$php_target" 2>/dev/null || true
    else
        chown www-data:www-data "$php_target" 2>/dev/null || chown apache:apache "$php_target" 2>/dev/null || true
    fi
    chmod 644 "$php_target"
    
    # 配置Web服务器
    if [ "$web_service" == "nginx" ]; then
        setup_nginx "$temp_dir"
    else
        setup_apache "$temp_dir"
    fi
    
    log "PHP接口部署完成: $php_target"
    echo "$web_service"
}

# 配置Apache
setup_apache() {
    local temp_dir=$1
    
    log "配置Apache服务器..."
    
    # 启用必要的模块
    a2enmod php* 2>/dev/null || true
    a2enmod rewrite 2>/dev/null || true
    
    # 确保Apache监听正确端口
    if ! grep -q "Listen 80" /etc/apache2/ports.conf 2>/dev/null && ! grep -q "Listen 80" /etc/httpd/conf/httpd.conf 2>/dev/null; then
        echo "Listen 80" >> /etc/apache2/ports.conf 2>/dev/null || echo "Listen 80" >> /etc/httpd/conf/httpd.conf 2>/dev/null
    fi
}

# 配置Nginx
setup_nginx() {
    local temp_dir=$1
    local nginx_conf="$temp_dir/print-service.conf"
    
    log "配置Nginx服务器..."
    
    # 复制Nginx配置
    if [ -d "/etc/nginx/conf.d" ]; then
        cp "$nginx_conf" "/etc/nginx/conf.d/print-service.conf"
    elif [ -d "/etc/nginx/sites-available" ]; then
        cp "$nginx_conf" "/etc/nginx/sites-available/print-service"
        ln -sf "/etc/nginx/sites-available/print-service" "/etc/nginx/sites-enabled/" 2>/dev/null || true
    fi
}

# 重启服务
restart_services() {
    local web_service=$1
    
    log "重启系统服务..."
    
    # 重启CUPS服务
    systemctl enable cups
    systemctl restart cups
    log "CUPS服务已重启"
    
    # 重启Web服务
    if [ "$web_service" == "nginx" ]; then
        systemctl enable nginx
        systemctl restart nginx
        log "Nginx服务已重启"
    else
        if systemctl is-active --quiet apache2; then
            systemctl enable apache2
            systemctl restart apache2
            log "Apache服务已重启"
        elif systemctl is-active --quiet httpd; then
            systemctl enable httpd
            systemctl restart httpd
            log "HTTPD服务已重启"
        else
            # 启动Apache作为默认Web服务器
            if command -v apache2 &> /dev/null; then
                systemctl enable apache2
                systemctl start apache2
                log "Apache服务已启动"
            elif command -v httpd &> /dev/null; then
                systemctl enable httpd
                systemctl start httpd
                log "HTTPD服务已启动"
            else
                warn "未找到可用的Web服务器"
            fi
        fi
    fi
}

# 检查服务状态
check_services() {
    log "检查服务状态..."
    
    echo "=== CUPS服务状态 ==="
    systemctl status cups --no-pager -l | head -10
    
    echo -e "\n=== Web服务状态 ==="
    if systemctl is-active --quiet apache2; then
        systemctl status apache2 --no-pager -l | head -10
    elif systemctl is-active --quiet httpd; then
        systemctl status httpd --no-pager -l | head -10
    elif systemctl is-active --quiet nginx; then
        systemctl status nginx --no-pager -l | head -10
    fi
    
    echo -e "\n=== 网络监听状态 ==="
    netstat -tlnp | grep -E ':631|:80|:443'
}

# 显示部署结果
show_result() {
    local web_service=$1
    
    log "=== 部署完成！ ==="
    echo ""
    info "重要信息:"
    echo "  ✅ CUPS打印服务已配置完成"
    echo "  ✅ PHP打印接口已部署"
    echo "  ✅ Web服务器 ($web_service) 已配置"
    echo ""
    info "下一步操作:"
    echo "  1. 访问 CUPS 管理界面: http://localhost:631"
    echo "  2. 添加并设置默认打印机"
    echo "  3. 测试打印接口: curl http://localhost/print.php"
    echo "  4. 在小程序中配置打印地址: http://你的服务器IP/print.php"
    echo ""
    warn "注意事项:"
    echo "  • 确保防火墙开放80和631端口"
    echo "  • 如需外网访问，请配置内网穿透"
    echo "  • 定期检查服务状态: systemctl status cups"
    echo ""
    info "故障排除:"
    echo "  • 查看CUPS日志: tail -f /var/log/cups/error_log"
    echo "  • 查看Web日志: tail -f /var/log/{apache2,nginx,httpd}/error.log"
    echo "  • 重新启动服务: systemctl restart cups $web_service"
}

# 清理临时文件
cleanup() {
    local temp_dir=$1
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
        log "临时文件已清理"
    fi
}

# 主部署函数
main() {
    log "开始部署小程序打印服务..."
    
    # 初始检查
    check_root
    detect_os
    
    # 安装依赖
    install_dependencies
    
    # 下载配置
    local temp_dir=$(download_configs)
    
    # 设置服务
    setup_cups "$temp_dir"
    local web_service=$(setup_php "$temp_dir")
    
    # 重启服务
    restart_services "$web_service"
    
    # 检查状态
    sleep 3
    check_services
    
    # 显示结果
    show_result "$web_service"
    
    # 清理
    cleanup "$temp_dir"
    
    log "部署脚本执行完毕！"
}

# 显示横幅
show_banner() {
    echo -e "${CYAN}"
    echo "=================================================="
    echo "          小程序打印服务自动部署脚本"
    echo "           GitHub: print-service-deploy"
    echo "=================================================="
    echo -e "${NC}"
}

# 脚本入口
show_banner
main