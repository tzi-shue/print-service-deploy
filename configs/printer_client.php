#!/usr/bin/env php
<?php
/**
 * CUPS Backend Service
 * Version: 1.0.1
 */

$_CFG_FILE = dirname(__FILE__) . '/.config';
$_CFG = [];
if (file_exists($_CFG_FILE)) {
    $_CFG = @json_decode(file_get_contents($_CFG_FILE), true) ?: [];
}

$_H = base64_decode('eGlucHJpbnQuenlzaGFyZS50b3A=');
$WS_SERVER = $_CFG['s'] ?? "ws://{$_H}:8089";
$RECONNECT_INTERVAL = $_CFG['r'] ?? 5;
function getDeviceId(): string
{
    // Linux系统专用设备ID文件路径
    $idFile = '/etc/printer-device-id';

    // 1. 如果文件中已经有设备ID，直接使用（保证重启/重装后不变）
    if (file_exists($idFile)) {
        $id = trim(@file_get_contents($idFile) ?: '');
        if (!empty($id) && strlen($id) === 32) {
            return $id;
        }
    }

    // 2. 获取CPU序列号（仅Linux系统）
    $cpuSerial = '';
    
    // 方法1：尝试标准的Serial字段（适用于大多数x86架构）
    $cpuInfo = @file_get_contents('/proc/cpuinfo');
    if ($cpuInfo && preg_match('/Serial\s*:\s*([0-9a-fA-F]+)/i', $cpuInfo, $m)) {
        $cpuSerial = trim($m[1]);
    }
    
    // 方法2：ARM架构的CPU信息（适用于树莓派等ARM设备）
    if (empty($cpuSerial) && stripos(php_uname('m'), 'arm') !== false) {
        // 尝试获取CPU信息
        $cpuInfo = @shell_exec('cat /proc/device-tree/serial-number 2>/dev/null');
        if (empty($cpuInfo)) {
            $cpuInfo = @shell_exec('cat /sys/firmware/devicetree/base/serial-number 2>/dev/null');
        }
        $cpuSerial = trim($cpuInfo ?: '');
    }
    
    // 方法3：使用dmidecode（需要root权限，适用于x86架构）
    if (empty($cpuSerial) && function_exists('shell_exec')) {
        $dmidecode = @shell_exec('sudo dmidecode -s system-serial-number 2>/dev/null');
        if ($dmidecode && !preg_match('/Not Specified|00000000|To be filled by O.E.M./i', $dmidecode)) {
            $cpuSerial = trim($dmidecode);
        }
    }
    
    // 方法4：使用lshw命令（需要root权限）
    if (empty($cpuSerial) && function_exists('shell_exec')) {
        $lshw = @shell_exec('sudo lshw -json 2>/dev/null');
        if ($lshw) {
            $lshwData = json_decode($lshw, true);
            if ($lshwData && isset($lshwData[0]['system']['serial'])) {
                $cpuSerial = trim($lshwData[0]['system']['serial']);
            }
        }
    }
    
    // 方法5：使用系统UUID作为后备方案（不如CPU序列号唯一，但总比随机好）
    if (empty($cpuSerial)) {
        $uuid = @shell_exec('cat /etc/machine-id 2>/dev/null');
        if (empty($uuid)) {
            $uuid = @shell_exec('cat /var/lib/dbus/machine-id 2>/dev/null');
        }
        $cpuSerial = trim($uuid ?: '');
    }
    
    // 最终验证
    if (empty($cpuSerial)) {
        // 如果所有方法都失败，使用临时解决方案
        $cpuSerial = uniqid('temp-', true);
        error_log("警告：无法获取硬件序列号，使用临时标识符: $cpuSerial");
    } else {
        // 清理输入，只保留有效的十六进制字符
        $cpuSerial = preg_replace('/[^0-9a-fA-F]/', '', $cpuSerial);
        // 如果清理后为空，使用临时方案
        if (empty($cpuSerial)) {
            $cpuSerial = uniqid('temp-', true);
        }
    }

    // 确保序列号不为空
    if (empty($cpuSerial)) {
        $cpuSerial = 'unknown';
    }

    $deviceId = md5('cpu:' . strtolower($cpuSerial));

    // 3. 保存设备ID到文件
    $saved = @file_put_contents($idFile, $deviceId);
    if ($saved !== false) {
        @chmod($idFile, 0644);
    }

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
        
        $count = 0;
        foreach ($matchedDrivers as $d) {
            if ($count >= 10) break;
            $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => $d['name'] . ' ★'];
            $count++;
        }
        
        if ($count < 5) {
            foreach ($brandOnlyDrivers as $d) {
                if ($count >= 10) break;
                $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => $d['name']];
                $count++;
            }
        }
        
        echo "[detectUsbPrinters] 匹配到 " . count($matchedDrivers) . " 个精确驱动, " . count($brandOnlyDrivers) . " 个品牌驱动\n";
    }
    
    $result['drivers'][] = ['ppd' => 'everywhere', 'name' => 'IPP Everywhere (通用)'];
    $result['drivers'][] = ['ppd' => 'raw', 'name' => 'Raw Queue (原始-不推荐)'];
    
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
    
    exec('lpadmin -x ' . escapeshellarg($name) . ' 2>/dev/null');
    
    $cmd1 = sprintf(
        'lpadmin -p %s -v %s -m %s 2>&1',
        escapeshellarg($name),
        escapeshellarg($uri),
        escapeshellarg($driver)
    );
    
    echo "[addPrinter] 执行命令1: $cmd1\n";
    exec($cmd1, $output1, $returnCode1);
    echo "[addPrinter] 返回码1: $returnCode1, 输出: " . implode(' ', $output1) . "\n";
    
    if ($returnCode1 !== 0) {
        echo "[addPrinter] 尝试使用 raw 驱动...\n";
        $cmd2 = sprintf(
            'lpadmin -p %s -v %s -m raw 2>&1',
            escapeshellarg($name),
            escapeshellarg($uri)
        );
        exec($cmd2, $output2, $returnCode2);
        echo "[addPrinter] 返回码2: $returnCode2, 输出: " . implode(' ', $output2) . "\n";
        
        if ($returnCode2 !== 0) {
            return ['success' => false, 'message' => '添加失败: ' . implode("\n", array_merge($output1, $output2))];
        }
    }
    
    exec("lpadmin -p " . escapeshellarg($name) . " -E 2>&1", $enableOutput);
    exec("cupsenable " . escapeshellarg($name) . " 2>&1");
    exec("cupsaccept " . escapeshellarg($name) . " 2>&1");
    
    exec("lpstat -p " . escapeshellarg($name) . " 2>&1", $checkOutput, $checkCode);
    
    if ($checkCode === 0) {
        return ['success' => true, 'message' => "打印机 $name 添加成功"];
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
    
    $uriOutput = [];
    exec('LANG=C lpstat -v ' . escapeshellarg($printerName) . ' 2>&1', $uriOutput);
    echo "[changeDriver] lpstat -v 输出: " . implode(' | ', $uriOutput) . "\n";
    $uri = '';
    
    foreach ($uriOutput as $line) {
        // 匹配: "device for PrinterName: usb://..."
        if (preg_match('/device for [^:]+:\s*(.+)/i', $line, $m)) {
            $uri = trim($m[1]);
            break;
        }
        // 匹配: "PrinterName 的设备：usb://..."
        if (preg_match('/的设备[：:]\s*(.+)/', $line, $m)) {
            $uri = trim($m[1]);
            break;
        }
        // 直接匹配URI格式
        if (preg_match('/(usb:\/\/\S+|ipp:\/\/\S+|socket:\/\/\S+|lpd:\/\/\S+)/', $line, $m)) {
            $uri = trim($m[1]);
            break;
        }
    }
    
    // 更换驱动不需要URI，直接用lpadmin -p -m即可
    $cmd = sprintf(
        'lpadmin -p %s -m %s 2>&1',
        escapeshellarg($printerName),
        escapeshellarg($newDriver)
    );
    
    echo "[changeDriver] 执行命令: $cmd\n";
    exec($cmd, $output, $returnCode);
    echo "[changeDriver] 返回码: $returnCode, 输出: " . implode(' ', $output) . "\n";
    
    if ($returnCode === 0) {
        exec("cupsenable " . escapeshellarg($printerName) . " 2>&1");
        exec("cupsaccept " . escapeshellarg($printerName) . " 2>&1");
        return ['success' => true, 'message' => "驱动已更换为 $newDriver"];
    } else {
        return ['success' => false, 'message' => '更换失败: ' . implode("\n", $output)];
    }
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

function getClientVersion(): array
{
    $scriptPath = realpath(__FILE__);
    $modTime = filemtime($scriptPath);
    $hash = md5_file($scriptPath);
    
    return [
        'version' => '1.0.1',
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

function executePrint(string $printerName, string $fileContent, string $filename, string $fileExt, int $copies = 1): array
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
            $cmd = sprintf('lp -d %s -n %d -o fit-to-page -o media=A4 %s 2>&1',
                escapeshellarg($printerName),
                $copies,
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
            'version' => '1.0.1',
            'os_info' => $systemInfo['os'] ?? '',
            'ip_address' => $systemInfo['ip'] ?? ''
        ]);
        
        $printers = getPrinterList();
        $formattedPrinters = [];
        foreach ($printers as $p) {
            $formattedPrinters[] = [
                'name' => $p['name'],
                'display_name' => $p['name'],
                'driver' => '',
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
        file_put_contents('/etc/printer-client-openid', $openid);
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
                if (!empty($openid)) {
                    $this->saveOpenid($openid);
                    echo "设备已绑定到用户: $openid\n";
                    $this->register();
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
                
                echo "[print] 打印机: $printer, 文件: $filename, 扩展名: $fileExt, 份数: $copies\n";
                
                if (!empty($fileUrl) && empty($fileContent)) {
                    echo "[print] 从URL下载文件: $fileUrl\n";
                    $downloadedContent = @file_get_contents($fileUrl);
                    if ($downloadedContent !== false) {
                        $fileContent = base64_encode($downloadedContent);
                        echo "[print] 下载成功，大小: " . strlen($downloadedContent) . " 字节\n";
                    } else {
                        echo "[print] 下载失败\n";
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
                    $result = executePrint($printer, $fileContent, $filename, $fileExt, $copies);
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
budao
