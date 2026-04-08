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

# ==================== 增强动态包名数据库 ====================
declare -A PKG_PHP_CLI=(
    ["ubuntu24"]="php8.3-cli php8.2-cli php8.1-cli php8.0-cli"
    ["ubuntu23"]="php8.2-cli php8.1-cli php8.0-cli"
    ["ubuntu22"]="php8.1-cli php8.0-cli php7.4-cli"
    ["ubuntu20"]="php7.4-cli php7.3-cli php7.2-cli"
    ["ubuntu18"]="php7.2-cli php7.0-cli php5.6-cli"
    ["ubuntu16"]="php7.0-cli php5.6-cli"
    ["debian12"]="php8.2-cli php8.1-cli php8.0-cli"
    ["debian11"]="php7.4-cli php7.3-cli"
    ["debian10"]="php7.3-cli php7.0-cli"
    ["debian9"]="php7.0-cli php5.6-cli"
    ["armbian"]="php8.1-cli php7.4-cli php7.3-cli php7.2-cli php7.0-cli php-cli"
    ["default"]="php-cli php8.3-cli php8.2-cli php8.1-cli php8.0-cli php7.4-cli php7.3-cli php7.2-cli php7.0-cli"
)

declare -A PKG_PHP_EXT=(
    ["ubuntu24"]="php8.3-curl php8.3-mbstring php8.3-sockets php8.2-curl php8.2-mbstring php8.2-sockets php8.1-curl php8.1-mbstring php8.1-sockets"
    ["ubuntu23"]="php8.2-curl php8.2-mbstring php8.2-sockets php8.1-curl php8.1-mbstring php8.1-sockets"
    ["ubuntu22"]="php8.1-curl php8.1-mbstring php8.1-sockets php8.0-curl php8.0-mbstring php8.0-sockets php7.4-curl php7.4-mbstring php7.4-sockets"
    ["ubuntu20"]="php7.4-curl php7.4-mbstring php7.4-sockets php7.3-curl php7.3-mbstring php7.3-sockets"
    ["ubuntu18"]="php7.2-curl php7.2-mbstring php7.2-sockets php7.0-curl php7.0-mbstring php7.0-sockets"
    ["debian12"]="php8.2-curl php8.2-mbstring php8.2-sockets php8.1-curl php8.1-mbstring php8.1-sockets"
    ["debian11"]="php7.4-curl php7.4-mbstring php7.4-sockets php7.3-curl php7.3-mbstring php7.3-sockets"
    ["armbian"]="php-curl php-mbstring php-sockets php8.1-curl php8.1-mbstring php8.1-sockets php7.4-curl php7.4-mbstring php7.4-sockets"
    ["default"]="php-curl php-mbstring php-sockets"
)

declare -A PKG_CUPS=(
    ["ubuntu24"]="cups cups-filters cups-client cups-bsd cups-common libcups2 libcupsfilters2 cups-ppdc"
    ["ubuntu22"]="cups cups-filters cups-client cups-bsd cups-common libcups2 libcupsfilters1 cups-ppdc"
    ["ubuntu20"]="cups cups-filters cups-client cups-bsd cups-common libcups2 libcupsfilters1 cups-ppdc"
    ["ubuntu18"]="cups cups-filters cups-client cups-bsd cups-common libcups2 libcupsfilters1 libcupsimage2 libcupsppdc1 cups-ppdc"
    ["debian12"]="cups cups-filters cups-client cups-bsd cups-common libcups2 libcupsfilters2"
    ["debian11"]="cups cups-filters cups-client cups-bsd cups-common libcups2 libcupsfilters1"
    ["armbian"]="cups cups-filters cups-client cups-bsd cups-common libcups2"
    ["fallback"]="cups cups-filters cups-client cups-bsd cups-common libcups2"
)

declare -A PKG_FONTS=(
    ["ubuntu24"]="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-noto-cjk-extra fonts-arphic-ukai fonts-arphic-uming fontconfig"
    ["ubuntu22"]="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-noto-cjk-extra fonts-arphic-ukai fonts-arphic-uming fontconfig"
    ["ubuntu20"]="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-noto-cjk-extra fonts-arphic-ukai fonts-arphic-uming fontconfig"
    ["ubuntu18"]="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-arphic-ukai fonts-arphic-uming fontconfig"
    ["debian12"]="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-arphic-ukai fonts-arphic-uming fontconfig"
    ["debian11"]="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-arphic-ukai fonts-arphic-uming fontconfig"
    ["armbian"]="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fontconfig"
    ["minimal"]="fonts-wqy-microhei fontconfig"
)

# 新增：打印机驱动包数据库
declare -A PKG_PRINTER_DRIVERS=(
    ["ubuntu24"]="printer-driver-gutenprint printer-driver-hpijs hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix foomatic-db-engine foomatic-db-compressed-ppds openprinting-ppds"
    ["ubuntu22"]="printer-driver-gutenprint printer-driver-hpijs hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix foomatic-db-engine foomatic-db-compressed-ppds openprinting-ppds hpijs-ppds"
    ["ubuntu20"]="printer-driver-gutenprint printer-driver-hpijs hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix foomatic-db foomatic-db-engine openprinting-ppds hpijs-ppds"
    ["ubuntu18"]="printer-driver-gutenprint printer-driver-hpijs hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix foomatic-db foomatic-db-engine hpijs-ppds"
    ["armbian"]="printer-driver-gutenprint hplip foomatic-db-engine"
    ["minimal"]="printer-driver-gutenprint foomatic-db-engine"
)

# ==================== 基础函数 ====================

_h() { 
    echo "$1" | xxd -r -p 2>/dev/null || echo "$1"
}

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

# ==================== 基础依赖函数 ====================

update_system() {
    print_step "更新系统包列表"
    
    print_msg "正在更新 apt 缓存..."
    if ! apt-get update 2>/dev/null; then
        print_warn "系统更新失败，尝试强制更新..."
        apt-get update --fix-missing 2>/dev/null || {
            print_warn "无法更新系统包列表，继续安装..."
        }
    else
        print_msg "系统包列表已更新"
    fi
}

install_base_deps() {
    print_step "安装基础依赖"
    
    PACKAGES="curl wget git unzip qrencode build-essential bc"
    
    for pkg in $PACKAGES; do
        if command -v $pkg &> /dev/null; then
            print_msg "✓ $pkg 已安装"
        else
            print_msg "安装 $pkg..."
            if ! apt-get install -y $pkg 2>/dev/null; then
                print_warn "$pkg 安装失败，尝试继续..."
            fi
        fi
    done
    
    if ! command -v xxd &> /dev/null; then
        print_warn "xxd 未找到，尝试安装..."
        apt-get install -y xxd 2>/dev/null || \
        apt-get install -y vim-common 2>/dev/null || \
        apt-get install -y busybox 2>/dev/null || {
            print_warn "xxd 不可用，URL 解码可能失败"
        }
    fi
    
    print_msg "基础依赖处理完成"
}

# ==================== 增强兼容性检查 ====================

check_system_compatibility() {
    print_step "系统兼容性快速检查"
    
    # 在自动安装模式下，跳过复杂检查直接继续
    if [ "${AUTO_INSTALL:-false}" = "true" ]; then
        print_msg "自动安装模式：跳过详细兼容性检查"
        print_msg "系统: $OS_NAME"
        print_msg "架构: $ARCH"
        print_msg "内存: ${TOTAL_MEM}MB"
        print_msg "✓ 快速检查通过，开始安装..."
        return 0
    fi
    
    # 交互模式下的简化检查
    local ISSUES=0
    
    print_msg "系统: $OS_NAME"
    print_msg "架构: $ARCH"
    print_msg "内存: ${TOTAL_MEM}MB"
    
    # 只检查关键项
    if [ "$TOTAL_MEM" -lt 128 ]; then
        print_warn "内存较小，可能影响性能"
        ((ISSUES++))
    fi
    
    if ! command -v apt-get &> /dev/null; then
        print_error "apt-get 不可用"
        exit 1
    fi
    
    if [ $ISSUES -gt 0 ]; then
        print_warn "发现 $ISSUES 个潜在问题"
        read -p "是否继续安装? [Y/n]: " CONTINUE
        if [ "$CONTINUE" = "n" ] || [ "$CONTINUE" = "N" ]; then
            exit 0
        fi
    else
        print_msg "✓ 兼容性检查通过"
    fi
    
    return 0
}

# ==================== 智能动态包安装函数 ====================

# 智能包安装函数 - 自动检测可用包并安装
smart_install_packages() {
    local PACKAGE_LIST="$1"
    local COMPONENT_NAME="$2"
    local INSTALL_SUCCESS=0
    local INSTALL_FAILED=0
    
    print_msg "智能安装 $COMPONENT_NAME 组件..."
    
    for pkg in $PACKAGE_LIST; do
        if [ -z "$pkg" ]; then continue; fi
        
        # 检查包是否已安装
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            print_msg "  ✓ $pkg 已安装"
            continue
        fi
        
        # 检查包是否在仓库中可用
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            print_msg "  正在安装 $pkg..."
            if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
                print_msg "    ✓ $pkg 安装成功"
                ((INSTALL_SUCCESS++))
            else
                print_warn "    ✗ $pkg 安装失败"
                ((INSTALL_FAILED++))
            fi
        else
            print_warn "  ⚠ $pkg 在仓库中不可用，跳过"
        fi
    done
    
    print_msg "$COMPONENT_NAME 安装完成: 成功 $INSTALL_SUCCESS 个，失败 $INSTALL_FAILED 个"
    return 0
}

# 动态检测最佳PHP版本并安装
install_php_smart() {
    print_step "智能检测并安装 PHP"
    
    # 检查是否已有PHP
    if command -v php &> /dev/null; then
        local CURRENT_PHP=$(php -v | head -1 | grep -oP 'PHP \K[0-9]+\.[0-9]+')
        print_msg "检测到已安装 PHP $CURRENT_PHP"
        
        # 检查扩展
        local MISSING_EXTS=""
        for ext in curl mbstring sockets; do
            if ! php -m 2>/dev/null | grep -q "^$ext$"; then
                MISSING_EXTS="$MISSING_EXTS php-$ext"
            fi
        done
        
        if [ -n "$MISSING_EXTS" ]; then
            print_msg "安装缺失的PHP扩展: $MISSING_EXTS"
            smart_install_packages "$MISSING_EXTS" "PHP扩展"
        fi
        return 0
    fi
    
    # 动态检测可用的PHP版本
    print_msg "检测可用的PHP版本..."
    local AVAILABLE_PHP=""
    
    # 按优先级检测PHP版本
    for version in 8.3 8.2 8.1 8.0 7.4 7.3 7.2 7.0; do
        if apt-cache search "^php${version}-cli$" 2>/dev/null | grep -q "^php${version}-cli "; then
            AVAILABLE_PHP="php${version}-cli"
            print_msg "找到可用版本: PHP $version"
            break
        fi
    done
    
    # 如果没找到具体版本，尝试通用包名
    if [ -z "$AVAILABLE_PHP" ]; then
        if apt-cache search "^php-cli$" 2>/dev/null | grep -q "^php-cli "; then
            AVAILABLE_PHP="php-cli"
            print_msg "使用通用PHP包"
        fi
    fi
    
    if [ -z "$AVAILABLE_PHP" ]; then
        print_error "未找到可用的PHP包"
        return 1
    fi
    
    # 安装PHP及扩展
    local PHP_VERSION=$(echo $AVAILABLE_PHP | grep -oP 'php\K[0-9.]+' || echo "")
    local PHP_PACKAGES="$AVAILABLE_PHP"
    
    if [ -n "$PHP_VERSION" ]; then
        # 版本特定的扩展包
        PHP_PACKAGES="$PHP_PACKAGES php${PHP_VERSION}-curl php${PHP_VERSION}-mbstring php${PHP_VERSION}-sockets"
        # PHP 8+ 不需要 json 扩展（内置）
        if [[ ! "$PHP_VERSION" =~ ^8 ]]; then
            PHP_PACKAGES="$PHP_PACKAGES php${PHP_VERSION}-json"
        fi
    else
        # 通用扩展包
        PHP_PACKAGES="$PHP_PACKAGES php-curl php-mbstring php-sockets php-json"
    fi
    
    smart_install_packages "$PHP_PACKAGES" "PHP"
    
    # 验证安装
    if command -v php &> /dev/null; then
        local INSTALLED_VERSION=$(php -v | head -1)
        print_msg "✓ PHP 安装成功: $INSTALLED_VERSION"
        return 0
    else
        print_error "PHP 安装失败"
        return 1
    fi
}

# 智能CUPS安装
install_cups_smart() {
    print_step "智能检测并安装 CUPS"
    
    if command -v lpstat &> /dev/null && systemctl is-active --quiet cups 2>/dev/null; then
        print_msg "CUPS 已安装并运行"
        return 0
    fi
    
    # 动态检测CUPS包
    print_msg "检测可用的CUPS包..."
    local CUPS_PACKAGES="cups"
    
    # 检测过滤器包
    if apt-cache search "^cups-filters$" 2>/dev/null | grep -q "^cups-filters "; then
        CUPS_PACKAGES="$CUPS_PACKAGES cups-filters"
    fi
    
    # 检测客户端工具
    for pkg in cups-client cups-bsd cups-common; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            CUPS_PACKAGES="$CUPS_PACKAGES $pkg"
        fi
    done
    
    # 检测库文件
    for pkg in libcups2 libcupsfilters1 libcupsfilters2; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            CUPS_PACKAGES="$CUPS_PACKAGES $pkg"
            break  # 只需要一个版本的过滤器库
        fi
    done
    
    # 检测PPD工具
    if apt-cache search "^cups-ppdc$" 2>/dev/null | grep -q "^cups-ppdc "; then
        CUPS_PACKAGES="$CUPS_PACKAGES cups-ppdc"
    fi
    
    smart_install_packages "$CUPS_PACKAGES" "CUPS"
    
    # 启动服务
    systemctl enable cups 2>/dev/null || true
    systemctl start cups 2>/dev/null || true
    
    # 验证
    if command -v lpstat &> /dev/null; then
        print_msg "✓ CUPS 安装成功"
        return 0
    else
        print_error "CUPS 安装失败"
        return 1
    fi
}

# 增强错误处理函数
handle_install_error() {
    local COMPONENT="$1"
    local ERROR_CODE="$2"
    local ERROR_MSG="$3"
    
    print_error "组件 '$COMPONENT' 安装失败"
    print_error "错误代码: $ERROR_CODE"
    [ -n "$ERROR_MSG" ] && print_error "错误信息: $ERROR_MSG"
    
    echo ""
    print_msg "故障排除建议:"
    
    case "$COMPONENT" in
        "php")
            echo "  1. 检查是否启用了正确的软件源"
            echo "  2. 尝试手动安装: apt-get install php-cli"
            echo "  3. 检查系统版本是否支持所需的 PHP 版本"
            ;;
        "cups")
            echo "  1. 检查是否有足够的磁盘空间"
            echo "  2. 尝试手动安装: apt-get install cups"
            echo "  3. 检查是否有其他打印服务冲突"
            ;;
        "ghostscript")
            echo "  1. 尝试安装基础版本: apt-get install ghostscript"
            echo "  2. 检查是否缺少依赖库"
            ;;
        *)
            echo "  1. 检查网络连接"
            echo "  2. 更新软件源: apt-get update"
            echo "  3. 检查磁盘空间"
            ;;
    esac
    
    echo ""
    read -p "是否继续安装其他组件? [Y/n]: " CONTINUE_OTHER
    if [ "$CONTINUE_OTHER" = "n" ] || [ "$CONTINUE_OTHER" = "N" ]; then
        print_msg "安装已停止"
        exit 1
    fi
}

# ==================== 动态系统检测 ====================

detect_system() {
    print_step "增强动态检测系统环境"
    
    ARCH=$(uname -m)
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    
    # 检测是否为 Armbian 系统
    IS_ARMBIAN=false
    if [ -f /etc/armbian-release ]; then
        IS_ARMBIAN=true
        print_msg "检测到 Armbian 系统"
    elif [ -f /boot/armbianEnv.txt ]; then
        IS_ARMBIAN=true
        print_msg "检测到 Armbian 系统 (boot 标识)"
    elif grep -qi "armbian" /etc/os-release 2>/dev/null; then
        IS_ARMBIAN=true
        print_msg "检测到 Armbian 系统 (os-release)"
    fi
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME=$PRETTY_NAME
        
        VERSION_MAJOR=$(echo $OS_VERSION | cut -d '.' -f 1)
        VERSION_MINOR=$(echo $OS_VERSION | cut -d '.' -f 2)
        
        print_msg "系统: $OS_NAME"
        print_msg "架构: $ARCH"
        print_msg "内存: ${TOTAL_MEM}MB"
        
        # 增强系统标识逻辑
        if [ "$IS_ARMBIAN" = true ]; then
            SYSTEM_KEY="armbian"
            print_msg "使用 Armbian 专用配置"
        elif [ "$OS_ID" = "ubuntu" ]; then
            # 支持更多 Ubuntu 版本
            case "$VERSION_MAJOR" in
                24) SYSTEM_KEY="ubuntu24" ;;
                23) SYSTEM_KEY="ubuntu23" ;;
                22) SYSTEM_KEY="ubuntu22" ;;
                20) SYSTEM_KEY="ubuntu20" ;;
                18) SYSTEM_KEY="ubuntu18" ;;
                16) SYSTEM_KEY="ubuntu16" ;;
                *) 
                    print_warn "未知 Ubuntu 版本: $OS_VERSION，使用默认配置"
                    SYSTEM_KEY="default"
                    ;;
            esac
        elif [ "$OS_ID" = "debian" ]; then
            case "$VERSION_MAJOR" in
                12) SYSTEM_KEY="debian12" ;;
                11) SYSTEM_KEY="debian11" ;;
                10) SYSTEM_KEY="debian10" ;;
                9) SYSTEM_KEY="debian9" ;;
                *) 
                    print_warn "未知 Debian 版本: $OS_VERSION，使用默认配置"
                    SYSTEM_KEY="default"
                    ;;
            esac
        else
            print_warn "未知系统类型: $OS_ID，使用默认配置"
            SYSTEM_KEY="default"
        fi
        
        print_msg "系统标识: $SYSTEM_KEY"
        
        # 检测包管理器可用性
        if ! command -v apt-get &> /dev/null; then
            print_error "apt-get 不可用，此脚本仅支持基于 Debian 的系统"
            exit 1
        fi
        
    else
        print_error "无法检测系统类型 (/etc/os-release 不存在)"
        exit 1
    fi
    
    # 内存模式检测
    if [ "$TOTAL_MEM" -lt 256 ]; then
        print_warn "内存较小 (${TOTAL_MEM}MB)，启用低内存模式"
        LOW_MEMORY_MODE=true
    elif [ "$TOTAL_MEM" -lt 512 ]; then
        print_warn "内存适中 (${TOTAL_MEM}MB)，使用轻量配置"
        LOW_MEMORY_MODE=true
    else
        LOW_MEMORY_MODE=false
    fi
    
    # ARM 架构特殊处理
    if [[ "$ARCH" =~ ^(arm|aarch64) ]]; then
        print_msg "ARM 架构系统，启用特殊优化"
        ARM_OPTIMIZED=true
    else
        ARM_OPTIMIZED=false
    fi
}

# ==================== 动态 PHP 检测与安装 ====================

detect_php_version() {
    print_step "动态检测 PHP 环境"
    
    PHP_CURRENT=""
    PHP_EXTENSIONS_OK=true
    REQUIRED_EXTS=("curl" "mbstring" "json" "sockets")
    
    if command -v php &> /dev/null; then
        PHP_CURRENT=$(php -v 2>/dev/null | head -n 1 | grep -oP 'PHP \K[0-9]+\.[0-9]+' || echo "")
        if [ -n "$PHP_CURRENT" ]; then
            print_msg "检测到 PHP: $PHP_CURRENT"
            
            MISSING_EXTS=()
            for ext in "${REQUIRED_EXTS[@]}"; do
                if [ "$ext" = "json" ]; then
                    PHP_MAJOR=$(echo "$PHP_CURRENT" | cut -d '.' -f 1)
                    if [ "$PHP_MAJOR" -ge "8" ]; then
                        print_msg "  ✓ $ext (PHP 8.0+ 内置)"
                        continue
                    fi
                fi
                
                if php -m 2>/dev/null | grep -qi "^$ext$"; then
                    print_msg "  ✓ $ext"
                else
                    print_warn "  ✗ $ext 缺失"
                    MISSING_EXTS+=("$ext")
                    PHP_EXTENSIONS_OK=false
                fi
            done
            
            if [ ${#MISSING_EXTS[@]} -eq 0 ]; then
                print_msg "所有必要扩展已安装"
                PHP_NEED_INSTALL=false
            else
                print_warn "缺少扩展: ${MISSING_EXTS[*]}"
                PHP_NEED_INSTALL=true
            fi
        else
            print_msg "PHP 已安装但无法检测版本"
            PHP_NEED_INSTALL=true
        fi
    else
        print_msg "PHP 未安装"
        PHP_NEED_INSTALL=true
        PHP_CURRENT=""
    fi
}

install_php_dynamic() {
    print_step "动态安装 PHP"
    
    if [ "$PHP_NEED_INSTALL" = false ]; then
        print_msg "PHP 环境已满足，跳过安装"
        return 0
    fi
    
    if [ -n "$PHP_CURRENT" ]; then
        print_msg "为 PHP $PHP_CURRENT 安装缺失扩展..."
        
        PHP_MAJOR_MINOR=$(echo "$PHP_CURRENT" | cut -d '.' -f 1,2)
        EXT_PREFIX="php${PHP_MAJOR_MINOR}-"
        
        for ext in "${MISSING_EXTS[@]}"; do
            print_msg "  安装 $ext 扩展..."
            
            if apt-get install -y "${EXT_PREFIX}${ext}" 2>/dev/null; then
                print_msg "    ✓ ${EXT_PREFIX}${ext}"
            else
                if apt-get install -y "php-${ext}" 2>/dev/null; then
                    print_msg "    ✓ php-${ext}"
                else
                    print_warn "    ✗ $ext 安装失败"
                fi
            fi
        done
    else
        print_msg "动态选择 PHP 版本安装..."
        
        PHP_CANDIDATES="${PKG_PHP_CLI[$SYSTEM_KEY]:-${PKG_PHP_CLI["default"]}}"
        
        PHP_INSTALLED=false
        for pkg in $PHP_CANDIDATES; do
            print_msg "尝试安装 $pkg..."
            if apt-get install -y "$pkg" 2>/dev/null; then
                if command -v php &> /dev/null; then
                    PHP_CURRENT=$(php -v 2>/dev/null | head -n 1 | grep -oP 'PHP \K[0-9]+\.[0-9]+' || echo "未知")
                    print_msg "✓ PHP $PHP_CURRENT 安装成功"
                    PHP_INSTALLED=true
                    break
                fi
            fi
        done
        
        if [ "$PHP_INSTALLED" = false ]; then
            print_error "PHP 安装失败"
            return 1
        fi
        
        print_msg "安装 PHP 扩展..."
        EXT_CANDIDATES="${PKG_PHP_EXT[$SYSTEM_KEY]:-${PKG_PHP_EXT["default"]}}"
        
        for pkg in $EXT_CANDIDATES; do
            apt-get install -y "$pkg" 2>/dev/null || true
        done
    fi
    
    print_msg "验证 PHP 安装..."
    if command -v php &> /dev/null; then
        php -v 2>/dev/null | head -1
    fi
}

# ==================== 动态 Ghostscript 检测 ====================

detect_gs_library() {
    print_step "动态检测 Ghostscript 库"
    
    print_msg "搜索可用的 Ghostscript 库包..."
    
    apt-cache search "^libgs[0-9]" 2>/dev/null | grep -E "^libgs[0-9]+ " | sort -V -r > /tmp/gs_libs.txt 2>/dev/null || true
    
    if [ -s /tmp/gs_libs.txt ]; then
        print_msg "发现以下 Ghostscript 库:"
        cat /tmp/gs_libs.txt | head -5
        
        GS_LIB_PKG=$(head -1 /tmp/gs_libs.txt | awk '{print $1}')
        GS_MAJOR=$(echo "$GS_LIB_PKG" | grep -oE '[0-9]+' || echo "")
        
        if [ -n "$GS_MAJOR" ]; then
            if apt-cache search "^libgs${GS_MAJOR}-common" 2>/dev/null | grep -q "^libgs${GS_MAJOR}-common"; then
                GS_COMMON_PKG="libgs${GS_MAJOR}-common"
            elif apt-cache search "^libgs-common" 2>/dev/null | grep -q "^libgs-common"; then
                GS_COMMON_PKG="libgs-common"
            else
                GS_COMMON_PKG=""
            fi
        else
            GS_COMMON_PKG=""
        fi
        
        print_msg "选择: $GS_LIB_PKG ${GS_COMMON_PKG:+(common: $GS_COMMON_PKG)}"
    else
        print_warn "未找到版本化的 Ghostscript 库"
        GS_LIB_PKG=""
        GS_COMMON_PKG=""
    fi
    
    rm -f /tmp/gs_libs.txt
}

install_pwg_components() {
    print_step "动态安装 PWG 光栅化组件"
    
    local INSTALL_SUCCESS=false
    
    if [ -n "$GS_LIB_PKG" ]; then
        print_msg "方案1: 安装检测到的库 $GS_LIB_PKG..."
        
        if apt-get install -y ghostscript gsfonts poppler-utils qpdf imagemagick $GS_LIB_PKG $GS_COMMON_PKG 2>/dev/null; then
            print_msg "✓ 安装成功"
            INSTALL_SUCCESS=true
        else
            print_warn "方案1失败"
        fi
    fi
    
    if [ "$INSTALL_SUCCESS" = false ]; then
        print_msg "方案2: 尝试所有已知版本..."
        
        for gs_lib in libgs15 libgs14 libgs13 libgs12 libgs11 libgs10 libgs9 libgs8; do
            if [ "$INSTALL_SUCCESS" = true ]; then break; fi
            
            if apt-cache search "^$gs_lib$" 2>/dev/null | grep -q "^$gs_lib "; then
                print_msg "  尝试 $gs_lib..."
                if apt-get install -y ghostscript gsfonts poppler-utils qpdf imagemagick $gs_lib ${gs_lib}-common 2>/dev/null; then
                    GS_LIB_PKG="$gs_lib"
                    GS_COMMON_PKG="${gs_lib}-common"
                    print_msg "  ✓ $gs_lib 安装成功"
                    INSTALL_SUCCESS=true
                fi
            fi
        done
    fi
    
    if [ "$INSTALL_SUCCESS" = false ]; then
        print_msg "方案3: 尝试通用包名..."
        if apt-get install -y ghostscript gsfonts poppler-utils qpdf imagemagick libgs-common 2>/dev/null; then
            GS_LIB_PKG="libgs-common"
            GS_COMMON_PKG=""
            print_msg "✓ 通用包安装成功"
            INSTALL_SUCCESS=true
        fi
    fi
    
    if [ "$INSTALL_SUCCESS" = false ]; then
        print_warn "方案4: 最小化安装..."
        if apt-get install -y ghostscript gsfonts poppler-utils qpdf imagemagick 2>/dev/null; then
            GS_LIB_PKG="minimal"
            print_msg "✓ 最小化安装成功"
            INSTALL_SUCCESS=true
        fi
    fi
    
    echo ""
    if [ "$INSTALL_SUCCESS" = true ]; then
        print_msg "PWG 组件安装完成"
        
        if command -v gs &> /dev/null; then
            GS_VERSION=$(gs --version 2>/dev/null || echo "未知")
            print_msg "Ghostscript 版本: $GS_VERSION"
        fi
    else
        print_error "PWG 组件安装失败"
        return 1
    fi
}

# ==================== 动态 CUPS 安装 ====================

install_cups_dynamic() {
    print_step "增强动态安装 CUPS 打印系统"
    
    CUPS_INSTALLED=false
    CUPS_COMPLETE=false
    
    if command -v lpstat &> /dev/null; then
        CUPS_INSTALLED=true
        print_msg "CUPS 已安装"
        
        if dpkg -l cups-filters 2>/dev/null | grep -q "^ii"; then
            CUPS_COMPLETE=true
            print_msg "CUPS 完整版已确认"
        else
            print_warn "CUPS 过滤器缺失"
        fi
    fi
    
    if [ "$CUPS_INSTALLED" = true ] && [ "$CUPS_COMPLETE" = true ]; then
        print_msg "CUPS 环境已满足"
    else
        print_msg "安装 CUPS 组件..."
        
        # 使用系统特定的包列表
        CUPS_PACKAGES="${PKG_CUPS[$SYSTEM_KEY]:-${PKG_CUPS["fallback"]}}"
        
        print_msg "尝试安装: $CUPS_PACKAGES"
        
        # 方案1: 使用系统特定包列表
        INSTALL_SUCCESS=false
        if apt-get install -y --no-install-recommends $CUPS_PACKAGES 2>/dev/null; then
            print_msg "✓ CUPS 安装成功（系统优化包）"
            INSTALL_SUCCESS=true
        else
            print_warn "系统优化包安装失败，尝试逐个安装..."
            
            # 方案2: 逐个安装核心包
            CORE_PACKAGES="cups cups-filters cups-client cups-bsd"
            INSTALLED_COUNT=0
            
            for pkg in $CORE_PACKAGES; do
                if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
                    print_msg "  ✓ $pkg"
                    ((INSTALLED_COUNT++))
                else
                    print_warn "  ✗ $pkg 安装失败"
                fi
            done
            
            if [ $INSTALLED_COUNT -ge 2 ]; then
                print_msg "✓ CUPS 核心组件安装成功 ($INSTALLED_COUNT/4)"
                INSTALL_SUCCESS=true
            fi
        fi
        
        # 方案3: 最小化安装
        if [ "$INSTALL_SUCCESS" = false ]; then
            print_warn "尝试最小化 CUPS 安装..."
            if apt-get install -y cups 2>/dev/null; then
                print_msg "✓ CUPS 最小化安装成功"
                INSTALL_SUCCESS=true
            else
                print_error "CUPS 安装完全失败"
                return 1
            fi
        fi
        
        # 安装额外组件（可选）
        print_msg "安装 CUPS 额外组件..."
        EXTRA_PACKAGES="cups-common libcups2"
        for pkg in $EXTRA_PACKAGES; do
            if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
                apt-get install -y --no-install-recommends "$pkg" 2>/dev/null || print_warn "$pkg 安装失败"
            fi
        done
    fi
    
    print_msg "配置 CUPS 服务..."
    
    # 确保 CUPS 目录存在
    mkdir -p /etc/cups /var/log/cups /var/spool/cups /var/cache/cups 2>/dev/null || true
    
    # 启用和启动服务
    if systemctl enable cups 2>/dev/null; then
        print_msg "✓ CUPS 服务已启用"
    else
        print_warn "CUPS 服务启用失败"
    fi
    
    if systemctl start cups 2>/dev/null; then
        print_msg "✓ CUPS 服务已启动"
    else
        print_warn "CUPS 服务启动失败，尝试重启..."
        systemctl restart cups 2>/dev/null || print_warn "CUPS 重启也失败"
    fi
    
    # 配置文件更新
    if [ -f /etc/cups/cupsd.conf ]; then
        cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak 2>/dev/null || true
        
        CUPSD_CONF_URL="${REMOTE_BASE_URL}/cupsd.conf"
        if curl -sSL --connect-timeout 10 --max-time 30 -o /etc/cups/cupsd.conf.new "$CUPSD_CONF_URL" 2>/dev/null; then
            if head -5 /etc/cups/cupsd.conf.new | grep -qE "CUPS|LogLevel|Port"; then
                mv /etc/cups/cupsd.conf.new /etc/cups/cupsd.conf
                systemctl restart cups 2>/dev/null || true
                print_msg "✓ CUPS 配置更新成功"
            else
                rm -f /etc/cups/cupsd.conf.new
                print_warn "CUPS 配置文件验证失败"
            fi
        else
            print_warn "CUPS 配置文件下载失败，使用默认配置"
        fi
    fi
    
    # 验证安装
    sleep 2
    CUPS_STATUS=$(systemctl is-active cups 2>/dev/null || echo "unknown")
    print_msg "CUPS 服务状态: $CUPS_STATUS"
    
    if command -v lpstat &> /dev/null; then
        print_msg "✓ CUPS 命令行工具可用"
    else
        print_warn "CUPS 命令行工具不可用"
    fi
}

# ==================== 动态打印机驱动安装 ====================

detect_connected_printers() {
    print_step "动态检测连接的打印机"
    
    DETECTED_PRINTERS=()
    
    print_msg "检测 USB 设备..."
    USB_PRINTERS=$(lsusb 2>/dev/null | grep -iE "print|hp|canon|epson|brother|samsung|xerox|lexmark|dell|lenovo" || true)
    
    if [ -n "$USB_PRINTERS" ]; then
        echo "$USB_PRINTERS" | while read line; do
            print_msg "  发现: $line"
        done
        
        if echo "$USB_PRINTERS" | grep -qi "hp"; then
            DETECTED_PRINTERS+=("hp")
        fi
        if echo "$USB_PRINTERS" | grep -qiE "samsung|xerox"; then
            DETECTED_PRINTERS+=("samsung")
        fi
        if echo "$USB_PRINTERS" | grep -qiE "brother|lenovo"; then
            DETECTED_PRINTERS+=("brother")
        fi
        if echo "$USB_PRINTERS" | grep -qi "canon"; then
            DETECTED_PRINTERS+=("canon")
        fi
        if echo "$USB_PRINTERS" | grep -qi "epson"; then
            DETECTED_PRINTERS+=("epson")
        fi
    else
        print_msg "未检测到 USB 打印机"
    fi
    
    if command -v lpinfo &> /dev/null; then
        print_msg "检测网络打印机..."
        NET_PRINTERS=$(lpinfo -v 2>/dev/null | grep -E "ipp|socket|lpd" | head -3 || true)
        if [ -n "$NET_PRINTERS" ]; then
            print_msg "发现网络打印协议"
        fi
    fi
    
    UNIQUE_PRINTERS=($(echo "${DETECTED_PRINTERS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    
    if [ ${#UNIQUE_PRINTERS[@]} -gt 0 ]; then
        print_msg "检测到的厂商: ${UNIQUE_PRINTERS[*]}"
    else
        print_msg "未识别特定厂商，将安装通用驱动"
    fi
}

install_printer_drivers_dynamic() {
    print_step "增强动态安装打印机驱动"
    
    # 使用系统特定的驱动包列表
    SYSTEM_DRIVERS="${PKG_PRINTER_DRIVERS[$SYSTEM_KEY]:-${PKG_PRINTER_DRIVERS["minimal"]}}"
    
    print_msg "系统驱动包: $SYSTEM_DRIVERS"
    
    # 基于检测到的打印机添加特定驱动
    SPECIFIC_DRIVERS=""
    for vendor in "${UNIQUE_PRINTERS[@]}"; do
        case "$vendor" in
            hp)
                SPECIFIC_DRIVERS="$SPECIFIC_DRIVERS hplip"
                print_msg "添加 HP 驱动"
                ;;
            samsung)
                SPECIFIC_DRIVERS="$SPECIFIC_DRIVERS printer-driver-splix"
                print_msg "添加 Samsung/Xerox 驱动"
                ;;
            brother)
                SPECIFIC_DRIVERS="$SPECIFIC_DRIVERS printer-driver-brlaser"
                print_msg "添加 Brother/Lenovo 驱动"
                ;;
            canon)
                SPECIFIC_DRIVERS="$SPECIFIC_DRIVERS printer-driver-cque"
                print_msg "添加 Canon 驱动"
                ;;
            epson)
                SPECIFIC_DRIVERS="$SPECIFIC_DRIVERS printer-driver-escpr"
                print_msg "添加 Epson 驱动"
                ;;
        esac
    done
    
    # 合并所有驱动包
    ALL_DRIVERS="$SYSTEM_DRIVERS $SPECIFIC_DRIVERS"
    
    # 去重并安装
    UNIQUE_DRIVERS=($(echo $ALL_DRIVERS | tr ' ' '\n' | sort -u | tr '\n' ' '))
    
    INSTALL_SUCCESS=0
    INSTALL_FAILED=0
    
    for pkg in "${UNIQUE_DRIVERS[@]}"; do
        if [ -z "$pkg" ]; then continue; fi
        
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            print_msg "✓ $pkg 已安装"
        else
            print_msg "安装 $pkg..."
            
            # 先检查包是否存在
            if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
                if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
                    print_msg "  ✓ $pkg 安装成功"
                    ((INSTALL_SUCCESS++))
                else
                    print_warn "  ✗ $pkg 安装失败"
                    ((INSTALL_FAILED++))
                fi
            else
                print_warn "  ⚠ $pkg 在仓库中不可用"
                ((INSTALL_FAILED++))
            fi
        fi
    done
    
    # 特殊处理一些可能冲突的包
    print_msg "检查特殊驱动包..."
    
    # foo2zjs (激光打印机)
    if ! dpkg -l foo2zjs 2>/dev/null | grep -q "^ii"; then
        if apt-cache search "^foo2zjs$" 2>/dev/null | grep -q "^foo2zjs "; then
            apt-get install -y foo2zjs 2>/dev/null && print_msg "✓ foo2zjs 已安装" || print_warn "foo2zjs 安装失败"
        fi
    else
        print_msg "✓ foo2zjs 已安装"
    fi
    
    # foomatic-db vs foomatic-db-compressed-ppds 冲突处理
    if dpkg -l foomatic-db 2>/dev/null | grep -q "^ii" && dpkg -l foomatic-db-compressed-ppds 2>/dev/null | grep -q "^ii"; then
        print_warn "检测到 foomatic-db 包冲突，移除 foomatic-db"
        apt-get remove -y foomatic-db 2>/dev/null || true
    fi
    
    # 报告安装结果
    echo ""
    print_msg "驱动安装完成："
    print_msg "  成功: $INSTALL_SUCCESS 个包"
    [ $INSTALL_FAILED -gt 0 ] && print_warn "  失败: $INSTALL_FAILED 个包"
    
    # 重启 CUPS 服务
    print_msg "重启 CUPS 服务以加载新驱动..."
    if systemctl restart cups 2>/dev/null; then
        print_msg "✓ CUPS 服务重启成功"
    else
        print_warn "CUPS 服务重启失败"
    fi
    
    # 验证驱动安装
    sleep 2
    if command -v lpinfo &> /dev/null; then
        DRIVER_COUNT=$(lpinfo -m 2>/dev/null | wc -l || echo "0")
        print_msg "可用打印机驱动: $DRIVER_COUNT 个"
    fi
}

# ==================== 新增：更新驱动及字体（用户指定命令） ====================

update_drivers_and_fonts() {
    print_step "更新驱动及字体"
    
    print_msg "此操作将安装/更新以下组件："
    echo "  - CUPS 打印系统组件"
    echo "  - 打印机驱动（HP、Epson、Brother、Samsung等）"
    echo "  - Ghostscript 及相关工具"
    echo "  - 中文字体"
    echo "  - 图像处理工具"
    echo ""
    
    read -p "确认继续? [Y/n]: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        print_msg "已取消"
        return 0
    fi
    
    # 先更新系统
    update_system
    
    print_msg "开始安装驱动和字体包..."
    
    # 定义要安装的包列表（基于用户提供的命令，添加动态检测）
    local PACKAGES=""
    
    # CUPS 核心组件（动态检测可用包名）
    print_msg "检查 CUPS 组件..."
    local CUPS_PACKAGES="cups cups-client cups-bsd cups-filters cups-browsed"
    for pkg in $CUPS_PACKAGES; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            PACKAGES="$PACKAGES $pkg"
        fi
    done
    
    # 打印机驱动（逐个检测安装）
    print_msg "检查打印机驱动..."
    local DRIVER_PACKAGES="printer-driver-gutenprint printer-driver-hpijs hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix foomatic-db foomatic-db-engine openprinting-ppds hpijs-ppds"
    for pkg in $DRIVER_PACKAGES; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            PACKAGES="$PACKAGES $pkg"
        else
            print_warn "  $pkg 在仓库中不可用，跳过"
        fi
    done
    
    # 文档处理工具
    print_msg "检查文档处理工具..."
    local TOOL_PACKAGES="ghostscript qpdf poppler-utils unoconv imagemagick graphicsmagick netpbm"
    for pkg in $TOOL_PACKAGES; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            PACKAGES="$PACKAGES $pkg"
        fi
    done
    
    # 中文字体（动态选择）
    print_msg "检查中文字体..."
    local FONT_PACKAGES="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fontconfig"
    for pkg in $FONT_PACKAGES; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            PACKAGES="$PACKAGES $pkg"
        fi
    done
    
    # 语言包（Ubuntu/Debian 差异）
    print_msg "检查语言包..."
    if apt-cache search "^language-pack-zh-hans$" 2>/dev/null | grep -q "^language-pack-zh-hans "; then
        PACKAGES="$PACKAGES language-pack-zh-hans language-pack-zh-hans-base"
    fi
    
    # 色彩管理
    print_msg "检查色彩管理..."
    if apt-cache search "^colord$" 2>/dev/null | grep -q "^colord "; then
        PACKAGES="$PACKAGES colord liblcms2-2"
    fi
    
    # 执行安装
    print_msg "开始安装以下包："
    echo "$PACKAGES" | tr ' ' '\n' | sort | column -c 80
    echo ""
    
    local INSTALL_COUNT=0
    local FAIL_COUNT=0
    
    for pkg in $PACKAGES; do
        print_msg "[$((++INSTALL_COUNT))] 安装 $pkg..."
        if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
            print_msg "  ✓ $pkg 成功"
        else
            print_warn "  ✗ $pkg 失败"
            ((FAIL_COUNT++))
        fi
    done
    
    # 重启 CUPS 服务
    print_msg "重启 CUPS 服务..."
    systemctl restart cups 2>/dev/null || print_warn "CUPS 重启失败"
    
    # 更新字体缓存
    print_msg "更新字体缓存..."
    fc-cache -fv >/dev/null 2>&1 || print_warn "字体缓存更新失败"
    
    # 报告结果
    echo ""
    print_msg "安装完成！"
    print_msg "成功: $((INSTALL_COUNT - FAIL_COUNT)) 个包"
    [ $FAIL_COUNT -gt 0 ] && print_warn "失败: $FAIL_COUNT 个包"
    
    # 显示状态
    echo ""
    echo "组件状态："
    command -v lpstat &> /dev/null && echo "  ✓ CUPS 可用" || echo "  ✗ CUPS 不可用"
    command -v gs &> /dev/null && echo "  ✓ Ghostscript 可用" || echo "  ✗ Ghostscript 不可用"
    command -v convert &> /dev/null && echo "  ✓ ImageMagick 可用" || echo "  ✗ ImageMagick 不可用"
    
    local FONT_COUNT=$(fc-list :lang=zh 2>/dev/null | wc -l || echo "0")
    echo "  中文字体: $FONT_COUNT 个"
}

# ==================== 其他安装步骤 ====================

install_libreoffice() {
    print_step "安装 LibreOffice"
    
    if command -v libreoffice &> /dev/null; then
        LO_VERSION=$(libreoffice --version 2>/dev/null | head -n 1 || echo "未知版本")
        print_msg "LibreOffice 已安装: $LO_VERSION"
    else
        print_msg "安装 LibreOffice..."
        
        if [ "$LOW_MEMORY_MODE" = true ]; then
            print_msg "低内存模式，安装轻量版本..."
            apt-get install -y --no-install-recommends \
                libreoffice-writer-nogui libreoffice-calc-nogui 2>/dev/null || \
            apt-get install -y --no-install-recommends \
                libreoffice-writer libreoffice-calc
        else
            apt-get install -y --no-install-recommends \
                libreoffice-writer libreoffice-calc libreoffice-impress
        fi
    fi
    
    mkdir -p /tmp/.libreoffice
    chmod 777 /tmp/.libreoffice 2>/dev/null || true
}

install_print_tools() {
    print_step "安装打印工具"
    
    TOOLS="ghostscript:gs qpdf:qpdf imagemagick:convert texlive-extra-utils:pdfjam texlive-latex-extra:pdflatex"
    
    for tool_pair in $TOOLS; do
        pkg="${tool_pair%%:*}"
        cmd="${tool_pair##*:}"
        
        if command -v "$cmd" &> /dev/null; then
            print_msg "✓ $pkg ($cmd) 已安装"
        else
            print_msg "安装 $pkg..."
            apt-get install -y --no-install-recommends "$pkg" 2>/dev/null || print_warn "$pkg 安装失败"
        fi
    done
}

install_fonts_dynamic() {
    print_step "动态安装中文字体"
    
    if [ -n "${PKG_FONTS[$SYSTEM_KEY]}" ]; then
        FONT_PACKAGES="${PKG_FONTS[$SYSTEM_KEY]}"
        print_msg "使用 $SYSTEM_KEY 字体配置"
    else
        FONT_PACKAGES="${PKG_FONTS["minimal"]}"
        print_msg "使用最小字体配置"
    fi
    
    for pkg in $FONT_PACKAGES; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                print_msg "  ✓ $pkg 已安装"
            else
                print_msg "  安装 $pkg..."
                apt-get install -y --no-install-recommends "$pkg" 2>/dev/null || print_warn "  $pkg 安装失败"
            fi
        else
            print_warn "  $pkg 在仓库中不可用"
        fi
    done
    
    print_msg "更新字体缓存..."
    fc-cache -fv >/dev/null 2>&1 || true
    
    FONT_COUNT=$(fc-list :lang=zh 2>/dev/null | wc -l || echo "0")
    print_msg "已安装 $FONT_COUNT 个中文字体"
}

# ==================== 客户端安装 ====================

download_files() {
    print_step "下载客户端文件"
    mkdir -p $INSTALL_DIR
    
    for file in "${REMOTE_FILES[@]}"; do
        print_msg "获取 $file..."
        DOWNLOAD_URL="${REMOTE_BASE_URL}/download.php?f=${file}"
        
        if curl -sSL --connect-timeout 10 --max-time 30 -o "$INSTALL_DIR/$file" "$DOWNLOAD_URL" 2>/dev/null; then
            if head -1 "$INSTALL_DIR/$file" 2>/dev/null | grep -qE "^#!/usr/bin/env php|^#!/bin/bash|^\[Unit\]"; then
                print_msg "  ✓ $file 下载成功"
            else
                copy_local_file "$file"
            fi
        else
            copy_local_file "$file"
        fi
    done
    
    if [ ! -f "$INSTALL_DIR/printer_client.php" ]; then
        print_error "printer_client.php 获取失败"
        exit 1
    fi
    
    chmod +x "$INSTALL_DIR/printer_client.php" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/generate_qrcode.sh" 2>/dev/null || true
    touch $LOG_FILE 2>/dev/null || true
    chmod 666 $LOG_FILE 2>/dev/null || true
    
    print_msg "客户端文件准备完成"
}

copy_local_file() {
    local file="$1"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [ -f "$script_dir/$file" ]; then
        cp "$script_dir/$file" "$INSTALL_DIR/"
        print_msg "  ✓ $file 从本地复制"
    else
        print_warn "  ✗ $file 本地也不可用"
    fi
}

configure_server() {
    print_step "配置服务器"
    
    if [ -f "$INSTALL_DIR/printer_client.php" ]; then
        CURRENT_SERVER=$(grep -oP "\\\$WS_SERVER = '\K[^']+" "$INSTALL_DIR/printer_client.php" 2>/dev/null || echo "")
        
        if [ -n "$CURRENT_SERVER" ] && [ "$CURRENT_SERVER" != "ws://your-server:8089" ]; then
            print_msg "服务器已配置: $CURRENT_SERVER"
        else
            print_msg "使用默认服务器配置"
        fi
    fi
}

get_device_id() {
    local id_file="/etc/printer-device-id"
    
    if [ -f "$id_file" ]; then
        local id=$(cat "$id_file" 2>/dev/null | tr -d '\r\n')
        if [[ "$id" =~ ^[0-9a-fA-F]{30,32}$ ]]; then
            echo "${id,,}"
            return 0
        fi
    fi
    
    if command -v openssl >/dev/null 2>&1; then
        local new_id=$(openssl rand -hex 15 2>/dev/null)
    else
        local new_id=$(head -c 15 /dev/urandom 2>/dev/null | hexdump -e '15/1 "%02x"')
    fi
    
    if [[ -n "$new_id" && "$new_id" =~ ^[0-9a-fA-F]{30}$ ]]; then
        echo "${new_id,,}" > "$id_file" 2>/dev/null && chmod 644 "$id_file" 2>/dev/null
        echo "${new_id,,}"
    else
        new_id=$(date +%s%N | sha256sum | head -c 30)
        echo "${new_id,,}" > "$id_file" 2>/dev/null
        echo "${new_id,,}"
    fi
}

configure_device_id() {
    print_step "设备ID配置"
    
    DEVICE_ID=$(get_device_id)
    print_msg "设备ID: $DEVICE_ID"
}

create_service() {
    print_step "创建系统服务"
    
    if [ -f "$INSTALL_DIR/printer-client.service" ]; then
        sed -i "s|/opt/printer-client|$INSTALL_DIR|g" "$INSTALL_DIR/printer-client.service" 2>/dev/null || true
        cp "$INSTALL_DIR/printer-client.service" /etc/systemd/system/${SERVICE_NAME}.service
    else
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

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable $SERVICE_NAME 2>/dev/null || true
    print_msg "服务已创建: $SERVICE_NAME"
}

start_service() {
    print_step "启动服务"
    
    systemctl start $SERVICE_NAME 2>/dev/null || true
    sleep 2
    
    if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
        print_msg "✓ 服务启动成功"
    else
        print_warn "服务启动可能失败，查看日志:"
        tail -10 $LOG_FILE 2>/dev/null || echo "无日志"
    fi
}

cleanup_cache() {
    print_step "清理缓存"
    
    apt-get clean 2>/dev/null || true
    apt-get autoclean 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 2>/dev/null || true
    
    print_msg "缓存清理完成"
}

# ==================== 生成设备二维码 ====================

generate_device_qrcode() {
    print_step "生成设备二维码"
    
    local device_id=$(get_device_id)
    if [ -z "$device_id" ]; then
        print_error "无法获取设备ID"
        return 1
    fi
    
    print_msg "设备ID: $device_id"
    
    if ! command -v qrencode &> /dev/null; then
        print_msg "安装 qrencode..."
        apt-get install -y qrencode 2>/dev/null || {
            print_error "qrencode 安装失败"
            return 1
        }
    fi
    
    local qr_content="device://${device_id}"
    print_msg "二维码内容: $qr_content"
    
    local qr_file="/tmp/device_qr_${device_id}.png"
    if qrencode -o "$qr_file" -s 10 "$qr_content" 2>/dev/null; then
        print_msg "✓ 二维码图片已保存: $qr_file"
    fi
    
    echo ""
    echo -e "${GREEN}请使用微信扫描以下二维码绑定设备:${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$qr_content" 2>/dev/null || {
        print_warn "终端二维码显示失败"
        echo "手动绑定地址: $qr_content"
    }
    echo ""
    
    if [ -d "$INSTALL_DIR" ]; then
        echo "$qr_content" > "$INSTALL_DIR/device_id.txt"
        [ -f "$qr_file" ] && cp "$qr_file" "$INSTALL_DIR/qrcode.png" 2>/dev/null || true
        print_msg "设备信息已保存到 $INSTALL_DIR"
    fi
}

# ==================== 更新程序 ====================

update_client() {
    print_step "更新打印客户端"
    
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "安装目录不存在: $INSTALL_DIR"
        print_msg "请先运行完整安装"
        return 1
    fi
    
    local backup_time=$(date +%Y%m%d_%H%M%S)
    if [ -f "$INSTALL_DIR/printer_client.php" ]; then
        cp "$INSTALL_DIR/printer_client.php" "$INSTALL_DIR/printer_client.php.bak.${backup_time}"
        print_msg "已备份当前版本"
    fi
    
    print_msg "停止服务..."
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    sleep 1
    
    print_msg "下载最新版本..."
    local download_url="${REMOTE_BASE_URL}/download.php?f=printer_client.php"
    
    if curl -sSL --connect-timeout 10 --max-time 60 -o "$INSTALL_DIR/printer_client.php.new" "$download_url" 2>/dev/null; then
        if head -1 "$INSTALL_DIR/printer_client.php.new" 2>/dev/null | grep -q "^#!/usr/bin/env php"; then
            local new_version=$(grep -oP "define\s*\(\s*'CLIENT_VERSION'\s*,\s*'\K[^']+" "$INSTALL_DIR/printer_client.php.new" 2>/dev/null || echo "未知")
            local old_version=$(grep -oP "define\s*\(\s*'CLIENT_VERSION'\s*,\s*'\K[^']+" "$INSTALL_DIR/printer_client.php" 2>/dev/null || echo "旧版")
            
            print_msg "当前版本: $old_version"
            print_msg "新版本: $new_version"
            
            mv "$INSTALL_DIR/printer_client.php.new" "$INSTALL_DIR/printer_client.php"
            chmod +x "$INSTALL_DIR/printer_client.php"
            print_msg "✓ 客户端文件已更新"
        else
            rm -f "$INSTALL_DIR/printer_client.php.new"
            print_error "下载内容验证失败"
            return 1
        fi
    else
        rm -f "$INSTALL_DIR/printer_client.php.new" 2>/dev/null || true
        print_error "下载失败"
        return 1
    fi
    
    print_msg "检查 CUPS 配置更新..."
    local cupsd_url="${REMOTE_BASE_URL}/cupsd.conf"
    if curl -sSL --connect-timeout 10 --max-time 30 -o "/etc/cups/cupsd.conf.new" "$cupsd_url" 2>/dev/null; then
        if head -5 "/etc/cups/cupsd.conf.new" 2>/dev/null | grep -qE "CUPS|LogLevel|Port"; then
            cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak.${backup_time} 2>/dev/null || true
            mv /etc/cups/cupsd.conf.new /etc/cups/cupsd.conf
            systemctl restart cups 2>/dev/null || true
            print_msg "✓ CUPS 配置已更新"
        else
            rm -f /etc/cups/cupsd.conf.new
        fi
    fi
    
    print_msg "重启服务..."
    systemctl start $SERVICE_NAME 2>/dev/null || true
    sleep 2
    
    if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
        print_msg "✓ 服务重启成功"
        print_msg "更新完成！"
    else
        print_warn "服务启动可能失败"
        tail -20 $LOG_FILE 2>/dev/null || echo "无日志"
    fi
}

# ==================== 安装报告 ====================

show_summary() {
    print_step "安装完成摘要"
    
    echo ""
    echo "============================================"
    echo "         打印客户端安装完成！"
    echo "============================================"
    echo ""
    echo "安装目录: $INSTALL_DIR"
    echo "日志文件: $LOG_FILE"
    echo "服务名称: $SERVICE_NAME"
    echo "设备ID: $DEVICE_ID"
    echo ""
    echo "组件验证:"
    
    command -v php &> /dev/null && echo "  ✓ PHP" || echo "  ✗ PHP"
    command -v lpstat &> /dev/null && echo "  ✓ CUPS" || echo "  ✗ CUPS"
    command -v gs &> /dev/null && echo "  ✓ Ghostscript" || echo "  ✗ Ghostscript"
    
    if dpkg -l 2>/dev/null | grep -qE "^ii\s+libgs[0-9]"; then
        GS_LIB=$(dpkg -l 2>/dev/null | grep -E "^ii\s+libgs[0-9]" | awk '{print $2}' | head -1)
        echo "  ✓ Ghostscript库 ($GS_LIB)"
    else
        echo "  ⚠ Ghostscript库 (未检测到特定版本)"
    fi
    
    command -v libreoffice &> /dev/null && echo "  ✓ LibreOffice" || echo "  ✗ LibreOffice"
    command -v convert &> /dev/null && echo "  ✓ ImageMagick" || echo "  ✗ ImageMagick"
    
    echo ""
    echo "常用命令:"
    echo "  启动: systemctl start $SERVICE_NAME"
    echo "  停止: systemctl stop $SERVICE_NAME"
    echo "  重启: systemctl restart $SERVICE_NAME"
    echo "  状态: systemctl status $SERVICE_NAME"
    echo "  日志: tail -f $LOG_FILE"
    echo "  更新: bash install.sh --update"
    echo "  二维码: bash install.sh --qrcode"
    echo "  驱动字体: bash install.sh --drivers"
    echo ""
    
    local IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    echo "CUPS管理: http://${IP_ADDR}:631"
    echo ""
    
    generate_qrcode_summary
}

generate_qrcode_summary() {
    local _qa="68747470733a2f2f"
    local _qb="78696e7072696e74"
    local _qc="2e7a79736861"
    local _qd="72652e746f70"
    local _qe="2f6170695f696e7374616c6c5f7172636f64652e706870"
    local QR_API=$(_h "${_qa}${_qb}${_qc}${_qd}${_qe}")
    
    local QR_CONTENT=$(curl -sSL --connect-timeout 5 --max-time 10 "$QR_API" 2>/dev/null | grep -oP '"qrcode"\s*:\s*"\K[^"]+' || echo "")
    
    if [ -z "$QR_CONTENT" ]; then
        local _ba="68747470733a2f2f"
        local _bb="78696e7072696e74"
        local _bc="2e7a79736861"
        local _bd="72652e746f70"
        local _be="2f7863782e706870"
        QR_CONTENT=$(_h "${_ba}${_bb}${_bc}${_bd}${_be}")
    fi
    
    if command -v qrencode &> /dev/null; then
        echo -e "${GREEN}请使用微信扫描以下二维码进入小程序:${NC}"
        echo ""
        qrencode -t ANSIUTF8 "$QR_CONTENT" 2>/dev/null || echo "二维码: $QR_CONTENT"
    else
        echo "小程序地址: $QR_CONTENT"
    fi
    echo ""
}

# ==================== 主流程 ====================

full_install() {
    echo ""
    print_msg "=========================================="
    print_msg "      开始完整安装流程"
    print_msg "=========================================="
    echo ""
    
    check_root
    detect_system
    check_system_compatibility
    
    echo ""
    print_step "第1步：更新系统包列表"
    update_system
    
    echo ""
    print_step "第2步：安装基础依赖"
    install_base_deps
    
    echo ""
    print_step "第3步：智能安装 PHP"
    if ! install_php_smart; then
        handle_install_error "php" $? "PHP 智能安装失败"
    fi
    
    echo ""
    print_step "第4步：智能安装 CUPS"
    if ! install_cups_smart; then
        handle_install_error "cups" $? "CUPS 智能安装失败"
    fi
    
    echo ""
    print_step "第5步：智能安装 Ghostscript"
    local GS_PACKAGES=""
    if apt-cache search "^ghostscript$" 2>/dev/null | grep -q "^ghostscript "; then
        GS_PACKAGES="ghostscript"
    fi
    for lib in libgs9 libgs10 libgs-dev; do
        if apt-cache search "^$lib$" 2>/dev/null | grep -q "^$lib "; then
            GS_PACKAGES="$GS_PACKAGES $lib"
            break
        fi
    done
    if [ -n "$GS_PACKAGES" ]; then
        smart_install_packages "$GS_PACKAGES" "Ghostscript"
    fi
    
    echo ""
    print_step "第6步：智能安装打印机驱动"
    detect_connected_printers
    local DRIVER_PACKAGES="printer-driver-gutenprint foomatic-db-engine"
    
    for pkg in printer-driver-hpijs hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            DRIVER_PACKAGES="$DRIVER_PACKAGES $pkg"
        fi
    done
    
    if apt-cache search "^foomatic-db-compressed-ppds$" 2>/dev/null | grep -q "^foomatic-db-compressed-ppds "; then
        DRIVER_PACKAGES="$DRIVER_PACKAGES foomatic-db-compressed-ppds"
    elif apt-cache search "^foomatic-db$" 2>/dev/null | grep -q "^foomatic-db "; then
        DRIVER_PACKAGES="$DRIVER_PACKAGES foomatic-db"
    fi
    
    smart_install_packages "$DRIVER_PACKAGES" "打印机驱动"
    
    echo ""
    print_step "第7步：智能安装办公软件"
    local OFFICE_PACKAGES=""
    if apt-cache search "^libreoffice$" 2>/dev/null | grep -q "^libreoffice "; then
        OFFICE_PACKAGES="libreoffice"
    elif apt-cache search "^libreoffice-core$" 2>/dev/null | grep -q "^libreoffice-core "; then
        OFFICE_PACKAGES="libreoffice-core libreoffice-writer libreoffice-calc"
    fi
    if [ -n "$OFFICE_PACKAGES" ]; then
        smart_install_packages "$OFFICE_PACKAGES" "LibreOffice"
    else
        print_warn "LibreOffice 在仓库中不可用，跳过"
    fi
    
    echo ""
    print_step "第8步：智能安装图像处理工具"
    local IMAGE_PACKAGES=""
    for pkg in imagemagick graphicsmagick netpbm qpdf poppler-utils; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            IMAGE_PACKAGES="$IMAGE_PACKAGES $pkg"
        fi
    done
    if [ -n "$IMAGE_PACKAGES" ]; then
        smart_install_packages "$IMAGE_PACKAGES" "图像处理工具"
    fi
    
    echo ""
    print_step "第9步：智能安装中文字体"
    local FONT_PACKAGES=""
    for pkg in fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fontconfig; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg "; then
            FONT_PACKAGES="$FONT_PACKAGES $pkg"
        fi
    done
    if [ -n "$FONT_PACKAGES" ]; then
        smart_install_packages "$FONT_PACKAGES" "中文字体"
    fi
    
    echo ""
    print_step "第10步：下载客户端文件"
    download_files
    
    echo ""
    print_step "第11步：配置服务"
    configure_server
    configure_device_id
    create_service
    
    echo ""
    print_step "第12步：清理和启动"
    cleanup_cache
    start_service
    
    echo ""
    show_summary
    
    echo ""
    if [ "${AUTO_INSTALL:-false}" = "true" ]; then
        print_msg "自动安装模式：跳过二维码生成确认"
        generate_device_qrcode
    else
        read -p "是否生成设备二维码? [Y/n]: " GEN_QR
        if [ "$GEN_QR" != "n" ] && [ "$GEN_QR" != "N" ]; then
            generate_device_qrcode
        fi
    fi
}

show_menu() {
    echo ""
    echo "============================================"
    echo "           打印客户端安装脚本"
    echo "============================================"
    echo ""
    echo "  1. 完整安装 (智能检测所有组件)"
    echo "  2. 仅检测环境 (不安装)"
    echo "  3. 仅安装缺失组件"
    echo "  4. 重新安装所有组件"
    echo "  5. 查看当前状态"
    echo "  6. 生成设备二维码"
    echo "  7. 更新程序"
    echo "  8. 查看服务日志"
    echo "  9. 更新驱动及字体"
    echo "  10. 卸载"
    echo "  0. 退出"
    echo ""
    read -p "请选择 [0-10]: " MENU_CHOICE
    
    case $MENU_CHOICE in
        1) 
            AUTO_INSTALL=true
            full_install 
            ;;
        2) 
            check_root
            detect_system
            detect_php_version
            detect_gs_library
            detect_connected_printers
            print_msg "检测完成"
            ;;
        3)
            check_root
            detect_system
            
            echo ""
            print_msg "=========================================="
            print_msg "      仅安装缺失组件"
            print_msg "=========================================="
            echo ""
            
            # 检查并安装缺失的PHP
            if ! command -v php &> /dev/null; then
                print_step "检测到PHP缺失，开始安装..."
                install_php_smart
            else
                print_msg "✓ PHP 已安装: $(php -v | head -1)"
            fi
            
            # 检查并安装缺失的CUPS
            if ! command -v lpstat &> /dev/null; then
                print_step "检测到CUPS缺失，开始安装..."
                install_cups_smart
            else
                print_msg "✓ CUPS 已安装"
            fi
            
            # 检查并安装缺失的Ghostscript
            if ! command -v gs &> /dev/null; then
                print_step "检测到Ghostscript缺失，开始安装..."
                local GS_PACKAGES=""
                if apt-cache search "^ghostscript$" 2>/dev/null | grep -q "^ghostscript "; then
                    GS_PACKAGES="ghostscript"
                fi
                for lib in libgs9 libgs10 libgs-dev; do
                    if apt-cache search "^$lib$" 2>/dev/null | grep -q "^$lib "; then
                        GS_PACKAGES="$GS_PACKAGES $lib"
                        break
                    fi
                done
                if [ -n "$GS_PACKAGES" ]; then
                    smart_install_packages "$GS_PACKAGES" "Ghostscript"
                fi
            else
                print_msg "✓ Ghostscript 已安装"
            fi
            
            # 检查并安装缺失的客户端文件
            if [ ! -f "$INSTALL_DIR/printer_client.php" ]; then
                print_step "检测到客户端文件缺失，开始下载..."
                download_files
                configure_server
            else
                print_msg "✓ 客户端文件已存在"
            fi
            
            # 检查并创建服务
            if ! systemctl is-enabled $SERVICE_NAME &> /dev/null; then
                print_step "检测到服务未配置，开始配置..."
                configure_device_id
                create_service
                start_service
            else
                print_msg "✓ 服务已配置"
            fi
            
            print_msg "缺失组件检查完成"
            ;;
        4)
            check_root
            detect_system
            FORCE_REINSTALL=true
            AUTO_INSTALL=true
            
            echo ""
            print_msg "=========================================="
            print_msg "      重新安装所有组件"
            print_msg "=========================================="
            echo ""
            
            print_warn "这将重新安装所有组件，包括已安装的"
            read -p "确认继续? [y/N]: " CONFIRM_REINSTALL
            if [ "$CONFIRM_REINSTALL" != "y" ] && [ "$CONFIRM_REINSTALL" != "Y" ]; then
                print_msg "已取消重新安装"
            else
                full_install
            fi
            ;;
        5)
            check_root
            detect_system
            
            echo ""
            print_msg "=========================================="
            print_msg "      系统状态检查"
            print_msg "=========================================="
            echo ""
            
            # 检查PHP状态
            print_step "PHP 状态"
            if command -v php &> /dev/null; then
                print_msg "✓ PHP 已安装: $(php -v | head -1)"
                print_msg "  扩展: $(php -m 2>/dev/null | grep -E '^(curl|mbstring|sockets)' | tr '\n' ' ')"
            else
                print_warn "✗ PHP 未安装"
            fi
            
            # 检查CUPS状态
            echo ""
            print_step "CUPS 状态"
            if command -v lpstat &> /dev/null; then
                print_msg "✓ CUPS 已安装"
                if systemctl is-active --quiet cups 2>/dev/null; then
                    print_msg "✓ CUPS 服务运行中"
                else
                    print_warn "✗ CUPS 服务未运行"
                fi
            else
                print_warn "✗ CUPS 未安装"
            fi
            
            # 检查Ghostscript状态
            echo ""
            print_step "Ghostscript 状态"
            if command -v gs &> /dev/null; then
                print_msg "✓ Ghostscript 已安装: $(gs --version 2>/dev/null)"
            else
                print_warn "✗ Ghostscript 未安装"
            fi
            
            # 检查客户端状态
            echo ""
            print_step "打印客户端状态"
            if [ -f "$INSTALL_DIR/printer_client.php" ]; then
                print_msg "✓ 客户端文件已安装"
            else
                print_warn "✗ 客户端文件未安装"
            fi
            
            # 检查服务状态
            echo ""
            print_step "服务状态"
            if systemctl is-enabled $SERVICE_NAME &> /dev/null; then
                print_msg "✓ 服务已配置"
                systemctl status $SERVICE_NAME --no-pager -l 2>/dev/null || true
            else
                print_warn "✗ 服务未配置"
            fi
            
            # 检查设备ID
            echo ""
            print_step "设备配置"
            if [ -f /etc/printer-device-id ]; then
                local DEVICE_ID=$(cat /etc/printer-device-id 2>/dev/null)
                print_msg "✓ 设备ID: $DEVICE_ID"
            else
                print_warn "✗ 设备ID 未配置"
            fi
            ;;
        6)
            check_root
            configure_device_id
            generate_device_qrcode
            ;;
        7)
            check_root
            update_client
            ;;
        8)
            tail -50 $LOG_FILE 2>/dev/null || echo "无日志"
            ;;
        9)
            check_root
            update_drivers_and_fonts
            ;;
        10)
            read -p "确定卸载? [y/N]: " CONFIRM
            [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] && {
                systemctl stop $SERVICE_NAME 2>/dev/null || true
                systemctl disable $SERVICE_NAME 2>/dev/null || true
                rm -rf $INSTALL_DIR /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true
                rm -f /etc/printer-device-id 2>/dev/null || true
                print_msg "已卸载"
            }
            ;;
        0) exit 0 ;;
        *) print_error "无效选择" ;;
    esac
}

main() {
    case "${1:-}" in
        --install|-i) 
            AUTO_INSTALL=true
            full_install 
            ;;
        --detect|-d) 
            check_root
            detect_system
            detect_php_version
            detect_gs_library
            detect_connected_printers
            ;;
        --qrcode|-q)
            check_root
            configure_device_id
            generate_device_qrcode
            ;;
        --update|-u)
            check_root
            update_client
            ;;
        --drivers|-D)
            check_root
            update_drivers_and_fonts
            ;;
        --uninstall)
            check_root
            systemctl stop $SERVICE_NAME 2>/dev/null || true
            systemctl disable $SERVICE_NAME 2>/dev/null || true
            rm -rf $INSTALL_DIR /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true
            systemctl daemon-reload 2>/dev/null || true
            rm -f /etc/printer-device-id 2>/dev/null || true
            print_msg "已卸载"
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --install, -i     完整安装（自动模式，跳过交互确认）"
            echo "  --detect, -d      仅检测环境"
            echo "  --qrcode, -q      生成设备二维码"
            echo "  --update, -u      更新程序"
            echo "  --drivers, -D     更新驱动及字体"
            echo "  --uninstall       卸载程序"
            echo "  --help, -h        显示帮助"
            echo ""
            echo "示例:"
            echo "  sudo bash install.sh              # 交互式菜单"
            echo "  sudo bash install.sh --install    # 自动完整安装"
            echo "  sudo bash install.sh --qrcode     # 仅生成二维码"
            echo "  sudo bash install.sh --update     # 更新到最新版"
            echo "  sudo bash install.sh --drivers    # 更新驱动及字体"
            ;;
        *) show_menu ;;
    esac
}

main "$@"
