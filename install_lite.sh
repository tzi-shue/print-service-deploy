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

check_and_install_xxd() {
    if ! command -v xxd &> /dev/null; then
        echo -e "\033[1;33m[WARN]\033[0m xxd 未安装，正在尝试安装..."
        
        apt-get update -qq
        
        echo -e "\033[0;32m[INFO]\033[0m 尝试安装 xxd（独立包）..."
        if apt-get install -y xxd 2>/dev/null; then
            if command -v xxd &> /dev/null; then
                echo -e "\033[0;32m[INFO]\033[0m xxd 安装成功（独立包方案）"
                return
            fi
        fi
        
        echo -e "\033[1;33m[WARN]\033[0m 独立xxd包安装失败，尝试vim-common..."
        if apt-get install -y vim-common 2>/dev/null; then
            if command -v xxd &> /dev/null; then
                echo -e "\033[0;32m[INFO]\033[0m xxd 安装成功（vim-common方案）"
                return
            fi
        fi
        
        echo -e "\033[1;33m[WARN]\033[0m 真正的xxd安装失败，使用busybox备用方案..."
        
        if ! command -v busybox &> /dev/null; then
            echo -e "\033[0;32m[INFO]\033[0m 安装 busybox..."
            if ! apt-get install -y busybox 2>/dev/null; then
                echo -e "\033[0;31m[ERROR]\033[0m 所有xxd安装方案都失败，脚本无法继续"
                echo -e "\033[0;31m[ERROR]\033[0m 请手动安装: apt-get install vim-common 或 apt-get install busybox"
                exit 1
            fi
        else
            echo -e "\033[0;32m[INFO]\033[0m busybox 已存在"
        fi
        
        if ! busybox xxd --help &>/dev/null && ! busybox xxd -h &>/dev/null; then
            echo -e "\033[0;31m[ERROR]\033[0m busybox 不支持xxd功能，所有方案都失败"
            echo -e "\033[0;31m[ERROR]\033[0m 请手动安装: apt-get install vim-common"
            exit 1
        fi
        
        echo -e "\033[0;32m[INFO]\033[0m 创建 xxd 兼容命令（busybox方案）..."
        cat > /usr/bin/xxd << 'EOF'
#!/bin/sh
# xxd compatibility wrapper using busybox
busybox xxd "$@"
EOF
        
        chmod +x /usr/bin/xxd
        
        if command -v xxd &> /dev/null && xxd --help &>/dev/null; then
            echo -e "\033[0;32m[INFO]\033[0m xxd 兼容命令创建成功（busybox备用方案）"
        else
            echo -e "\033[0;31m[ERROR]\033[0m xxd 兼容命令创建失败"
            exit 1
        fi
    else
        echo -e "\033[0;32m[INFO]\033[0m xxd 已存在，跳过安装"
    fi
}

check_and_install_xxd

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
        
        # 检测Ubuntu版本并设置版本特定的包名
        if [ "$ID" = "ubuntu" ]; then
            VERSION_MAJOR=$(echo $VERSION_ID | cut -d '.' -f 1)
            VERSION_MINOR=$(echo $VERSION_ID | cut -d '.' -f 2)
            
            print_msg "Ubuntu版本: $VERSION_MAJOR.$VERSION_MINOR"
            
            # 根据版本设置包名映射
            if [ "$VERSION_MAJOR" -ge "22" ]; then
                # Ubuntu 22.04+ 使用PHP 8.1+
                PHP_VERSION="8.1"
                PHP_CLI_PKG="php8.1-cli"
                PHP_EXT_PREFIX="php8.1-"
                print_msg "检测到Ubuntu 22.04+，使用PHP 8.1"
            elif [ "$VERSION_MAJOR" -eq "20" ]; then
                # Ubuntu 20.04 使用PHP 7.4
                PHP_VERSION="7.4"
                PHP_CLI_PKG="php7.4-cli"
                PHP_EXT_PREFIX="php7.4-"
                print_msg "检测到Ubuntu 20.04，使用PHP 7.4"
            else
                # 更早版本或其他情况，尝试自动检测
                PHP_VERSION=""
                PHP_CLI_PKG="php-cli"
                PHP_EXT_PREFIX="php-"
                print_msg "检测到较老版本Ubuntu，使用默认PHP包"
            fi
        fi
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

install_base_deps() {
    print_step "安装基础依赖"
    PACKAGES="curl wget git unzip qrencode build-essential bc"
    for pkg in $PACKAGES; do
        if ! command -v $pkg &> /dev/null; then
            print_msg "安装 $pkg..."
            apt-get install -y $pkg
        else
            print_msg "$pkg 已安装"
        fi
    done
    
    if command -v xxd &> /dev/null; then
        print_msg "xxd 已可用"
    else
        print_warn "xxd 不可用，但脚本开头应该已处理此问题"
    fi
}

install_php() {
    print_step "检查 PHP 环境"
    REQUIRED_EXTS="curl mbstring json sockets"
    NEED_INSTALL=false
    MISSING_EXTS=""
    
    # 使用检测到的PHP版本信息
    if [ -n "$PHP_VERSION" ]; then
        print_msg "目标PHP版本: $PHP_VERSION"
        print_msg "CLI包名: $PHP_CLI_PKG"
        print_msg "扩展前缀: $PHP_EXT_PREFIX"
    fi
    
    if command -v php &> /dev/null; then
        CURRENT_PHP_VERSION=$(php -v | head -n 1 | cut -d ' ' -f 2 | cut -d '.' -f 1,2)
        print_msg "PHP 已安装: $CURRENT_PHP_VERSION"
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
            print_msg "安装 PHP CLI..."
            # 使用版本特定的包名
            if [ -n "$PHP_CLI_PKG" ]; then
                apt-get install -y $PHP_CLI_PKG 2>/dev/null || {
                    print_warn "版本特定包安装失败，尝试通用包..."
                    apt-get install -y php php-cli 2>/dev/null || apt-get install -y php7.4 php7.4-cli 2>/dev/null || true
                }
            else
                apt-get install -y php php-cli 2>/dev/null || apt-get install -y php7.4 php7.4-cli 2>/dev/null || true
            fi
        fi
        
        print_msg "安装 PHP 扩展..."
        for ext in $REQUIRED_EXTS; do
            if ! php -m | grep -qi "^$ext$"; then
                print_msg "  安装 $ext 扩展..."
                # 特殊处理json扩展 (PHP 8.0+内置)
                if [ "$ext" = "json" ] && [ -n "$PHP_VERSION" ] && [ "$(echo $PHP_VERSION | cut -d '.' -f 1)" -ge "8" ]; then
                    print_msg "    PHP 8.0+ 中json扩展已内置，跳过安装"
                    continue
                fi
                
                # 使用版本特定的扩展包名
                if [ -n "$PHP_EXT_PREFIX" ] && [ "$PHP_EXT_PREFIX" != "php-" ]; then
                    apt-get install -y ${PHP_EXT_PREFIX}$ext 2>/dev/null || {
                        print_warn "    版本特定扩展安装失败，尝试通用包..."
                        apt-get install -y php-$ext 2>/dev/null || apt-get install -y php7.4-$ext 2>/dev/null || true
                    }
                else
                    apt-get install -y php-$ext 2>/dev/null || apt-get install -y php7.4-$ext 2>/dev/null || true
                fi
            fi
        done
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
        # 检查是否为完整版
        if dpkg -l cups-filters 2>/dev/null | grep -q "^ii"; then
            print_msg "CUPS 完整版已安装"
        else
            print_msg "升级 CUPS 到完整版..."
            apt-get install -y cups cups-filters cups-client cups-bsd cups-common libcups2 libcupsfilters1
        fi
    else
        print_msg "安装 CUPS "
        # 使用兼容新/旧系统的包名（修复后的代码）
        apt-get install -y \
            cups \
            cups-filters \
            cups-client \
            cups-bsd \
            cups-common \
            libcups2 \
            libcupsfilters1 \
            cups-ppdc \
            2>/dev/null || \
        apt-get install -y \
            cups \
            cups-filters \
            cups-client \
            cups-bsd \
            cups-common \
            libcups2 \
            libcupsfilters1 \
            libcupsimage2 \
            libcupsppdc1 \
            libcupscgi1 \
            libcupsdriver1 \
            libcupsmime1 \
            cups-ppdc
    fi
    
    # 安装PWG光栅化所需的核心组件
    print_msg "安装 PWG 光栅化支持..."
    apt-get install -y \
        ghostscript \
        gsfonts \
        poppler-utils \
        qpdf \
        imagemagick \
        libgs9 \
        libgs9-common
    
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
    NEED_INSTALL=false
    if check_pkg_installed "printer-driver-gutenprint"; then
        print_msg "Gutenprint 驱动已安装"
    else
        print_msg "安装通用打印机驱动..."
        apt-get install -y --no-install-recommends printer-driver-gutenprint 2>/dev/null || print_warn "Gutenprint驱动安装跳过"
        NEED_INSTALL=true
    fi
    if check_pkg_installed "hplip" || check_pkg_installed "hplip-minimal"; then
        print_msg "HP 驱动已安装"
    else
        print_msg "安装 HP 驱动..."
        apt-get install -y --no-install-recommends hplip 2>/dev/null || print_warn "HP驱动安装跳过"
        NEED_INSTALL=true
    fi
    if check_pkg_installed "printer-driver-splix"; then
        print_msg "Samsung/Xerox 驱动已安装"
    else
        print_msg "安装 Samsung/Xerox 驱动..."
        apt-get install -y --no-install-recommends printer-driver-splix 2>/dev/null || print_warn "Samsung/Xerox驱动安装跳过"
        NEED_INSTALL=true
    fi
    if check_pkg_installed "printer-driver-brlaser"; then
        print_msg "Lenovo/Brother 驱动已安装"
    else
        print_msg "安装 Lenovo/Brother 驱动..."
        apt-get install -y --no-install-recommends printer-driver-brlaser 2>/dev/null || print_warn "Lenovo/Brother驱动安装跳过"
        NEED_INSTALL=true
    fi
    if check_pkg_installed "printer-driver-escpr"; then
        print_msg "Epson 驱动已安装"
    else
        print_msg "安装 Epson 驱动..."
        apt-get install -y --no-install-recommends printer-driver-escpr 2>/dev/null || print_warn "Epson驱动安装跳过"
        NEED_INSTALL=true
    fi
    if check_pkg_installed "foomatic-db-engine"; then
        print_msg "Foomatic 驱动引擎已安装"
    else
        print_msg "安装Foomatic驱动引擎..."
        apt-get install -y --no-install-recommends foomatic-db-engine 2>/dev/null || print_warn "Foomatic引擎安装跳过"
        NEED_INSTALL=true
    fi
    if ! check_pkg_installed "foomatic-db-compressed-ppds"; then
        apt-get install -y --no-install-recommends foomatic-db-compressed-ppds 2>/dev/null || true
        NEED_INSTALL=true
    fi
    
    # 安装 foo2zjs 驱动
    print_msg "安装 foo2zjs 驱动"
    if check_pkg_installed "foo2zjs"; then
        print_msg "foo2zjs 驱动已安装"
    else
        print_msg "下载并安装 foo2zjs 驱动..."
        # 创建临时目录
        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"
        
        # 下载 foo2zjs 源码 - 尝试多个源
        DOWNLOAD_SUCCESS=false
        # 尝试官方源
        if wget --timeout=30 --tries=3 -q http://foo2zjs.rkkda.com/foo2zjs.tar.gz; then
            DOWNLOAD_SUCCESS=true
        # 尝试GitHub镜像
        elif wget --timeout=30 --tries=3 -q https://github.com/koenkooi/foo2zjs/archive/master.tar.gz -O foo2zjs.tar.gz; then
            DOWNLOAD_SUCCESS=true
        # 尝试其他镜像
        elif wget --timeout=30 --tries=3 -q https://mirrors.ustc.edu.cn/foo2zjs/foo2zjs.tar.gz; then
            DOWNLOAD_SUCCESS=true
        fi
        
        if [ "$DOWNLOAD_SUCCESS" = true ]; then
            tar -xzf foo2zjs.tar.gz || {
                print_warn "foo2zjs 解压失败，跳过安装"
                cd /
                rm -rf "$TEMP_DIR"
                return
            }
            cd foo2zjs || {
                print_warn "无法进入foo2zjs目录，跳过安装"
                cd /
                rm -rf "$TEMP_DIR"
                return
            }
            
            # 安装编译依赖
            apt-get install -y --no-install-recommends build-essential bc 2>/dev/null || true
            
            # 编译安装
            make 2>/dev/null || print_warn "foo2zjs 编译失败"
            
            # 下载固件 (支持多种打印机型号)
            print_msg "下载打印机固件..."
            ./getweb 1010 2>/dev/null || true  # HP LaserJet 1010
            ./getweb 1015 2>/dev/null || true  # HP LaserJet 1015  
            ./getweb 1020 2>/dev/null || true  # HP LaserJet 1020
            ./getweb 1025 2>/dev/null || true  # HP LaserJet 1025
            ./getweb 1000 2>/dev/null || true  # HP LaserJet 1000
            ./getweb 1005 2>/dev/null || true  # HP LaserJet 1005
            ./getweb p1005 2>/dev/null || true # HP LaserJet P1005
            ./getweb p1006 2>/dev/null || true # HP LaserJet P1006
            ./getweb p1007 2>/dev/null || true # HP LaserJet P1007
            ./getweb p1008 2>/dev/null || true # HP LaserJet P1008
            ./getweb p1505 2>/dev/null || true # HP LaserJet P1505
            ./getweb p1505n 2>/dev/null || true # HP LaserJet P1505n
            ./getweb 2200 2>/dev/null || true  # HP LaserJet 2200
            ./getweb 2300 2>/dev/null || true  # HP LaserJet 2300
            ./getweb 2410 2>/dev/null || true  # HP LaserJet 2410
            ./getweb 2420 2>/dev/null || true  # HP LaserJet 2420
            ./getweb 2430 2>/dev/null || true  # HP LaserJet 2430
            ./getweb 300 2>/dev/null || true   # Minolta 2300/2400
            ./getweb 2200 2>/dev/null || true  # Samsung ML-2010
            ./getweb 2250 2>/dev/null || true  # Samsung ML-2250
            
            # 安装驱动和固件
            make install 2>/dev/null || print_warn "foo2zjs 安装失败"
            
            # 更新 CUPS 过滤器
            make cups 2>/dev/null || true
            
            print_msg "foo2zjs 驱动安装完成"
            NEED_INSTALL=true
        else
            print_warn "foo2zjs 下载失败，跳过安装"
        fi
        
        # 清理临时文件
        cd /
        rm -rf "$TEMP_DIR"
    fi
    
    # 如果安装了任何驱动，重启 CUPS 以加载新驱动
    if [ "$NEED_INSTALL" = true ]; then
        print_msg "重启 CUPS 服务以加载新驱动..."
        systemctl restart cups 2>/dev/null || print_warn "CUPS 重启失败"
    fi
    
    print_msg "打印机驱动安装完成"
}

install_libreoffice() {
    print_step "安装 LibreOffice"
    if command -v libreoffice &> /dev/null; then
        LO_VERSION=$(libreoffice --version | head -n 1)
        print_msg "LibreOffice 已安装: $LO_VERSION"
    else
        print_msg "安装 LibreOffice (Writer + Calc + Impress)..."
        if [ "$TOTAL_MEM" -lt 512 ]; then
            print_warn "内存较小，安装 nogui 版本..."
            apt-get install -y --no-install-recommends libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui 2>/dev/null || \
            apt-get install -y --no-install-recommends libreoffice-writer libreoffice-calc libreoffice-impress
        else
            apt-get install -y --no-install-recommends libreoffice-writer libreoffice-calc libreoffice-impress
        fi
    fi
    mkdir -p /tmp/.libreoffice
    chmod 777 /tmp/.libreoffice
}

install_print_tools() {
    print_step "安装打印工具"
    NEED_INSTALL=false
    
    # Ghostscript 已在CUPS安装中安装，只检查
    if command -v gs &> /dev/null; then
        print_msg "Ghostscript 已安装"
    else
        print_msg "安装 Ghostscript (PDF处理)..."
        apt-get install -y --no-install-recommends ghostscript 2>/dev/null || print_warn "ghostscript 安装跳过"
        NEED_INSTALL=true
    fi
    
    # qpdf 已在CUPS安装中安装，只检查
    if command -v qpdf &> /dev/null; then
        print_msg "qpdf 已安装"
    else
        print_msg "安装 qpdf (PDF处理)..."
        apt-get install -y --no-install-recommends qpdf 2>/dev/null || print_warn "qpdf 安装跳过"
        NEED_INSTALL=true
    fi
    
    # ImageMagick 已在CUPS安装中安装，只检查
    if command -v convert &> /dev/null; then
        print_msg "ImageMagick 已安装"
    else
        print_msg "安装 ImageMagick (图片处理)..."
        apt-get install -y --no-install-recommends imagemagick 2>/dev/null || print_warn "ImageMagick 安装跳过"
        NEED_INSTALL=true
    fi
    if command -v pdfjam &> /dev/null; then
        print_msg "pdfjam 已安装"
    else
        print_msg "安装 pdfjam (横向打印支持)..."
        apt-get install -y --no-install-recommends texlive-extra-utils 2>/dev/null || print_warn "pdfjam 安装跳过"
        NEED_INSTALL=true
    fi
    if command -v pdflatex &> /dev/null; then
        print_msg "pdflatex 已安装"
    else
        print_msg "安装 texlive-latex-extra (轻量版)..."
        apt-get install -y --no-install-recommends texlive-latex-extra 2>/dev/null || print_warn "texlive-latex-extra 安装跳过"
        NEED_INSTALL=true
    fi
    echo ""
    print_msg "打印工具安装状态:"
    command -v gs &> /dev/null && print_msg "  ✓ Ghostscript" || print_warn "  ✗ Ghostscript"
    command -v qpdf &> /dev/null && print_msg "  ✓ qpdf" || print_warn "  ✗ qpdf"
    command -v convert &> /dev/null && print_msg "  ✓ ImageMagick" || print_warn "  ✗ ImageMagick"
    command -v pdfjam &> /dev/null && print_msg "  ✓ pdfjam" || print_warn "  ✗ pdfjam"
    command -v pdflatex &> /dev/null && print_msg "  ✓ pdflatex" || print_warn "  ✗ pdflatex"
    print_msg "打印工具安装完成"
}

install_fonts() {
    print_step "安装中文字体"
    
    print_msg "安装中文字体包..."
    
    # 根据Ubuntu版本设置字体包
    if [ "$ID" = "ubuntu" ] && [ -n "$VERSION_MAJOR" ]; then
        if [ "$VERSION_MAJOR" -ge "22" ]; then
            # Ubuntu 22.04+ 字体包
            FONT_PACKAGES_GROUP1="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-noto-cjk-extra"
            FONT_PACKAGES_GROUP2="fonts-arphic-ukai fonts-arphic-uming fontconfig"
            FONT_PACKAGES_GROUP3="fonts-droid-fallback fonts-hanazono fonts-open-sans fonts-roboto"
            # Ubuntu 22.04+ 可能不存在的字体包
            OPTIONAL_FONTS="fonts-arphic-gbsn00lp fonts-arphic-bkai00mp fonts-arphic-bsmi00lp fonts-arphic-gkai00mp fonts-cns11643 fonts-cwtex-fs fonts-cwtex-heib fonts-cwtex-kai fonts-cwtex-ming fonts-cwtex-yen fonts-moe-standard-kai fonts-moe-standard-song fonts-nanum fonts-nanum-coding fonts-nanum-extra xfonts-wqy"
            print_msg "使用Ubuntu 22.04+字体包配置"
        elif [ "$VERSION_MAJOR" -eq "20" ]; then
            # Ubuntu 20.04 字体包 (更兼容)
            FONT_PACKAGES_GROUP1="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fonts-noto-cjk-extra"
            FONT_PACKAGES_GROUP2="fonts-arphic-ukai fonts-arphic-uming fontconfig"
            FONT_PACKAGES_GROUP3="fonts-droid-fallback fonts-hanazono fonts-open-sans fonts-roboto"
            # Ubuntu 20.04 中通常存在的字体包
            OPTIONAL_FONTS="fonts-arphic-gbsn00lp fonts-arphic-bkai00mp fonts-arphic-bsmi00lp fonts-arphic-gkai00mp fonts-cns11643 fonts-cwtex-fs fonts-cwtex-heib fonts-cwtex-kai fonts-cwtex-ming fonts-cwtex-yen fonts-moe-standard-kai fonts-moe-standard-song fonts-nanum fonts-nanum-coding fonts-nanum-extra xfonts-wqy"
            print_msg "使用Ubuntu 20.04字体包配置"
        else
            # 更早版本Ubuntu，使用最小字体集
            FONT_PACKAGES_GROUP1="fonts-wqy-microhei fonts-wqy-zenhei fontconfig"
            FONT_PACKAGES_GROUP2="fonts-noto-cjk"
            FONT_PACKAGES_GROUP3="fonts-droid-fallback"
            OPTIONAL_FONTS="fonts-arphic-ukai fonts-arphic-uming xfonts-wqy"
            print_msg "使用兼容字体包配置 (较老Ubuntu版本)"
        fi
    else
        # 非Ubuntu系统，使用通用配置
        FONT_PACKAGES_GROUP1="fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fontconfig"
        FONT_PACKAGES_GROUP2="fonts-arphic-ukai fonts-arphic-uming"
        FONT_PACKAGES_GROUP3="fonts-droid-fallback fonts-hanazono"
        OPTIONAL_FONTS="xfonts-wqy fonts-arphic-gbsn00lp fonts-arphic-bkai00mp"
        print_msg "使用通用字体包配置"
    fi
    
    # 安装第一组字体 (核心中文字体)
    print_msg "安装核心中文字体..."
    apt-get install -y --no-install-recommends $FONT_PACKAGES_GROUP1 2>/dev/null || print_warn "部分核心字体安装跳过"
    
    # 安装第二组字体 (ARPHIC字体)
    print_msg "安装ARPHIC字体..."
    apt-get install -y --no-install-recommends $FONT_PACKAGES_GROUP2 2>/dev/null || print_warn "ARPHIC字体安装跳过"
    
    # 安装第三组字体 (备用字体)
    print_msg "安装备用字体..."
    apt-get install -y --no-install-recommends $FONT_PACKAGES_GROUP3 2>/dev/null || print_warn "备用字体安装跳过"
    
    # 尝试安装可选字体包 (逐个安装，避免失败)
    if [ -n "$OPTIONAL_FONTS" ]; then
        print_msg "安装扩展字体..."
        for font_pkg in $OPTIONAL_FONTS; do
            apt-get install -y --no-install-recommends $font_pkg 2>/dev/null || true
        done
    fi
    
    print_msg "更新字体缓存..."
    fc-cache -fv >/dev/null 2>&1 || print_warn "字体缓存更新失败"
    
    print_msg "检查已安装字体..."
    fc-list :lang=zh >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        FONT_COUNT=$(fc-list :lang=zh | wc -l)
        print_msg "已安装 $FONT_COUNT 个中文字体"
    else
        print_warn "无法检测已安装的中文字体"
    fi
    
    print_msg "中文字体安装完成"
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
    
    # 检查 foo2zjs 驱动状态
    if [ -f /usr/share/foo2zjs/foo2zjs ]; then
        print_msg "foo2zjs 驱动: ✓ 已安装"
        print_msg "  支持的打印机型号包括:"
        print_msg "  - HP LaserJet: 1000/1005/1010/1015/1020/1025/P1005/P1006/P1007/P1008/P1505/P1505n"
        print_msg "  - HP LaserJet: 2200/2300/2410/2420/2430"
        print_msg "  - Minolta: 2300/2400"
        print_msg "  - Samsung: ML-2010/ML-2250"
    else
        print_warn "foo2zjs 驱动: ✗ 未安装"
    fi
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

cleanup_cache() {
    print_step "清理缓存节省空间"
    print_msg "清理 apt 缓存..."
    apt-get clean
    apt-get autoclean
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /var/lib/apt/lists/*
    rm -rf /tmp/* 2>/dev/null || true
    rm -rf /var/tmp/* 2>/dev/null || true
    find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
    find /var/log -type f -name "*.1" -delete 2>/dev/null || true
    print_msg "缓存清理完成"
}

show_summary() {
    print_step "安装完成"
    echo ""
    echo "============================================"
    echo "             打印客户端安装完成!"
    echo "============================================"
    echo ""
    echo "安装目录: $INSTALL_DIR"
    echo "日志文件: $LOG_FILE"
    echo "服务名称: $SERVICE_NAME"
    echo ""
    echo "CUPS完整版组件验证:"
    command -v lpstat &> /dev/null && echo "  ✓ CUPS 核心服务" || echo "  ✗ CUPS 核心服务"
    dpkg -l cups-filters 2>/dev/null | grep -q "^ii" && echo "  ✓ CUPS 过滤器" || echo "  ✗ CUPS 过滤器"
    command -v gs &> /dev/null && echo "  ✓ Ghostscript (PDF处理)" || echo "  ✗ Ghostscript"
    command -v qpdf &> /dev/null && echo "  ✓ QPDF (PDF工具)" || echo "  ✗ QPDF"
    command -v convert &> /dev/null && echo "  ✓ ImageMagick (图像处理)" || echo "  ✗ ImageMagick"
    command -v pdfjam &> /dev/null && echo "  ✓ PDFJam (PDF处理)" || echo "  ✗ PDFJam"
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
    echo "当前服务状态:"
    systemctl status $SERVICE_NAME --no-pager -l | head -10
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${GREEN}  使用说明${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo "1. 微信扫描下方二维码进入打印小程序"
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
    print_step "卸载打印客户端"
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

update_client() {
    print_step "更新打印客户端"
    
    # 备份当前文件
    if [ -f "$INSTALL_DIR/printer_client.php" ]; then
        cp "$INSTALL_DIR/printer_client.php" "$INSTALL_DIR/printer_client.php.bak"
        print_msg "已备份 printer_client.php"
    fi
    
    # 下载新的 printer_client.php
    print_msg "下载 printer_client.php..."
    DOWNLOAD_URL="${REMOTE_BASE_URL}/download.php?f=printer_client.php"
    if curl -sSL -o "$INSTALL_DIR/printer_client.php.new" "$DOWNLOAD_URL"; then
        if head -1 "$INSTALL_DIR/printer_client.php.new" | grep -q "^#!/usr/bin/env php"; then
            mv "$INSTALL_DIR/printer_client.php.new" "$INSTALL_DIR/printer_client.php"
            chmod +x "$INSTALL_DIR/printer_client.php"
            print_msg "✓ printer_client.php 更新成功"
        else
            print_error "✗ printer_client.php 下载内容异常"
            rm -f "$INSTALL_DIR/printer_client.php.new"
            if [ -f "$INSTALL_DIR/printer_client.php.bak" ]; then
                mv "$INSTALL_DIR/printer_client.php.bak" "$INSTALL_DIR/printer_client.php"
                print_msg "已恢复备份"
            fi
            return 1
        fi
    else
        print_error "✗ printer_client.php 下载失败"
        return 1
    fi
    
    # 下载新的 cupsd.conf
    print_msg "下载 cupsd.conf..."
    CUPSD_URL="${REMOTE_BASE_URL}/cupsd.conf"
    if curl -sSL -o "/etc/cups/cupsd.conf.new" "$CUPSD_URL"; then
        if head -5 "/etc/cups/cupsd.conf.new" | grep -q "CUPS\|LogLevel\|Port"; then
            cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
            mv /etc/cups/cupsd.conf.new /etc/cups/cupsd.conf
            chmod 644 /etc/cups/cupsd.conf
            print_msg "✓ cupsd.conf 更新成功"
        else
            print_error "✗ cupsd.conf 下载内容异常"
            rm -f /etc/cups/cupsd.conf.new
        fi
    else
        print_warn "cupsd.conf 下载失败，保持原配置"
    fi
    
    # 重启服务
    print_msg "重启 CUPS 服务..."
    systemctl restart cups
    if systemctl is-active --quiet cups; then
        print_msg "✓ CUPS 服务重启成功"
    else
        print_error "✗ CUPS 服务重启失败"
    fi
    
    print_msg "重启打印客户端服务..."
    systemctl restart $SERVICE_NAME
    sleep 2
    if systemctl is-active --quiet $SERVICE_NAME; then
        print_msg "✓ 打印客户端服务重启成功"
    else
        print_error "✗ 打印客户端服务重启失败"
        tail -10 $LOG_FILE
    fi
    
    # 显示版本信息
    if [ -f "$INSTALL_DIR/printer_client.php" ]; then
        VERSION=$(grep -oP "define\s*\(\s*'CLIENT_VERSION'\s*,\s*'\K[^']+" "$INSTALL_DIR/printer_client.php" 2>/dev/null || echo "未知")
        print_msg "当前版本: $VERSION"
    fi
    
    print_msg "更新完成!"
}

show_menu() {
    echo ""
    echo "============================================"
    echo "    打印客户端安装脚本 有问题联系V：nmydzf"
    echo "============================================"
    echo ""
    echo "  1. 完整安装 (首次安装必须用这个)"
    echo "  2. 仅安装依赖"
    echo "  3. 仅配置客户端"
    echo "  4. 检测打印机"
    echo "  5. 添加打印机"
    echo "  6. 生成设备二维码"
    echo "  7. 查看服务状态"
    echo "  8. 更新程序"
    echo "  9. 卸载"
    echo "  0. 退出"
    echo ""
    read -p "请选择 [0-9]: " MENU_CHOICE
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
            update_client
            ;;
        9)
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
    install_fonts
    install_websocket_client
    configure_server
    configure_device_id
    create_service
    cleanup_cache
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
        --update|-U)
            check_root
            update_client
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
            echo "  --update, -U     更新程序"
            echo "  --uninstall, -u  卸载"
            echo "  --status, -s     查看状态"
            echo "  --help, -h       显示帮助"
            echo ""
            echo "支持的打印机驱动:"
            echo "  - Gutenprint (通用)"
            echo "  - HPLIP (HP 打印机)"
            echo "  - SpliX (Samsung/Xerox)"
            echo "  - BRLaser (Lenovo/Brother)"
            echo "  - ESCPR (Epson)"
            echo "  - foo2zjs (HP LaserJet/Minolta/Samsung 激光打印机)"
            echo ""
            echo "foo2zjs 支持的主要型号:"
            echo "  - HP LaserJet: 1000/1005/1010/1015/1020/1025/P1005/P1006/P1007/P1008"
            echo "  - HP LaserJet: P1505/P1505n/2200/2300/2410/2420/2430"
            echo "  - Minolta: 2300/2400"
            echo "  - Samsung: ML-2010/ML-2250"
            echo ""
            echo "无参数时显示交互菜单"
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"
