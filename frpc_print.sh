#!/bin/bash

# 字体颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
FONT="\033[0m"

# 全局变量
SERVICE_NAME=""
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
FRP_NAME="frpc"
FRP_VERSION="0.61.0"
FRP_PATH="/usr/local/frp"
PROXY_URL="https://ghproxy.cfd/"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"

# 函数定义
info() { echo -e "${GREEN}=== $1 ===${FONT}"; }
warn() { echo -e "${YELLOW}$1${FONT}"; }
error_exit() { echo -e "${RED}$1${FONT}"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 清理缓存释放空间（核心优化）
clean_cache() {
    if type apt-get >/dev/null 2>&1; then
        info "清理系统缓存释放空间"
        apt-get clean >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
    fi
}

# 检测并安装CUPS
install_cups_if_needed() {
    if command_exists cupsd || systemctl status cups >/dev/null 2>&1 || [ -f /usr/sbin/cupsd ]; then
        info "CUPS已安装，跳过安装"
        return 0
    fi
    
    info "安装CUPS打印服务"
    if type apt-get >/dev/null 2>&1; then
        PM="apt-get"
        PM_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
    elif type yum >/dev/null 2>&1; then
        PM="yum"
        PM_INSTALL="yum install -y"
    else
        error_exit "不支持的包管理器"
    fi

    # 更新软件包列表
    $PM update || warn "更新软件包列表失败，继续安装"

    # 安装CUPS核心组件
    info "安装CUPS核心组件"
    $PM_INSTALL cups cups-filters ghostscript || {
        clean_cache
        $PM_INSTALL cups cups-filters ghostscript || error_exit "安装CUPS失败"
    }

    # 安装打印机驱动
    info "安装打印机驱动"
    $PM_INSTALL -y printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || {
        clean_cache
        $PM_INSTALL -y printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine || warn "部分打印机驱动安装失败"
    }

    # 安装HP插件
    info "安装HP打印机插件"
    HP_PLUGIN_DIR="/tmp/hp_plugin_$$"
    mkdir -p "$HP_PLUGIN_DIR"
    cd "$HP_PLUGIN_DIR" || error_exit "进入HP插件目录失败"

    # 下载HP插件文件
    wget -q https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-3.20.3-plugin.run || warn "下载HP插件失败"
    wget -q https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hplip-3.20.3-plugin.run.asc || warn "下载HP插件签名失败"
    wget -q https://www.openprinting.org/download/printdriver/auxfiles/HP/plugins/hp_laserjet_1020.plugin || warn "下载HP LaserJet插件失败"

    # 安装HP插件（非交互模式）
    if [ -f "hplip-3.20.3-plugin.run" ]; then
        # 使用非交互模式安装HP插件
        sh hplip-3.20.3-plugin.run --noexec --target ./hplip-extract
        # 或者使用hp-plugin命令的非交互模式
        echo "y" | hp-plugin -p 2>/dev/null || warn "HP插件安装可能存在问题，继续执行"
    else
        warn "HP插件下载失败，跳过安装"
    fi

    # 清理HP插件临时目录
    cd /
    rm -rf "$HP_PLUGIN_DIR"

    # 允许远程访问 CUPS
    info "配置CUPS远程访问"
    cupsctl --remote-any || warn "CUPS远程访问配置失败"
}

# 第一步：检测并安装CUPS（如需要）
clean_cache  # 先清理空间
install_cups_if_needed

# 第二步：检测并安装LibreOffice
if command_exists soffice; then
    info "LibreOffice已安装"
else
    info "安装LibreOffice"
    if type apt-get >/dev/null 2>&1; then
        PM_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
        $PM_INSTALL libreoffice-core libreoffice-writer libreoffice-calc || {
            clean_cache
            $PM_INSTALL libreoffice-core libreoffice-writer libreoffice-calc || error_exit "安装LibreOffice失败"
        }
    elif type yum >/dev/null 2>&1; then
        PM_INSTALL="yum install -y"
        $PM_INSTALL libreoffice-core libreoffice-writer libreoffice-calc || error_exit "安装LibreOffice失败"
    fi
fi

# 第三步：安装基础工具
info "安装基础工具"
if type apt-get >/dev/null 2>&1; then
    PM_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
else
    PM_INSTALL="yum install -y"
fi

$PM_INSTALL wget curl qrencode || {
    clean_cache
    $PM_INSTALL wget curl qrencode || error_exit "安装工具失败"
}

# 第四步：精简打印服务配置
info "配置打印服务"
TEMP_DIR=$(mktemp -d) || error_exit "创建临时目录失败"
cd "$TEMP_DIR" || error_exit "进入临时目录失败"

# 下载必要配置文件
curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || error_exit "下载cupsd.conf失败"
curl -fsSL -o print.php "${REPO_URL}/configs/print.php" || error_exit "下载print.php失败"

# 替换配置
cp cupsd.conf /etc/cups/cupsd.conf && chown root:lp /etc/cups/cupsd.conf && chmod 640 /etc/cups/cupsd.conf || error_exit "替换cupsd.conf失败"
mkdir -p /var/www/html && cp print.php /var/www/html/print.php && chmod 644 /var/www/html/print.php || error_exit "替换print.php失败"

# 立即清理临时文件
rm -rf "$TEMP_DIR"

# 第五步：FRP配置（优化下载流程）
info "配置FRP内网穿透"

# 检查FRP是否已安装
if [ -f "${FRP_PATH}/${FRP_NAME}" ]; then
    info "FRP已安装"
else
    # 系统架构检测
    case $(uname -m) in
        x86_64) PLATFORM="amd64" ;;
        aarch64) PLATFORM="arm64" ;;
        armv7l|armhf) PLATFORM="arm" ;;
        *) error_exit "不支持的架构: $(uname -m)" ;;
    esac

    FILE_NAME="frp_${FRP_VERSION}_linux_${PLATFORM}"
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE_NAME}.tar.gz"
    # 强制使用代理加速
    DOWNLOAD_URL="${PROXY_URL}${DOWNLOAD_URL}"

    # 流式下载解压（不保存压缩包，直接解压到内存）
    info "下载并安装FRP"
    wget -q "$DOWNLOAD_URL" -O - | tar -zxf - -C /tmp || error_exit "FRP安装失败"
    mkdir -p "${FRP_PATH}"
    mv "/tmp/${FILE_NAME}/${FRP_NAME}" "${FRP_PATH}" || error_exit "移动FRP文件失败"
    rm -rf "/tmp/${FILE_NAME}"  # 即时清理

   # 生成服务名称
CURRENT_DATE=$(date +%m%d)
RANDOM_SUFFIX=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 2)
SERVICE_NAME="${CURRENT_DATE}${RANDOM_SUFFIX}"

# 生成随机 remote_port（范围：3000到6000）
REMOTE_PORT_SSH=$((RANDOM % 3001 + 3000))
    # 生成精简FRP配置
    mkdir -p "$(dirname "${FRP_CONFIG_FILE}")"
    cat <<EOL > "${FRP_CONFIG_FILE}"
serverAddr = "frps.tzishue.tk"
serverPort = 7000
auth.token = "12345"
[[proxies]]
name = "print-ssh-$SERVICE_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $REMOTE_PORT_SSH
[[proxies]]
name = "print-web-${SERVICE_NAME}"
type = "http"
localIP = "127.0.0.1"
localPort = 80
subdomain = "nas-${SERVICE_NAME}"
EOL

    # 配置服务
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
    systemctl start "${FRP_NAME}" && systemctl enable "${FRP_NAME}" || error_exit "启动FRP失败"
fi

# 第六步：重启CUPS服务
info "重启CUPS服务"
systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || warn "CUPS服务重启失败，请手动检查"

# 第七步：输出信息并生成二维码
echo -e "\n${GREEN}配置完成${FONT}"
REMOTE_PRINT_ADDR="http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php"
echo -e "远程打印机地址: ${REMOTE_PRINT_ADDR}"

# 生成二维码
echo -e "\n二维码:"
qrencode -t ANSIUTF8 "${REMOTE_PRINT_ADDR}"

echo -e "\n重启FRP命令: systemctl restart ${FRP_NAME}"
echo -e "重启CUPS命令: systemctl restart cups"