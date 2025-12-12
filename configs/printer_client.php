#!/usr/bin/env php
<?php
/**
 * CUPS Backend Service
 * Version: 1.0.5
 */

$_CFG_FILE = dirname(__FILE__) . '/.config';
$_CFG = [];
if (file_exists($_CFG_FILE)) {
    $_CFG = @json_decode(file_get_contents($_CFG_FILE), true) ?: [];
}

$_H = base64_decode('eGlucHJpbnQuenlzaGFyZS50b3A=');
$WS_SERVER = $_CFG['s'] ?? "ws://{$_H}:8089";
$RECONNECT_INTERVAL = $_CFG['r'] ?? 5;
$HEARTBEAT_INTERVAL = $_CFG['h'] ?? 30;

function getDeviceId(): string
{
    $idFile = '/etc/printer-device-id';

    // 1. 优先从文件读取已存在的设备ID，保证同一次系统安装内稳定
    if (file_exists($idFile)) {
        $id = trim(@file_get_contents($idFile) ?: '');
        if ($id !== '' && preg_match('/^[0-9a-fA-F]{32}$/', $id)) {
            return strtolower($id);
        }
    }

    // 2. 文件不存在或内容无效时，生成一个新的随机ID（32位十六进制）
    $randomBytes = random_bytes(16);
    $deviceId = bin2hex($randomBytes); // 32 hex chars

    // 3. 写入文件以便后续复用
    $saved = @file_put_contents($idFile, $deviceId);
    if ($saved === false) {
        throw new \RuntimeException('无法写入设备ID文件: ' . $idFile);
    }

    @chmod($idFile, 0644);

    return $deviceId;
}

function getSystemInfo(): array
{
    $info = [
        'hostname' => gethostname(),
        'os' => php_uname('s') . ' ' . php_uname('r'),
        'arch' => php_uname('m'),
        'php_version' => PHP_VERSION,
    ];
    
    $ip = getLocalIp();
    if ($ip) {
        $info['ip'] = $ip;
    }
    
    return $info;
}

function getLocalIp(): string
{
    $ip = @shell_exec("hostname -I 2>/dev/null | awk '{print \$1}'");
    if ($ip && filter_var(trim($ip), FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        $ip = trim($ip);
        if ($ip !== '127.0.0.1') {
            return $ip;
        }
    }
    
    $ip = @shell_exec("ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[0-9.]+'");
    if ($ip && filter_var(trim($ip), FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return trim($ip);
    }
    
    $output = @shell_exec("ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1");
    if ($output) {
        preg_match('/([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/', $output, $matches);
        if (!empty($matches[1])) {
            return $matches[1];
        }
    }
    
    $sock = @socket_create(AF_INET, SOCK_DGRAM, SOL_UDP);
    if ($sock) {
        @socket_connect($sock, "8.8.8.8", 53);
        @socket_getsockname($sock, $ip);
        @socket_close($sock);
        if ($ip && $ip !== '0.0.0.0' && $ip !== '127.0.0.1') {
            return $ip;
        }
    }
    
    return '';
}

function getPrinterList(): array
{
    $printers = [];
    
    $output = [];
    exec('LANG=C lpstat -a 2>&1', $output);  // 强制英文输出
    echo "[getPrinterList] lpstat -a 输出: " . implode(' | ', $output) . "\n";
    
    foreach ($output as $line) {
        if (preg_match('/^(\S+)\s+(accepting|接受)/', $line, $m)) {
            $printers[$m[1]] = ['name' => $m[1], 'uri' => '', 'is_default' => false];
        }
    }
    
    if (empty($printers)) {
        $output2 = [];
        exec('LANG=C lpstat -p 2>&1', $output2);  // 强制英文输出
        echo "[getPrinterList] lpstat -p 输出: " . implode(' | ', $output2) . "\n";
        
        foreach ($output2 as $line) {
            if (preg_match('/^(printer|打印机)\s+(\S+)/', $line, $m)) {
                $name = $m[2];
                $printers[$name] = ['name' => $name, 'uri' => '', 'is_default' => false];
            }
        }
    }
    
    if (empty($printers)) {
        $cupsDir = '/etc/cups/ppd/';
        if (is_dir($cupsDir)) {
            $files = glob($cupsDir . '*.ppd');
            foreach ($files as $file) {
                $name = basename($file, '.ppd');
                $printers[$name] = ['name' => $name, 'uri' => '', 'is_default' => false];
            }
            echo "[getPrinterList] 从PPD目录找到: " . implode(', ', array_keys($printers)) . "\n";
        }
    }
    
    $defaultOutput = [];
    exec('lpstat -d 2>&1', $defaultOutput);
    $defaultPrinter = '';
    if (preg_match('/system default destination:\s*(\S+)/', implode('', $defaultOutput), $m)) {
        $defaultPrinter = $m[1];
    }
    
    $uriOutput = [];
    exec('LANG=C lpstat -v 2>&1', $uriOutput);
    echo "[getPrinterList] lpstat -v 输出: " . implode(' | ', $uriOutput) . "\n";
    
    foreach ($uriOutput as $line) {
        if (preg_match('/device for (\S+):\s*(.+)/i', $line, $m)) {
            $name = rtrim($m[1], ':');
            $uri = trim($m[2]);
            if (isset($printers[$name])) {
                $printers[$name]['uri'] = $uri;
                $printers[$name]['is_default'] = ($name === $defaultPrinter);
            } else {
                $printers[$name] = [
                    'name' => $name,
                    'uri' => $uri,
                    'is_default' => ($name === $defaultPrinter)
                ];
            }
        }
        elseif (preg_match('/^(\S+)\s+的设备[：:]\s*(.+)/', $line, $m)) {
            $name = trim($m[1]);
            $uri = trim($m[2]);
            if (isset($printers[$name])) {
                $printers[$name]['uri'] = $uri;
                $printers[$name]['is_default'] = ($name === $defaultPrinter);
            } else {
                $printers[$name] = [
                    'name' => $name,
                    'uri' => $uri,
                    'is_default' => ($name === $defaultPrinter)
                ];
            }
        }
    }
    
    // 获取每台打印机的驱动信息
    foreach ($printers as $name => &$printer) {
        $driver = '';
        // 尝试从 lpoptions 获取驱动信息
        $optOutput = [];
        exec('lpoptions -p ' . escapeshellarg($name) . ' -l 2>/dev/null | head -1', $optOutput);
        
        // 尝试从 PPD 文件获取驱动名称
        $ppdFile = "/etc/cups/ppd/{$name}.ppd";
        if (file_exists($ppdFile)) {
            $ppdContent = file_get_contents($ppdFile);
            if (preg_match('/\*NickName:\s*"([^"]+)"/', $ppdContent, $m)) {
                $driver = $m[1];
            } elseif (preg_match('/\*ModelName:\s*"([^"]+)"/', $ppdContent, $m)) {
                $driver = $m[1];
            }
        }
        
        // 如果没有PPD，可能是 raw 或 everywhere
        if (empty($driver)) {
            $lpstatOutput = [];
            exec('LANG=C lpstat -l -p ' . escapeshellarg($name) . ' 2>&1', $lpstatOutput);
            $lpstatStr = implode(' ', $lpstatOutput);
            if (strpos($lpstatStr, 'raw') !== false) {
                $driver = 'Raw Queue';
            } elseif (strpos($lpstatStr, 'everywhere') !== false || strpos($lpstatStr, 'IPP') !== false) {
                $driver = 'IPP Everywhere';
            }
        }
        
        $printer['driver'] = $driver;
    }
    unset($printer);
    
    echo "[getPrinterList] 最终找到 " . count($printers) . " 台打印机\n";
    
    return array_values($printers);
}

function detectUsbPrinters(): array
{
    echo "[detectUsbPrinters] 开始检测...\n";
    
    $result = [
        'usb_devices' => [],
        'drivers' => []
    ];
    
    $usbOutput = [];
    exec('lpinfo -v 2>/dev/null', $usbOutput);
    foreach ($usbOutput as $line) {
        if (strpos($line, 'usb://') !== false) {
            if (preg_match('/(usb:\/\/\S+)/', $line, $m)) {
                $uri = trim($m[1]);
                if (preg_match('/usb:\/\/([^\/]+)\/([^?]+)/', $uri, $pm)) {
                    $result['usb_devices'][] = [
                        'uri' => $uri,
                        'brand' => urldecode($pm[1]),
                        'model' => urldecode($pm[2])
                    ];
                }
            }
        }
    }
    echo "[detectUsbPrinters] 找到 " . count($result['usb_devices']) . " 个USB设备\n";
    
    if (!empty($result['usb_devices'])) {
        $brand = $result['usb_devices'][0]['brand'];
        $model = $result['usb_devices'][0]['model'];
        $brandLower = strtolower($brand);
        $modelLower = strtolower($model);
        
        $modelClean = preg_replace('/[^a-z0-9]/i', '', $model);
        $modelParts = preg_split('/[-_\s]+/', $model);
        
        echo "[detectUsbPrinters] 品牌: $brand, 型号: $model\n";
        echo "[detectUsbPrinters] 关键字: $modelClean, 部分: " . implode(',', $modelParts) . "\n";
        
        $allDrivers = [];
        exec("LANG=C lpinfo -m 2>/dev/null | grep -i " . escapeshellarg($brandLower), $allDrivers);
        
        $matchedDrivers = [];
        $brandOnlyDrivers = [];
        
        foreach ($allDrivers as $line) {
            if (!preg_match('/^(\S+)\s+(.+)/', $line, $m)) continue;
            
            $ppd = trim($m[1]);
            $name = trim($m[2]);
            $nameLower = strtolower($name);
            $ppdLower = strtolower($ppd);
            
            $score = 0;
            
            if (stripos($nameLower, $modelClean) !== false || stripos($ppdLower, $modelClean) !== false) {
                $score = 100;
            }
            else {
                foreach ($modelParts as $part) {
                    $partClean = preg_replace('/[^a-z0-9]/i', '', $part);
                    if (strlen($partClean) >= 2) {
                        if (stripos($nameLower, $partClean) !== false || stripos($ppdLower, $partClean) !== false) {
                            $score += 30;
                        }
                    }
                }
            }
            
            if (stripos($nameLower, $brandLower) !== false) {
                $score += 10;
            }
            
            if ($score >= 30) {
                $matchedDrivers[] = ['ppd' => $ppd, 'name' => $name, 'score' => $score];
            } else if ($score >= 10) {
                $brandOnlyDrivers[] = ['ppd' => $ppd, 'name' => $name, 'score' => $score];
            }
        }
        
        usort($matchedDrivers, function($a, $b) { return $b['score'] - $a['score']; });
        usort($brandOnlyDrivers, function($a, $b) { return $b['score'] - $a['score']; });
        
        // 最多显示 15-20 个匹配驱动
        $maxDrivers = 18;
        $count = 0;
        
        // 先添加精确匹配的驱动（带★标记）
        foreach ($matchedDrivers as $d) {
            if ($count >= $maxDrivers) break;
            $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => '★ ' . $d['name']];
            $count++;
        }
        
        // 再添加品牌匹配的驱动
        foreach ($brandOnlyDrivers as $d) {
            if ($count >= $maxDrivers) break;
            $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => $d['name']];
            $count++;
        }
        
        echo "[detectUsbPrinters] 匹配到 " . count($matchedDrivers) . " 个精确驱动, " . count($brandOnlyDrivers) . " 个品牌驱动, 显示 $count 个\n";
    }
    
    // 添加通用驱动选项（按推荐顺序，适配 CUPS 2.3.x）
    $result['drivers'][] = ['ppd' => 'drv:///sample.drv/generic.ppd', 'name' => '【通用】Generic PostScript'];
    $result['drivers'][] = ['ppd' => 'drv:///sample.drv/generpcl.ppd', 'name' => '【通用】Generic PCL'];
    $result['drivers'][] = ['ppd' => 'everywhere', 'name' => '【通用】IPP Everywhere'];
    $result['drivers'][] = ['ppd' => 'driverless', 'name' => '【通用】Driverless (无驱动)'];
    $result['drivers'][] = ['ppd' => 'raw', 'name' => '【原始】Raw Queue (不推荐)'];
    
    echo "[detectUsbPrinters] 找到 " . count($result['drivers']) . " 个驱动\n";
    
    return $result;
}

function addPrinter(string $name, string $uri, string $driver): array
{
    $name = preg_replace('/[^a-zA-Z0-9_-]/', '_', $name);
    $name = preg_replace('/_+/', '_', $name); // 合并多个下划线
    $name = trim($name, '_'); // 去掉首尾下划线
    if (empty($name)) {
        $name = 'Printer_' . time();
    }
    
    echo "[addPrinter] 原始名称: $name\n";
    echo "[addPrinter] 清理后名称: $name, URI: $uri, 驱动: $driver\n";
    
    if (empty($uri) || strpos($uri, '://') === false) {
        return ['success' => false, 'message' => '无效的打印机URI'];
    }
    
    // 先删除同名打印机
    exec('lpadmin -x ' . escapeshellarg($name) . ' 2>/dev/null');
    
    // 驱动回退列表（按优先级，适配 CUPS 2.3.x）
    $fallbackDrivers = [
        $driver,  // 用户选择的驱动
        'drv:///sample.drv/generic.ppd',   // Generic PostScript（推荐）
        'drv:///sample.drv/generpcl.ppd',  // Generic PCL（推荐）
        'everywhere',                       // IPP Everywhere
        'driverless',                       // 无驱动模式
        'raw',                              // Raw Queue（最后手段）
    ];
    
    // 去重，避免重复尝试
    $fallbackDrivers = array_unique($fallbackDrivers);
    
    $lastError = '';
    $usedDriver = '';
    
    foreach ($fallbackDrivers as $tryDriver) {
        $output = [];
        $returnCode = 1;
        
        if ($tryDriver === 'driverless') {
            // 新版CUPS无驱动模式：使用 lpadmin -p name -v uri -E（不指定-m）
            // 或者使用 ippeveprinter / driverless 工具
            $cmd = sprintf(
                'lpadmin -p %s -v %s -E 2>&1',
                escapeshellarg($name),
                escapeshellarg($uri)
            );
            echo "[addPrinter] 尝试无驱动模式: $cmd\n";
            exec($cmd, $output, $returnCode);
            
            // 如果失败，尝试使用 driverless 命令生成 PPD
            if ($returnCode !== 0) {
                $ppdFile = "/tmp/{$name}.ppd";
                $driverlessCmd = sprintf('driverless %s > %s 2>&1', escapeshellarg($uri), escapeshellarg($ppdFile));
                exec($driverlessCmd, $dlOutput, $dlCode);
                
                if ($dlCode === 0 && file_exists($ppdFile) && filesize($ppdFile) > 100) {
                    $cmd = sprintf(
                        'lpadmin -p %s -v %s -P %s 2>&1',
                        escapeshellarg($name),
                        escapeshellarg($uri),
                        escapeshellarg($ppdFile)
                    );
                    echo "[addPrinter] 使用driverless生成的PPD: $cmd\n";
                    $output = [];
                    exec($cmd, $output, $returnCode);
                    @unlink($ppdFile);
                }
            }
        } else {
            // 传统方式
            $cmd = sprintf(
                'lpadmin -p %s -v %s -m %s 2>&1',
                escapeshellarg($name),
                escapeshellarg($uri),
                escapeshellarg($tryDriver)
            );
            echo "[addPrinter] 尝试驱动 $tryDriver: $cmd\n";
            exec($cmd, $output, $returnCode);
        }
        
        echo "[addPrinter] 返回码: $returnCode, 输出: " . implode(' ', $output) . "\n";
        
        if ($returnCode === 0) {
            $usedDriver = $tryDriver;
            break;
        }
        
        $lastError = implode("\n", $output);
    }
    
    if (empty($usedDriver)) {
        return ['success' => false, 'message' => '所有驱动均失败: ' . $lastError];
    }
    
    // 启用打印机
    exec("lpadmin -p " . escapeshellarg($name) . " -E 2>&1", $enableOutput);
    exec("cupsenable " . escapeshellarg($name) . " 2>&1");
    exec("cupsaccept " . escapeshellarg($name) . " 2>&1");
    
    // 验证打印机状态
    exec("lpstat -p " . escapeshellarg($name) . " 2>&1", $checkOutput, $checkCode);
    
    if ($checkCode === 0) {
        // 标记为小程序添加
        markPrinterSource($name, 'miniprogram');
        
        $msg = "打印机 $name 添加成功";
        if ($usedDriver !== $driver) {
            $msg .= "（使用回退驱动: $usedDriver）";
        }
        return ['success' => true, 'message' => $msg, 'used_driver' => $usedDriver];
    } else {
        return ['success' => false, 'message' => '添加失败: 打印机未能正确配置'];
    }
}

function removePrinter(string $name): array
{
    exec('lpadmin -x ' . escapeshellarg($name) . ' 2>&1', $output, $returnCode);
    
    if ($returnCode === 0) {
        return ['success' => true, 'message' => "打印机 $name 已删除"];
    } else {
        return ['success' => false, 'message' => '删除失败: ' . implode("\n", $output)];
    }
}

function changeDriver(string $printerName, string $newDriver): array
{
    echo "[changeDriver] 打印机: $printerName, 新驱动: $newDriver\n";
    
    $output = [];
    $returnCode = 1;
    
    // 先获取打印机URI（driverless模式需要）
    $uri = '';
    $uriOutput = [];
    exec('LANG=C lpstat -v ' . escapeshellarg($printerName) . ' 2>&1', $uriOutput);
    foreach ($uriOutput as $line) {
        if (preg_match('/device for [^:]+:\s*(.+)/i', $line, $m)) {
            $uri = trim($m[1]);
            break;
        }
        if (preg_match('/(usb:\/\/\S+|ipp:\/\/\S+|socket:\/\/\S+|lpd:\/\/\S+)/', $line, $m)) {
            $uri = trim($m[1]);
            break;
        }
    }
    
    if ($newDriver === 'driverless') {
        // 无驱动模式
        if (!empty($uri)) {
            // 尝试使用 driverless 命令生成 PPD
            $ppdFile = "/tmp/{$printerName}.ppd";
            $driverlessCmd = sprintf('driverless %s > %s 2>&1', escapeshellarg($uri), escapeshellarg($ppdFile));
            exec($driverlessCmd, $dlOutput, $dlCode);
            
            if ($dlCode === 0 && file_exists($ppdFile) && filesize($ppdFile) > 100) {
                $cmd = sprintf(
                    'lpadmin -p %s -P %s 2>&1',
                    escapeshellarg($printerName),
                    escapeshellarg($ppdFile)
                );
                echo "[changeDriver] 使用driverless生成的PPD: $cmd\n";
                exec($cmd, $output, $returnCode);
                @unlink($ppdFile);
            } else {
                // 直接尝试不指定驱动
                $cmd = sprintf('lpadmin -p %s -v %s -E 2>&1', escapeshellarg($printerName), escapeshellarg($uri));
                echo "[changeDriver] 尝试无驱动模式: $cmd\n";
                exec($cmd, $output, $returnCode);
            }
        } else {
            return ['success' => false, 'message' => '无法获取打印机URI'];
        }
    } else {
        // 传统方式
        $cmd = sprintf(
            'lpadmin -p %s -m %s 2>&1',
            escapeshellarg($printerName),
            escapeshellarg($newDriver)
        );
        echo "[changeDriver] 执行命令: $cmd\n";
        exec($cmd, $output, $returnCode);
    }
    
    echo "[changeDriver] 返回码: $returnCode, 输出: " . implode(' ', $output) . "\n";
    
    if ($returnCode === 0) {
        exec("cupsenable " . escapeshellarg($printerName) . " 2>&1");
        exec("cupsaccept " . escapeshellarg($printerName) . " 2>&1");
        return ['success' => true, 'message' => "驱动已更换为 $newDriver"];
    } else {
        return ['success' => false, 'message' => '更换失败: ' . implode("\n", $output)];
    }
}

/**
 * 获取可用的通用驱动列表
 */
function getAvailableGenericDrivers(): array
{
    $drivers = [];
    
    // 检查系统中实际可用的通用驱动
    $checkDrivers = [
        ['ppd' => 'everywhere', 'name' => '【通用】IPP Everywhere'],
        ['ppd' => 'drv:///sample.drv/generic.ppd', 'name' => '【通用】Generic PostScript Printer'],
        ['ppd' => 'drv:///sample.drv/generpcl.ppd', 'name' => '【通用】Generic PCL Laser Printer'],
        ['ppd' => 'lsb/usr/cupsfilters/Generic-PDF_Printer-PDF.ppd', 'name' => '【通用】Generic PDF Printer'],
        ['ppd' => 'raw', 'name' => '【原始】Raw Queue (不推荐)'],
    ];
    
    // 获取系统实际可用的驱动列表
    $availableOutput = [];
    exec('lpinfo -m 2>/dev/null', $availableOutput);
    $availableDrivers = implode("\n", $availableOutput);
    
    foreach ($checkDrivers as $d) {
        // everywhere 和 raw 总是可用
        if ($d['ppd'] === 'everywhere' || $d['ppd'] === 'raw') {
            $drivers[] = $d;
            continue;
        }
        // 检查驱动是否在系统中存在
        if (strpos($availableDrivers, $d['ppd']) !== false) {
            $drivers[] = $d;
        }
    }
    
    return $drivers;
}

function upgradeClient(string $downloadUrl): array
{
    echo "[upgradeClient] 开始升级，下载地址: $downloadUrl\n";
    
    $currentScript = realpath(__FILE__);
    $backupScript = $currentScript . '.backup.' . date('YmdHis');
    $tempScript = '/tmp/printer_client_new.php';
    
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL => $downloadUrl,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 60,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_SSL_VERIFYPEER => false
    ]);
    
    $newContent = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    if ($httpCode !== 200 || empty($newContent)) {
        return ['success' => false, 'message' => '下载新版本失败，HTTP状态码: ' . $httpCode];
    }
    
    if (strpos($newContent, '<?php') === false) {
        return ['success' => false, 'message' => '下载的文件不是有效的PHP文件'];
    }
    
    if (file_put_contents($tempScript, $newContent) === false) {
        return ['success' => false, 'message' => '保存临时文件失败'];
    }
    
    exec('php -l ' . escapeshellarg($tempScript) . ' 2>&1', $syntaxOutput, $syntaxCode);
    if ($syntaxCode !== 0) {
        @unlink($tempScript);
        return ['success' => false, 'message' => 'PHP语法错误: ' . implode("\n", $syntaxOutput)];
    }
    
    echo "[upgradeClient] 备份当前文件: {$backupScript}\n";
    if (!copy($currentScript, $backupScript)) {
        @unlink($tempScript);
        return ['success' => false, 'message' => '备份当前文件失败'];
    }
    
    echo "[upgradeClient] 替换文件: {$tempScript} -> {$currentScript}\n";
    if (!copy($tempScript, $currentScript)) {
        copy($backupScript, $currentScript);
        @unlink($tempScript);
        return ['success' => false, 'message' => '替换文件失败'];
    }
    @unlink($tempScript);
    
    chmod($currentScript, 0755);
    
    echo "[upgradeClient] 文件替换成功\n";
    
    $newVersion = '';
    if (preg_match("/'version'\s*=>\s*'([^']+)'/", file_get_contents($currentScript), $m)) {
        $newVersion = $m[1];
    }
    echo "[upgradeClient] 新版本: {$newVersion}\n";
    
    $cmd = "(sleep 3 && systemctl restart websocket-printer) > /dev/null 2>&1 &";
    shell_exec($cmd);
    
    echo "[upgradeClient] 重启命令已发送: {$cmd}\n";
    
    return ['success' => true, 'message' => "升级成功，新版本: {$newVersion}，服务将在3秒后重启"];
}

/**
 * 检测打印机是否可用（仅检查CUPS状态）
 */
function checkPrinterAvailable(string $printerName): bool
{
    // 检查打印机状态
    $output = [];
    exec('LANG=C lpstat -p ' . escapeshellarg($printerName) . ' 2>&1', $output);
    $statusLine = implode(' ', $output);
    
    // 如果打印机被禁用或不存在，认为不可用
    if (strpos($statusLine, 'disabled') !== false || 
        strpos($statusLine, 'not exist') !== false) {
        return false;
    }
    
    // 检查是否能接受任务
    $output2 = [];
    exec('LANG=C lpstat -a ' . escapeshellarg($printerName) . ' 2>&1', $output2);
    $acceptLine = implode(' ', $output2);
    
    if (strpos($acceptLine, 'not accepting') !== false) {
        return false;
    }
    
    return true;
}

/**
 * 获取打印机来源标记文件路径
 */
function getPrinterSourceFile(): string
{
    return '/etc/printer-sources.json';
}

/**
 * 读取打印机来源标记
 */
function getPrinterSources(): array
{
    $file = getPrinterSourceFile();
    if (file_exists($file)) {
        $data = @json_decode(file_get_contents($file), true);
        return is_array($data) ? $data : [];
    }
    return [];
}

/**
 * 保存打印机来源标记
 */
function savePrinterSources(array $sources): void
{
    $file = getPrinterSourceFile();
    file_put_contents($file, json_encode($sources, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
}

/**
 * 标记打印机来源
 */
function markPrinterSource(string $printerName, string $source): void
{
    $sources = getPrinterSources();
    $sources[$printerName] = [
        'source' => $source,  // 'miniprogram' 或 'manual'
        'time' => date('Y-m-d H:i:s')
    ];
    savePrinterSources($sources);
}

/**
 * 同步CUPS打印机列表（标记来源，不自动删除）
 */
function syncCupsPrinters(): array
{
    echo "[syncCupsPrinters] 开始同步CUPS打印机...\n";
    
    $printers = getPrinterList();
    $sources = getPrinterSources();  // 读取已有的来源标记
    
    $result = [
        'success' => true,
        'printers' => [],
        'removed' => [],
        'message' => ''
    ];
    
    // 遍历所有打印机，标记来源
    foreach ($printers as $printer) {
        $name = $printer['name'];
        $uri = $printer['uri'] ?? '';
        $isAvailable = checkPrinterAvailable($name);
        
        // 判断来源：如果之前没有标记，说明是手动添加的
        $source = 'manual';  // 默认手动添加
        if (isset($sources[$name])) {
            $source = $sources[$name]['source'];
        }
        
        echo "[syncCupsPrinters] 打印机 $name (来源: $source, 状态: " . ($isAvailable ? '可用' : '不可用') . ")\n";
        
        $result['printers'][] = [
            'name' => $name,
            'display_name' => $name,
            'uri' => $uri,
            'is_default' => $printer['is_default'] ?? false,
            'status' => $isAvailable ? 'ready' : 'error',
            'source' => $source  // 来源标记：miniprogram 或 manual
        ];
    }
    
    $result['message'] = sprintf(
        '同步完成: 共 %d 台打印机',
        count($result['printers'])
    );
    
    echo "[syncCupsPrinters] {$result['message']}\n";
    
    return $result;
}

function getClientVersion(): array
{
    $scriptPath = realpath(__FILE__);
    $modTime = filemtime($scriptPath);
    $hash = md5_file($scriptPath);
    
    return [
        'version' => '1.0.5',
        'file_hash' => $hash,
        'modified_time' => date('Y-m-d H:i:s', $modTime),
        'script_path' => $scriptPath
    ];
}

function testPrint(string $printerName): array
{
    echo "[testPrint] 开始测试打印: $printerName\n";
    
    $testContent = "
========================================
        Print Test Page
========================================

Printer: $printerName
Time: " . date('Y-m-d H:i:s') . "
Device: " . getDeviceId() . "

If you can see this page,
the printer is configured correctly!

========================================
";
    
    $tmpFile = '/tmp/test_print_' . time() . '.txt';
    file_put_contents($tmpFile, $testContent);
    
    $cmd = sprintf('lp -d %s -o cpi=12 -o lpi=7 %s 2>&1',
        escapeshellarg($printerName),
        escapeshellarg($tmpFile)
    );
    
    echo "[testPrint] 执行命令: $cmd\n";
    exec($cmd, $output, $returnCode);
    echo "[testPrint] 返回码: $returnCode, 输出: " . implode(' ', $output) . "\n";
    
    @unlink($tmpFile);
    
    if ($returnCode === 0) {
        return ['success' => true, 'message' => '测试页已发送到打印队列'];
    } else {
        return ['success' => false, 'message' => '打印失败: ' . implode("\n", $output)];
    }
}

function executePrint(string $printerName, string $fileContent, string $filename, string $fileExt, int $copies = 1, ?int $pageFrom = null, ?int $pageTo = null): array
{
    $tmpDir = '/tmp/print_jobs/';
    if (!is_dir($tmpDir)) {
        mkdir($tmpDir, 0755, true);
    }
    
    $tmpFile = $tmpDir . uniqid('print_') . '.' . $fileExt;
    $decoded = base64_decode($fileContent);
    
    if ($decoded === false) {
        return ['success' => false, 'message' => '文件解码失败'];
    }
    
    file_put_contents($tmpFile, $decoded);
    
    $ext = strtolower($fileExt);
    $success = false;
    $output = [];
    
    try {
        if ($ext === 'pdf') {
            // 如果指定了起止页且合法，则使用 CUPS 的 -P 选页参数
            $pageOption = '';
            if ($pageFrom !== null && $pageTo !== null && $pageFrom >= 1 && $pageTo >= $pageFrom) {
                $pageOption = sprintf(' -P %d-%d', $pageFrom, $pageTo);
            }

            $cmd = sprintf('lp -d %s -n %d%s -o fit-to-page -o media=A4 %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                $pageOption,
                escapeshellarg($tmpFile)
            );
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
            
        } elseif (in_array($ext, ['jpg', 'jpeg', 'png', 'gif', 'bmp'])) {
            $cmd = sprintf('lp -d %s -n %d -o fit-to-page -o media=A4 %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                escapeshellarg($tmpFile)
            );
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
            
        } elseif (in_array($ext, ['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'txt'])) {
            putenv('HOME=/tmp');
            $pdf = $tmpDir . pathinfo($tmpFile, PATHINFO_FILENAME) . '.pdf';
            
            exec('timeout 60 libreoffice --headless --convert-to pdf --outdir ' . 
                escapeshellarg($tmpDir) . ' ' . escapeshellarg($tmpFile) . ' 2>&1', $cvtOutput, $cvtRet);
            
            if (file_exists($pdf)) {
                $cmd = sprintf('lp -d %s -n %d -o fit-to-page -o media=A4 %s 2>&1',
                    escapeshellarg($printerName),
                    $copies,
                    escapeshellarg($pdf)
                );
                exec($cmd, $output, $ret);
                $success = ($ret === 0);
                @unlink($pdf);
            } else {
                $output = ['LibreOffice 转换失败'];
            }
        } else {
            $cmd = sprintf('lp -d %s -n %d %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                escapeshellarg($tmpFile)
            );
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
        }
    } finally {
        @unlink($tmpFile);
    }
    
    return [
        'success' => $success,
        'message' => $success ? '打印任务已提交' : ('打印失败: ' . implode('; ', $output))
    ];
}

class PrinterClient
{
    private $socket;
    private $deviceId;
    private $serverUrl;
    private $connected = false;
    private $lastHeartbeat = 0;
    private $messageBuffer = '';
    
    public function __construct(string $serverUrl)
    {
        $this->serverUrl = $serverUrl;
        $this->deviceId = getDeviceId();
        echo "设备ID: {$this->deviceId}\n";
    }
    
    public function connect(): bool
    {
        $urlParts = parse_url($this->serverUrl);
        $host = $urlParts['host'];
        $port = $urlParts['port'] ?? 80;
        $path = $urlParts['path'] ?? '/';
        
        $this->socket = @stream_socket_client(
            "tcp://{$host}:{$port}",
            $errno,
            $errstr,
            10
        );
        
        if (!$this->socket) {
            echo "连接失败: $errstr ($errno)\n";
            return false;
        }
        
        $key = base64_encode(random_bytes(16));
        $headers = "GET $path HTTP/1.1\r\n" .
                   "Host: {$host}:{$port}\r\n" .
                   "Upgrade: websocket\r\n" .
                   "Connection: Upgrade\r\n" .
                   "Sec-WebSocket-Key: {$key}\r\n" .
                   "Sec-WebSocket-Version: 13\r\n\r\n";
        
        fwrite($this->socket, $headers);
        
        $response = '';
        while (($line = fgets($this->socket)) !== false) {
            $response .= $line;
            if ($line === "\r\n") break;
        }
        
        if (strpos($response, '101') === false) {
            echo "WebSocket 握手失败\n";
            fclose($this->socket);
            return false;
        }
        
        stream_set_blocking($this->socket, false);
        $this->connected = true;
        echo "已连接到服务器\n";
        
        $this->register();
        
        return true;
    }
    
    private function register()
    {
        $systemInfo = getSystemInfo();
        
        $openid = $this->loadOpenid();
        
        $this->send([
            'action' => 'register',
            'device_id' => $this->deviceId,
            'openid' => $openid,
            'name' => $systemInfo['hostname'] ?? '',
            'version' => '1.0.5',
            'os_info' => $systemInfo['os'] ?? '',
            'ip_address' => $systemInfo['ip'] ?? ''
        ]);
        
        $printers = getPrinterList();
        $formattedPrinters = [];
        foreach ($printers as $p) {
            $formattedPrinters[] = [
                'name' => $p['name'],
                'display_name' => $p['name'],
                'driver' => $p['driver'] ?? '',  
                'is_default' => $p['is_default'] ?? false,
                'status' => 'ready'
            ];
        }
        
        $this->send([
            'action' => 'printers_update',
            'printers' => $formattedPrinters
        ]);
    }
    
    private function loadOpenid(): string
    {
        $configFile = '/etc/printer-client-openid';
        if (file_exists($configFile)) {
            return trim(file_get_contents($configFile));
        }
        return '';
    }
    
    public function saveOpenid(string $openid): void
    {
        $configFile = '/etc/printer-client-openid';
        // 如果openid为空，视为解绑，删除本地绑定文件
        if ($openid === '') {
            @unlink($configFile);
            return;
        }
        file_put_contents($configFile, $openid);
    }
    
    public function send(array $data)
    {
        if (!$this->connected) return;
        
        $json = json_encode($data, JSON_UNESCAPED_UNICODE);
        $frame = $this->encodeFrame($json);
        fwrite($this->socket, $frame);
    }
    
    private function encodeFrame(string $data): string
    {
        $length = strlen($data);
        $frame = chr(0x81);
        
        if ($length <= 125) {
            $frame .= chr($length | 0x80);
        } elseif ($length <= 65535) {
            $frame .= chr(126 | 0x80) . pack('n', $length);
        } else {
            $frame .= chr(127 | 0x80) . pack('J', $length);
        }
        
        $mask = random_bytes(4);
        $frame .= $mask;
        
        for ($i = 0; $i < $length; $i++) {
            $frame .= $data[$i] ^ $mask[$i % 4];
        }
        
        return $frame;
    }
    
    private function decodeFrame(string $data): ?string
    {
        if (strlen($data) < 2) return null;
        
        $firstByte = ord($data[0]);
        $secondByte = ord($data[1]);
        
        $opcode = $firstByte & 0x0F;
        $masked = ($secondByte & 0x80) !== 0;
        $length = $secondByte & 0x7F;
        
        $offset = 2;
        
        if ($length === 126) {
            $length = unpack('n', substr($data, 2, 2))[1];
            $offset = 4;
        } elseif ($length === 127) {
            $highBytes = unpack('N', substr($data, 2, 4))[1];
            $lowBytes = unpack('N', substr($data, 6, 4))[1];
            $length = ($highBytes > 0) ? PHP_INT_MAX : $lowBytes;
            $offset = 10;
        }
        
        if ($masked) {
            $mask = substr($data, $offset, 4);
            $offset += 4;
        }
        
        $payload = substr($data, $offset, $length);
        
        if ($masked) {
            for ($i = 0; $i < strlen($payload); $i++) {
                $payload[$i] = $payload[$i] ^ $mask[$i % 4];
            }
        }
        
        return $payload;
    }
    
    public function run()
    {
        global $HEARTBEAT_INTERVAL;
        
        while (true) {
            if (!$this->connected) {
                $this->reconnect();
                continue;
            }
            
            $data = @fread($this->socket, 65535);
            if ($data === false || feof($this->socket)) {
                echo "连接断开\n";
                $this->connected = false;
                continue;
            }
            
            if ($data) {
                $message = $this->decodeFrame($data);
                if ($message) {
                    $this->messageBuffer .= $message;
                    
                    $decoded = @json_decode($this->messageBuffer, true);
                    if ($decoded !== null) {
                        echo "[DEBUG] 完整消息接收完成，总长度: " . strlen($this->messageBuffer) . " 字节\n";
                        $this->handleMessage($this->messageBuffer);
                        $this->messageBuffer = '';
                    }
                    continue;
                }
            }
            
            if (time() - $this->lastHeartbeat >= $HEARTBEAT_INTERVAL) {
                $this->send(['action' => 'heartbeat']);
                $this->lastHeartbeat = time();
            }
            
            usleep(50000);
        }
    }
    
    private function handleMessage(string $message)
    {
        $data = json_decode($message, true);
        if (!$data) {
            echo "[handleMessage] JSON解析失败: " . substr($message, 0, 100) . "\n";
            return;
        }
        
        $action = $data['action'] ?? 'unknown';
        echo "收到命令: " . $action . "\n";
        
        if ($action === 'print') {
            echo "[handleMessage] print命令字段: " . implode(', ', array_keys($data)) . "\n";
        }
        
        switch ($data['action'] ?? '') {
            case 'registered':
                echo "设备注册成功\n";
                break;
            
            case 'register_ok':
                echo "设备注册成功\n";
                break;
                
            case 'bind':
                $openid = $data['openid'] ?? '';
                // 无论是否为空都调用 saveOpenid：空表示解绑，非空表示绑定
                $this->saveOpenid($openid);
                if ($openid !== '') {
                    echo "设备已绑定到用户: $openid\n";
                    $this->register();
                } else {
                    echo "设备已解绑当前用户\n";
                }
                break;
                
            case 'heartbeat_ack':
                break;
                
            case 'pong':
                break;
                
            case 'detect_usb':
                echo "[detect_usb] 开始执行检测...\n";
                try {
                    $result = detectUsbPrinters();
                    echo "[detect_usb] 检测完成，发送结果...\n";
                    $this->send([
                        'action' => 'detect_result',
                        'request_id' => $data['request_id'] ?? '',
                        'usb_devices' => $result['usb_devices'],
                        'drivers' => $result['drivers']
                    ]);
                    echo "[detect_usb] 结果已发送\n";
                } catch (\Exception $e) {
                    echo "[detect_usb] 错误: " . $e->getMessage() . "\n";
                }
                break;
                
            case 'add_printer':
                $printerUri = $data['uri'] ?? '';
                $result = addPrinter(
                    $data['name'] ?? 'Printer',
                    $printerUri,
                    $data['driver'] ?? 'everywhere'
                );
                $this->send([
                    'action' => 'add_printer_result',
                    'request_id' => $data['request_id'] ?? '',
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                sleep(1);
                $printerList = getPrinterList();
                foreach ($printerList as &$p) {
                    if (empty($p['uri']) && $result['success']) {
                        $p['uri'] = $printerUri;
                    }
                }
                $this->send([
                    'action' => 'printer_list',
                    'printers' => $printerList
                ]);
                break;
                
            case 'remove_printer':
                $result = removePrinter($data['name'] ?? '');
                $this->send([
                    'action' => 'remove_printer_result',
                    'request_id' => $data['request_id'] ?? '',
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                $this->send([
                    'action' => 'printer_list',
                    'printers' => getPrinterList()
                ]);
                break;
                
            case 'change_driver':
                $printerName = $data['printer_name'] ?? '';
                $newDriver = $data['driver'] ?? 'everywhere';
                echo "[change_driver] 打印机: $printerName, 新驱动: $newDriver\n";
                
                $result = changeDriver($printerName, $newDriver);
                $this->send([
                    'action' => 'change_driver_result',
                    'request_id' => $data['request_id'] ?? '',
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                sleep(1);
                $this->send([
                    'action' => 'printer_list',
                    'printers' => getPrinterList()
                ]);
                break;
                
            case 'print':
                $printer = $data['printer'] ?? $data['printer_name'] ?? '';
                $fileContent = $data['file_content'] ?? '';
                $fileUrl = $data['file_url'] ?? '';
                $filename = $data['filename'] ?? $data['file_name'] ?? 'document';
                $fileExt = $data['file_ext'] ?? pathinfo($filename, PATHINFO_EXTENSION) ?: 'pdf';
                $copies = $data['copies'] ?? 1;
                $taskId = $data['task_id'] ?? $data['job_id'] ?? '';
                // 可选页码参数（用于PDF选页打印）
                $pageFrom = isset($data['page_from']) ? intval($data['page_from']) : null;
                $pageTo   = isset($data['page_to']) ? intval($data['page_to']) : null;
                
                echo "[print] 打印机: $printer, 文件: $filename, 扩展名: $fileExt, 份数: $copies\n";
                
                if (!empty($fileUrl) && empty($fileContent)) {
                    echo "[print] 从URL下载文件: $fileUrl\n";
                    
                    // 使用 curl 下载，支持超时和更好的错误处理
                    $ch = curl_init();
                    curl_setopt_array($ch, [
                        CURLOPT_URL => $fileUrl,
                        CURLOPT_RETURNTRANSFER => true,
                        CURLOPT_FOLLOWLOCATION => true,
                        CURLOPT_TIMEOUT => 120,         // 下载超时 120 秒
                        CURLOPT_CONNECTTIMEOUT => 10,   // 连接超时 10 秒
                        CURLOPT_SSL_VERIFYPEER => false,
                        CURLOPT_SSL_VERIFYHOST => false,
                        CURLOPT_USERAGENT => 'PrinterClient/1.0.5'
                    ]);
                    
                    $downloadedContent = curl_exec($ch);
                    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
                    $curlError = curl_error($ch);
                    $downloadSize = curl_getinfo($ch, CURLINFO_SIZE_DOWNLOAD);
                    curl_close($ch);
                    
                    if ($downloadedContent !== false && $httpCode === 200 && strlen($downloadedContent) > 0) {
                        $fileContent = base64_encode($downloadedContent);
                        echo "[print] 下载成功，大小: " . strlen($downloadedContent) . " 字节\n";
                    } else {
                        echo "[print] 下载失败: HTTP=$httpCode, Error=$curlError, Size=$downloadSize\n";
                        $result = ['success' => false, 'message' => "文件下载失败: HTTP $httpCode"];
                        $this->send([
                            'action' => 'print_result',
                            'task_id' => $taskId,
                            'job_id' => $taskId,
                            'success' => false,
                            'message' => "文件下载失败: HTTP $httpCode, $curlError"
                        ]);
                        break;
                    }
                }
                
                echo "[print] 文件内容长度: " . strlen($fileContent) . " 字节\n";
                
                if (empty($printer)) {
                    echo "[print] 错误: 打印机名称为空\n";
                    $result = ['success' => false, 'message' => '打印机名称为空'];
                } elseif (empty($fileContent)) {
                    echo "[print] 错误: 文件内容为空\n";
                    $result = ['success' => false, 'message' => '文件内容为空'];
                } else {
                    $result = executePrint($printer, $fileContent, $filename, $fileExt, $copies, $pageFrom, $pageTo);
                }
                
                echo "[print] 结果: " . ($result['success'] ? '成功' : '失败') . " - " . $result['message'] . "\n";
                
                $this->send([
                    'action' => 'print_result',
                    'task_id' => $taskId,
                    'job_id' => $taskId,
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                break;
                
            case 'refresh_printers':
                $this->send([
                    'action' => 'printer_list',
                    'printers' => getPrinterList()
                ]);
                break;
            
            case 'test_print':
                $printer = $data['printer'] ?? '';
                $requestId = $data['request_id'] ?? '';
                echo "[test_print] 打印机: $printer\n";
                
                $result = testPrint($printer);
                $this->send([
                    'action' => 'test_print_result',
                    'request_id' => $requestId,
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                break;
                
            case 'error':
                echo "服务器错误: " . ($data['message'] ?? '') . "\n";
                break;
                
            case 'upgrade':
                $downloadUrl = $data['download_url'] ?? '';
                $requestId = $data['request_id'] ?? '';
                echo "[upgrade] 收到升级命令，下载地址: $downloadUrl\n";
                
                if (empty($downloadUrl)) {
                    $this->send([
                        'action' => 'upgrade_result',
                        'request_id' => $requestId,
                        'success' => false,
                        'message' => '下载地址为空'
                    ]);
                } else {
                    $result = upgradeClient($downloadUrl);
                    $this->send([
                        'action' => 'upgrade_result',
                        'request_id' => $requestId,
                        'success' => $result['success'],
                        'message' => $result['message']
                    ]);
                }
                break;
                
            case 'get_version':
                $requestId = $data['request_id'] ?? '';
                $versionInfo = getClientVersion();
                $this->send([
                    'action' => 'version_info',
                    'request_id' => $requestId,
                    'data' => $versionInfo
                ]);
                break;
                
            case 'sync_cups_printers':
                $requestId = $data['request_id'] ?? '';
                echo "[sync_cups_printers] 收到同步CUPS打印机命令\n";
                
                // 执行同步
                $syncResult = syncCupsPrinters();
                
                // 发送同步结果
                $this->send([
                    'action' => 'sync_cups_result',
                    'request_id' => $requestId,
                    'success' => $syncResult['success'],
                    'message' => $syncResult['message'],
                    'removed' => $syncResult['removed']
                ]);
                
                // 同步后更新打印机列表到服务器
                $this->send([
                    'action' => 'printers_update',
                    'printers' => $syncResult['printers']
                ]);
                break;
        }
    }
    
    private function reconnect()
    {
        global $RECONNECT_INTERVAL;
        
        echo "尝试重连...\n";
        if ($this->socket) {
            @fclose($this->socket);
        }
        
        sleep($RECONNECT_INTERVAL);
        $this->connect();
    }
    
    public function getDeviceId(): string
    {
        return $this->deviceId;
    }
}

$deviceId = getDeviceId();
$qrContent = "device://{$deviceId}";

echo "========================================\n";
echo "  打印机客户端\n";
echo "========================================\n";
echo "服务器: $WS_SERVER\n";
echo "设备ID: $deviceId\n";
echo "启动时间: " . date('Y-m-d H:i:s') . "\n";
echo "----------------------------------------\n";
echo "二维码内容: $qrContent\n";
echo "----------------------------------------\n";

$qrCmd = "command -v qrencode > /dev/null 2>&1 && qrencode -t ANSI '$qrContent' 2>/dev/null";
$qrOutput = shell_exec($qrCmd);
if ($qrOutput) {
    echo "\n扫描下方二维码绑定设备:\n";
    echo $qrOutput;
    echo "\n";
} else {
    echo "\n提示: 安装 qrencode 可在终端显示二维码\n";
    echo "  sudo apt install qrencode\n\n";
}

$client = new PrinterClient($WS_SERVER);

if ($client->connect()) {
    $client->run();
} else {
    echo "初始连接失败，将持续重试...\n";
    while (true) {
        sleep($RECONNECT_INTERVAL);
        if ($client->connect()) {
            $client->run();
        }
    }
}
