#!/usr/bin/env bash
# ==========================================================
#  all_print.sh  ——  纯本地解析 frpc 配置并生成远程打印地址/二维码
# ==========================================================
set -e

FRP_CONFIG="/etc/frp/frpc.toml"

# ---- 颜色 ----
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; FONT="\033[0m"

# ---- 1. 解析子域名 ----
if [ ! -f "$FRP_CONFIG" ]; then
    echo -e "${RED}未找到 FRP 配置文件：$FRP_CONFIG${FONT}"
    exit 1
fi
SUB_DOMAIN=$(grep -oP 'subdomain\s*=\s*"\K[^"]+' "$FRP_CONFIG" | head -n1)
if [ -z "$SUB_DOMAIN" ]; then
    echo -e "${RED}解析 subdomain 失败，请检查 $FRP_CONFIG 格式${FONT}"
    exit 1
fi

# ---- 2. 枚举打印机 ----
PRINTERS=$(lpstat -a 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u)
if [ -z "$PRINTERS" ]; then
    echo -e "${YELLOW}当前系统没有任何打印机${FONT}"
    exit 0
fi

# ---- 3. 输出地址 + 二维码 ----
echo -e "${GREEN}当前全部打印机远程地址：${FONT}"
for pr in $PRINTERS; do
    URL="http://${SUB_DOMAIN}.frp.tzishue.tk/print.php?printer=${pr}"
    echo -e "${GREEN}● $pr${FONT}\n$URL"
    command -v qrencode >/dev/null && qrencode -t ANSIUTF8 "$URL" || echo -e "${YELLOW}(qrencode 未安装，无法显示二维码)${FONT}"
    echo
done
