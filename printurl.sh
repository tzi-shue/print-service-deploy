#!/usr/bin/env bash
GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; FONT="\033[0m"
FRP_CONFIG_FILE="/etc/frp/frpc.toml" 

warn()  { echo -e "${YELLOW}$1${FONT}"; }
err()   { echo -e "${RED}$1${FONT}"; exit 1; }
cmdx()  { command -v "$1" >/dev/null 2>&1; }

main() {
    SUB_DOMAIN=$(grep -oP 'subdomain\s*=\s*"\K[^"]+' "$FRP_CONFIG_FILE" 2>/dev/null | head -n1)
    [ -z "$SUB_DOMAIN" ] && err "FRP配置缺失：$FRP_CONFIG_FILE 或 subdomain解析失败"
    
    PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
    [ -z "$PRINTERS" ] && warn "当前系统无可用打印机" && exit 0
    
    echo -e "${GREEN}远程打印链接：${FONT}"
    for pr in $PRINTERS; do
        URL="http://${SUB_DOMAIN}.frp.tzishue.tk/print.php?printer=${pr}"
        echo -e "${GREEN}● $pr${FONT}\n$URL"
        cmdx qrencode && qrencode -t ANSIUTF8 "$URL" || echo -e "${YELLOW}(qrencode未安装，无法显示二维码)${FONT}"
        echo
    done
}

main
