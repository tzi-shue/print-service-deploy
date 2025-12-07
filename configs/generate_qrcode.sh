#!/bin/bash
# 生成设备二维码脚本（使用PHP生成一致的设备ID）
# 使用方法: ./generate_qrcode.sh

# 使用 PHP 生成设备ID（与 printer_client.php 一致）
DEVICE_ID=$(php -r "
\$machineId = @file_get_contents('/etc/machine-id');
if (\$machineId) {
    echo md5(trim(\$machineId));
} elseif (file_exists('/etc/printer-device-id')) {
    echo trim(file_get_contents('/etc/printer-device-id'));
} else {
    \$mac = trim(shell_exec(\"ip link show | grep -m1 'link/ether' | awk '{print \\\$2}'\"));
    if (\$mac) {
        echo md5(\$mac);
    } else {
        echo 'error';
    }
}
")

if [ "$DEVICE_ID" = "error" ] || [ -z "$DEVICE_ID" ]; then
    echo "无法获取设备ID"
    exit 1
fi

QR_CONTENT="device://$DEVICE_ID"

echo "========================================"
echo "  设备二维码生成器"
echo "========================================"
echo ""
echo "设备ID: $DEVICE_ID"
echo "二维码内容: $QR_CONTENT"
echo ""

# 检查是否安装了 qrencode
if command -v qrencode &> /dev/null; then
    echo "在终端显示二维码:"
    echo ""
    qrencode -t ANSI "$QR_CONTENT"
    echo ""
    
    # 生成图片文件
    OUTPUT_FILE="/tmp/device_qr.png"
    qrencode -o "$OUTPUT_FILE" -s 10 "$QR_CONTENT"
    echo "二维码图片已保存到: $OUTPUT_FILE"
else
    echo "未安装 qrencode，请先安装:"
    echo "  sudo apt install qrencode"
    echo ""
    echo "或者手动将以下内容生成二维码:"
    echo "  $QR_CONTENT"
fi

echo ""
echo "========================================"
