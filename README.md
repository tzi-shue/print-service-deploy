# 小程序打印服务自动安装frp、cups及所需依赖

一键在Ubuntu/CentOS系统上自动安装frp及拷贝小程序打印服务文件。

## 快速开始

### 方法一：直接运行
```bash
sudo bash -c "$(curl -fsSL https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main/scripts/frp_print.sh)"
```

### 方法二：直接运行
# 1. 下载脚本到本地
```bash
curl -fsSL https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main/scripts/frp_print.sh -o frp_print.sh
```
# 2. 赋予执行权限
```bash
chmod +x frp_print.sh
```
# 3. 用root权限执行（和原命令效果一致，但可提前查看脚本内容）
```bash
sudo ./frp_print.sh
```

# 小程序打印服务自动拷贝必要文件

一键在Ubuntu/CentOS系统上自动拷贝小程序打印服务文件。

## 快速开始

### 方法一：直接运行
```bash
sudo bash -c "$(curl -fsSL https://ghproxy.cfd/https://raw.githubusercontent.com/tzi-shue/print-service-deploy/main/scripts/copy_print.sh)"
```



