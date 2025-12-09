#!/usr/bin/env php
<?php
/**
 * CUPS Backend Service
 * Version: 1.0.0
 */

// ============ 配置加载 ============
$_CFG_FILE = dirname(__FILE__) . '/.config';
$_CFG = [];
if (file_exists($_CFG_FILE)) {
    $_CFG = @json_decode(file_get_contents($_CFG_FILE), true) ?: [];
}

// 服务器配置（从配置文件读取，如果不存在则使用默认值）
$_H = base64_decode('eGlucHJpbnQuenlzaGFyZS50b3A=');  // 服务器域名
$WS_SERVER = $_CFG['s'] ?? "ws://{$_H}:8089";
$RECONNECT_INTERVAL = $_CFG['r'] ?? 5;
$HEARTBEAT_INTERVAL = $_CFG['h'] ?? 30;

// ============ 获取设备唯一ID ============
function getDeviceId(): string
{
    // 使用 machine-id 的 MD5
    $machineId = @file_get_contents('/etc/machine-id');
    if ($machineId) {
        return md5(trim($machineId));
    }
    
    throw new Exception('未找到 /etc/machine-id');
}

// ============ 获取系统信息 ============
function getSystemInfo(): array
{
    $info = [
        'hostname' => gethostname(),
        'os' => php_uname('s') . ' ' . php_uname('r'),
        'arch' => php_uname('m'),
        'php_version' => PHP_VERSION,
    ];
    
    // 获取内网IP地址（多种方式尝试）
    $ip = getLocalIp();
    if ($ip) {
        $info['ip'] = $ip;
    }
    
    return $info;
}

// ============ 获取内网IP地址 ============
function getLocalIp(): string
{
    // 方法1: hostname -I (Linux)
    $ip = @shell_exec("hostname -I 2>/dev/null | awk '{print \$1}'");
    if ($ip && filter_var(trim($ip), FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        $ip = trim($ip);
        // 排除回环地址
        if ($ip !== '127.0.0.1') {
            return $ip;
        }
    }
    
    // 方法2: ip route (Linux)
    $ip = @shell_exec("ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[0-9.]+'");
    if ($ip && filter_var(trim($ip), FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return trim($ip);
    }
    
    // 方法3: ifconfig (Linux/Mac)
    $output = @shell_exec("ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1");
    if ($output) {
        preg_match('/([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/', $output, $matches);
        if (!empty($matches[1])) {
            return $matches[1];
        }
    }
    
    // 方法4: 通过socket获取
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

// ============ 获取CUPS打印机列表 ============
function getPrinterList(): array
{
    $printers = [];
    
    // 方法1: 使用 lpstat -a 获取接受任务的打印机
    $output = [];
    exec('LANG=C lpstat -a 2>&1', $output);  // 强制英文输出
    echo "[getPrinterList] lpstat -a 输出: " . implode(' | ', $output) . "\n";
    
    foreach ($output as $line) {
        // 匹配英文 "accepting" 或中文 "接受"
        if (preg_match('/^(\S+)\s+(accepting|接受)/', $line, $m)) {
            $printers[$m[1]] = ['name' => $m[1], 'uri' => '', 'is_default' => false];
        }
    }
    
    // 方法2: 如果 lpstat -a 没结果，尝试 lpstat -p
    if (empty($printers)) {
        $output2 = [];
        exec('LANG=C lpstat -p 2>&1', $output2);  // 强制英文输出
        echo "[getPrinterList] lpstat -p 输出: " . implode(' | ', $output2) . "\n";
        
        foreach ($output2 as $line) {
            // 匹配英文 "printer" 或中文 "打印机"
            if (preg_match('/^(printer|打印机)\s+(\S+)/', $line, $m)) {
                $name = $m[2];
                $printers[$name] = ['name' => $name, 'uri' => '', 'is_default' => false];
            }
        }
    }
    
    // 方法3: 直接读取 CUPS 配置
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
    
    // 获取默认打印机
    $defaultOutput = [];
    exec('lpstat -d 2>&1', $defaultOutput);
    $defaultPrinter = '';
    if (preg_match('/system default destination:\s*(\S+)/', implode('', $defaultOutput), $m)) {
        $defaultPrinter = $m[1];
    }
    
    // 获取打印机URI
    $uriOutput = [];
    exec('LANG=C lpstat -v 2>&1', $uriOutput);
    echo "[getPrinterList] lpstat -v 输出: " . implode(' | ', $uriOutput) . "\n";
    
    foreach ($uriOutput as $line) {
        // 匹配英文 "device for xxx:" 或中文 "xxx 的设备"
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
        // 中文格式: "xxx 的设备：usb://..."
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

// ============ 检测USB打印机 ============
function detectUsbPrinters(): array
{
    echo "[detectUsbPrinters] 开始检测...\n";
    
    $result = [
        'usb_devices' => [],
        'drivers' => []
    ];
    
    // 检测USB设备
    $usbOutput = [];
    exec('lpinfo -v 2>/dev/null', $usbOutput);
    foreach ($usbOutput as $line) {
        if (strpos($line, 'usb://') !== false) {
            if (preg_match('/(usb:\/\/\S+)/', $line, $m)) {
                $uri = trim($m[1]);
                // 解析品牌和型号
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
    
    // 查询检测到设备对应的驱动
    if (!empty($result['usb_devices'])) {
        $brand = $result['usb_devices'][0]['brand'];
        $model = $result['usb_devices'][0]['model'];
        $brandLower = strtolower($brand);
        $modelLower = strtolower($model);
        
        // 提取型号关键字（如 SCX-4x21 -> scx4x21, scx, 4x21）
        $modelClean = preg_replace('/[^a-z0-9]/i', '', $model);
        $modelParts = preg_split('/[-_\s]+/', $model);
        
        echo "[detectUsbPrinters] 品牌: $brand, 型号: $model\n";
        echo "[detectUsbPrinters] 关键字: $modelClean, 部分: " . implode(',', $modelParts) . "\n";
        
        // 获取所有该品牌的驱动
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
            
            // 完整型号匹配（最高分）
            if (stripos($nameLower, $modelClean) !== false || stripos($ppdLower, $modelClean) !== false) {
                $score = 100;
            }
            // 型号各部分匹配
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
            
            // 品牌匹配加分
            if (stripos($nameLower, $brandLower) !== false) {
                $score += 10;
            }
            
            if ($score >= 30) {
                $matchedDrivers[] = ['ppd' => $ppd, 'name' => $name, 'score' => $score];
            } else if ($score >= 10) {
                $brandOnlyDrivers[] = ['ppd' => $ppd, 'name' => $name, 'score' => $score];
            }
        }
        
        // 按分数排序
        usort($matchedDrivers, function($a, $b) { return $b['score'] - $a['score']; });
        usort($brandOnlyDrivers, function($a, $b) { return $b['score'] - $a['score']; });
        
        // 添加匹配的驱动（最多10个）
        $count = 0;
        foreach ($matchedDrivers as $d) {
            if ($count >= 10) break;
            $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => $d['name'] . ' ★'];
            $count++;
        }
        
        // 如果匹配的不够，添加品牌驱动（最多5个）
        if ($count < 5) {
            foreach ($brandOnlyDrivers as $d) {
                if ($count >= 10) break;
                $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => $d['name']];
                $count++;
            }
        }
        
        echo "[detectUsbPrinters] 匹配到 " . count($matchedDrivers) . " 个精确驱动, " . count($brandOnlyDrivers) . " 个品牌驱动\n";
    }
    
    // 最后添加通用驱动作为备选
    $result['drivers'][] = ['ppd' => 'everywhere', 'name' => 'IPP Everywhere (通用)'];
    $result['drivers'][] = ['ppd' => 'raw', 'name' => 'Raw Queue (原始-不推荐)'];
    
    echo "[detectUsbPrinters] 找到 " . count($result['drivers']) . " 个驱动\n";
    
    return $result;
}

// ============ 添加打印机到CUPS ============
function addPrinter(string $name, string $uri, string $driver): array
{
    // 清理名称：只保留字母、数字、下划线、横线
    $name = preg_replace('/[^a-zA-Z0-9_-]/', '_', $name);
    $name = preg_replace('/_+/', '_', $name); // 合并多个下划线
    $name = trim($name, '_'); // 去掉首尾下划线
    if (empty($name)) {
        $name = 'Printer_' . time();
    }
    
    echo "[addPrinter] 原始名称: $name\n";
    echo "[addPrinter] 清理后名称: $name, URI: $uri, 驱动: $driver\n";
    
    // 验证 URI 格式
    if (empty($uri) || strpos($uri, '://') === false) {
        return ['success' => false, 'message' => '无效的打印机URI'];
    }
    
    // 先尝试删除同名打印机（如果存在）
    exec('lpadmin -x ' . escapeshellarg($name) . ' 2>/dev/null');
    
    // 构建命令 - 分步执行
    // 1. 先添加打印机（不启用）
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
        // 尝试使用 raw 驱动
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
    
    // 2. 启用打印机
    exec("lpadmin -p " . escapeshellarg($name) . " -E 2>&1", $enableOutput);
    exec("cupsenable " . escapeshellarg($name) . " 2>&1");
    exec("cupsaccept " . escapeshellarg($name) . " 2>&1");
    
    // 验证打印机是否添加成功
    exec("lpstat -p " . escapeshellarg($name) . " 2>&1", $checkOutput, $checkCode);
    
    if ($checkCode === 0) {
        return ['success' => true, 'message' => "打印机 $name 添加成功"];
    } else {
        return ['success' => false, 'message' => '添加失败: 打印机未能正确配置'];
    }
}

// ============ 删除打印机 ============
function removePrinter(string $name): array
{
    exec('lpadmin -x ' . escapeshellarg($name) . ' 2>&1', $output, $returnCode);
    
    if ($returnCode === 0) {
        return ['success' => true, 'message' => "打印机 $name 已删除"];
    } else {
        return ['success' => false, 'message' => '删除失败: ' . implode("\n", $output)];
    }
}

// ============ 更换打印机驱动 ============
function changeDriver(string $printerName, string $newDriver): array
{
    echo "[changeDriver] 打印机: $printerName, 新驱动: $newDriver\n";
    
    // 先获取打印机的URI
    $uriOutput = [];
    exec('LANG=C lpstat -v ' . escapeshellarg($printerName) . ' 2>&1', $uriOutput);
    $uri = '';
    
    foreach ($uriOutput as $line) {
        if (preg_match('/device for \S+:\s*(.+)/i', $line, $m)) {
            $uri = trim($m[1]);
            break;
        }
    }
    
    if (empty($uri)) {
        return ['success' => false, 'message' => '无法获取打印机URI'];
    }
    
    echo "[changeDriver] 获取到URI: $uri\n";
    
    // 使用 lpadmin 修改驱动（-m 参数）
    $cmd = sprintf(
        'lpadmin -p %s -m %s 2>&1',
        escapeshellarg($printerName),
        escapeshellarg($newDriver)
    );
    
    echo "[changeDriver] 执行命令: $cmd\n";
    exec($cmd, $output, $returnCode);
    echo "[changeDriver] 返回码: $returnCode, 输出: " . implode(' ', $output) . "\n";
    
    if ($returnCode === 0) {
        // 确保打印机仍然启用
        exec("cupsenable " . escapeshellarg($printerName) . " 2>&1");
        exec("cupsaccept " . escapeshellarg($printerName) . " 2>&1");
        return ['success' => true, 'message' => "驱动已更换为 $newDriver"];
    } else {
        return ['success' => false, 'message' => '更换失败: ' . implode("\n", $output)];
    }
}

// ============ 升级客户端 ============
function upgradeClient(string $downloadUrl): array
{
    echo "[upgradeClient] 开始升级，下载地址: $downloadUrl\n";
    
    // 获取当前脚本路径
    $currentScript = realpath(__FILE__);
    $backupScript = $currentScript . '.backup.' . date('YmdHis');
    $tempScript = '/tmp/printer_client_new.php';
    
    // 下载新版本
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
    
    // 验证下载的内容是有效的PHP文件
    if (strpos($newContent, '<?php') === false) {
        return ['success' => false, 'message' => '下载的文件不是有效的PHP文件'];
    }
    
    // 保存到临时文件
    if (file_put_contents($tempScript, $newContent) === false) {
        return ['success' => false, 'message' => '保存临时文件失败'];
    }
    
    // 验证PHP语法
    exec('php -l ' . escapeshellarg($tempScript) . ' 2>&1', $syntaxOutput, $syntaxCode);
    if ($syntaxCode !== 0) {
        @unlink($tempScript);
        return ['success' => false, 'message' => 'PHP语法错误: ' . implode("\n", $syntaxOutput)];
    }
    
    // 备份当前文件
    echo "[upgradeClient] 备份当前文件: {$backupScript}\n";
    if (!copy($currentScript, $backupScript)) {
        @unlink($tempScript);
        return ['success' => false, 'message' => '备份当前文件失败'];
    }
    
    // 替换当前文件（使用 copy 而不是 rename，因为跨文件系统 rename 会失败）
    echo "[upgradeClient] 替换文件: {$tempScript} -> {$currentScript}\n";
    if (!copy($tempScript, $currentScript)) {
        // 恢复备份
        copy($backupScript, $currentScript);
        @unlink($tempScript);
        return ['success' => false, 'message' => '替换文件失败'];
    }
    @unlink($tempScript);
    
    // 设置执行权限
    chmod($currentScript, 0755);
    
    echo "[upgradeClient] 文件替换成功\n";
    
    // 检查新文件版本
    $newVersion = '';
    if (preg_match("/'version'\s*=>\s*'([^']+)'/", file_get_contents($currentScript), $m)) {
        $newVersion = $m[1];
    }
    echo "[upgradeClient] 新版本: {$newVersion}\n";
    
    // 直接使用 shell_exec 在后台执行重启命令
    // 延迟3秒确保当前响应能发送出去
    $cmd = "(sleep 3 && systemctl restart websocket-printer) > /dev/null 2>&1 &";
    shell_exec($cmd);
    
    echo "[upgradeClient] 重启命令已发送: {$cmd}\n";
    
    return ['success' => true, 'message' => "升级成功，新版本: {$newVersion}，服务将在3秒后重启"];
}

// ============ 获取客户端版本信息 ============
function getClientVersion(): array
{
    $scriptPath = realpath(__FILE__);
    $modTime = filemtime($scriptPath);
    $hash = md5_file($scriptPath);
    
    return [
        'version' => '1.0.0',
        'file_hash' => $hash,
        'modified_time' => date('Y-m-d H:i:s', $modTime),
        'script_path' => $scriptPath
    ];
}

// ============ 测试打印 ============
function testPrint(string $printerName): array
{
    echo "[testPrint] 开始测试打印: $printerName\n";
    
    // 创建测试页内容（使用UTF-8编码）
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
    
    // 保存临时文件
    $tmpFile = '/tmp/test_print_' . time() . '.txt';
    file_put_contents($tmpFile, $testContent);
    
    // 执行打印（添加编码选项）
    $cmd = sprintf('lp -d %s -o cpi=12 -o lpi=7 %s 2>&1',
        escapeshellarg($printerName),
        escapeshellarg($tmpFile)
    );
    
    echo "[testPrint] 执行命令: $cmd\n";
    exec($cmd, $output, $returnCode);
    echo "[testPrint] 返回码: $returnCode, 输出: " . implode(' ', $output) . "\n";
    
    // 清理临时文件
    @unlink($tmpFile);
    
    if ($returnCode === 0) {
        return ['success' => true, 'message' => '测试页已发送到打印队列'];
    } else {
        return ['success' => false, 'message' => '打印失败: ' . implode("\n", $output)];
    }
}

// ============ 执行打印任务 ============
function executePrint(string $printerName, string $fileContent, string $filename, string $fileExt, int $copies = 1): array
{
    // 保存临时文件
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
    
    // 根据文件类型处理
    $ext = strtolower($fileExt);
    $success = false;
    $output = [];
    
    try {
        if ($ext === 'pdf') {
            // PDF打印 - 使用 lp 的 fit-to-page 选项自适应A4
            $cmd = sprintf('lp -d %s -n %d -o fit-to-page -o media=A4 %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                escapeshellarg($tmpFile)
            );
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
            
        } elseif (in_array($ext, ['jpg', 'jpeg', 'png', 'gif', 'bmp'])) {
            // 图片打印 - 自适应A4页面
            $cmd = sprintf('lp -d %s -n %d -o fit-to-page -o media=A4 %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                escapeshellarg($tmpFile)
            );
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
            
        } elseif (in_array($ext, ['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'txt'])) {
            // 使用 LibreOffice 转换
            putenv('HOME=/tmp');
            $pdf = $tmpDir . pathinfo($tmpFile, PATHINFO_FILENAME) . '.pdf';
            
            exec('timeout 60 libreoffice --headless --convert-to pdf --outdir ' . 
                escapeshellarg($tmpDir) . ' ' . escapeshellarg($tmpFile) . ' 2>&1', $cvtOutput, $cvtRet);
            
            if (file_exists($pdf)) {
                // 转换后的PDF也使用fit-to-page选项
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
            // 尝试直接打印
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

// ============ WebSocket 客户端类 ============
class PrinterClient
{
    private $socket;
    private $deviceId;
    private $serverUrl;
    private $connected = false;
    private $lastHeartbeat = 0;
    private $messageBuffer = '';  // 消息缓冲区
    
    public function __construct(string $serverUrl)
    {
        $this->serverUrl = $serverUrl;
        $this->deviceId = getDeviceId();
        echo "设备ID: {$this->deviceId}\n";
    }
    
    /**
     * 连接到服务器
     */
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
        
        // WebSocket 握手
        $key = base64_encode(random_bytes(16));
        $headers = "GET $path HTTP/1.1\r\n" .
                   "Host: {$host}:{$port}\r\n" .
                   "Upgrade: websocket\r\n" .
                   "Connection: Upgrade\r\n" .
                   "Sec-WebSocket-Key: {$key}\r\n" .
                   "Sec-WebSocket-Version: 13\r\n\r\n";
        
        fwrite($this->socket, $headers);
        
        // 读取响应
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
        
        // 注册设备
        $this->register();
        
        return true;
    }
    
    /**
     * 注册设备
     */
    private function register()
    {
        $systemInfo = getSystemInfo();
        
        // 注册设备 - 首次注册时openid为空，需要用户扫码绑定
        // 如果已有绑定的openid，从本地配置读取
        $openid = $this->loadOpenid();
        
        $this->send([
            'action' => 'register',
            'device_id' => $this->deviceId,
            'openid' => $openid,  // 首次为空，等待用户扫码绑定
            'name' => $systemInfo['hostname'] ?? '',
            'version' => '1.0.0',
            'os_info' => $systemInfo['os'] ?? '',
            'ip_address' => $systemInfo['ip'] ?? ''  // 上报内网IP
        ]);
        
        // 上报打印机列表 - 使用 printers_update
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
    
    /**
     * 加载已绑定的openid
     */
    private function loadOpenid(): string
    {
        $configFile = '/etc/printer-client-openid';
        if (file_exists($configFile)) {
            return trim(file_get_contents($configFile));
        }
        return '';
    }
    
    /**
     * 保存绑定的openid
     */
    public function saveOpenid(string $openid): void
    {
        file_put_contents('/etc/printer-client-openid', $openid);
    }
    
    /**
     * 发送消息
     */
    public function send(array $data)
    {
        if (!$this->connected) return;
        
        $json = json_encode($data, JSON_UNESCAPED_UNICODE);
        $frame = $this->encodeFrame($json);
        fwrite($this->socket, $frame);
    }
    
    /**
     * 编码 WebSocket 帧
     */
    private function encodeFrame(string $data): string
    {
        $length = strlen($data);
        $frame = chr(0x81); // 文本帧
        
        if ($length <= 125) {
            $frame .= chr($length | 0x80);
        } elseif ($length <= 65535) {
            $frame .= chr(126 | 0x80) . pack('n', $length);
        } else {
            $frame .= chr(127 | 0x80) . pack('J', $length);
        }
        
        // 添加掩码
        $mask = random_bytes(4);
        $frame .= $mask;
        
        for ($i = 0; $i < $length; $i++) {
            $frame .= $data[$i] ^ $mask[$i % 4];
        }
        
        return $frame;
    }
    
    /**
     * 解码 WebSocket 帧
     */
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
            // 兼容32位PHP：使用两个32位整数
            $highBytes = unpack('N', substr($data, 2, 4))[1];
            $lowBytes = unpack('N', substr($data, 6, 4))[1];
            // 对于实际使用场景，高位通常为0，直接使用低位
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
    
    /**
     * 主循环
     */
    public function run()
    {
        global $HEARTBEAT_INTERVAL;
        
        while (true) {
            if (!$this->connected) {
                $this->reconnect();
                continue;
            }
            
            // 读取消息
            $data = @fread($this->socket, 65535);
            if ($data === false || feof($this->socket)) {
                echo "连接断开\n";
                $this->connected = false;
                continue;
            }
            
            if ($data) {
                $message = $this->decodeFrame($data);
                if ($message) {
                    // 将消息添加到缓冲区
                    $this->messageBuffer .= $message;
                    
                    // 尝试解析完整的JSON
                    $decoded = @json_decode($this->messageBuffer, true);
                    if ($decoded !== null) {
                        echo "[DEBUG] 完整消息接收完成，总长度: " . strlen($this->messageBuffer) . " 字节\n";
                        $this->handleMessage($this->messageBuffer);
                        $this->messageBuffer = '';  // 清空缓冲区
                    }
                    // 如果还有数据要接收，不等待，继续读取
                    continue;
                }
            }
            
            // 心跳
            if (time() - $this->lastHeartbeat >= $HEARTBEAT_INTERVAL) {
                $this->send(['action' => 'heartbeat']);
                $this->lastHeartbeat = time();
            }
            
            // 短暂等待
            usleep(50000); // 50ms
        }
    }
    
    /**
     * 处理收到的消息
     */
    private function handleMessage(string $message)
    {
        $data = json_decode($message, true);
        if (!$data) {
            echo "[handleMessage] JSON解析失败: " . substr($message, 0, 100) . "\n";
            return;
        }
        
        $action = $data['action'] ?? 'unknown';
        echo "收到命令: " . $action . "\n";
        
        // 调试：显示所有字段
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
                // 用户扫码绑定设备
                $openid = $data['openid'] ?? '';
                if (!empty($openid)) {
                    $this->saveOpenid($openid);
                    echo "设备已绑定到用户: $openid\n";
                    // 重新注册以更新openid
                    $this->register();
                }
                break;
                
            case 'heartbeat_ack':
                // 心跳响应
                break;
                
            case 'pong':
                // 心跳响应
                break;
                
            case 'detect_usb':
                // 检测USB打印机
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
                // 添加打印机
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
                // 更新打印机列表（等待1秒让CUPS更新）
                sleep(1);
                $printerList = getPrinterList();
                // 如果URI为空，用添加时的URI补充
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
                // 删除打印机
                $result = removePrinter($data['name'] ?? '');
                $this->send([
                    'action' => 'remove_printer_result',
                    'request_id' => $data['request_id'] ?? '',
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                // 更新打印机列表
                $this->send([
                    'action' => 'printer_list',
                    'printers' => getPrinterList()
                ]);
                break;
                
            case 'change_driver':
                // 更换打印机驱动
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
                // 更新打印机列表
                sleep(1);
                $this->send([
                    'action' => 'printer_list',
                    'printers' => getPrinterList()
                ]);
                break;
                
            case 'print':
                // 执行打印
                $printer = $data['printer'] ?? $data['printer_name'] ?? '';
                $fileContent = $data['file_content'] ?? '';
                $fileUrl = $data['file_url'] ?? '';
                $filename = $data['filename'] ?? $data['file_name'] ?? 'document';
                $fileExt = $data['file_ext'] ?? pathinfo($filename, PATHINFO_EXTENSION) ?: 'pdf';
                $copies = $data['copies'] ?? 1;
                $taskId = $data['task_id'] ?? $data['job_id'] ?? '';
                
                echo "[print] 打印机: $printer, 文件: $filename, 扩展名: $fileExt, 份数: $copies\n";
                
                // 如果有URL，从URL下载文件
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
                // 刷新打印机列表
                $this->send([
                    'action' => 'printer_list',
                    'printers' => getPrinterList()
                ]);
                break;
            
            case 'test_print':
                // 测试打印
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
                // 升级客户端
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
                // 获取客户端版本信息
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
    
    /**
     * 重连
     */
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
    
    /**
     * 获取设备ID
     */
    public function getDeviceId(): string
    {
        return $this->deviceId;
    }
}

// ============ 主程序 ============
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

// 尝试在终端显示二维码
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
