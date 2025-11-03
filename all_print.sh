#!/bin/bash


############### 通用工具 ###############
color(){
    local c="$1" s="$2"; shift 2
    case "$c" in
        g) echo -e "\033[32m=== $s ===\033[0m" ;;
        r) echo -e "\033[31m$*\033[0m" ;;
        y) echo -e "\033[33m$*\033[0m" ;;
    esac
}
info(){ color g "$*"; }
warn(){ color y "$*"; }
error_exit(){ color r "$*" "有问题联系开发者 VX:nmydzf"; exit 1; }
cmd(){ command -v "$1" >/dev/null 2>&1; }

############### 自动换源 ###############
fix_apt_sources(){
    grep -qi 'debian.*stretch\|jessie\|wheezy' /etc/os-release 2>/dev/null && \
        sed -i 's|http://deb.debian.org|http://archive.debian.org|g;
                s|http://security.debian.org|http://archive.debian.org|g' /etc/apt/sources.list
    grep -qi 'ubuntu.*1[0-6]\.' /etc/os-release 2>/dev/null && \
        sed -i 's|http://.*.ubuntu.com|http://old-releases.ubuntu.com|g' /etc/apt/sources.list
}

############### 包管理器统一封装 ###############
pkg_update(){
    if cmd apt-get; then
        fix_apt_sources
        apt-get update >/dev/null 2>&1 || true
    elif cmd yum; then
        yum makecache fast >/dev/null 2>&1 || true
    fi
}
pkg_install(){
    local pkgs="$*"
    if cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends $pkgs >/dev/null 2>&1 || true
    elif cmd yum; then
        yum install -y $pkgs >/dev/null 2>&1 || true
    fi
}

############### 缓存清理（不退出） ###############
clean_cache(){
    if cmd apt-get; then
        info "清理系统缓存"
        apt-get clean              >/dev/null 2>&1 || true
        apt-get autoremove -y      >/dev/null 2>&1 || true
    fi
}

############### CUPS ###############
install_cups(){
    if cmd cupsd || systemctl is-active --quiet cups 2>/dev/null; then
        info "CUPS 已安装"
        return 0
    fi
    info "安装 CUPS"
    pkg_update
    pkg_install cups cups-filters ghostscript \
                printer-driver-gutenprint printer-driver-splix hplip foomatic-db-engine
    cupsctl --remote-any >/dev/null 2>&1 || true
}

############### LibreOffice ###############
install_lo(){
    cmd soffice && return 0
    info "安装 LibreOffice"
    pkg_install libreoffice-core libreoffice-writer libreoffice-calc
}

############### 基础工具 ###############
install_tools(){
    info "安装基础工具"
    pkg_install wget curl qrencode
}

############### 打印服务配置（含重启） ###############
config_print(){
    info "配置打印服务"
    temp=$(mktemp -d) || exit 1
    cd "$temp"
    curl -fsSL -o cupsd.conf "${REPO_URL}/configs/cupsd.conf" || error_exit "下载 cupsd.conf 失败"
    curl -fsSL -o print.php   "${REPO_URL}/configs/print.php"   || error_exit "下载 print.php 失败"
    mkdir -p /etc/cups /var/www/html
    cp cupsd.conf /etc/cups/cupsd.conf
    chown root:lp /etc/cups/cupsd.conf && chmod 640 /etc/cups/cupsd.conf
    cp print.php /var/www/html/print.php && chmod 644 /var/www/html/print.php
    cd / && rm -rf "$temp"
    # ******** 关键：让新配置生效 ********
    systemctl restart cups 2>/dev/null || service cups restart || true
}

############### 打印机检测 ###############
check_printer(){
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    [ -z "$PRINTERS" ] && error_exit "系统未添加任何打印机，请先连接并添加打印机"
    DEFAULT=$(echo "$PRINTERS" | head -n1)
    info "已发现打印机：$(echo "$PRINTERS" | tr '\n' ' ')"
    info "默认使用：$DEFAULT"
}

############### FRP ###############
install_frp(){
    [ -f "${FRP_PATH}/${FRP_NAME}" ] && return 0
    case $(uname -m) in
        x86_64)  ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        armv7l|armhf) ARCH=arm ;;
        *) error_exit "不支持的架构：$(uname -m)" ;;
    esac
    FILE="frp_${FRP_VERSION}_linux_${ARCH}"
    URL="${PROXY_URL}https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FILE}.tar.gz"
    info "安装 FRP"
    wget -qO- "$URL" | tar -xz -C /tmp
    mkdir -p "${FRP_PATH}"
    mv "/tmp/${FILE}/${FRP_NAME}" "${FRP_PATH}"
    rm -rf "/tmp/${FILE}"

    DATE=$(date +%m%d)
    RAND=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c2)
    SERVICE_NAME="${DATE}${RAND}"
    REMOTE_PORT=$((RANDOM % 3001 + 3000))

    mkdir -p "$(dirname "${FRP_CONFIG_FILE}")"
    cat >"${FRP_CONFIG_FILE}" <<EOF
serverAddr = "frps.tzishue.tk"
serverPort = 7000
auth.token = "12345"

[[proxies]]
name = "print-ssh-${SERVICE_NAME}"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = ${REMOTE_PORT}

[[proxies]]
name = "print-web-${SERVICE_NAME}"
type = "http"
localIP = "127.0.0.1"
localPort = 80
subdomain = "nas-${SERVICE_NAME}"
EOF

    # 统一 systemd/sysv 服务
    if cmd systemctl; then
        cat >/etc/systemd/system/${FRP_NAME}.service <<EOF
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
        systemctl enable --now ${FRP_NAME} || true
    else
        cat >/etc/init.d/${FRP_NAME} <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          frpc
# Required-Start:    \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start frpc at boot
### END INIT INFO
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DAEMON=${FRP_PATH}/${FRP_NAME}
DAEMON_ARGS="-c ${FRP_CONFIG_FILE}"
PIDFILE=/var/run/${FRP_NAME}.pid
. /lib/lsb/init-functions
do_start(){ start-stop-daemon --start --quiet --background --make-pidfile --pidfile \$PIDFILE --exec \$DAEMON -- \$DAEMON_ARGS; }
do_stop(){ start-stop-daemon --stop --quiet --pidfile \$PIDFILE; }
case "\$1" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; sleep 1; do_start ;;
  *)       echo "Usage: \$0 {start|stop|restart}" ;;
esac
EOF
        chmod +x /etc/init.d/${FRP_NAME}
        update-rc.d ${FRP_NAME} defaults >/dev/null 2>&1 || true
        /etc/init.d/${FRP_NAME} start
    fi
}

############### 输出二维码 ###############
show_url(){
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    DEFAULT=$(echo "$PRINTERS" | head -n1)
    ADDR="http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php?printer=${DEFAULT}"
    info "远程打印地址：$ADDR"
    echo -e "\n二维码："
    qrencode -t ANSIUTF8 "$ADDR"
    if [ "$(echo "$PRINTERS" | wc -l)" -gt 1 ]; then
        info "全部打印机链接："
        echo "$PRINTERS" | while read -r p; do
            echo "  - $p: http://nas-${SERVICE_NAME}.frp.tzishue.tk/print.php?printer=${p}"
        done
    fi
}

############### 主流程 ###############
REPO_URL="https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main"
FRP_NAME="frpc"
FRP_VERSION="0.61.0"
FRP_PATH="/usr/local/frp"
PROXY_URL="https://ghproxy.cfd/"
FRP_CONFIG_FILE="/etc/frp/frpc.toml"

clean_cache
install_cups
install_lo
install_tools
config_print      # 已自动重启 CUPS
check_printer
install_frp

info "常用命令："
echo "  重启 FRP：systemctl restart ${FRP_NAME} 或 service ${FRP_NAME} restart"
echo "  重启 CUPS：systemctl restart cups 或 service cups restart"
echo -e "\033[32m有问题联系开发者 VX:nmydzf\033[0m"
