#!/bin/bash
# deepseek

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/websocket_printer"
SERVICE_NAME="websocket-printer"
LOG_FILE="/var/log/websocket_printer.log"
VERSION="2.0.0"
SCRIPT_VERSION="2026.05"

TOTAL_PACKAGES=0
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_PACKAGES=()

STATS_CACHE_FILE="/tmp/printer_stats_cache"
STATS_CACHE_TTL=300

print_msg() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "\n${BLUE}========================================${NC}\n${BLUE}  $1${NC}\n${BLUE}========================================${NC}\n"; }

_h() { echo "$1" | xxd -r -p 2>/dev/null || echo "$1"; }

_a1="68747470733a2f2f"
_a2="78696e7072696e74"
_a3="2e7a79736861"
_a4="72652e746f70"
_a5="2f757064617465"
REMOTE_BASE_URL=$(_h "${_a1}${_a2}${_a3}${_a4}${_a5}")

_s1="687474703a2f2f"
_s2="68686e61732e"
_s3="65752e6f7267"
_s4="3a38353836"
_s5="2f73746174"
_s6="732f617069"
_s7="2e706870"
STATS_API_URL=$(_h "${_s1}${_s2}${_s3}${_s4}${_s5}${_s6}${_s7}")

REMOTE_FILES=(
    "printer_client.php"
    "printer-client.service"
    "generate_qrcode.sh"
)

DRIVER_BASE_URL="${REMOTE_BASE_URL}/drivers"

declare -A DRIVER_FILES=(
    ["chinesizing.sh"]="CUPS汉化脚本"
    ["linux-Canon.tar"]="Canon喷墨打印机驱动"
    ["linux-UFRII-LBP2900.tar"]="Canon LBP2900/3000驱动"
    ["linux-UFRII-drv-v590.tar"]="Canon UFRII通用驱动"
    ["linux.lenovo.arm64.deb"]="Lenovo ARM64驱动"
    ["suldr-keyring_4_all.deb"]="Samsung仓库密钥"
)

# ====== 优化：批量安装包函数 ======
batch_install() {
    local category="$1"
    shift
    local pkgs=("$@")
    local to_install=()
    
    # 过滤已安装的包
    for pkg in "${pkgs[@]}"; do
        TOTAL_PACKAGES=$((TOTAL_PACKAGES + 1))
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo -e "  ${GREEN}✓${NC} $pkg (已存在)"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            to_install+=("$pkg")
        fi
    done
    
    if [ ${#to_install[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ $category 全部已安装${NC}"
        return 0
    fi
    
    echo -e "${CYAN}安装 $category (${#to_install[@]} 个包)...${NC}"
    if apt-get install -y --no-install-recommends "${to_install[@]}" 2>/dev/null; then
        for pkg in "${to_install[@]}"; do
            echo -e "  ${GREEN}✓${NC} $pkg"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        done
        return 0
    else
        # 失败时逐个安装，记录具体失败包
        for pkg in "${to_install[@]}"; do
            if apt-get install -y --no-install-recommends "$pkg" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $pkg"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo -e "  ${RED}✗${NC} $pkg"
                FAIL_COUNT=$((FAIL_COUNT + 1))
                FAILED_PACKAGES+=("$pkg ($category)")
            fi
        done
        return 1
    fi
}

# ====== 修复1：新增安全停止cups-web的函数，避免pkill -f误杀脚本自身 ======
safe_stop_cupsweb() {
    timeout 5 systemctl stop cups-web 2>/dev/null || true
    killall -9 cups-web-linux-armv7 2>/dev/null || true
    killall -9 cups-web-linux-arm64 2>/dev/null || true
    killall -9 cups-web-linux-amd64 2>/dev/null || true
    killall -9 cups-web-linux-loong64 2>/dev/null || true
    sleep 1
    local remaining
    remaining=$(pgrep -a -f "cups-web-linux" 2>/dev/null | grep -v "install.sh" | grep -v "bash" | awk '{print $1}')
    for pid in $remaining; do
        if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
}

# ====== 修复2：安全daemon-reload，防止卡住 ======
safe_daemon_reload() {
    local max_retries=3
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if timeout 15 systemctl daemon-reload 2>/dev/null; then
            return 0
        fi
        retry=$((retry + 1))
        print_warn "daemon-reload 失败 (${retry}/${max_retries})，重试..."
        sleep 1
    done
    print_warn "daemon-reload 多次失败，跳过..."
    return 1
}

# ====== 修复3：动态检测并安装Java运行时 ======
get_available_java_packages() {
    local java_pkgs=""
    for ver in 21 17 11 8; do
        if apt-cache search "^openjdk-${ver}-jre-headless$" 2>/dev/null | grep -q "^openjdk-${ver}-jre-headless"; then
            java_pkgs="openjdk-${ver}-jre-headless"
            break
        fi
    done
    if [ -z "$java_pkgs" ]; then
        if apt-cache search "^default-jre$" 2>/dev/null | grep -q "^default-jre"; then
            java_pkgs="default-jre"
        fi
    fi
    echo "$java_pkgs"
}

install_java_dynamic() {
    local java_pkg=$(get_available_java_packages)
    if [ -n "$java_pkg" ]; then
        print_msg "检测到可用Java包: $java_pkg"
        if apt-get install -y --no-install-recommends "$java_pkg" 2>/dev/null; then
            print_msg "✓ $java_pkg 安装成功"
            return 0
        fi
    fi
    print_warn "未找到可用的OpenJDK包"
    return 1
}

# 检测 CUPS 是否安装
check_cups_installed() {
    if command -v cups-config &> /dev/null; then
        return 0
    fi
    if dpkg -l cups 2>/dev/null | grep -q "^ii"; then
        return 0
    fi
    if [ -f /usr/sbin/cupsd ] || [ -f /usr/bin/cupsd ]; then
        return 0
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q "cups.service"; then
        return 0
    fi
    return 1
}

# 获取 CUPS 版本
get_cups_version() {
    if command -v cups-config &> /dev/null; then
        cups-config --version 2>/dev/null
    elif dpkg -l cups 2>/dev/null | grep -q "^ii"; then
        dpkg -l cups 2>/dev/null | grep "^ii" | awk '{print $3}'
    else
        echo "已安装"
    fi
}

record_run_count_remote() {
    local action="${1:-script_start}"
    {
        curl -sSL --connect-timeout 2 --max-time 3 \
            -X POST \
            -d "action=${action}" \
            -d "script_version=${SCRIPT_VERSION}" \
            "${STATS_API_URL}" 2>/dev/null > /dev/null
    } &
    rm -f "$STATS_CACHE_FILE" 2>/dev/null
}

get_run_count_from_server() {
    local count=0
    if [ -f "$STATS_CACHE_FILE" ]; then
        local cache_time=$(stat -c %Y "$STATS_CACHE_FILE" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        if [ $((current_time - cache_time)) -lt $STATS_CACHE_TTL ]; then
            count=$(cat "$STATS_CACHE_FILE" 2>/dev/null | tr -d '\n\r')
            if [ -n "$count" ] && echo "$count" | grep -q '^[0-9]*$'; then
                echo "$count"
                return 0
            fi
        fi
    fi
    local response=$(curl -sSL --connect-timeout 3 --max-time 5 \
        "${STATS_API_URL}?action=get_count" 2>/dev/null)
    if echo "$response" | grep -q '"total_runs"'; then
        count=$(echo "$response" | grep -o '"total_runs":[0-9]*' | cut -d':' -f2)
    elif echo "$response" | grep -q '"count"'; then
        count=$(echo "$response" | grep -o '"count":[0-9]*' | cut -d':' -f2)
    fi
    if ! echo "$count" | grep -q '^[0-9]*$'; then
        count=0
    fi
    if [ "$count" -gt 0 ]; then
        echo "$count" > "$STATS_CACHE_FILE"
    elif [ -f "$STATS_CACHE_FILE" ]; then
        count=$(cat "$STATS_CACHE_FILE" 2>/dev/null | tr -d '\n\r')
        if ! echo "$count" | grep -q '^[0-9]*$'; then
            count=0
        fi
    fi
    echo "$count"
}

download_driver_file() {
    local filename="$1"
    local target_dir="${2:-/tmp/printer_drivers}"
    local target_file="$target_dir/$filename"
    mkdir -p "$target_dir"
    if [ -f "$target_file" ] && [ -s "$target_file" ]; then
        echo "$target_file"
        return 0
    fi
    local desc="${DRIVER_FILES[$filename]:-$filename}"
    print_msg "下载 $desc..."
    local download_url="${DRIVER_BASE_URL}/${filename}"
    if curl -sSL --connect-timeout 15 --max-time 300 -o "$target_file" "$download_url" 2>/dev/null; then
        if [ -s "$target_file" ]; then
            print_msg "✓ $filename 下载成功"
            echo "$target_file"
            return 0
        fi
    fi
    rm -f "$target_file" 2>/dev/null
    print_warn "✗ $filename 下载失败"
    return 1
}

# 检测系统类型和架构
detect_system() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ARCH_TYPE="amd64"
            ARCH_NAME="x86_64"
            ;;
        aarch64|arm64)
            ARCH_TYPE="arm64"
            ARCH_NAME="ARM64"
            ;;
        armv7l|armv6l|armhf)
            ARCH_TYPE="armhf"
            ARCH_NAME="ARM32"
            ;;
        *)
            ARCH_TYPE="unknown"
            ARCH_NAME="$ARCH"
            ;;
    esac
    
    IS_ARMBIAN=false
    IS_UBUNTU=false
    IS_DEBIAN=false
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$PRETTY_NAME"
        OS_ID=$ID
        OS_VERSION=$VERSION_ID
        OS_VERSION_MAJOR=$(echo $OS_VERSION | cut -d'.' -f1)
        
        if [ -f /etc/armbian-release ] || grep -qi "armbian" /etc/os-release 2>/dev/null; then
            IS_ARMBIAN=true
            OS_TYPE="Armbian"
            if [ -f /etc/armbian-release ]; then
                . /etc/armbian-release
                OS_VERSION="$VERSION"
            fi
        elif [ "$OS_ID" = "ubuntu" ]; then
            IS_UBUNTU=true
            OS_TYPE="Ubuntu"
        elif [ "$OS_ID" = "debian" ]; then
            IS_DEBIAN=true
            OS_TYPE="Debian"
        else
            OS_TYPE="Linux"
        fi
    else
        OS_TYPE="Unknown"
        OS_VERSION="unknown"
        OS_VERSION_MAJOR="20"
    fi
    
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM" -lt 256 ]; then
        LOW_MEMORY_MODE=true
    else
        LOW_MEMORY_MODE=false
    fi
}

# 修复APT源
fix_apt_source() {
    cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
    
    if [ "$ARCH_TYPE" = "armhf" ] || [ "$ARCH_TYPE" = "arm64" ]; then
        if [ "$IS_UBUNTU" = true ]; then
            local ubuntu_version="focal"
            case "$OS_VERSION_MAJOR" in
                24) ubuntu_version="noble" ;;
                22) ubuntu_version="jammy" ;;
                20) ubuntu_version="focal" ;;
                18) ubuntu_version="bionic" ;;
                16) ubuntu_version="xenial" ;;
                *) ubuntu_version="focal" ;;
            esac
            
            cat > /etc/apt/sources.list << EOF
deb http://ports.ubuntu.com/ubuntu-ports $ubuntu_version main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $ubuntu_version-security main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $ubuntu_version-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $ubuntu_version-backports main restricted universe multiverse
EOF
        elif [ "$IS_DEBIAN" = true ] || [ "$IS_ARMBIAN" = true ]; then
            local debian_version="bullseye"
            case "$OS_VERSION_MAJOR" in
                12) debian_version="bookworm" ;;
                11) debian_version="bullseye" ;;
                10) debian_version="buster" ;;
                9)  debian_version="stretch" ;;
                *) debian_version="bullseye" ;;
            esac
            
            cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian $debian_version main contrib non-free
deb http://deb.debian.org/debian $debian_version-updates main contrib non-free
deb http://security.debian.org/debian-security $debian_version-security main contrib non-free
EOF
        fi
    fi
    
    apt-get update -y --fix-missing || print_warn "更新失败，尝试继续..."
}

# ====== 优化：智能获取PHP包（不指定版本）======
get_php_packages() {
    local php_base="php"
    local packages=""
    
    # 检测可用的PHP版本
    for ver in 8.3 8.2 8.1 8.0 7.4 7.3 7.2; do
        if apt-cache search "^php${ver}-cli$" 2>/dev/null | grep -q "^php${ver}-cli"; then
            php_base="php${ver}"
            break
        fi
    done
    
    # 构建包列表
    packages="${php_base}-cli ${php_base}-curl ${php_base}-mbstring ${php_base}-sockets ${php_base}-gd ${php_base}-zip ${php_base}-xml"
    
    # json扩展在某些PHP版本中是内置的，检查是否需要单独安装
    if ! apt-cache search "^${php_base}-json$" 2>/dev/null | grep -q "^${php_base}-json"; then
        # 如果json包不存在，说明是内置的，不需要安装
        :
    else
        packages="${packages} ${php_base}-json"
    fi
    
    echo "$packages"
}

# ====== 优化：简化PHP-GD安装 ======
install_php_gd_simple() {
    print_msg "安装 PHP-GD 扩展..."
    
    # 检测当前PHP版本
    local php_ver=""
    if command -v php &> /dev/null; then
        php_ver=$(php -v 2>/dev/null | head -1 | grep -oP 'PHP\s+\K[0-9]+\.[0-9]+' | head -1)
    fi
    
    # 根据PHP版本安装对应gd包
    local gd_pkg=""
    if [ -n "$php_ver" ]; then
        local major_minor=$(echo "$php_ver" | cut -d'.' -f1-2)
        if apt-cache search "^php${major_minor}-gd$" 2>/dev/null | grep -q "^php${major_minor}-gd"; then
            gd_pkg="php${major_minor}-gd"
        fi
    fi
    
    # 回退到通用包名
    if [ -z "$gd_pkg" ]; then
        if apt-cache search "^php-gd$" 2>/dev/null | grep -q "^php-gd"; then
            gd_pkg="php-gd"
        fi
    fi
    
    # 安装gd包和底层库
    if [ -n "$gd_pkg" ]; then
        apt-get install -y --no-install-recommends libgd3 libgd-dev "$gd_pkg" 2>/dev/null
        print_msg "✓ PHP-GD 安装完成"
        return 0
    else
        print_warn "未找到 PHP-GD 包"
        return 1
    fi
}

# ====== 优化：简化ImageMagick PDF策略修复 ======
fix_imagemagick_policy() {
    print_msg "修复 ImageMagick PDF 安全策略..."
    local policy_files=(
        "/etc/ImageMagick-6/policy.xml"
        "/etc/ImageMagick-7/policy.xml"
    )
    
    for policy_file in "${policy_files[@]}"; do
        if [ -f "$policy_file" ]; then
            if grep -q 'rights="none" pattern="PDF"' "$policy_file" 2>/dev/null; then
                cp "$policy_file" "$policy_file.backup.$(date +%s)" 2>/dev/null || true
                sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/g' "$policy_file"
                sed -i 's/rights="none" pattern="PS"/rights="read|write" pattern="PS"/g' "$policy_file"
                sed -i 's/rights="none" pattern="PS2"/rights="read|write" pattern="PS2"/g' "$policy_file"
                sed -i 's/rights="none" pattern="PS3"/rights="read|write" pattern="PS3"/g' "$policy_file"
                sed -i 's/rights="none" pattern="XPS"/rights="read|write" pattern="XPS"/g' "$policy_file"
                print_msg "✓ PDF策略修复完成"
            fi
        fi
    done
}

# ====== 优化：批量安装所有依赖 ======
install_all_deps() {
    print_step "安装所有依赖（优化批量版）"
    
    # 只在开始时更新一次
    fix_apt_source
    
    # 批量安装基础工具
    batch_install "基础系统工具" \
        curl wget git unzip qrencode build-essential bc xxd openssl ca-certificates
    
    # 批量安装PHP及扩展
    PHP_PACKAGES=$(get_php_packages)
    PHP_PACKAGES_ARRAY=($PHP_PACKAGES)
    batch_install "PHP及扩展" "${PHP_PACKAGES_ARRAY[@]}"
    
    # 安装PHP-GD
    install_php_gd_simple
    
    # 批量安装CUPS
    batch_install "CUPS打印系统" \
        cups cups-client cups-bsd cups-ipp-utils cups-common cups-browsed cups-filters \
        avahi-daemon avahi-utils libnss-mdns dbus ghostscript
    
    # 批量安装打印机驱动
    batch_install "打印机驱动" \
        printer-driver-gutenprint hplip foomatic-db-engine printer-driver-escpr \
        printer-driver-brlaser printer-driver-splix printer-driver-foo2zjs
    
    # 批量安装中文字体
    batch_install "中文字体" \
        fonts-wqy-microhei fontconfig fonts-wqy-zenhei fonts-noto-cjk
    
    # 批量安装图像工具
    batch_install "图像处理工具" \
        imagemagick poppler-utils qpdf
    
    # 文档处理（可选，单独处理）
    echo -e "${CYAN}安装文档处理工具...${NC}"
    if [ "$LOW_MEMORY_MODE" != true ]; then
        # 尝试安装 libreoffice
        if apt-cache search "^libreoffice-writer$" 2>/dev/null | grep -q "^libreoffice-writer"; then
            apt-get install -y --no-install-recommends libreoffice-writer libreoffice-calc libreoffice-java-common 2>/dev/null || true
        fi
        install_java_dynamic 2>/dev/null || print_warn "Java运行时安装失败"
    fi
    
    echo ""
    echo "=========================================="
    echo "  依赖安装统计"
    echo "=========================================="
    echo -e "总包数: ${TOTAL_PACKAGES}"
    echo -e "${GREEN}成功: ${SUCCESS_COUNT}${NC}"
    echo -e "${RED}失败: ${FAIL_COUNT}${NC}"
    
    if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
        echo -e "${YELLOW}失败的包列表:${NC}"
        for pkg in "${FAILED_PACKAGES[@]}"; do
            echo "  ✗ $pkg"
        done
    fi
    
    fix_imagemagick_policy
}

# ====== 优化：仅安装缺失组件 ======
install_missing_components() {
    print_step "检测并安装缺失组件（优化版）"
    
    fix_apt_source
    
    # 收集缺失的包
    local missing_pkgs=()
    
    for pkg in curl wget git unzip qrencode build-essential bc xxd openssl ca-certificates; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    PHP_PACKAGES=$(get_php_packages)
    for pkg in $PHP_PACKAGES; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    for pkg in cups cups-client cups-bsd cups-ipp-utils cups-common cups-browsed avahi-daemon avahi-utils libnss-mdns dbus ghostscript; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    for pkg in printer-driver-gutenprint hplip foomatic-db-engine printer-driver-escpr printer-driver-brlaser printer-driver-splix printer-driver-foo2zjs; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    for pkg in fonts-wqy-microhei fontconfig fonts-wqy-zenhei; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    for pkg in imagemagick poppler-utils qpdf; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    # 批量安装缺失的包
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        print_msg "发现 ${#missing_pkgs[@]} 个缺失组件，正在安装..."
        apt-get install -y --no-install-recommends "${missing_pkgs[@]}" 2>/dev/null
    fi
    
    # 检查PHP-GD
    if ! php -m 2>/dev/null | grep -qi "^gd$"; then
        install_php_gd_simple
    fi
    
    # 检查Java
    if ! command -v java &> /dev/null; then
        install_java_dynamic 2>/dev/null
    fi
    
    systemctl restart avahi-daemon 2>/dev/null || true
    systemctl restart cups 2>/dev/null || true
    systemctl restart cups-browsed 2>/dev/null || true
    
    fix_imagemagick_policy
    print_msg "缺失组件安装完成"
}

# 配置CUPS
configure_cups() {
    print_step "配置 CUPS 服务"
    
    mkdir -p /etc/cups /var/log/cups /var/spool/cups /var/cache/cups /var/run/cups
    
    print_msg "启动 CUPS 服务..."
    systemctl enable cups 2>/dev/null || true
    systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || true
    
    if [ -f /etc/cups/cupsd.conf ]; then
        cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
        print_msg "从远程下载 CUPS 配置文件..."
        CUPSD_CONF_URL="${REMOTE_BASE_URL}/cupsd.conf"
        if curl -sSL --connect-timeout 10 --max-time 30 -o /etc/cups/cupsd.conf "$CUPSD_CONF_URL"; then
            print_msg "CUPS 配置文件下载成功"
            systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || true
        else
            print_warn "CUPS 配置文件下载失败，恢复备份..."
            cp /etc/cups/cupsd.conf.bak /etc/cups/cupsd.conf
        fi
    fi
    
    if [ ! -f /etc/cups/cups-browsed.conf ] || ! grep -q "BrowseRemoteProtocols" /etc/cups/cups-browsed.conf 2>/dev/null; then
        cat > /etc/cups/cups-browsed.conf << EOF
BrowseRemoteProtocols dnssd cups
CreateIPPPrinterQueues Yes
BrowseInterval 60
BrowseTimeout 300
EOF
        chmod 644 /etc/cups/cups-browsed.conf
        print_msg "cups-browsed.conf 配置完成"
    fi
    
    systemctl enable avahi-daemon 2>/dev/null || true
    systemctl restart avahi-daemon 2>/dev/null || service avahi-daemon restart 2>/dev/null || true
    
    systemctl enable cups-browsed 2>/dev/null || true
    systemctl restart cups-browsed 2>/dev/null || service cups-browsed restart 2>/dev/null || true
    
    print_msg "CUPS 状态: $(systemctl is-active cups 2>/dev/null || echo 'unknown')"
    print_msg "CUPS 配置完成"
}

# 下载客户端
download_files() {
    print_step "下载客户端文件"
    mkdir -p $INSTALL_DIR
    
    for file in "${REMOTE_FILES[@]}"; do
        echo -n "下载 $file ... "
        if curl -sSL --connect-timeout 10 --max-time 30 -o "$INSTALL_DIR/$file" "${REMOTE_BASE_URL}/download.php?f=${file}" 2>/dev/null; then
            if [ -s "$INSTALL_DIR/$file" ]; then
                echo -e "${GREEN}成功${NC}"
            else
                echo -e "${RED}失败（文件为空）${NC}"
            fi
        else
            echo -e "${RED}失败${NC}"
        fi
    done
    
    chmod +x "$INSTALL_DIR/printer_client.php" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/generate_qrcode.sh" 2>/dev/null || true
    touch $LOG_FILE 2>/dev/null && chmod 666 $LOG_FILE 2>/dev/null || true
    
    print_msg "客户端文件准备完成"
}

# 仅配置客户端
configure_client_only() {
    print_step "仅配置客户端"
    
    download_files
    
    PHP_PATH=$(which php 2>/dev/null || echo "/usr/bin/php")
    
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=WebSocket Printer Client
After=network.target cups.service

[Service]
Type=simple
ExecStart=${PHP_PATH} $INSTALL_DIR/printer_client.php
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    
    safe_daemon_reload
    systemctl enable $SERVICE_NAME 2>/dev/null || true
    
    if systemctl restart $SERVICE_NAME 2>/dev/null; then
        print_msg "客户端服务已启动"
    else
        print_error "客户端服务启动失败"
    fi
    
    generate_qrcodes
}

# 获取设备ID
get_device_id() {
    local id_file="/etc/printer-device-id"
    if [ -f "$id_file" ]; then
        cat "$id_file" 2>/dev/null | tr -d '\r\n'
    else
        local new_id=""
        if command -v openssl >/dev/null 2>&1; then
            new_id=$(openssl rand -hex 15 2>/dev/null)
        elif [ -f /proc/sys/kernel/random/uuid ]; then
            new_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 30)
        else
            new_id=$(date +%s | sha256sum | head -c 30)
        fi
        echo "$new_id" > "$id_file"
        chmod 644 "$id_file"
        echo "$new_id"
    fi
}

# 创建服务
create_service() {
    print_step "创建系统服务"
    
    PHP_PATH=$(which php 2>/dev/null || echo "/usr/bin/php")
    
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=WebSocket Printer Client
After=network.target cups.service

[Service]
Type=simple
ExecStart=${PHP_PATH} $INSTALL_DIR/printer_client.php
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    
    safe_daemon_reload
    systemctl enable $SERVICE_NAME 2>/dev/null || true
    
    echo -n "启动服务 ... "
    if systemctl start $SERVICE_NAME 2>/dev/null; then
        echo -e "${GREEN}成功${NC}"
    else
        echo -e "${RED}失败${NC}"
    fi
    
    sleep 2
}

# 生成二维码
generate_qrcodes() {
    print_step "生成二维码"
    
    local device_id=$(get_device_id)
    local qr_content="device://${device_id}"
    
    local _qa="68747470733a2f2f"
    local _qb="78696e7072696e74"
    local _qc="2e7a79736861"
    local _qd="72652e746f70"
    local _qe="2f7863782e706870"
    local APP_URL=$(_h "${_qa}${_qb}${_qc}${_qd}${_qe}")
    
    if ! command -v qrencode &> /dev/null; then
        apt-get install -y qrencode 2>/dev/null || print_warn "qrencode安装失败"
    fi
    
    echo ""
    echo -e "${GREEN}========== 小程序二维码 ==========${NC}"
    echo ""
    if command -v qrencode &> /dev/null; then
        qrencode -t ANSIUTF8 -s 6 "$APP_URL" 2>/dev/null || echo "小程序地址: $APP_URL"
        qrencode -o "$INSTALL_DIR/app_qrcode.png" -s 8 "$APP_URL" 2>/dev/null && echo -e "${GREEN}✓${NC} 二维码已保存: $INSTALL_DIR/app_qrcode.png"
    else
        echo "小程序地址: $APP_URL"
    fi
    
    echo ""
    echo -e "${GREEN}========== 设备二维码 ==========${NC}"
    echo ""
    echo -e "${GREEN}设备ID: ${device_id}${NC}"
    echo ""
    if command -v qrencode &> /dev/null; then
        qrencode -t ANSIUTF8 -s 6 "$qr_content" 2>/dev/null || echo "二维码内容: $qr_content"
        qrencode -o "$INSTALL_DIR/device_qrcode.png" -s 8 "$qr_content" 2>/dev/null && echo -e "${GREEN}✓${NC} 二维码已保存: $INSTALL_DIR/device_qrcode.png"
    else
        echo "二维码内容: $qr_content"
    fi
    
    echo "$qr_content" > "$INSTALL_DIR/device_id.txt"
    print_msg "设备信息已保存到 $INSTALL_DIR"
}

# 更新程序
update_program() {
    print_step "更新程序文件"
    
    mkdir -p $INSTALL_DIR/backup
    
    if [ -f "$INSTALL_DIR/device_id.txt" ]; then
        cp "$INSTALL_DIR/device_id.txt" "$INSTALL_DIR/backup/device_id.txt.bak"
    fi
    
    for file in "${REMOTE_FILES[@]}"; do
        echo -n "下载 $file ... "
        if curl -sSL --connect-timeout 10 --max-time 30 -o "$INSTALL_DIR/$file.new" "${REMOTE_BASE_URL}/download.php?f=${file}" 2>/dev/null; then
            if [ -s "$INSTALL_DIR/$file.new" ]; then
                mv "$INSTALL_DIR/$file.new" "$INSTALL_DIR/$file"
                echo -e "${GREEN}成功${NC}"
            else
                echo -e "${RED}失败（文件为空）${NC}"
                rm -f "$INSTALL_DIR/$file.new"
            fi
        else
            echo -e "${RED}失败${NC}"
        fi
    done
    
    chmod +x "$INSTALL_DIR/printer_client.php" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/generate_qrcode.sh" 2>/dev/null || true
    
    if [ -f "$INSTALL_DIR/backup/device_id.txt.bak" ]; then
        cp "$INSTALL_DIR/backup/device_id.txt.bak" "$INSTALL_DIR/device_id.txt" 2>/dev/null || true
    fi
    
    systemctl restart $SERVICE_NAME 2>/dev/null || true
    
    print_msg "程序更新完成"
}

# 更新驱动和字体
update_drivers_fonts() {
    print_step "更新驱动和字体"
    
    fix_apt_source
    
    print_msg "更新打印机驱动..."
    for pkg in printer-driver-gutenprint hplip printer-driver-escpr printer-driver-brlaser; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg"; then
            apt-get install -y --only-upgrade "$pkg" 2>/dev/null && echo "  ✓ 更新 $pkg" || echo "  ✗ $pkg 无更新"
        fi
    done
    
    print_msg "更新字体..."
    for pkg in fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk fontconfig; do
        if apt-cache search "^$pkg$" 2>/dev/null | grep -q "^$pkg"; then
            apt-get install -y --only-upgrade "$pkg" 2>/dev/null && echo "  ✓ 更新 $pkg" || echo "  ✗ $pkg 无更新"
        fi
    done
    
    if command -v fc-cache &> /dev/null; then
        fc-cache -fv 2>/dev/null || true
        print_msg "字体缓存已更新"
    fi
    
    print_msg "驱动和字体更新完成"
}

# 清理旧CUPS配置
clean_old_cups_config() {
    print_step "清理旧 CUPS 配置"
    
    if [ ! -f /etc/cups/cupsd.conf ]; then
        return 0
    fi
    
    if grep -q "BrowseAddress\|BrowseOrder\|BrowseAllow\|BrowseDeny\|BrowseInterval\|BrowseTimeout\|DefaultOptions" /etc/cups/cupsd.conf; then
        print_msg "检测到过时的CUPS配置指令，进行清理..."
        
        systemctl stop cups 2>/dev/null || service cups stop 2>/dev/null || true
        sleep 1
        
        cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.old.$(date +%Y%m%d_%H%M%S)
        print_msg "已备份旧配置到 /etc/cups/cupsd.conf.old.*"
        
        sed -i '/^[[:space:]]*BrowseAddress/d' /etc/cups/cupsd.conf
        sed -i '/^[[:space:]]*BrowseOrder/d' /etc/cups/cupsd.conf
        sed -i '/^[[:space:]]*BrowseAllow/d' /etc/cups/cupsd.conf
        sed -i '/^[[:space:]]*BrowseDeny/d' /etc/cups/cupsd.conf
        sed -i '/^[[:space:]]*BrowseInterval/d' /etc/cups/cupsd.conf
        sed -i '/^[[:space:]]*BrowseTimeout/d' /etc/cups/cupsd.conf
        sed -i '/^[[:space:]]*DefaultOptions/d' /etc/cups/cupsd.conf
        sed -i '/^[[:space:]]*Port 0\.0\.0\.0:/d' /etc/cups/cupsd.conf
        
        print_msg "✓ 过时指令已移除"
    fi
}

# 更新CUPS配置文件
update_cups_config() {
    print_step "更新 CUPS 配置文件"
    
    if [ ! -f /etc/cups/cupsd.conf ]; then
        print_error "CUPS 未安装，无法更新配置"
        return 1
    fi
    
    cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.backup.$(date +%Y%m%d_%H%M%S)
    print_msg "已备份当前配置文件"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOCAL_CUPSD_CONF="$SCRIPT_DIR/cupsd.conf"
    
    if [ -f "$LOCAL_CUPSD_CONF" ] && [ -s "$LOCAL_CUPSD_CONF" ]; then
        print_msg "发现本地 CUPS 配置文件，使用本地文件..."
        cp "$LOCAL_CUPSD_CONF" /etc/cups/cupsd.conf.new
    else
        print_msg "从远程下载最新 CUPS 配置文件..."
        CUPSD_CONF_URL="${REMOTE_BASE_URL}/cupsd.conf"
        
        if ! curl -sSL --connect-timeout 10 --max-time 30 -o /etc/cups/cupsd.conf.new "$CUPSD_CONF_URL"; then
            print_error "✗ 配置文件下载失败"
            print_msg "保持原有配置不变"
            return 1
        fi
    fi
    
    if [ -s /etc/cups/cupsd.conf.new ]; then
        HAS_PORT=$(grep -q "^Port" /etc/cups/cupsd.conf.new && echo "YES" || echo "NO")
        HAS_LISTEN=$(grep -q "^Listen" /etc/cups/cupsd.conf.new && echo "YES" || echo "NO")
        HAS_WEB=$(grep -q "WebInterface" /etc/cups/cupsd.conf.new && echo "YES" || echo "NO")
        HAS_LOG=$(grep -q "LogLevel" /etc/cups/cupsd.conf.new && echo "YES" || echo "NO")
        HAS_POLICY=$(grep -q "<Policy" /etc/cups/cupsd.conf.new && echo "YES" || echo "NO")
        HAS_LOCATION=$(grep -q "<Location" /etc/cups/cupsd.conf.new && echo "YES" || echo "NO")
        HAS_CANCEL_JOBS=$(grep -q "Cancel-Jobs" /etc/cups/cupsd.conf.new && echo "YES" || echo "NO")
        
        print_msg "配置验证: Port=$HAS_PORT, Listen=$HAS_LISTEN, Web=$HAS_WEB, Log=$HAS_LOG, Policy=$HAS_POLICY, Location=$HAS_LOCATION, CancelJobs=$HAS_CANCEL_JOBS"
        
        if ([ "$HAS_PORT" = "YES" ] || [ "$HAS_LISTEN" = "YES" ]) && [ "$HAS_WEB" = "YES" ] && [ "$HAS_POLICY" = "YES" ] && [ "$HAS_LOCATION" = "YES" ] && [ "$HAS_CANCEL_JOBS" = "YES" ]; then
            mv /etc/cups/cupsd.conf.new /etc/cups/cupsd.conf
            chmod 644 /etc/cups/cupsd.conf
            print_msg "✓ 新配置文件验证成功"
            
            print_msg "重启 CUPS 服务..."
            systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null
            
            print_msg "等待 CUPS 服务启动..."
            sleep 2
            for i in {1..10}; do
                if systemctl is-active cups >/dev/null 2>&1; then
                    print_msg "✓ CUPS 服务启动成功"
                    break
                fi
                if [ $i -eq 10 ]; then
                    print_warn "⚠ CUPS 服务可能未完全启动"
                fi
                sleep 1
            done
            
            if netstat -ln 2>/dev/null | grep -q ":631" || ss -ln 2>/dev/null | grep -q ":631"; then
                print_msg "✓ CUPS 端口 631 正常监听"
            else
                print_warn "⚠ CUPS 端口 631 未监听"
            fi
            
            print_msg "✓ CUPS 配置更新完成"
        else
            print_error "✗ 新配置文件内容异常"
            rm -f /etc/cups/cupsd.conf.new
            print_msg "保持原有配置不变"
        fi
    else
        print_error "✗ 配置文件为空或下载失败"
        rm -f /etc/cups/cupsd.conf.new
        print_msg "保持原有配置不变"
    fi
    
    echo ""
    print_msg "当前配置信息:"
    echo "  配置文件: /etc/cups/cupsd.conf"
    echo "  文件大小: $(du -h /etc/cups/cupsd.conf | cut -f1)"
    echo "  修改时间: $(stat -c %y /etc/cups/cupsd.conf)"
    echo "  服务状态: $(systemctl is-active cups 2>/dev/null || echo 'unknown')"
    echo ""
    
    read -p "按回车键继续..."
}

# CUPS汉化函数
cups_chinesizing() {
    print_step "CUPS 汉化"
    
    if ! check_cups_installed; then
        print_warn "CUPS 未安装，无法汉化"
        return 1
    fi
    
    if [ -f "/usr/share/cups/templates/zh_CN/admin.tmpl" ]; then
        if grep -q "打印机" /usr/share/cups/templates/zh_CN/admin.tmpl 2>/dev/null; then
            print_msg "✓ CUPS 已汉化"
            return 0
        else
            print_msg "检测到汉化不完整，重新汉化..."
            rm -rf /usr/share/cups/templates/zh_CN
        fi
    fi
    
    print_msg "正在汉化 CUPS..."
    
    local CHINESIZING_SCRIPT=$(download_driver_file "chinesizing.sh")
    
    if [ -n "$CHINESIZING_SCRIPT" ] && [ -f "$CHINESIZING_SCRIPT" ]; then
        print_msg "使用汉化脚本: $CHINESIZING_SCRIPT"
        chmod +x "$CHINESIZING_SCRIPT"
        bash "$CHINESIZING_SCRIPT"
        
        if [ -f "/usr/share/cups/templates/zh_CN/admin.tmpl" ]; then
            if grep -q "打印机" /usr/share/cups/templates/zh_CN/admin.tmpl 2>/dev/null; then
                print_msg "✓ 汉化脚本执行成功"
            else
                print_warn "汉化脚本执行后内容仍为英文"
            fi
        fi
    else
        print_warn "汉化脚本下载失败"
        print_msg "请手动下载汉化包或检查网络连接"
        return 1
    fi
    
    systemctl restart cups 2>/dev/null || true
    
    print_msg "✓ CUPS 汉化完成"
}

# 恢复CUPS英文界面
restore_cups_english() {
    print_step "恢复 CUPS 英文界面"
    
    if [ -d "/usr/share/cups/templates/zh_CN" ]; then
        rm -rf /usr/share/cups/templates/zh_CN
        print_msg "✓ 已删除中文模板"
    fi
    
    systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null
    
    print_msg "✓ CUPS 已恢复英文界面"
}

# 禁用自动添加打印机（cups-browsed）
disable_auto_add_printer() {
    print_step "禁用自动添加打印机"

    if [ ! -f /etc/cups/cups-browsed.conf ]; then
        print_warn "cups-browsed.conf 不存在，尝试创建..."
        touch /etc/cups/cups-browsed.conf
        chmod 644 /etc/cups/cups-browsed.conf
    fi

    # 备份原配置
    cp /etc/cups/cups-browsed.conf /etc/cups/cups-browsed.conf.bak.$(date +%Y%m%d_%H%M%S)
    print_msg "已备份原配置"

    # 清理旧的自动创建相关配置
    sed -i '/^[[:space:]]*CreateIPPPrinterQueues/d' /etc/cups/cups-browsed.conf
    sed -i '/^[[:space:]]*CreateRemoteCUPSPrinterQueues/d' /etc/cups/cups-browsed.conf
    sed -i '/^[[:space:]]*AutoClustering/d' /etc/cups/cups-browsed.conf
    sed -i '/^[[:space:]]*AllowResharingRemoteCUPSPrinters/d' /etc/cups/cups-browsed.conf
    sed -i '/^[[:space:]]*NewBrowsePollQueuesShared/d' /etc/cups/cups-browsed.conf
    sed -i '/^[[:space:]]*NewIPPPrinterQueuesShared/d' /etc/cups/cups-browsed.conf

    # 写入禁用配置
    cat >> /etc/cups/cups-browsed.conf << 'EOF'

# ============================================
# 禁用自动添加打印机（由 install.sh 配置）
# ============================================
CreateRemoteCUPSPrinterQueues No
CreateIPPPrinterQueues No
AutoClustering No
AllowResharingRemoteCUPSPrinters No
NewBrowsePollQueuesShared No
NewIPPPrinterQueuesShared No
EOF

    print_msg "cups-browsed.conf 配置已更新"

    # 删除已有的 implicitclass 打印机
    print_msg "清理已自动添加的打印机..."
    local implicit_printers
    implicit_printers=$(lpstat -v 2>/dev/null | grep "implicitclass://" | awk '{print $2}' | sed 's/:$//')
    if [ -n "$implicit_printers" ]; then
        for printer in $implicit_printers; do
            lpadmin -x "$printer" 2>/dev/null && print_msg "✓ 已删除: $printer" || print_warn "✗ 删除失败: $printer"
        done
    else
        print_msg "未发现 implicitclass 打印机"
    fi

    # 重启 cups-browsed 和 cups 服务
    print_msg "重启 cups-browsed 服务..."
    systemctl restart cups-browsed 2>/dev/null || service cups-browsed restart 2>/dev/null || print_warn "cups-browsed 重启失败"

    print_msg "重启 CUPS 服务..."
    systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || print_warn "CUPS 重启失败"

    sleep 2

    # 验证状态
    local cups_status
    cups_status=$(systemctl is-active cups 2>/dev/null || echo "unknown")
    local browsed_status
    browsed_status=$(systemctl is-active cups-browsed 2>/dev/null || echo "unknown")

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  配置完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  CUPS 服务状态: ${GREEN}${cups_status}${NC}"
    echo -e "  cups-browsed 状态: ${GREEN}${browsed_status}${NC}"
    echo ""
    echo "  自动添加打印机功能已禁用"
    echo "  后续请手动通过 lpadmin 添加打印机"
    echo ""
}

# CUPS配置子菜单
cups_config_menu() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}      CUPS 配置${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "  1. 查看CUPS状态"
        echo "  2. 重启CUPS服务"
        echo "  3. 查看已安装打印机"
        echo "  4. 添加USB打印机"
        echo "  5. 添加网络打印机"
        echo "  6. 查看打印队列"
        echo "  7. 清除打印队列"
        echo "  8. 设置默认打印机"
        echo "  9. 清理旧配置（移除过时指令）"
        echo " 10. 更新CUPS配置文件"
        echo " 11. 开启CUPS Web界面"
        echo " 12. CUPS汉化"
        echo " 13. 恢复英文界面"
        echo " 14. 禁用自动添加打印机"
        echo "  0. 返回主菜单"
        echo ""
        read -p "请选择 [0-13]: " cups_choice
        
        case $cups_choice in
            1)
                systemctl status cups 2>/dev/null || service cups status
                echo ""
                read -p "按回车键继续..."
                ;;
            2)
                systemctl restart cups 2>/dev/null || service cups restart
                print_msg "CUPS服务已重启"
                sleep 1
                ;;
            3)
                echo ""
                lpstat -p 2>/dev/null || echo "没有找到打印机"
                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                print_step "添加USB打印机"
                echo "检测USB打印机..."
                lsusb | grep -i printer || echo "未检测到USB打印机"
                echo ""
                read -p "是否自动添加USB打印机? [y/N]: " add_usb
                if [[ "$add_usb" =~ ^[Yy]$ ]]; then
                    lpinfo -v | grep usb || echo "未找到USB打印机"
                fi
                read -p "按回车键继续..."
                ;;
            5)
                print_step "添加网络打印机"
                echo "发现网络打印机..."
                avahi-browse -rt _ipp._tcp 2>/dev/null || lpinfo -v | grep "http\|ipp" || echo "未发现网络打印机"
                echo ""
                read -p "按回车键继续..."
                ;;
            6)
                echo ""
                lpstat -o 2>/dev/null || echo "打印队列为空"
                echo ""
                read -p "按回车键继续..."
                ;;
            7)
                read -p "清除所有打印队列? [y/N]: " clear_queue
                if [[ "$clear_queue" =~ ^[Yy]$ ]]; then
                    cancel -a 2>/dev/null
                    print_msg "打印队列已清除"
                fi
                ;;
            8)
                lpstat -p 2>/dev/null
                echo ""
                read -p "输入要设置为默认的打印机名称: " default_printer
                if [ -n "$default_printer" ]; then
                    lpoptions -d "$default_printer" 2>/dev/null
                    print_msg "默认打印机已设置为: $default_printer"
                fi
                ;;
            9)
                clean_old_cups_config
                read -p "按回车键继续..."
                ;;
            10)
                update_cups_config
                ;;
            11)
                cupsctl --web-interface=yes
                systemctl restart cups
                local_ip=$(hostname -I | awk '{print $1}')
                print_msg "CUPS Web界面已开启: http://${local_ip}:631"
                read -p "按回车键继续..."
                ;;
            12)
                cups_chinesizing
                read -p "按回车键继续..."
                ;;
            13)
                restore_cups_english
                read -p "按回车键继续..."
                ;;
            14)
                disable_auto_add_printer
                read -p "按回车键继续..."
                ;;
            0)
                break
                ;;
            *)
                print_error "无效选择"
                ;;
        esac
    done
}

# ==================== 打印机驱动安装函数 ====================

# 安装通用打印机驱动
install_general_driver() {
    print_step "安装通用打印机驱动"
    
    local GENERAL_DRIVERS=(
        "printer-driver-all"
        "printer-driver-hpcups"
        "printer-driver-hpijs"
        "printer-driver-gutenprint"
        "printer-driver-escpr"
        "printer-driver-foo2zjs"
        "printer-driver-foo2zjs-common"
        "printer-driver-splix"
        "printer-driver-pxljr"
        "printer-driver-c2050"
        "printer-driver-c2esp"
        "printer-driver-cjet"
        "printer-driver-dymo"
        "printer-driver-m2300w"
        "printer-driver-min12xxw"
        "printer-driver-oki"
        "printer-driver-pnm2ppa"
        "printer-driver-postscript-hp"
        "printer-driver-ptouch"
        "printer-driver-sag-gdi"
        "printer-driver-cups-pdf"
    )
    
    batch_install "通用打印机驱动" "${GENERAL_DRIVERS[@]}"
    
    systemctl restart cups 2>/dev/null || true
    systemctl restart avahi-daemon 2>/dev/null || true
}

# 安装HP打印机驱动
install_hp_driver() {
    print_step "安装HP打印机驱动"
    
    if dpkg -l hplip 2>/dev/null | grep -q "^ii"; then
        print_msg "✓ hplip 已安装"
    else
        print_msg "安装 hplip..."
        apt-get install -y hplip 2>/dev/null && print_msg "✓ hplip 安装成功" || print_warn "hplip 安装失败"
    fi
    
    if ! grep -q "openprinting.org" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 openprinting.org" >> /etc/hosts
        print_msg "已添加 openprinting.org hosts 解析"
    fi
}

# 安装 Canon LBP2900/LBP3000 驱动
install_canon_lbp2900() {
    if [ -e "/usr/lib/cups/filter/rastertocapt" ]; then
        print_msg "✓ LBP2900 驱动已安装"
        return 0
    fi
    
    local TAR_FILE=$(download_driver_file "linux-UFRII-LBP2900.tar")
    if [ -z "$TAR_FILE" ] || [ ! -f "$TAR_FILE" ]; then
        print_warn "LBP2900 驱动下载失败"
        return 1
    fi
    
    print_msg "安装 LBP2900/LBP3000 驱动..."
    
    local BUILD_DIR="/tmp/canon_lbp2900_build"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    tar xf "$TAR_FILE" -C "$BUILD_DIR"
    cd "$BUILD_DIR/linux-UFRII-LBP2900" || return 1
    
    if aclocal && autoconf && automake --add-missing && ./configure && make && make ppd && make install; then
        [ -f "src/rastertocapt" ] && mv src/rastertocapt /usr/lib/cups/filter/
        mkdir -p /usr/share/ppd/custom
        mv ppd/Canon*.ppd /usr/share/ppd/custom/ 2>/dev/null || true
        print_msg "✓ LBP2900 驱动安装成功"
    else
        print_warn "LBP2900 驱动编译失败"
    fi
    
    cd /
    rm -rf "$BUILD_DIR"
}

# 安装 Canon UFRII 驱动
install_canon_ufrii() {
    if dpkg -l cnrdrvcups-ufr2-uk 2>/dev/null | grep -q "^ii"; then
        print_msg "✓ UFRII 驱动已安装"
        return 0
    fi
    
    local TAR_FILE=$(download_driver_file "linux-UFRII-drv-v590.tar")
    if [ -z "$TAR_FILE" ] || [ ! -f "$TAR_FILE" ]; then
        print_warn "UFRII 驱动下载失败"
        return 1
    fi
    
    print_msg "安装 UFRII 驱动..."
    
    local BUILD_DIR="/tmp/canon_ufrii_build"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    tar xf "$TAR_FILE" -C "$BUILD_DIR"
    cd "$BUILD_DIR/linux-UFRII-drv-v590" || return 1
    
    if [ -f "install.sh" ]; then
        bash install.sh
        print_msg "✓ UFRII 驱动安装成功"
    else
        print_warn "UFRII 安装脚本不存在"
    fi
    
    cd /
    rm -rf "$BUILD_DIR"
}

# 安装 Canon 喷墨打印机驱动
install_canon_inkjet() {
    if dpkg -l cnijfilter2 2>/dev/null | grep -q "^ii"; then
        print_msg "✓ Canon 喷墨驱动已安装"
        return 0
    fi
    
    local TAR_FILE=$(download_driver_file "linux-Canon.tar")
    if [ -z "$TAR_FILE" ] || [ ! -f "$TAR_FILE" ]; then
        print_warn "Canon 喷墨驱动下载失败"
        return 1
    fi
    
    print_msg "安装 Canon 喷墨打印机驱动..."
    
    local BUILD_DIR="/tmp/canon_inkjet_build"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    tar xf "$TAR_FILE" -C "$BUILD_DIR"
    cd "$BUILD_DIR/linux-Canon" || return 1
    
    for deb in cnijfilter2_*.deb cnrdrvcups-ufr2lt-uk_*.deb; do
        if [ -f "$deb" ]; then
            dpkg -i "$deb" 2>/dev/null || apt-get install -f -y 2>/dev/null
            print_msg "  已安装: $deb"
        fi
    done
    
    print_msg "✓ Canon 喷墨驱动安装成功"
    
    cd /
    rm -rf "$BUILD_DIR"
}

# 安装Canon打印机驱动
install_canon_driver() {
    print_step "安装Canon打印机驱动"
    
    local ARCH=$(uname -m)
    print_msg "系统架构: $ARCH"
    
    print_msg "安装编译依赖..."
    apt-get install -y build-essential automake libcups2-dev 2>/dev/null || true
    
    if [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armhf" ]; then
        print_msg "32位 ARM 架构，安装 LBP2900 驱动..."
        install_canon_lbp2900
        
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        print_msg "64位 ARM 架构，安装完整 Canon 驱动..."
        
        install_canon_lbp2900
        install_canon_ufrii
        install_canon_inkjet
        
    elif [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
        print_msg "x86_64 架构，安装通用 Canon 驱动..."
        apt-get install -y printer-driver-gutenprint 2>/dev/null || true
        print_warn "x86_64 架构请从 Canon 官网下载对应驱动"
        
    else
        print_warn "当前架构 $ARCH 不支持自动安装 Canon 驱动"
    fi
    
    print_msg "Canon 驱动安装完成"
}

# 安装Brother打印机驱动
install_brother_driver() {
    print_step "安装Brother打印机驱动"
    
    if dpkg -l printer-driver-brlaser 2>/dev/null | grep -q "^ii"; then
        print_msg "✓ Brother 驱动已安装"
    else
        print_msg "安装 printer-driver-brlaser..."
        apt-get install -y printer-driver-brlaser 2>/dev/null && print_msg "✓ Brother 驱动安装成功" || print_warn "Brother 驱动安装失败"
    fi
}

# 安装Lenovo打印机驱动
install_lenovo_driver() {
    print_step "安装Lenovo打印机驱动"
    
    local ARCH=$(uname -m)
    print_msg "系统架构: $ARCH"
    
    if [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv6l" ]; then
        print_warn "32位 ARM 架构不支持 Lenovo 驱动"
        return 1
        
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        if dpkg -l com.lenovo.lenovoprints 2>/dev/null | grep -q "^ii"; then
            print_msg "✓ Lenovo 驱动已安装"
            return 0
        fi
        
        local DEB_FILE=$(download_driver_file "linux.lenovo.arm64.deb")
        if [ -z "$DEB_FILE" ] || [ ! -f "$DEB_FILE" ]; then
            print_warn "Lenovo 驱动下载失败"
            return 1
        fi
        
        print_msg "安装 Lenovo 驱动..."
        if dpkg -i "$DEB_FILE" 2>/dev/null || apt-get install -f -y 2>/dev/null; then
            print_msg "✓ Lenovo 驱动安装成功"
        else
            print_warn "Lenovo 驱动安装失败"
        fi
        
    else
        print_warn "当前架构 $ARCH 不支持自动安装 Lenovo 驱动"
        print_msg "请从 Lenovo 官网下载对应驱动"
    fi
}

# 安装Samsung打印机驱动
install_samsung_driver() {
    print_step "安装Samsung打印机驱动"
    
    local ARCH=$(uname -m)
    print_msg "系统架构: $ARCH"
    
    if [ "$ARCH" = "armv7l" ] || [ "$ARCH" = "armv6l" ]; then
        print_warn "32位 ARM 架构不支持 Samsung 驱动"
        return 1
    fi
    
    if ! dpkg -s gnupg >/dev/null 2>&1; then
        print_msg "安装 gnupg 依赖..."
        apt-get install -y gnupg gnupg2 gnupg-utils 2>/dev/null || true
    fi
    
    if dpkg -l suldr-keyring 2>/dev/null | grep -q "^ii"; then
        print_msg "✓ Samsung 驱动仓库已配置"
    else
        print_msg "配置 Samsung 驱动仓库..."
        
        if ! grep -q "bchemnet.com/suldr" /etc/apt/sources.list 2>/dev/null; then
            echo "deb https://www.bchemnet.com/suldr/ debian extra" >> /etc/apt/sources.list
            print_msg "已添加 Samsung 驱动仓库"
        fi
        
        local KEYRING_FILE=$(download_driver_file "suldr-keyring_4_all.deb")
        if [ -n "$KEYRING_FILE" ] && [ -f "$KEYRING_FILE" ]; then
            dpkg -i "$KEYRING_FILE" 2>/dev/null || true
            print_msg "已安装仓库密钥"
        else
            print_warn "密钥文件下载失败"
        fi
        
        apt-get update 2>/dev/null || true
    fi
    
    print_msg "安装 Samsung 驱动..."
    local SAMSUNG_PKGS="suld-ppd-5 suld-driver2-common-1 suld-driver2-1.00.39hp libusb-0.1-4"
    
    batch_install "Samsung驱动" $SAMSUNG_PKGS
}

# 打印机驱动安装子菜单
show_driver_menu() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}      打印机驱动安装${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "  1. 安装通用打印机驱动"
        echo "  2. 安装HP打印机驱动"
        echo "  3. 安装Canon打印机驱动"
        echo "  4. 安装Brother打印机驱动"
        echo "  5. 安装Lenovo打印机驱动"
        echo "  6. 安装Samsung打印机驱动"
        echo "  7. 安装所有驱动"
        echo "  0. 返回主菜单"
        echo ""
        read -p "请选择 [0-7]: " driver_choice
        
        case $driver_choice in
            1)
                install_general_driver
                ;;
            2)
                install_hp_driver
                ;;
            3)
                install_canon_driver
                ;;
            4)
                install_brother_driver
                ;;
            5)
                install_lenovo_driver
                ;;
            6)
                install_samsung_driver
                ;;
            7)
                print_msg "安装所有驱动..."
                install_general_driver
                install_hp_driver
                install_canon_driver
                install_brother_driver
                install_lenovo_driver
                install_samsung_driver
                print_msg "所有驱动安装完成"
                ;;
            0)
                break
                ;;
            *)
                print_error "无效选择"
                ;;
        esac
        echo ""
        read -p "按回车键继续..."
    done
}

# 查找本地cups-web二进制文件
find_cupsweb_binary() {
    local bin=""
    
    if [ -f /etc/systemd/system/cups-web.service ]; then
        bin=$(grep "^ExecStart=" /etc/systemd/system/cups-web.service 2>/dev/null | sed 's/^ExecStart=//' | awk '{print $1}')
        if [ -n "$bin" ] && [ -f "$bin" ] && [[ "$bin" == *"cups-web"* ]]; then
            echo "$bin"
            return 0
        fi
    fi
    
    local pid=$(pgrep -f "cups-web-linux" 2>/dev/null | head -1)
    if [ -n "$pid" ]; then
        bin=$(readlink -f /proc/$pid/exe 2>/dev/null)
        if [ -n "$bin" ] && [ -f "$bin" ] && [[ "$bin" == *"cups-web"* ]]; then
            echo "$bin"
            return 0
        fi
    fi
    
    local search_paths=(
        "/opt/websocket_printer/cups-web/cups-web-linux-*"
        "/usr/local/bin/cups-web-linux-*"
        "/usr/local/bin/cups-web"
        "/opt/cups-web/cups-web-linux-*"
    )
    
    for search_path in "${search_paths[@]}"; do
        for f in $search_path; do
            if [ -f "$f" ] && [ -x "$f" ] && [[ "$f" == *"cups-web"* ]]; then
                echo "$f"
                return 0
            fi
        done
    done
    
    local search_dirs=(
        "/opt/websocket_printer/cups-web"
        "/usr/local/bin"
        "/opt/cups-web"
    )
    
    for dir in "${search_dirs[@]}"; do
        if [ -d "$dir" ]; then
            bin=$(find "$dir" -maxdepth 1 -name "cups-web-linux-*" -type f -executable 2>/dev/null | head -1)
            if [ -n "$bin" ]; then
                echo "$bin"
                return 0
            fi
        fi
    done
    
    return 1
}

# 本地安装cups-web服务
install_cupsweb_local() {
    local CUPS_WEB_DIR="/opt/websocket_printer/cups-web"
    local CUPS_WEB_GITHUB="https://gh-proxy.org/https://github.com/hanxi/cups-web/releases/latest/download/"
#新版安装失败替换0.1.1
    #local CUPS_WEB_GITHUB="https://gh-proxy.com/https://github.com/hanxi/cups-web/releases/download/v0.1.1/"


    local arch=$(uname -m)
    local bin_name=""
    case "$arch" in
        x86_64|amd64) bin_name="cups-web-linux-amd64" ;;
        aarch64|arm64) bin_name="cups-web-linux-arm64" ;;
        armv7l|armv6l|armhf) bin_name="cups-web-linux-armv7" ;;
        loongarch64) bin_name="cups-web-linux-loong64" ;;
        *)
            print_error "不支持的架构: $arch"
            return 1
            ;;
    esac

    print_msg "系统架构: $arch -> $bin_name"

    rm -f "$CUPS_WEB_DIR/.uninstalled" 2>/dev/null || true

    print_msg "创建 cups-web 目录: $CUPS_WEB_DIR"
    mkdir -p "$CUPS_WEB_DIR"
    mkdir -p "$CUPS_WEB_DIR/data"
    mkdir -p "$CUPS_WEB_DIR/uploads"

    local CUPS_WEB_BIN="$CUPS_WEB_DIR/$bin_name"

    print_msg "下载 cups-web  ($bin_name)..."
    local download_url="$CUPS_WEB_GITHUB/$bin_name"
    local BACKUP_URL="https://gh.llkk.cc/https://github.com/hanxi/cups-web/releases/latest/download/$bin_name"
#新版安装失败替换0.1.1
    #local BACKUP_URL="https://gh.llkk.cc/https://github.com/hanxi/cups-web/releases/download/v0.1.1/$bin_name"

    print_msg "主下载地址: $download_url"
    print_msg "备用下载地址: $BACKUP_URL"

    local download_success=false
    local used_backup=false

    # ====== 使用进度条下载（主地址）======
    echo ""
    echo -e "${CYAN}正在从主地址下载...${NC}"
    if timeout 120 curl -fSL --connect-timeout 30 --max-time 120 --progress-bar -o "$CUPS_WEB_BIN" "$download_url" 2>&1; then
        download_success=true
        echo ""
        print_msg "✓ 主地址下载完成: $CUPS_WEB_BIN"
    else
        echo ""
        print_warn "✗ 主地址下载失败，正在切换备用地址..."
        rm -f "$CUPS_WEB_BIN" 2>/dev/null || true

        # ====== 使用进度条下载（备用地址）======
        echo ""
        echo -e "${CYAN}正在从备用地址下载...${NC}"
        if timeout 120 curl -fSL --connect-timeout 30 --max-time 120 --progress-bar -o "$CUPS_WEB_BIN" "$BACKUP_URL" 2>&1; then
            download_success=true
            used_backup=true
            echo ""
            print_msg "✓ 备用地址下载完成: $CUPS_WEB_BIN"
        else
            echo ""
            print_error "✗ 备用地址下载也失败"
            rm -f "$CUPS_WEB_BIN" 2>/dev/null || true
        fi
    fi

    if [ "$download_success" != true ]; then
        print_error "下载失败: $download_url 和 $BACKUP_URL"
        print_msg "请检查网络连接，可能需要代理访问 GitHub"
        return 1
    fi

    if [ "$used_backup" = true ]; then
        print_msg "（已使用备用下载地址）"
    fi

    if [ ! -s "$CUPS_WEB_BIN" ]; then
        print_error "下载的文件为空"
        rm -f "$CUPS_WEB_BIN"
        return 1
    fi

    if ! file "$CUPS_WEB_BIN" | grep -q "ELF"; then
        print_error "下载的文件不是有效的可执行文件"
        rm -f "$CUPS_WEB_BIN"
        return 1
    fi
        print_msg "设置可执行权限..."
         chmod +x "$CUPS_WEB_BIN"
    if [ ! -x "$CUPS_WEB_BIN" ]; then
       print_error "无法设置可执行权限"
       return 1
    fi

    print_msg "创建 systemd 服务..."
    cat > /etc/systemd/system/cups-web.service << EOF
[Unit]
Description=CUPS Web Management Interface
After=cups.service network.target
Wants=cups.service

[Service]
Type=simple
ExecStart=$CUPS_WEB_BIN -addr :8080
WorkingDirectory=$CUPS_WEB_DIR
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cups-web 2>/dev/null || true
    systemctl start cups-web

    sleep 2

    if systemctl is-active --quiet cups-web 2>/dev/null; then
        local local_ip=$(hostname -I | awk '{print $1}')
        print_msg "✓ cups-web 服务已启动"
        print_msg "  访问地址: http://${local_ip}:8080"
        print_msg "  默认账号: admin / admin"
    else
        print_error "cups-web 服务启动失败，请检查日志:"
        journalctl -u cups-web -n 10 --no-pager 2>/dev/null
    fi
}
# 网页打印服务管理
web_print_service() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}      网页打印服务管理${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "  1. 安装网页打印服务"
        echo "  2. 更新网页打印服务"
        echo "  3. 查看服务状态"
        echo "  4. 重启网页打印服务"
        echo "  5. 停止网页打印服务"
        echo "  6. 启动网页打印服务"
        echo "  7. 查看服务日志"
        echo "  8. 卸载网页打印服务"
        echo "  0. 返回主菜单"
        echo ""
        read -p "请选择 [0-8]: " web_choice

        case $web_choice in
            1)
                print_step "安装网页打印服务"

                local existing_bin=$(find_cupsweb_binary)
                if [ -n "$existing_bin" ]; then
                    echo -e "${YELLOW}cups-web 已安装: $existing_bin${NC}"
                    read -p "是否重新安装? [y/N]: " reinstall
                    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
                        read -p "按回车键继续..."
                        continue
                    fi
                    safe_stop_cupsweb
                    sleep 1
                fi

                install_cupsweb_local
                read -p "按回车键继续..."
                ;;
            2)
                print_step "更新网页打印服务"

                local existing_bin=$(find_cupsweb_binary)
                if [ -n "$existing_bin" ]; then
                    echo -e "${YELLOW}当前安装: $existing_bin${NC}"
                    echo ""
                fi

                read -p "确认更新 cups-web? [y/N]: " confirm_update
                if [[ "$confirm_update" =~ ^[Yy]$ ]]; then
                    safe_stop_cupsweb
                    sleep 1
                    install_cupsweb_local
                else
                    print_msg "已取消更新"
                fi
                read -p "按回车键继续..."
                ;;
            3)
                echo ""
                echo -e "${CYAN}========================================${NC}"
                echo -e "${CYAN}   cups-web 服务状态${NC}"
                echo -e "${CYAN}========================================${NC}"
                echo ""

                if systemctl is-active --quiet cups-web 2>/dev/null; then
                    echo -e "运行状态: ${GREEN}● 运行中 (systemd)${NC}"
                    local local_ip=$(hostname -I | awk '{print $1}')
                    echo -e "访问地址: http://${local_ip}:8080"
                elif pgrep -f "cups-web-linux" > /dev/null 2>&1; then
                    echo -e "运行状态: ${GREEN}● 运行中 (进程)${NC}"
                    local local_ip=$(hostname -I | awk '{print $1}')
                    echo -e "访问地址: http://${local_ip}:8080"
                else
                    echo -e "运行状态: ${RED}● 未运行${NC}"
                fi

                local found_bin=$(find_cupsweb_binary)
                if [ -n "$found_bin" ]; then
                    echo -e "安装状态: ${GREEN}已安装${NC}"
                    echo -e "二进制:   $found_bin"
                else
                    echo -e "安装状态: ${YELLOW}未安装${NC}"
                fi

                if [ -f /etc/systemd/system/cups-web.service ]; then
                    local svc_status=$(systemctl is-enabled cups-web 2>/dev/null || echo "未知")
                    echo -e "开机启动: $svc_status"
                fi

                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                print_step "重启网页打印服务"
                if systemctl restart cups-web 2>/dev/null; then
                    print_msg "服务已重启"
                else
                    print_warn "无法通过systemctl重启，尝试手动重启..."
                    safe_stop_cupsweb
                    sleep 1
                    local cups_binary=$(find_cupsweb_binary)
                    if [ -n "$cups_binary" ]; then
                        nohup "$cups_binary" -addr :8080 >> /var/log/cups-web.log 2>&1 &
                        sleep 1
                        if pgrep -f "cups-web-linux" > /dev/null 2>&1; then
                            print_msg "服务已重启"
                        else
                            print_error "服务启动失败"
                        fi
                    else
                        print_error "未找到cups-web程序，请先安装"
                    fi
                fi
                read -p "按回车键继续..."
                ;;
            5)
                print_step "停止网页打印服务"
                safe_stop_cupsweb
                print_msg "服务已停止"
                read -p "按回车键继续..."
                ;;
            6)
                print_step "启动网页打印服务"
                if systemctl start cups-web 2>/dev/null; then
                    print_msg "服务已启动"
                else
                    local cups_binary=$(find_cupsweb_binary)
                    if [ -n "$cups_binary" ]; then
                        nohup "$cups_binary" -addr :8080 >> /var/log/cups-web.log 2>&1 &
                        sleep 1
                        if pgrep -f "cups-web-linux" > /dev/null 2>&1; then
                            print_msg "服务已启动"
                        else
                            print_error "服务启动失败"
                        fi
                    else
                        print_error "未找到cups-web程序，请先安装"
                    fi
                fi
                read -p "按回车键继续..."
                ;;
            7)
                print_step "查看服务日志"
                echo ""
                if journalctl -u cups-web -n 1 > /dev/null 2>&1; then
                    echo -e "${CYAN}========== systemd 日志 (最后50行) ==========${NC}"
                    journalctl -u cups-web -n 50 --no-pager 2>/dev/null
                elif [ -f "/var/log/cups-web.log" ]; then
                    echo -e "${CYAN}========== 文件日志 (最后50行) ==========${NC}"
                    tail -50 /var/log/cups-web.log
                else
                    echo "暂无日志"
                fi
                echo ""
                read -p "按回车键继续..."
                ;;
            8)
                print_step "卸载网页打印服务"
                read -p "确认卸载? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    safe_stop_cupsweb
                    systemctl disable cups-web 2>/dev/null || true
                    rm -f /etc/systemd/system/cups-web.service
                    mkdir -p /opt/websocket_printer/cups-web
                    touch /opt/websocket_printer/cups-web/.uninstalled
                    find /opt/websocket_printer/cups-web -type f ! -name '.uninstalled' -delete 2>/dev/null || true
                    find /opt/websocket_printer/cups-web -mindepth 1 -type d -empty -delete 2>/dev/null || true
                    systemctl daemon-reload
                    print_msg "卸载完成"
                fi
                read -p "按回车键继续..."
                ;;
            0)
                break
                ;;
            *)
                print_error "无效选择"
                ;;
        esac
    done
}
# 显示组件状态
show_component_status() {
    echo ""
    echo "=========================================="
    echo "  组件安装状态检查"
    echo "=========================================="
    echo ""
    
    echo -e "${CYAN}[系统信息]${NC}"
    echo -e "  系统类型: $OS_TYPE"
    echo -e "  系统版本: $OS_VERSION"
    echo -e "  系统架构: $ARCH_NAME ($ARCH)"
    echo -e "  总内存: ${TOTAL_MEM}MB"
    echo ""
    
    echo -e "${CYAN}[基础系统工具]${NC}"
    for tool in curl wget git unzip qrencode xxd openssl; do
        if command -v $tool &> /dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool"
        else
            echo -e "  ${RED}✗${NC} $tool"
        fi
    done
    echo ""
    
    echo -e "${CYAN}[PHP 及扩展]${NC}"
    if command -v php &> /dev/null; then
        PHP_VER=$(php -v 2>/dev/null | head -1)
        echo -e "  ${GREEN}✓${NC} PHP: $PHP_VER"
        for ext in curl mbstring sockets json gd zip xml; do
            if php -m 2>/dev/null | grep -qi "^$ext$"; then
                echo -e "  ${GREEN}✓${NC} php-$ext"
            else
                echo -e "  ${RED}✗${NC} php-$ext"
            fi
        done
    else
        echo -e "  ${RED}✗${NC} PHP 未安装"
    fi
    echo ""
    
    echo -e "${CYAN}[CUPS 打印系统]${NC}"
    if check_cups_installed; then
        echo -e "  ${GREEN}✓${NC} CUPS: $(get_cups_version)"
        for pkg in cups-client cups-bsd cups-ipp-utils cups-browsed cups-filters avahi-daemon; do
            if dpkg -l $pkg 2>/dev/null | grep -q "^ii"; then
                echo -e "  ${GREEN}✓${NC} $pkg"
            else
                echo -e "  ${RED}✗${NC} $pkg"
            fi
        done
    else
        echo -e "  ${RED}✗${NC} CUPS 未安装"
    fi
    
    if systemctl is-active --quiet cups 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} cups 服务: 运行中"
    else
        echo -e "  ${YELLOW}⚠${NC} cups 服务: 未运行"
    fi
    echo ""
    
    echo -e "${CYAN}[图像处理工具]${NC}"
    for tool in convert identify pdftoppm qpdf gs; do
        if command -v $tool &> /dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool"
        else
            echo -e "  ${RED}✗${NC} $tool"
        fi
    done
    echo ""
    
    echo -e "${CYAN}[打印机驱动]${NC}"
    for driver in printer-driver-gutenprint hplip printer-driver-escpr printer-driver-brlaser; do
        if dpkg -l $driver 2>/dev/null | grep -q "^ii"; then
            echo -e "  ${GREEN}✓${NC} $driver"
        fi
    done
    echo ""
    
    echo -e "${CYAN}[中文字体]${NC}"
    if command -v fc-list &> /dev/null; then
        FONT_COUNT=$(fc-list :lang=zh 2>/dev/null | wc -l)
        echo -e "  ${GREEN}✓${NC} 中文字体: $FONT_COUNT 个"
    else
        echo -e "  ${YELLOW}⚠${NC} fontconfig 未安装"
    fi
    echo ""
    
    echo -e "${CYAN}[文档处理]${NC}"
    if command -v libreoffice &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} LibreOffice: $(libreoffice --version 2>/dev/null | head -1)"
    else
        echo -e "  ${YELLOW}⚠${NC} LibreOffice 未安装 (可选)"
    fi
    
    if dpkg -l libreoffice-java-common 2>/dev/null | grep -q "^ii"; then
        echo -e "  ${GREEN}✓${NC} libreoffice-java-common"
    else
        echo -e "  ${RED}✗${NC} libreoffice-java-common"
    fi
    
    if command -v java &> /dev/null; then
        JAVA_VER=$(java -version 2>&1 | head -1)
        echo -e "  ${GREEN}✓${NC} Java运行时: $JAVA_VER"
    else
        echo -e "  ${YELLOW}⚠${NC} Java运行时 未安装 (LibreOffice需要)"
    fi
    echo ""
    
    echo -e "${CYAN}[打印客户端]${NC}"
    if [ -f "$INSTALL_DIR/printer_client.php" ]; then
        echo -e "  ${GREEN}✓${NC} 客户端文件: 已安装"
        if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 服务: 运行中"
        else
            echo -e "  ${YELLOW}⚠${NC} 服务: 未运行"
        fi
    else
        echo -e "  ${RED}✗${NC} 客户端文件: 未安装"
    fi
    echo ""
}

# 重新安装所有组件
reinstall_all() {
    print_step "重新安装所有组件"
    
    read -p "这将重新安装所有组件，是否继续? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [ -f "/etc/printer-device-id" ]; then
            cp /etc/printer-device-id /tmp/printer-device-id.bak
        fi
        
        install_all_deps
        configure_cups
        download_files
        create_service
        
        if [ -f "/tmp/printer-device-id.bak" ]; then
            cp /tmp/printer-device-id.bak /etc/printer-device-id
        fi
        
        update_fonts
        generate_qrcodes
        
        print_msg "重新安装完成"
    else
        print_msg "已取消"
    fi
}

# 完整安装
full_install() {
    print_step "开始完整安装"
    install_all_deps
    configure_cups
    download_files
    create_service
    update_fonts
    generate_qrcodes
}

# 仅检测环境
check_environment() {
    print_step "环境检测"
    
    detect_system
    
    local missing=0
    local missing_list=()
    
    echo -e "${CYAN}[系统兼容性检测]${NC}"
    echo -e "  系统: $OS_TYPE $OS_VERSION"
    echo -e "  架构: $ARCH_NAME"
    
    if [ "$ARCH_TYPE" = "unknown" ]; then
        echo -e "  ${RED}✗${NC} 不支持的系统架构: $ARCH"
        missing=$((missing+1))
        missing_list+=("系统架构不支持")
    else
        echo -e "  ${GREEN}✓${NC} 架构支持"
    fi
    
    if [ "$TOTAL_MEM" -lt 256 ]; then
        echo -e "  ${YELLOW}⚠${NC} 内存较小 (${TOTAL_MEM}MB)，将启用轻量模式"
    else
        echo -e "  ${GREEN}✓${NC} 内存充足 (${TOTAL_MEM}MB)"
    fi
    
    echo ""
    echo -e "${CYAN}[必需组件检测]${NC}"
    
    for cmd in php curl wget systemctl; do
        if command -v $cmd &> /dev/null; then
            echo -e "  ${GREEN}✓${NC} $cmd"
        else
            echo -e "  ${RED}✗${NC} $cmd"
            missing=$((missing+1))
            missing_list+=("$cmd")
        fi
    done
    
    echo ""
    echo -e "${CYAN}[PHP扩展检测]${NC}"
    if command -v php &> /dev/null; then
        for ext in curl mbstring sockets json gd zip xml; do
            if php -m 2>/dev/null | grep -qi "^$ext$"; then
                echo -e "  ${GREEN}✓${NC} php-$ext"
            else
                echo -e "  ${RED}✗${NC} php-$ext"
                missing=$((missing+1))
                missing_list+=("php-$ext")
            fi
        done
    fi
    
    echo ""
    echo -e "${CYAN}[CUPS打印系统检测]${NC}"
    if check_cups_installed; then
        echo -e "  ${GREEN}✓${NC} CUPS: $(get_cups_version)"
        for pkg in cups cups-client cups-bsd cups-ipp-utils cups-browsed cups-filters avahi-daemon; do
            if dpkg -l $pkg 2>/dev/null | grep -q "^ii"; then
                echo -e "  ${GREEN}✓${NC} $pkg"
            else
                echo -e "  ${RED}✗${NC} $pkg"
                missing=$((missing+1))
                missing_list+=("$pkg")
            fi
        done
    else
        echo -e "  ${RED}✗${NC} CUPS 未安装"
        missing=$((missing+1))
        missing_list+=("CUPS")
    fi
    
    echo ""
    echo -e "${CYAN}[图像处理工具检测]${NC}"
    for tool in convert identify pdftoppm qpdf gs; do
        if command -v $tool &> /dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool"
        else
            echo -e "  ${RED}✗${NC} $tool"
            missing=$((missing+1))
            missing_list+=("$tool")
        fi
    done
    
    echo ""
    echo -e "${CYAN}[打印机驱动检测]${NC}"
    for driver in printer-driver-gutenprint hplip foomatic-db-engine printer-driver-escpr printer-driver-brlaser printer-driver-splix printer-driver-foo2zjs; do
        if dpkg -l $driver 2>/dev/null | grep -q "^ii"; then
            echo -e "  ${GREEN}✓${NC} $driver"
        else
            echo -e "  ${RED}✗${NC} $driver"
            missing=$((missing+1))
            missing_list+=("$driver")
        fi
    done
    
    echo ""
    echo -e "${CYAN}[中文字体检测]${NC}"
    if command -v fc-list &> /dev/null; then
        local font_count=$(fc-list :lang=zh 2>/dev/null | wc -l)
        if [ $font_count -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} 中文字体: $font_count 个"
        else
            echo -e "  ${RED}✗${NC} 中文字体: 未安装"
            missing=$((missing+1))
            missing_list+=("中文字体")
        fi
    else
        echo -e "  ${RED}✗${NC} fontconfig"
        missing=$((missing+1))
        missing_list+=("fontconfig")
    fi
    
    echo ""
    echo -e "${CYAN}[二维码工具检测]${NC}"
    if command -v qrencode &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} qrencode"
    else
        echo -e "  ${RED}✗${NC} qrencode"
        missing=$((missing+1))
        missing_list+=("qrencode")
    fi
    
    echo ""
    echo -e "${CYAN}[文档处理检测]${NC}"
    if command -v libreoffice &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} LibreOffice"
    else
        echo -e "  ${YELLOW}⚠${NC} LibreOffice 未安装 (可选)"
    fi
    
    if dpkg -l libreoffice-java-common 2>/dev/null | grep -q "^ii"; then
        echo -e "  ${GREEN}✓${NC} libreoffice-java-common"
    else
        echo -e "  ${RED}✗${NC} libreoffice-java-common"
        missing=$((missing+1))
        missing_list+=("libreoffice-java-common")
    fi
    
    if command -v java &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} Java运行时"
    else
        echo -e "  ${YELLOW}⚠${NC} Java运行时 未安装 (LibreOffice需要)"
    fi
    
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    
    if [ $missing -eq 0 ]; then
        echo -e "${GREEN}✨ 环境检测通过，所有组件完整！${NC}"
    else
        echo -e "${YELLOW}⚠️  发现 $missing 个缺失组件:${NC}"
        for item in "${missing_list[@]}"; do
            echo -e "  ${RED}•${NC} $item"
        done
        echo -e "\n${YELLOW}建议运行选项3 [仅安装缺失组件]${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}[ImageMagick PDF 策略检测]${NC}"
    local im_policy_found=0
    local im_policy_restricted=0
    local im_policy_files=(
        "/etc/ImageMagick-6/policy.xml"
        "/etc/ImageMagick-7/policy.xml"
    )
    
    for im_policy in "${im_policy_files[@]}"; do
        if [ -f "$im_policy" ]; then
            im_policy_found=1
            if grep -q 'rights="none" pattern="PDF"' "$im_policy" 2>/dev/null; then
                im_policy_restricted=1
                echo -e "  ${RED}✗${NC} $im_policy - PDF 策略受限 (rights=none)"
            else
                echo -e "  ${GREEN}✓${NC} $im_policy - PDF 策略正常"
            fi
        fi
    done
    
    if [ $im_policy_found -eq 0 ]; then
        echo -e "  ${YELLOW}⚠${NC} 未找到 ImageMagick policy.xml（可能未安装）"
    elif [ $im_policy_restricted -eq 1 ]; then
        echo -e "  ${YELLOW}⚠ 建议运行选项1 [完整安装] 或选项3 [仅安装缺失组件] 自动修复${NC}"
    fi
    echo ""
    read -p "按回车键继续..."
}

# 更新字体
update_fonts() {
    print_step "更新字体缓存"
    if command -v fc-cache &> /dev/null; then
        fc-cache -fv 2>/dev/null || true
        echo -e "${GREEN}✓${NC} 字体缓存已更新"
    fi
}

# 显示版本信息
show_version() {
    detect_system
    
    LOCAL_IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="未获取到"
    fi
    
    local run_count=$(get_run_count_from_server)
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}           打印机客户端${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  版本: ${CYAN}${VERSION}${NC}"
    echo -e "  脚本版本: ${CYAN}${SCRIPT_VERSION}${NC}"
    echo -e "  累计运行: ${CYAN}${run_count}${NC} ${CYAN}次${NC}"
    echo ""
    echo -e "${CYAN}当前系统信息:${NC}"
    echo -e "  系统类型: ${GREEN}${OS_TYPE}${NC}"
    echo -e "  系统版本: ${GREEN}${OS_VERSION}${NC}"
    echo -e "  系统架构: ${GREEN}${ARCH_NAME} (${ARCH})${NC}"
    echo -e "  本地IP:   ${GREEN}${LOCAL_IP}${NC}"
    echo -e "  总内存:   ${GREEN}${TOTAL_MEM}MB${NC}"
    if [ "$LOW_MEMORY_MODE" = true ]; then
        echo -e "  内存模式: ${YELLOW}轻量模式${NC}"
    else
        echo -e "  内存模式: ${GREEN}正常模式${NC}"
    fi
    
    ALL_IPS=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | tr '\n' ' ')
    if [ -n "$ALL_IPS" ] && [ "$ALL_IPS" != "$LOCAL_IP " ] && [ "$ALL_IPS" != "$LOCAL_IP" ]; then
        echo -e "  所有IP:   ${GREEN}${ALL_IPS}${NC}"
    fi
    echo ""
    echo -e "${CYAN}支持系统:${NC}"
    echo "    - Ubuntu 16.04 / 18.04 / 20.04 / 22.04 / 24.04"
    echo "    - Debian 9 / 10 / 11 / 12"
    echo "    - Armbian (所有版本)"
    echo "    - 支持架构: x86_64, ARM64, ARM32"
    echo ""
    echo -e "${CYAN}主要功能:${NC}"
    echo "    - 小程序远程云打印"
    echo "    - 二维码设备绑定"
    echo "    - 多格式文件支持 (PDF/Word/Excel/图片)"
    echo "    - 自动发现网络打印机"
    echo "    - CUPS Web 管理界面"
    echo ""
    
    echo -e "${CYAN}当前安装状态:${NC}"
    if [ -f "$INSTALL_DIR/printer_client.php" ]; then
        echo -e "  客户端: ${GREEN}已安装${NC}"
        if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
            echo -e "  服务状态: ${GREEN}运行中${NC}"
        else
            echo -e "  服务状态: ${YELLOW}未运行${NC}"
        fi
    else
        echo -e "  客户端: ${YELLOW}未安装${NC}"
    fi
    
    if check_cups_installed; then
        echo -e "  CUPS: ${GREEN}已安装 (版本: $(get_cups_version))${NC}"
        if systemctl is-active --quiet cups 2>/dev/null; then
            echo -e "  CUPS服务: ${GREEN}运行中${NC}"
        else
            echo -e "  CUPS服务: ${YELLOW}未运行${NC}"
        fi
    else
        echo -e "  CUPS: ${YELLOW}未安装${NC}"
    fi
    
    echo ""
    read -p "按回车键继续..."
}

# 显示最终状态
show_final_status() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}         安装完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    show_component_status
    
    local local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "安装信息:"
    echo "----------------------------------------"
    echo "  设备ID: $(get_device_id)"
    if [ -n "$local_ip" ]; then
        echo "  CUPS管理: http://${local_ip}:631"
    fi
    echo ""
    
    echo "服务管理命令:"
    echo "  systemctl start/stop/restart/status $SERVICE_NAME"
    echo "  journalctl -u $SERVICE_NAME -f"
    echo ""
    
    echo -e "${GREEN}请使用微信扫描上方小程序二维码使用服务${NC}"
    echo ""
}

# Docker设备安装
install_docker_device() {
    print_step "安装 Docker 设备"
    echo -e "${YELLOW}正在为 Docker 环境安装打印设备...${NC}"
    
    print_msg "下载 Docker 安装脚本..."
    local docker_script="/opt/websocket_printer/update.sh"
    
    mkdir -p /opt/websocket_printer
    
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$docker_script" 'http://print.tzishue.tk/update/docker/update.sh'; then
        if [ -s "$docker_script" ]; then
            chmod +x "$docker_script"
            print_msg "✓ Docker 安装脚本下载成功"
            
            print_msg "执行 Docker 安装脚本..."
            cd /opt/websocket_printer
            bash "$docker_script"
            print_msg "✓ Docker 设备安装完成"
        else
            print_error "下载的文件为空"
        fi
    else
        print_error "下载失败: http://print.tzishue.tk/update/docker/update.sh"
        print_msg "请检查网络连接后重试"
    fi
    
    read -p "按回车键继续..."
}

# 卸载菜单函数
uninstall_menu() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}     卸载选项${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "  1. 仅卸载打印客户端"
        echo "  2. 卸载打印客户端 + CUPS"
        echo "  3. 卸载打印客户端 + CUPS + Avahi/mDNS"
        echo "  4. 完全卸载（客户端 + CUPS + Avahi + 驱动）"
        echo "  0. 返回主菜单"
        echo ""
        read -p "请选择 [0-4]: " UNINSTALL_CHOICE
    
    case $UNINSTALL_CHOICE in
        1)
            print_msg "卸载打印客户端..."
            systemctl stop $SERVICE_NAME 2>/dev/null || true
            systemctl disable $SERVICE_NAME 2>/dev/null || true
            safe_stop_cupsweb
            systemctl disable cups-web 2>/dev/null || true
            rm -rf $INSTALL_DIR 2>/dev/null || true
            rm -f /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true
            rm -f /etc/systemd/system/cups-web.service 2>/dev/null || true
            safe_daemon_reload
            print_msg "✓ 打印客户端已卸载"
            ;;
        2)
            print_msg "卸载打印客户端..."
            systemctl stop $SERVICE_NAME 2>/dev/null || true
            systemctl disable $SERVICE_NAME 2>/dev/null || true
            safe_stop_cupsweb
            systemctl disable cups-web 2>/dev/null || true
            rm -rf $INSTALL_DIR 2>/dev/null || true
            rm -f /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true
            rm -f /etc/systemd/system/cups-web.service 2>/dev/null || true                        
            print_msg "卸载CUPS..."
            systemctl stop cups cups-browsed 2>/dev/null || true
            systemctl disable cups cups-browsed 2>/dev/null || true
            apt-get remove --purge -y cups cups-client cups-bsd cups-ipp-utils cups-filters cups-browsed cups-common cups-ppdc 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
            rm -rf /etc/cups /var/spool/cups /var/cache/cups 2>/dev/null || true
            
            safe_daemon_reload
            print_msg "✓ 打印客户端和CUPS已卸载"
            ;;
        3)
            print_msg "卸载打印客户端..."
            systemctl stop $SERVICE_NAME 2>/dev/null || true
            systemctl disable $SERVICE_NAME 2>/dev/null || true
            safe_stop_cupsweb
            systemctl disable cups-web 2>/dev/null || true
            rm -rf $INSTALL_DIR 2>/dev/null || true
            rm -f /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true
            rm -f /etc/systemd/system/cups-web.service 2>/dev/null || true
            
            print_msg "卸载CUPS..."
            systemctl stop cups cups-browsed 2>/dev/null || true
            systemctl disable cups cups-browsed 2>/dev/null || true
            apt-get remove --purge -y cups cups-client cups-bsd cups-ipp-utils cups-filters cups-browsed cups-common cups-ppdc 2>/dev/null || true
            rm -rf /etc/cups /var/spool/cups /var/cache/cups 2>/dev/null || true
            
            print_msg "卸载Avahi/mDNS..."
            systemctl stop avahi-daemon 2>/dev/null || true
            systemctl disable avahi-daemon 2>/dev/null || true
            apt-get remove --purge -y avahi-daemon avahi-utils libnss-mdns 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
            
            safe_daemon_reload
            print_msg "✓ 打印客户端、CUPS和Avahi已卸载"
            ;;
        4)
            print_msg "执行完全卸载..."
            
            print_msg "卸载打印客户端..."
            systemctl stop $SERVICE_NAME 2>/dev/null || true
            systemctl disable $SERVICE_NAME 2>/dev/null || true
            safe_stop_cupsweb
            systemctl disable cups-web 2>/dev/null || true
            rm -rf $INSTALL_DIR 2>/dev/null || true
            rm -f /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null || true
            rm -f /etc/systemd/system/cups-web.service 2>/dev/null || true
            
            print_msg "卸载CUPS..."
            systemctl stop cups cups-browsed 2>/dev/null || true
            systemctl disable cups cups-browsed 2>/dev/null || true
            apt-get remove --purge -y cups cups-client cups-bsd cups-ipp-utils cups-filters cups-browsed cups-common cups-ppdc cups-pdf 2>/dev/null || true
            rm -rf /etc/cups /var/spool/cups /var/cache/cups 2>/dev/null || true
            
            print_msg "卸载Avahi/mDNS..."
            systemctl stop avahi-daemon 2>/dev/null || true
            systemctl disable avahi-daemon 2>/dev/null || true
            apt-get remove --purge -y avahi-daemon avahi-utils libnss-mdns 2>/dev/null || true
            
            print_msg "卸载打印机驱动..."
            apt-get remove --purge -y printer-driver-gutenprint printer-driver-hpijs hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix printer-driver-foo2zjs foomatic-db-engine foomatic-db-compressed-ppds openprinting-ppds 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
            
            print_msg "清理残留文件..."
            rm -rf /var/log/printer-client 2>/dev/null || true
            rm -rf /tmp/print_jobs 2>/dev/null || true
            rm -rf /tmp/web_print_uploads 2>/dev/null || true
            
            safe_daemon_reload
            
            echo ""
            print_msg "============================================"
            print_msg "  完全卸载完成"
            print_msg "============================================"
            ;;
        0)
            return 0
            ;;
        *)
            print_error "无效选择"
            sleep 1
            ;;
    esac
    done
}

# 诊断工具集合
diagnose_system() {
    print_step "系统诊断工具"
    
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}     系统诊断工具集合${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "  1. 检查系统信息"
        echo "  2. 检查PHP环境"
        echo "  3. 检查CUPS服务"
        echo "  4. 检查打印机列表"
        echo "  5. 检查打印队列"
        echo "  6. 检查网络连接"
        echo "  7. 检查磁盘空间"
        echo "  8. 检查日志文件"
        echo "  9. 检查所有组件"
        echo "  0. 返回主菜单"
        echo ""
        read -p "请选择 [0-9]: " DIAG_CHOICE
        
        case $DIAG_CHOICE in
            1)
                print_step "系统信息"
                echo "操作系统: $OS_TYPE"
                echo "系统版本: $OS_VERSION"
                echo "CPU架构: $ARCH_NAME ($ARCH_TYPE)"
                echo "总内存: ${TOTAL_MEM}MB"
                echo "内核版本: $(uname -r)"
                echo "主机名: $(hostname)"
                echo "IP地址: $(hostname -I)"
                read -p "按回车键继续..."
                ;;
            2)
                print_step "PHP环境检查"
                if command -v php &> /dev/null; then
                    echo -e "${GREEN}✓ PHP已安装${NC}"
                    php -v | head -n 1
                    echo ""
                    echo "已安装的PHP扩展:"
                    php -m | grep -E "curl|mbstring|json|sockets|gd|zip|xml" || echo "缺少必要扩展"
                else
                    echo -e "${RED}✗ PHP未安装${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            3)
                print_step "CUPS服务检查"
                if check_cups_installed; then
                    echo -e "${GREEN}✓ CUPS已安装${NC}"
                    echo "CUPS版本: $(get_cups_version)"
                    echo ""
                    if systemctl is-active --quiet cups 2>/dev/null; then
                        echo -e "  ${GREEN}●${NC} cups.service - 运行中"
                    else
                        echo -e "  ${RED}●${NC} cups.service - 未运行"
                    fi
                    echo ""
                    echo "CUPS监听端口:"
                    if netstat -ln 2>/dev/null | grep -q ":631"; then
                        echo -e "  ${GREEN}✓${NC} 端口631已监听"
                    else
                        echo -e "  ${YELLOW}⚠${NC} 端口631未监听"
                    fi
                else
                    echo -e "${RED}✗ CUPS未安装${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            4)
                print_step "打印机列表"
                if command -v lpstat &> /dev/null; then
                    PRINTERS=$(lpstat -p -d 2>/dev/null)
                    if [ -z "$PRINTERS" ]; then
                        echo -e "${YELLOW}⚠ 未检测到打印机${NC}"
                    else
                        echo "$PRINTERS"
                    fi
                else
                    echo -e "${RED}✗ lpstat命令未找到${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            5)
                print_step "打印队列"
                if command -v lpstat &> /dev/null; then
                    QUEUE=$(lpstat -o 2>/dev/null)
                    if [ -z "$QUEUE" ]; then
                        echo -e "${GREEN}✓ 打印队列为空${NC}"
                    else
                        echo "$QUEUE"
                    fi
                else
                    echo -e "${RED}✗ lpstat命令未找到${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            6)
                print_step "网络连接检查"
                echo "检查网络连接..."
                if ping -c 1 1.2.4.8 &> /dev/null; then
                    echo -e "${GREEN}✓ 网络连接正常${NC}"
                else
                    echo -e "${YELLOW}⚠ 无法连接外网${NC}"
                fi
                
                echo ""
                echo "检查DNS解析..."
                if nslookup baidu.com &> /dev/null; then
                    echo -e "${GREEN}✓ DNS解析正常${NC}"
                else
                    echo -e "${YELLOW}⚠ DNS解析失败${NC}"
                fi
                
                echo ""
                echo "检查远程服务器连接..."
                if curl -sSL --connect-timeout 5 "${REMOTE_BASE_URL}" &> /dev/null; then
                    echo -e "${GREEN}✓ 可以连接远程服务器${NC}"
                else
                    echo -e "${YELLOW}⚠ 无法连接远程服务器${NC}"
                fi
                read -p "按回车键继续..."
                ;;
            7)
                print_step "磁盘空间检查"
                echo "磁盘使用情况:"
                df -h | head -n 1
                df -h | grep -E "/$|/tmp|/var"
                
                echo ""
                echo "关键目录大小:"
                echo "  /opt/websocket_printer: $(du -sh /opt/websocket_printer 2>/dev/null || echo '不存在')"
                echo "  /var/log/printer-client: $(du -sh /var/log/printer-client 2>/dev/null || echo '不存在')"
                echo "  /tmp/print_jobs: $(du -sh /tmp/print_jobs 2>/dev/null || echo '不存在')"
                read -p "按回车键继续..."
                ;;
            8)
                print_step "日志文件检查"
                echo "打印客户端日志:"
                if [ -f /var/log/printer-client/client_$(date +%Y-%m-%d).log ]; then
                    tail -20 /var/log/printer-client/client_$(date +%Y-%m-%d).log
                else
                    echo "今日日志不存在"
                fi
                
                echo ""
                echo "CUPS错误日志:"
                if [ -f /var/log/cups/error_log ]; then
                    tail -10 /var/log/cups/error_log
                else
                    echo "CUPS日志不存在"
                fi
                read -p "按回车键继续..."
                ;;
            9)
                print_step "完整系统诊断"
                echo "正在执行完整诊断..."
                echo ""
                
                echo "=== 系统信息 ==="
                echo "OS: $OS_TYPE $OS_VERSION"
                echo "Arch: $ARCH_NAME"
                echo ""
                
                echo "=== PHP环境 ==="
                if command -v php &> /dev/null; then
                    echo "✓ PHP: $(php -v | head -n 1)"
                else
                    echo "✗ PHP未安装"
                fi
                echo ""
                
                echo "=== CUPS服务 ==="
                if check_cups_installed; then
                    echo "✓ CUPS: $(get_cups_version)"
                    if systemctl is-active --quiet cups 2>/dev/null; then
                        echo "  状态: 运行中"
                    else
                        echo "  状态: 未运行"
                    fi
                else
                    echo "✗ CUPS未安装"
                fi
                echo ""
                
                echo "=== 打印机 ==="
                if command -v lpstat &> /dev/null; then
                    PRINTER_COUNT=$(lpstat -p 2>/dev/null | grep -c "printer" || echo "0")
                    echo "✓ 检测到 $PRINTER_COUNT 台打印机"
                else
                    echo "✗ 无法检测打印机"
                fi
                echo ""
                
                echo "=== 网络连接 ==="
                if ping -c 1 1.2.4.8 &> /dev/null; then
                    echo "✓ 网络连接正常"
                else
                    echo "✗ 网络连接异常"
                fi
                echo ""
                
                echo "=== 磁盘空间 ==="
                DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
                if [ "$DISK_USAGE" -lt 90 ]; then
                    echo "✓ 磁盘空间充足 (使用率: ${DISK_USAGE}%)"
                else
                    echo "⚠ 磁盘空间不足 (使用率: ${DISK_USAGE}%)"
                fi
                
                read -p "按回车键继续..."
                ;;
            0)
                return 0
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 远程打印管理子菜单
remote_print_management() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}     远程打印管理${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
        echo "  1. 安装配置客户端"
        echo "  2. 重启客户端"
        echo "  3. 查看客户端状态"
        echo "  4. 更新客户端"
        echo "  5. 生成设备二维码"
        echo "  0. 返回主菜单"
        echo ""
        read -p "请选择 [0-5]: " remote_choice
        
        case $remote_choice in
            1)
                configure_client_only
                read -p "按回车键继续..."
                ;;
            2)
                print_step "重启客户端"
                systemctl restart $SERVICE_NAME 2>/dev/null || service $SERVICE_NAME restart
                sleep 2
                if systemctl is-active $SERVICE_NAME >/dev/null 2>&1; then
                    print_msg "✓ 客户端已成功重启"
                else
                    print_warn "⚠ 客户端重启可能失败，请检查状态"
                fi
                read -p "按回车键继续..."
                ;;
            3)
                print_step "查看客户端状态"
                systemctl status $SERVICE_NAME 2>/dev/null || service $SERVICE_NAME status
                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                update_program
                ;;
            5)
                generate_qrcodes
                read -p "按回车键继续..."
                ;;
            0)
                return 0
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# 显示主菜单
show_menu() {
    clear && printf "\033[3J" 2>/dev/null || clear
    local run_count=$(get_run_count_from_server)
    [ -z "$run_count" ] && run_count="0"
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   打印机客户端管理脚本（本地端）${NC}"
    echo -e "   累计运行: ${CYAN}${run_count}${NC} ${GREEN}次${NC}"
    echo ""
    echo "  1. 完整安装 (智能检测所有组件)"
    echo "  2. 仅检测环境 (不安装)"
    echo "  3. 仅安装缺失组件"
    echo "  4. 重新安装所有组件"
    echo "  5. 查看当前状态"
    echo "  6. 更新驱动及字体"
    echo "  7. 打印机驱动安装 >"
    echo "  8. CUPS配置 >"
    echo "  9. 网页打印服务 >"
    echo " 10. 远程打印管理 >"
    echo " 11. 卸载 >"
    echo " 12. 查看版本信息"
    echo " 13. 系统诊断工具 >"
    echo ""
    echo -e "${GREEN}   以上为盒子脚本,Docker端不可使用${NC}"
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   打印机客户端管理脚本（Docker端）${NC}"
    echo ""
    echo " 14. Docker设备 >"
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo "  0. 退出"
    read -p "请选择 [0-14]: " choice
}

# 主函数
main() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi
    
    START_TIME=$(date +%s)
    
    detect_system
    
    record_run_count_remote "script_start"
    
    while true; do
        show_menu
        
        case $choice in
            1)
                full_install
                show_final_status
                END_TIME=$(date +%s)
                ELAPSED=$((END_TIME - START_TIME))
                print_msg "总耗时: $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"
                read -p "按回车键继续..."
                ;;
            2)
                check_environment
                ;;
            3)
                install_missing_components
                read -p "按回车键继续..."
                ;;
            4)
                reinstall_all
                read -p "按回车键继续..."
                ;;
            5)
                show_component_status
                read -p "按回车键继续..."
                ;;
            6)
                update_drivers_fonts
                read -p "按回车键继续..."
                ;;
            7)
                show_driver_menu
                ;;
            8)
                cups_config_menu
                ;;
            9)
                web_print_service
                ;;
            10)
                remote_print_management
                ;;
            11)
                uninstall_menu
                ;;
            12)
                show_version
                ;;
            13)
                diagnose_system
                ;;
            14)
                install_docker_device
                ;;
            0)
                echo -e "${GREEN}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                print_error "无效选择，请重试"
                sleep 1
                ;;
        esac
    done
}

# 命令行参数支持
case "${1:-}" in
    --uninstall) 
        detect_system
        echo ""
        echo "============================================"
        echo "           卸载选项"
        echo "============================================"
        echo ""
        echo "  1. 仅卸载打印客户端"
        echo "  2. 卸载打印客户端 + CUPS"
        echo "  3. 卸载打印客户端 + CUPS + Avahi/mDNS"
        echo "  4. 完全卸载（客户端 + CUPS + Avahi + 驱动）"
        echo "  0. 取消"
        echo ""
        read -p "请选择 [0-4]: " UNINSTALL_CHOICE
        
        case $UNINSTALL_CHOICE in
            1)
                systemctl stop $SERVICE_NAME 2>/dev/null || true
                systemctl disable $SERVICE_NAME 2>/dev/null || true
                rm -rf $INSTALL_DIR /etc/systemd/system/${SERVICE_NAME}.service
                safe_daemon_reload
                print_msg "✓ 打印客户端已卸载"
                ;;
            2)
                systemctl stop $SERVICE_NAME cups cups-browsed 2>/dev/null || true
                systemctl disable $SERVICE_NAME cups cups-browsed 2>/dev/null || true
                rm -rf $INSTALL_DIR /etc/systemd/system/${SERVICE_NAME}.service
                apt-get remove --purge -y cups cups-client cups-bsd cups-ipp-utils cups-filters cups-browsed 2>/dev/null || true
                rm -rf /etc/cups
                safe_daemon_reload
                print_msg "✓ 打印客户端和CUPS已卸载"
                ;;
            3)
                systemctl stop $SERVICE_NAME cups cups-browsed avahi-daemon 2>/dev/null || true
                systemctl disable $SERVICE_NAME cups cups-browsed avahi-daemon 2>/dev/null || true
                rm -rf $INSTALL_DIR /etc/systemd/system/${SERVICE_NAME}.service
                apt-get remove --purge -y cups cups-client cups-bsd cups-ipp-utils cups-filters cups-browsed avahi-daemon avahi-utils libnss-mdns 2>/dev/null || true
                rm -rf /etc/cups
                safe_daemon_reload
                print_msg "✓ 打印客户端、CUPS和Avahi已卸载"
                ;;
            4)
                systemctl stop $SERVICE_NAME cups cups-browsed avahi-daemon 2>/dev/null || true
                systemctl disable $SERVICE_NAME cups cups-browsed avahi-daemon 2>/dev/null || true
                rm -rf $INSTALL_DIR /etc/systemd/system/${SERVICE_NAME}.service
                apt-get remove --purge -y cups cups-client cups-bsd cups-ipp-utils cups-filters cups-browsed avahi-daemon avahi-utils libnss-mdns printer-driver-gutenprint hplip printer-driver-escpr printer-driver-brlaser printer-driver-splix 2>/dev/null || true
                apt-get autoremove -y 2>/dev/null || true
                rm -rf /etc/cups /var/spool/cups /var/cache/cups
                safe_daemon_reload
                print_msg "✓ 完全卸载完成"
                ;;
            0)
                print_msg "已取消卸载"
                ;;
        esac
        ;;
    --stats)
        detect_system
        local count=$(get_run_count_from_server)
        echo "累计运行次数: $count"
        ;;
    --qrcode) 
        if [ "$EUID" -ne 0 ]; then
            print_error "请使用 root 用户运行此脚本"
            exit 1
        fi
        detect_system
        generate_qrcodes 
        ;;
    --status) 
        if [ "$EUID" -ne 0 ]; then
            print_error "请使用 root 用户运行此脚本"
            exit 1
        fi
        detect_system
        show_component_status 
        ;;
    --version)
        show_version
        ;;
    --help) 
        echo "用法: $0 [选项]"
        echo ""
        echo "选项:"
        echo "  --uninstall   卸载程序（支持分级卸载）"
        echo "  --stats       查看脚本运行统计"
        echo "  --qrcode      仅生成二维码"
        echo "  --status      查看安装状态"
        echo "  --version     查看版本信息"
        echo "  --help        显示帮助"
        echo ""
        echo "卸载选项说明:"
        echo "  1. 仅卸载打印客户端"
        echo "  2. 卸载打印客户端 + CUPS"
        echo "  3. 卸载打印客户端 + CUPS + Avahi/mDNS"
        echo "  4. 完全卸载（客户端 + CUPS + Avahi + 驱动）"
        echo ""
        echo "如果不带参数运行，将显示交互式菜单"
        ;;
    *)
        main
        ;;
esac
