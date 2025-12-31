#!/usr/bin/env php
<?php
define('CLIENT_VERSION', '1.1.0');
define('LOG_DIR', '/var/log/printer-client/');
define('LOG_RETENTION_DAYS', 2);
define('PRINT_TEMP_DIR', '/tmp/print_jobs/');
define('TEMP_CLEAN_INTERVAL', 300);

$_CFG_FILE = dirname(__FILE__) . '/.config';
$_CFG = [];
if (file_exists($_CFG_FILE)) {
    $_CFG = @json_decode(file_get_contents($_CFG_FILE), true) ?: [];
}

$_H = base64_decode('eGlucHJpbnQuenlzaGFyZS50b3A=');
$WS_SERVER = $_CFG['s'] ?? "ws://{$_H}:8089";
$RECONNECT_INTERVAL = $_CFG['r'] ?? 5;
$HEARTBEAT_INTERVAL = $_CFG['h'] ?? 30;
$MAX_RECONNECT_INTERVAL = 60; 
$LAST_TEMP_CLEAN = 0;

function initLogDir(): void
{
    if (!is_dir(LOG_DIR)) {
        @mkdir(LOG_DIR, 0755, true);
    }
}

function writeLog(string $level, string $message, array $context = []): void
{
    initLogDir();
    
    $date = date('Y-m-d');
    $time = date('Y-m-d H:i:s');
    $logFile = LOG_DIR . "client_{$date}.log";
    
    $logLine = "[{$time}] [{$level}] {$message}";
    if (!empty($context)) {
        $logLine .= " " . json_encode($context, JSON_UNESCAPED_UNICODE);
    }
    $logLine .= "\n";
    
    @file_put_contents($logFile, $logLine, FILE_APPEND | LOCK_EX);
    echo $logLine;
}

function cleanOldLogs(): void
{
    if (!is_dir(LOG_DIR)) return;
    
    $files = glob(LOG_DIR . 'client_*.log');
    $cutoffTime = time() - (LOG_RETENTION_DAYS * 86400);
    
    foreach ($files as $file) {
        if (filemtime($file) < $cutoffTime) {
            @unlink($file);
            writeLog('INFO', "清理过期日志: " . basename($file));
        }
    }
}

function getLogContent(int $lines = 200, string $date = ''): array
{
    initLogDir();
    
    if (empty($date)) {
        $date = date('Y-m-d');
    }
    
    $logFile = LOG_DIR . "client_{$date}.log";
    
    if (!file_exists($logFile)) {
        return [
            'success' => false,
            'message' => '日志文件不存在',
            'date' => $date,
            'logs' => []
        ];
    }
    
    $content = @file_get_contents($logFile);
    if ($content === false) {
        return [
            'success' => false,
            'message' => '读取日志失败',
            'date' => $date,
            'logs' => []
        ];
    }
    
    $allLines = explode("\n", trim($content));
    $totalLines = count($allLines);
    $logLines = array_slice($allLines, -$lines);
    
    return [
        'success' => true,
        'date' => $date,
        'total_lines' => $totalLines,
        'returned_lines' => count($logLines),
        'logs' => $logLines
    ];
}

function getLogDates(): array
{
    initLogDir();
    
    $files = glob(LOG_DIR . 'client_*.log');
    $dates = [];
    
    foreach ($files as $file) {
        $basename = basename($file, '.log');
        if (preg_match('/client_(\d{4}-\d{2}-\d{2})/', $basename, $m)) {
            $dates[] = [
                'date' => $m[1],
                'size' => filesize($file),
                'modified' => date('Y-m-d H:i:s', filemtime($file))
            ];
        }
    }
    
    usort($dates, function($a, $b) {
        return strcmp($b['date'], $a['date']);
    });
    
    return $dates;
}

function cleanTempPrintFiles(): array
{
    $cleaned = 0;
    $errors = 0;
    
    if (is_dir(PRINT_TEMP_DIR)) {
        $files = glob(PRINT_TEMP_DIR . '*');
        $cutoffTime = time() - 300;
        
        foreach ($files as $file) {
            if (is_file($file) && filemtime($file) < $cutoffTime) {
                if (@unlink($file)) {
                    $cleaned++;
                } else {
                    $errors++;
                }
            }
        }
    }
    
    $tmpPatterns = [
        '/tmp/print_*.txt',
        '/tmp/print_*.pdf',
        '/tmp/test_print_*.txt',
        '/tmp/*.ppd',
        '/tmp/printer_client_*.php',
        '/tmp/lu*',  
    ];
    
    foreach ($tmpPatterns as $pattern) {
        $files = glob($pattern);
        $cutoffTime = time() - 300;
        
        foreach ($files as $file) {
            if (is_file($file) && filemtime($file) < $cutoffTime) {
                if (@unlink($file)) {
                    $cleaned++;
                } else {
                    $errors++;
                }
            }
        }
    }
    
    $loTmpDir = '/tmp/.libreoffice';
    if (is_dir($loTmpDir)) {
        $cutoffTime = time() - 600; 
        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($loTmpDir, RecursiveDirectoryIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($iterator as $file) {
            if ($file->isFile() && $file->getMTime() < $cutoffTime) {
                if (@unlink($file->getPathname())) {
                    $cleaned++;
                }
            }
        }
    }
    
    $cupsSpoolDir = '/var/spool/cups';
    if (is_dir($cupsSpoolDir) && is_readable($cupsSpoolDir)) {
        $files = glob($cupsSpoolDir . '/d*');
        $cutoffTime = time() - 3600; 
        foreach ($files as $file) {
            if (is_file($file) && filemtime($file) < $cutoffTime) {
                if (@unlink($file)) {
                    $cleaned++;
                }
            }
        }
    }
    
    $cupsLogDir = '/var/log/cups';
    if (is_dir($cupsLogDir)) {
        $logPatterns = [
            $cupsLogDir . '/access_log.*',
            $cupsLogDir . '/error_log.*',
            $cupsLogDir . '/page_log.*',
        ];
        $cutoffTime = time() - (2 * 86400);
        foreach ($logPatterns as $pattern) {
            $files = glob($pattern);
            foreach ($files as $file) {
                if (is_file($file) && filemtime($file) < $cutoffTime) {
                    if (@unlink($file)) {
                        $cleaned++;
                    }
                }
            }
        }
    }
    
    if ($cleaned > 0) {
        writeLog('INFO', "清理临时文件: {$cleaned} 个", ['errors' => $errors]);
    }
    
    return ['cleaned' => $cleaned, 'errors' => $errors];
}


function getCupsJobs(string $printerName = ''): array
{
    $jobs = [];
    
    $cmd = 'LANG=C lpstat -o';
    if (!empty($printerName)) {
        $cmd .= ' ' . escapeshellarg($printerName);
    }
    $cmd .= ' 2>&1';
    
    $output = [];
    exec($cmd, $output);
    
    foreach ($output as $line) {
        if (preg_match('/^(\S+)-(\d+)\s+(\S+)\s+(\d+)\s+(.+)$/', $line, $m)) {
            $printer = $m[1];
            $jobId = $m[2];
            $user = $m[3];
            $size = intval($m[4]);
            $timeStr = $m[5];
            
            $jobInfo = getCupsJobInfo($printer . '-' . $jobId);
            
            $jobs[] = [
                'id' => $jobId,
                'printer' => $printer,
                'user' => $user,
                'size' => formatFileSizeForJobs($size),
                'size_bytes' => $size,
                'creation_time' => strtotime($timeStr),
                'title' => $jobInfo['title'] ?? '',
                'state' => $jobInfo['state'] ?? 'pending',
                'pages' => $jobInfo['pages'] ?? ''
            ];
        }
    }
    
    if (empty($jobs)) {
        $lpqCmd = 'LANG=C lpq -a 2>&1';
        $lpqOutput = [];
        exec($lpqCmd, $lpqOutput);
        
        foreach ($lpqOutput as $line) {
            if (preg_match('/^(\w+)\s+(\S+)\s+(\d+)\s+(.+?)\s+(\d+)\s*bytes/', $line, $m)) {
                $jobs[] = [
                    'id' => $m[3],
                    'printer' => '',
                    'user' => $m[2],
                    'title' => trim($m[4]),
                    'size' => formatFileSizeForJobs(intval($m[5])),
                    'size_bytes' => intval($m[5]),
                    'state' => strtolower($m[1]) === 'active' ? 'processing' : 'pending',
                    'creation_time' => time(),
                    'pages' => ''
                ];
            }
        }
    }
    
    return $jobs;
}


function getCupsJobInfo(string $jobId): array
{
    $info = [
        'title' => '',
        'state' => 'pending',
        'pages' => ''
    ];
    
    $cmd = 'LANG=C lpstat -l ' . escapeshellarg($jobId) . ' 2>&1';
    $output = [];
    exec($cmd, $output);
    $fullOutput = implode("\n", $output);
    
    if (preg_match('/job-name[=:]\s*(.+)/i', $fullOutput, $m)) {
        $info['title'] = trim($m[1]);
    }
    
    if (stripos($fullOutput, 'printing') !== false || stripos($fullOutput, 'processing') !== false) {
        $info['state'] = 'processing';
    } elseif (stripos($fullOutput, 'held') !== false) {
        $info['state'] = 'held';
    } elseif (stripos($fullOutput, 'stopped') !== false) {
        $info['state'] = 'stopped';
    } elseif (stripos($fullOutput, 'canceled') !== false || stripos($fullOutput, 'cancelled') !== false) {
        $info['state'] = 'canceled';
    } elseif (stripos($fullOutput, 'aborted') !== false) {
        $info['state'] = 'aborted';
    } elseif (stripos($fullOutput, 'completed') !== false) {
        $info['state'] = 'completed';
    }
    
    if (preg_match('/pages[=:]\s*(\d+)/i', $fullOutput, $m)) {
        $info['pages'] = $m[1];
    }
    
    return $info;
}

/**
 * 取消CUPS打印任务
 * @param string $jobId 任务ID
 * @param string $printerName 可选，打印机名称
 * @return array 操作结果
 */
function cancelCupsJob(string $jobId, string $printerName = ''): array
{
    echo "[cancelCupsJob] 取消任务: $jobId, 打印机: $printerName\n";
    
    $jobSpec = $jobId;
    if (!empty($printerName) && strpos($jobId, '-') === false) {
        $jobSpec = $printerName . '-' . $jobId;
    }
    
    $cmd = 'cancel ' . escapeshellarg($jobSpec) . ' 2>&1';
    $output = [];
    $returnCode = 0;
    exec($cmd, $output, $returnCode);
    
    echo "[cancelCupsJob] 命令: $cmd, 返回码: $returnCode, 输出: " . implode(' ', $output) . "\n";
    
    if ($returnCode === 0) {
        return ['success' => true, 'message' => "任务 $jobId 已取消"];
    } else {
        $cmd2 = 'lprm ' . escapeshellarg($jobId) . ' 2>&1';
        $output2 = [];
        exec($cmd2, $output2, $returnCode2);
        
        if ($returnCode2 === 0) {
            return ['success' => true, 'message' => "任务 $jobId 已取消"];
        }
        
        return ['success' => false, 'message' => '取消失败: ' . implode("\n", $output)];
    }
}

function formatFileSizeForJobs(int $bytes): string
{
    if ($bytes < 1024) {
        return $bytes . ' B';
    } elseif ($bytes < 1048576) {
        return round($bytes / 1024, 1) . ' KB';
    } else {
        return round($bytes / 1048576, 1) . ' MB';
    }
}

function getDeviceStatus(): array
{
    $status = [
        'device_id' => getDeviceId(),
        'version' => CLIENT_VERSION,
        'uptime' => @file_get_contents('/proc/uptime'),
        'load_avg' => sys_getloadavg(),
        'memory' => [],
        'disk' => [],
        'temp_files' => 0
    ];
    
    $memInfo = @file_get_contents('/proc/meminfo');
    if ($memInfo) {
        if (preg_match('/MemTotal:\s+(\d+)/', $memInfo, $m)) {
            $status['memory']['total'] = intval($m[1]) * 1024;
        }
        if (preg_match('/MemAvailable:\s+(\d+)/', $memInfo, $m)) {
            $status['memory']['available'] = intval($m[1]) * 1024;
        }
    }
    
    $status['disk']['total'] = @disk_total_space('/');
    $status['disk']['free'] = @disk_free_space('/');
    
    if (is_dir(PRINT_TEMP_DIR)) {
        $status['temp_files'] = count(glob(PRINT_TEMP_DIR . '*'));
    }
    
    return $status;
}

function getDeviceId(): string
{
    $idFile = '/etc/printer-device-id';

    if (file_exists($idFile)) {
        $id = trim(@file_get_contents($idFile) ?: '');
        if ($id !== '' && preg_match('/^[0-9a-fA-F]{30,32}$/', $id)) {
            return strtolower($id);
        }
    }

    $randomBytes = random_bytes(15);
    $deviceId = bin2hex($randomBytes);

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
    exec('LANG=C lpstat -a 2>&1', $output);
    echo "[getPrinterList] lpstat -a 输出: " . implode(' | ', $output) . "\n";
    
    foreach ($output as $line) {
        if (preg_match('/^(\S+)\s+(accepting|接受)/', $line, $m)) {
            $printers[$m[1]] = ['name' => $m[1], 'uri' => '', 'is_default' => false];
        }
    }
    
    if (empty($printers)) {
        $output2 = [];
        exec('LANG=C lpstat -p 2>&1', $output2);
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
    
    foreach ($printers as $name => &$printer) {
        $driver = '';
        $optOutput = [];
        exec('lpoptions -p ' . escapeshellarg($name) . ' -l 2>/dev/null | head -1', $optOutput);
        
        $ppdFile = "/etc/cups/ppd/{$name}.ppd";
        if (file_exists($ppdFile)) {
            $ppdContent = file_get_contents($ppdFile);
            if (preg_match('/\*NickName:\s*"([^"]+)"/', $ppdContent, $m)) {
                $driver = $m[1];
            } elseif (preg_match('/\*ModelName:\s*"([^"]+)"/', $ppdContent, $m)) {
                $driver = $m[1];
            }
        }
        
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
        
        $maxDrivers = 18;
        $count = 0;
        
        foreach ($matchedDrivers as $d) {
            if ($count >= $maxDrivers) break;
            $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => '★ ' . $d['name']];
            $count++;
        }
        
        foreach ($brandOnlyDrivers as $d) {
            if ($count >= $maxDrivers) break;
            $result['drivers'][] = ['ppd' => $d['ppd'], 'name' => $d['name']];
            $count++;
        }
        
        echo "[detectUsbPrinters] 匹配到 " . count($matchedDrivers) . " 个精确驱动, " . count($brandOnlyDrivers) . " 个品牌驱动, 显示 $count 个\n";
    }
    
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
    $name = preg_replace('/_+/', '_', $name);
    $name = trim($name, '_');
    if (empty($name)) {
        $name = 'Printer_' . time();
    }
    
    echo "[addPrinter] 原始名称: $name\n";
    echo "[addPrinter] 清理后名称: $name, URI: $uri, 驱动: $driver\n";
    
    if (empty($uri) || strpos($uri, '://') === false) {
        return ['success' => false, 'message' => '无效的打印机URI'];
    }
    
    exec('lpadmin -x ' . escapeshellarg($name) . ' 2>/dev/null');
    
    $fallbackDrivers = [
        $driver,
        'drv:///sample.drv/generic.ppd',
        'drv:///sample.drv/generpcl.ppd',
        'everywhere',
        'driverless',
        'raw',
    ];
    
    $fallbackDrivers = array_unique($fallbackDrivers);
    
    $lastError = '';
    $usedDriver = '';
    
    foreach ($fallbackDrivers as $tryDriver) {
        $output = [];
        $returnCode = 1;
        
        if ($tryDriver === 'driverless') {
            $cmd = sprintf(
                'lpadmin -p %s -v %s -E 2>&1',
                escapeshellarg($name),
                escapeshellarg($uri)
            );
            echo "[addPrinter] 尝试无驱动模式: $cmd\n";
            exec($cmd, $output, $returnCode);
            
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
    
    exec("lpadmin -p " . escapeshellarg($name) . " -E 2>&1", $enableOutput);
    exec("cupsenable " . escapeshellarg($name) . " 2>&1");
    exec("cupsaccept " . escapeshellarg($name) . " 2>&1");
    
    exec("lpstat -p " . escapeshellarg($name) . " 2>&1", $checkOutput, $checkCode);
    
    if ($checkCode === 0) {
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
        if (!empty($uri)) {
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
                $cmd = sprintf('lpadmin -p %s -v %s -E 2>&1', escapeshellarg($printerName), escapeshellarg($uri));
                echo "[changeDriver] 尝试无驱动模式: $cmd\n";
                exec($cmd, $output, $returnCode);
            }
        } else {
            return ['success' => false, 'message' => '无法获取打印机URI'];
        }
    } else {
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

function getAvailableGenericDrivers(): array
{
    $drivers = [];
    
    $checkDrivers = [
        ['ppd' => 'everywhere', 'name' => '【通用】IPP Everywhere'],
        ['ppd' => 'drv:///sample.drv/generic.ppd', 'name' => '【通用】Generic PostScript Printer'],
        ['ppd' => 'drv:///sample.drv/generpcl.ppd', 'name' => '【通用】Generic PCL Laser Printer'],
        ['ppd' => 'lsb/usr/cupsfilters/Generic-PDF_Printer-PDF.ppd', 'name' => '【通用】Generic PDF Printer'],
        ['ppd' => 'raw', 'name' => '【原始】Raw Queue (不推荐)'],
    ];
    
    $availableOutput = [];
    exec('lpinfo -m 2>/dev/null', $availableOutput);
    $availableDrivers = implode("\n", $availableOutput);
    
    foreach ($checkDrivers as $d) {
        if ($d['ppd'] === 'everywhere' || $d['ppd'] === 'raw') {
            $drivers[] = $d;
            continue;
        }
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
    $backupScript = $currentScript . '.backup';
    $tempScript = '/tmp/printer_client_new.php';
    
    $oldBackups = glob($currentScript . '.backup.*');
    foreach ($oldBackups as $oldBackup) {
        @unlink($oldBackup);
        echo "[upgradeClient] 删除旧备份: $oldBackup\n";
    }
    
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
    
    if (file_exists($backupScript)) {
        @unlink($backupScript);
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


function rebootDevice(bool $rebootSystem = false): array
{
    if ($rebootSystem) {
        writeLog('WARN', '收到远程重启系统命令，系统将在5秒后重启');
        $cmd = "(sleep 5 && reboot) > /dev/null 2>&1 &";
        shell_exec($cmd);
        return ['success' => true, 'message' => '系统将在5秒后重启'];
    } else {
        writeLog('INFO', '收到远程重启服务命令');
        $cmd = "(sleep 2 && systemctl restart websocket-printer) > /dev/null 2>&1 &";
        shell_exec($cmd);
        return ['success' => true, 'message' => '打印服务将在2秒后重启'];
    }
}

function checkPrinterAvailable(string $printerName): bool
{
    $output = [];
    exec('LANG=C lpstat -p ' . escapeshellarg($printerName) . ' 2>&1', $output);
    $statusLine = implode(' ', $output);
    
    if (strpos($statusLine, 'disabled') !== false || 
        strpos($statusLine, 'not exist') !== false) {
        return false;
    }
    
    $output2 = [];
    exec('LANG=C lpstat -a ' . escapeshellarg($printerName) . ' 2>&1', $output2);
    $acceptLine = implode(' ', $output2);
    
    if (strpos($acceptLine, 'not accepting') !== false) {
        return false;
    }
    
    return true;
}

function getPrinterSourceFile(): string
{
    return '/etc/printer-sources.json';
}

function getPrinterSources(): array
{
    $file = getPrinterSourceFile();
    if (file_exists($file)) {
        $data = @json_decode(file_get_contents($file), true);
        return is_array($data) ? $data : [];
    }
    return [];
}

function savePrinterSources(array $sources): void
{
    $file = getPrinterSourceFile();
    file_put_contents($file, json_encode($sources, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
}

function markPrinterSource(string $printerName, string $source): void
{
    $sources = getPrinterSources();
    $sources[$printerName] = [
        'source' => $source,
        'time' => date('Y-m-d H:i:s')
    ];
    savePrinterSources($sources);
}

function syncCupsPrinters(): array
{
    echo "[syncCupsPrinters] 开始同步CUPS打印机...\n";
    
    $printers = getPrinterList();
    $sources = getPrinterSources();
    
    $result = [
        'success' => true,
        'printers' => [],
        'removed' => [],
        'message' => ''
    ];
    
    foreach ($printers as $printer) {
        $name = $printer['name'];
        $uri = $printer['uri'] ?? '';
        $isAvailable = checkPrinterAvailable($name);
        
        $source = 'manual';
        if (isset($sources[$name]) ) {
            $source = $sources[$name]['source'];
        }
        
        echo "[syncCupsPrinters] 打印机 $name (来源: $source, 状态: " . ($isAvailable ? '可用' : '不可用') . ")\n";
        
        $result['printers'][] = [
            'name' => $name,
            'display_name' => $name,
            'uri' => $uri,
            'is_default' => $printer['is_default'] ?? false,
            'status' => $isAvailable ? 'ready' : 'error',
            'source' => $source
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
        'version' => CLIENT_VERSION,
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

function executePrint(string $printerName, string $fileContent, string $filename, string $fileExt, int $copies = 1, ?int $pageFrom = null, ?int $pageTo = null, string $colorMode = 'color', string $orientation = 'portrait'): array
{
    writeLog('INFO', "开始打印任务", [
        'printer' => $printerName,
        'filename' => $filename,
        'ext' => $fileExt,
        'copies' => $copies,
        'color_mode' => $colorMode,
        'orientation' => $orientation,
        'page_from' => $pageFrom,
        'page_to' => $pageTo,
        'content_size' => strlen($fileContent)
    ]);
    
    $tmpDir = '/tmp/print_jobs/';
    if (!is_dir($tmpDir)) {
        mkdir($tmpDir, 0755, true);
    }
    
    $tmpFile = $tmpDir . uniqid('print_') . '.' . $fileExt;
    $decoded = base64_decode($fileContent);
    
    if ($decoded === false) {
        writeLog('ERROR', "文件解码失败", ['filename' => $filename]);
        return ['success' => false, 'message' => '文件解码失败'];
    }
    
    writeLog('INFO', "文件解码成功", ['size' => strlen($decoded), 'tmpFile' => $tmpFile]);
    file_put_contents($tmpFile, $decoded);
    
    $ext = strtolower($fileExt);
    $success = false;
    $output = [];
    
    $lpOptions = buildLpOptions($colorMode, $orientation);
    
    try {
        if ($ext === 'pdf') {
            $printPdf = $tmpFile;
            $useRotatedPdf = false;
            $landscapeOption = '';
            
            if ($orientation === 'landscape') {
                writeLog('INFO', "PDF需要横向打印，尝试转换PDF");
                $rotatedPdf = rotatePdfForLandscape($tmpFile, $tmpDir);
                if (!empty($rotatedPdf) && file_exists($rotatedPdf)) {
                    $printPdf = $rotatedPdf;
                    $useRotatedPdf = true;
                    writeLog('INFO', "PDF已转换为横向", ['rotatedPdf' => $rotatedPdf]);
                } else {
                    $landscapeOption = '-o landscape';
                    writeLog('WARNING', "PDF转换失败，使用打印机横向选项");
                }
            }
            
            $pageOption = '';
            if ($pageFrom !== null && $pageTo !== null && $pageFrom >= 1 && $pageTo >= $pageFrom) {
                $pageOption = sprintf(' -P %d-%d', $pageFrom, $pageTo);
            }

            $cmd = sprintf('lp -d %s -n %d%s %s -o media=A4 %s -o fit-to-page %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                $pageOption,
                $lpOptions,
                $landscapeOption,
                escapeshellarg($printPdf)
            );
            writeLog('INFO', "执行PDF打印命令", ['cmd' => $cmd]);
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
            
            if ($useRotatedPdf && file_exists($printPdf)) {
                @unlink($printPdf);
            }
            
        } elseif (in_array($ext, ['jpg', 'jpeg', 'png', 'gif', 'bmp'])) {
            $printFile = $tmpFile;
            
            if ($orientation === 'landscape') {
                writeLog('INFO', "图片需要横向打印，尝试旋转图片");
                $rotatedImg = $tmpDir . 'rotated_' . uniqid() . '.' . $ext;
                
                $rotateCmd = sprintf('convert %s -rotate 90 %s 2>&1',
                    escapeshellarg($tmpFile),
                    escapeshellarg($rotatedImg)
                );
                exec($rotateCmd, $rotateOutput, $rotateRet);
                
                if ($rotateRet === 0 && file_exists($rotatedImg)) {
                    $printFile = $rotatedImg;
                    writeLog('INFO', "图片已旋转90度", ['rotatedImg' => $rotatedImg]);
                } else {
                    writeLog('WARNING', "图片旋转失败，使用原图打印", ['output' => implode('; ', $rotateOutput)]);
                }
            }
            
            $cmd = sprintf('lp -d %s -n %d %s -o media=A4 -o fit-to-page %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                $lpOptions,
                escapeshellarg($printFile)
            );
            writeLog('INFO', "执行图片打印命令", ['cmd' => $cmd, 'orientation' => $orientation]);
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
            
            if ($printFile !== $tmpFile && file_exists($printFile)) {
                @unlink($printFile);
            }
            
        } elseif (in_array($ext, ['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'txt'])) {
            writeLog('INFO', "准备转换文档为PDF", ['file' => $tmpFile]);
            putenv('HOME=/tmp');
            $pdf = $tmpDir . pathinfo($tmpFile, PATHINFO_FILENAME) . '.pdf';
            
            $convertCmd = 'timeout 60 libreoffice --headless --convert-to pdf --outdir ' . 
                escapeshellarg($tmpDir) . ' ' . escapeshellarg($tmpFile) . ' 2>&1';
            
            writeLog('INFO', "执行LibreOffice转换", ['cmd' => $convertCmd]);
            exec($convertCmd, $cvtOutput, $cvtRet);
            writeLog('INFO', "LibreOffice转换结果", ['ret' => $cvtRet, 'output' => implode('; ', $cvtOutput), 'pdf' => $pdf, 'exists' => file_exists($pdf)]);
            
            if (file_exists($pdf)) {
                $printPdf = $pdf;
                $useRotatedPdf = false;
                $landscapeOption = '';
                
                if ($orientation === 'landscape') {
                    writeLog('INFO', "文档需要横向打印，尝试转换PDF");
                    $rotatedPdf = rotatePdfForLandscape($pdf, $tmpDir);
                    if (!empty($rotatedPdf) && file_exists($rotatedPdf)) {
                        $printPdf = $rotatedPdf;
                        $useRotatedPdf = true;
                        writeLog('INFO', "PDF已转换为横向", ['rotatedPdf' => $rotatedPdf]);
                    } else {
                        $landscapeOption = '-o landscape';
                        writeLog('WARNING', "PDF转换失败，使用打印机横向选项");
                    }
                }
                
                $pageOption = '';
                $pFrom = intval($pageFrom);
                $pTo = intval($pageTo);
                writeLog('INFO', "检查页码参数", ['page_from' => $pageFrom, 'page_to' => $pageTo, 'pFrom' => $pFrom, 'pTo' => $pTo]);
                if ($pFrom >= 1 && $pTo >= $pFrom) {
                    $pageOption = sprintf(' -P %d-%d', $pFrom, $pTo);
                    writeLog('INFO', "文档选页打印", ['pageOption' => $pageOption]);
                }
                
                $cmd = sprintf('lp -d %s -n %d%s %s -o media=A4 %s -o fit-to-page %s 2>&1',
                    escapeshellarg($printerName),
                    $copies,
                    $pageOption,
                    $lpOptions,
                    $landscapeOption,
                    escapeshellarg($printPdf)
                );
                writeLog('INFO', "执行文档打印命令", ['cmd' => $cmd, 'orientation' => $orientation]);
                exec($cmd, $output, $ret);
                $success = ($ret === 0);
                
                @unlink($pdf);
                if ($useRotatedPdf && file_exists($printPdf)) {
                    @unlink($printPdf);
                }
            } else {
                $output = ['LibreOffice 转换失败'];
            }
        } else {
            $cmd = sprintf('lp -d %s -n %d %s %s 2>&1',
                escapeshellarg($printerName),
                $copies,
                $lpOptions,
                escapeshellarg($tmpFile)
            );
            exec($cmd, $output, $ret);
            $success = ($ret === 0);
        }
    } finally {
        @unlink($tmpFile);
    }
    
    $message = $success ? '打印任务已提交' : ('打印失败: ' . implode('; ', $output));
    writeLog($success ? 'INFO' : 'ERROR', "打印任务完成", [
        'success' => $success,
        'printer' => $printerName,
        'filename' => $filename,
        'message' => $message
    ]);
    
    return [
        'success' => $success,
        'message' => $message
    ];
}

function buildLpOptions($colorMode, $orientation): string
{
    $options = [];
    
    $colorMode = strval($colorMode ?: 'color');
    
    if ($colorMode === 'gray') {
        $options[] = '-o ColorModel=Gray';
        $options[] = '-o print-color-mode=monochrome';
    }
    

    return implode(' ', $options);
}


function rotatePdfForLandscape($pdfFile, $tmpDir): string
{
    $pdfFile = strval($pdfFile);
    $tmpDir = strval($tmpDir);
    $rotatedPdf = $tmpDir . uniqid('landscape_') . '.pdf';
    
    exec('which pdfjam 2>/dev/null', $whichPdfjam, $whichPdfjamRet);
    if ($whichPdfjamRet === 0) {
        $pdfjamCmd = sprintf('pdfjam --angle 90 --fitpaper true --rotateoversize true --outfile %s %s 2>&1',
            escapeshellarg($rotatedPdf),
            escapeshellarg($pdfFile)
        );
        exec($pdfjamCmd, $pdfjamOutput, $pdfjamRet);
        
        if ($pdfjamRet === 0 && file_exists($rotatedPdf)) {
            writeLog('INFO', "PDF已使用pdfjam转换为横向", ['rotatedPdf' => $rotatedPdf]);
            return $rotatedPdf;
        }
        writeLog('WARNING', "pdfjam转换失败", ['output' => implode('; ', $pdfjamOutput)]);
    }
    
    exec('which ps2pdf 2>/dev/null', $whichPs2pdf, $whichPs2pdfRet);
    if ($whichPs2pdfRet === 0) {
        $tmpPs = $tmpDir . uniqid('tmp_') . '.ps';
        $pdf2psCmd = sprintf('pdf2ps %s %s 2>&1', escapeshellarg($pdfFile), escapeshellarg($tmpPs));
        exec($pdf2psCmd, $pdf2psOutput, $pdf2psRet);
        
        if ($pdf2psRet === 0 && file_exists($tmpPs)) {
            $ps2pdfCmd = sprintf('ps2pdf -sPAPERSIZE=a4 -dAutoRotatePages=/None %s %s 2>&1',
                escapeshellarg($tmpPs),
                escapeshellarg($rotatedPdf)
            );
            exec($ps2pdfCmd, $ps2pdfOutput, $ps2pdfRet);
            @unlink($tmpPs);
            
            if ($ps2pdfRet === 0 && file_exists($rotatedPdf)) {
                writeLog('INFO', "PDF已使用ps2pdf转换", ['rotatedPdf' => $rotatedPdf]);
                return $rotatedPdf;
            }
        }
        writeLog('WARNING', "ps2pdf转换失败");
    }
    
    writeLog('WARNING', "未安装PDF转换工具(pdfjam/ps2pdf)，将尝试使用打印机横向选项");
    return '';
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
        
        writeLog('INFO', "正在连接服务器...");
        
        $this->socket = @stream_socket_client(
            "tcp://{$host}:{$port}",
            $errno,
            $errstr,
            10
        );
        
        if (!$this->socket) {
            writeLog('ERROR', "连接失败", ['errno' => $errno]);
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
            writeLog('ERROR', "WebSocket握手失败");
            fclose($this->socket);
            return false;
        }
        
        stream_set_blocking($this->socket, false);
        $this->connected = true;
        writeLog('INFO', "已连接到服务器");
        
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
            'version' => CLIENT_VERSION,
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
        global $HEARTBEAT_INTERVAL, $LAST_TEMP_CLEAN;
        
        cleanOldLogs();
        
        while (true) {
            if (!$this->connected) {
                $this->reconnect();
                continue;
            }
            
            $data = @fread($this->socket, 65535);
            if ($data === false || feof($this->socket)) {
                writeLog('WARN', "连接断开");
                $this->connected = false;
                continue;
            }
            
            if ($data) {
                $message = $this->decodeFrame($data);
                if ($message) {
                    $this->messageBuffer .= $message;
                    
                    $decoded = @json_decode($this->messageBuffer, true);
                    if ($decoded !== null) {
                        writeLog('DEBUG', "完整消息接收完成", ['length' => strlen($this->messageBuffer)]);
                        $this->handleMessage($this->messageBuffer);
                        $this->messageBuffer = '';
                    }
                    continue;
                }
            }
            
            $now = time();
            
            if ($now - $this->lastHeartbeat >= $HEARTBEAT_INTERVAL) {
                $this->send(['action' => 'heartbeat']);
                $this->lastHeartbeat = $now;
            }
            
            if ($now - $LAST_TEMP_CLEAN >= TEMP_CLEAN_INTERVAL) {
                cleanTempPrintFiles();
                cleanOldLogs();
                $LAST_TEMP_CLEAN = $now;
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
        
        $silentActions = ['heartbeat_ack', 'get_logs', 'get_log_dates', 'get_status', 'clean_temp'];
        if (!in_array($action, $silentActions)) {
            echo "收到命令: " . $action . "\n";
            if ($action === 'unknown') {
                echo "[DEBUG] 原始消息: " . substr($message, 0, 500) . "\n";
            }
        }
        
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
                $copies = intval($data['copies'] ?? 1);
                $taskId = $data['task_id'] ?? $data['job_id'] ?? '';
                $pageFrom = isset($data['page_from']) && $data['page_from'] !== '' ? intval($data['page_from']) : null;
                $pageTo   = isset($data['page_to']) && $data['page_to'] !== '' ? intval($data['page_to']) : null;
                $colorMode = strval($data['color_mode'] ?? 'color');
                $orientation = strval($data['orientation'] ?? 'portrait');
                
                echo "[print] 打印机: $printer, 文件: $filename, 扩展名: $fileExt, 份数: $copies, 色彩: $colorMode, 方向: $orientation\n";
                
                if (!empty($fileUrl) && empty($fileContent)) {
                    echo "[print] 从URL下载文件: $fileUrl\n";
                    
                    $ch = curl_init();
                    curl_setopt_array($ch, [
                        CURLOPT_URL => $fileUrl,
                        CURLOPT_RETURNTRANSFER => true,
                        CURLOPT_FOLLOWLOCATION => true,
                        CURLOPT_TIMEOUT => 120,
                        CURLOPT_CONNECTTIMEOUT => 10,
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
                    $result = executePrint($printer, $fileContent, $filename, $fileExt, $copies, $pageFrom, $pageTo, $colorMode, $orientation);
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
                
                $syncResult = syncCupsPrinters();
                
                $this->send([
                    'action' => 'sync_cups_result',
                    'request_id' => $requestId,
                    'success' => $syncResult['success'],
                    'message' => $syncResult['message'],
                    'removed' => $syncResult['removed']
                ]);
                
                $this->send([
                    'action' => 'printers_update',
                    'printers' => $syncResult['printers']
                ]);
                break;
                
            case 'get_logs':
                $requestId = $data['request_id'] ?? '';
                $lines = intval($data['lines'] ?? 200);
                $date = $data['date'] ?? '';
                
                $logResult = getLogContent($lines, $date);
                $this->send([
                    'action' => 'logs_result',
                    'request_id' => $requestId,
                    'success' => $logResult['success'],
                    'date' => $logResult['date'],
                    'total_lines' => $logResult['total_lines'] ?? 0,
                    'returned_lines' => $logResult['returned_lines'] ?? 0,
                    'logs' => $logResult['logs']
                ]);
                break;
                
            case 'get_log_dates':
                $requestId = $data['request_id'] ?? '';
                
                $dates = getLogDates();
                $this->send([
                    'action' => 'log_dates_result',
                    'request_id' => $requestId,
                    'dates' => $dates
                ]);
                break;
                
            case 'get_device_status':
                $requestId = $data['request_id'] ?? '';
                
                $status = getDeviceStatus();
                $this->send([
                    'action' => 'device_status_result',
                    'request_id' => $requestId,
                    'status' => $status
                ]);
                break;
                
            case 'clean_temp_files':
                $requestId = $data['request_id'] ?? '';
                
                writeLog('INFO', "收到清理临时文件请求");
                $cleanResult = cleanTempPrintFiles();
                
                $this->send([
                    'action' => 'clean_temp_result',
                    'request_id' => $requestId,
                    'success' => true,
                    'cleaned' => $cleanResult['cleaned'],
                    'errors' => $cleanResult['errors']
                ]);
                break;
                
            case 'get_cups_jobs':
                $requestId = $data['request_id'] ?? '';
                $printerName = $data['printer_name'] ?? '';
                echo "[get_cups_jobs] 获取打印队列, 打印机: $printerName\n";
                
                $jobs = getCupsJobs($printerName);
                $this->send([
                    'action' => 'cups_jobs_result',
                    'request_id' => $requestId,
                    'success' => true,
                    'jobs' => $jobs
                ]);
                break;
                
            case 'cancel_cups_job':
                $requestId = $data['request_id'] ?? '';
                $jobId = $data['job_id'] ?? '';
                $printerName = $data['printer_name'] ?? '';
                echo "[cancel_cups_job] 取消任务: $jobId\n";
                
                if (empty($jobId)) {
                    $this->send([
                        'action' => 'cancel_job_result',
                        'request_id' => $requestId,
                        'success' => false,
                        'message' => '任务ID不能为空'
                    ]);
                } else {
                    $result = cancelCupsJob($jobId, $printerName);
                    $this->send([
                        'action' => 'cancel_job_result',
                        'request_id' => $requestId,
                        'success' => $result['success'],
                        'message' => $result['message']
                    ]);
                }
                break;
                
            case 'reboot':
                $requestId = $data['request_id'] ?? '';
                $rebootSystem = ($data['reboot_system'] ?? false) === true;
                echo "========================================\n";
                echo "[reboot] 收到远程重启命令, 重启系统: " . ($rebootSystem ? '是' : '否') . "\n";
                echo "========================================\n";
                
                writeLog('WARN', "收到远程重启命令", ['reboot_system' => $rebootSystem]);
                
                $result = rebootDevice($rebootSystem);
                echo "[reboot] 执行结果: " . ($result['success'] ? '成功' : '失败') . " - " . $result['message'] . "\n";
                
                $this->send([
                    'action' => 'reboot_result',
                    'request_id' => $requestId,
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                break;
                
            case 'restart_service':
                $requestId = $data['request_id'] ?? '';
                echo "========================================\n";
                echo "[restart_service] 收到远程重启服务命令!\n";
                echo "========================================\n";
                
                writeLog('INFO', "收到远程重启服务命令");
                
                $result = rebootDevice(false);
                echo "[restart_service] 执行结果: " . ($result['success'] ? '成功' : '失败') . " - " . $result['message'] . "\n";
                
                $this->send([
                    'action' => 'restart_service_result',
                    'request_id' => $requestId,
                    'success' => $result['success'],
                    'message' => $result['message']
                ]);
                break;
        }
    }
    
    private function reconnect()
    {
        global $RECONNECT_INTERVAL, $MAX_RECONNECT_INTERVAL;
        
        $retryCount = 0;
        $currentInterval = $RECONNECT_INTERVAL;
        
        while (true) {
            $retryCount++;
            writeLog('INFO', "连接断开，尝试第 {$retryCount} 次重连...");
            echo "连接断开，尝试第 {$retryCount} 次重连...\n";
            
            if ($this->socket) {
                @fclose($this->socket);
                $this->socket = null;
            }
            $this->connected = false;
            $this->messageBuffer = '';
            
            sleep($currentInterval);
            
            if ($this->connect()) {
                writeLog('INFO', "重连成功，共尝试 {$retryCount} 次");
                echo "重连成功！\n";
                return; 
            }
            
            $currentInterval = min($currentInterval * 2, $MAX_RECONNECT_INTERVAL);
            writeLog('WARN', "重连失败，{$currentInterval}秒后继续尝试...");
        }
    }
    
    public function getDeviceId(): string
    {
        return $this->deviceId;
    }
}

$deviceId = getDeviceId();
$qrContent = "device://{$deviceId}";

initLogDir();
writeLog('INFO', "========================================");
writeLog('INFO', "  打印机客户端 v" . CLIENT_VERSION);
writeLog('INFO', "========================================");
writeLog('INFO', "设备ID: $deviceId");
writeLog('INFO', "启动时间: " . date('Y-m-d H:i:s'));

echo "========================================\n";
echo "  打印机客户端 v" . CLIENT_VERSION . "\n";
echo "========================================\n";
echo "设备ID: $deviceId\n";
echo "启动时间: " . date('Y-m-d H:i:s') . "\n";
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

while (true) {
    if ($client->connect()) {
        $client->run();
        // run() 
        writeLog('WARN', "主循环检测到连接断开，准备重连...");
    } else {
        writeLog('WARN', "连接失败，{$RECONNECT_INTERVAL}秒后重试...");
    }
    sleep($RECONNECT_INTERVAL);
}
