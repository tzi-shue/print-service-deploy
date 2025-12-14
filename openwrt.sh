# OpenWrt WebSocket 打印客户端

适用于OpenWrt路由器的WebSocket打印客户端安装程序。

## 系统要求

- OpenWrt 19.07 或更高版本
- 至少 32MB 可用存储空间
- 至少 64MB 内存
- 支持 USB 或网络打印机

## 推荐设备

- 软路由 (x86)
- 高性能路由器 (如 Newifi D2, K2P 等)
- 树莓派运行 OpenWrt

## 安装步骤

### 1. SSH连接到路由器
```bash
ssh root@192.168.1.1
```

### 2. 上传安装文件
使用 SCP 或 WinSCP 上传文件：
```bash
scp install.sh root@192.168.1.1:/tmp/
scp printer_client.php root@192.168.1.1:/tmp/
```

### 3. 运行安装脚本
```bash
cd /tmp
chmod +x install.sh
./install.sh
```

### 4. 选择 "1. 完整安装"
按提示输入WebSocket服务器地址

## 管理命令

```bash
# 启动服务
/etc/init.d/websocket_printer start

# 停止服务
/etc/init.d/websocket_printer stop

# 重启服务
/etc/init.d/websocket_printer restart

# 查看状态
/etc/init.d/websocket_printer status

# 启用开机自启
/etc/init.d/websocket_printer enable

# 禁用开机自启
/etc/init.d/websocket_printer disable

# 查看日志
logread | grep -i print
```

## 配置文件

配置文件位置: `/etc/websocket_printer.conf`

```bash
WS_SERVER="ws://xinprint.zyshare.top:8089"
RECONNECT_INTERVAL=5
HEARTBEAT_INTERVAL=30
```

## 添加打印机

### USB打印机
1. 安装USB打印支持
   ```bash
   opkg update
   opkg install kmod-usb-printer
   ```

2. 连接打印机后检查
   ```bash
   ls /dev/usb/lp*
   ```

3. 添加到CUPS
   ```bash
   lpadmin -p MyPrinter -E -v usb://dev/usb/lp0 -m everywhere
   ```

### 网络打印机
```bash
# 添加网络打印机
lpadmin -p NetworkPrinter -E -v socket://192.168.1.100:9100 -m everywhere

# 或使用IPP协议
lpadmin -p NetworkPrinter -E -v ipp://192.168.1.100/ipp/print -m everywhere
```

## 存储空间不足

如果路由器存储空间不足，可以使用外置存储：

### 使用U盘扩展
```bash
# 安装必要包
opkg install block-mount kmod-fs-ext4 e2fsprogs

# 格式化U盘
mkfs.ext4 /dev/sda1

# 挂载
mkdir -p /mnt/usb
mount /dev/sda1 /mnt/usb

# 修改安装目录
# 编辑 install.sh，将 INSTALL_DIR 改为 /mnt/usb/websocket_printer
```

## 故障排除

### 问题: opkg update 失败
```bash
# 检查网络
ping -c 3 downloads.openwrt.org

# 更换镜像源
sed -i 's/downloads.openwrt.org/mirrors.tuna.tsinghua.edu.cn\/openwrt/g' /etc/opkg/distfeeds.conf
opkg update
```

### 问题: PHP安装失败
```bash
# 检查可用的PHP版本
opkg list | grep php

# 尝试安装其他版本
opkg install php7-cli
# 或
opkg install php8-cli
```

### 问题: 内存不足
```bash
# 检查内存使用
free -m

# 创建swap
dd if=/dev/zero of=/mnt/usb/swap bs=1M count=128
mkswap /mnt/usb/swap
swapon /mnt/usb/swap
```

### 问题: 服务无法启动
```bash
# 手动运行查看错误
php /opt/websocket_printer/printer_client.php --server=ws://your-server:8089

# 检查PHP扩展
php -m | grep -E "curl|json"
```

## 性能优化

对于资源受限的设备：

1. **减少日志输出**
   编辑配置文件，设置 `log_level` 为 `error`

2. **增加重连间隔**
   将 `RECONNECT_INTERVAL` 改为 `30`

3. **禁用不需要的服务**
   ```bash
   /etc/init.d/uhttpd disable
   /etc/init.d/dnsmasq disable  # 如果不需要DHCP
   ```

## 卸载

```bash
./install.sh
# 选择 "5. 卸载"
```

或手动卸载：
```bash
/etc/init.d/websocket_printer stop
/etc/init.d/websocket_printer disable
rm -f /etc/init.d/websocket_printer
rm -rf /opt/websocket_printer
rm -f /etc/websocket_printer.conf
```
