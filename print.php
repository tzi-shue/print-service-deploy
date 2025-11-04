<?php
/* ---------- 探活 ---------- */
if (isset($_GET['action']) && $_GET['action'] === 'ping') {
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['pong' => 'printer_ready']);
    exit;
}

/* ---------- 统一头 ---------- */
header('Content-Type: text/html; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') exit;

/* ---------- 获取打印机列表 ---------- */
function getPrinters(): array
{
    $win = strtoupper(substr(PHP_OS, 0, 3)) === 'WIN';
    $list = $default = null;
    if ($win) {
        exec('wmic printer get name /format:list', $out);
        foreach ($out as $l) if (strpos($l, 'Name=') === 0) $list[] = trim(substr($l, 5));
        exec('wmic printer where "Default=\'TRUE\'" get name /format:list', $def);
        foreach ($def as $l) if (strpos($l, 'Name=') === 0) {$default = trim(substr($l, 5)); break;}
    } else {
        exec('lpstat -a 2>&1', $pa); foreach ($pa as $l) if (preg_match('/^(\S+)\s+accept/i', $l, $m)) $list[] = $m[1];
        exec('lpstat -d 2>&1', $d);  if (preg_match('/system default destination:\s*(\S+)/', implode('', $d), $m)) $default = $m[1];
    }
    return [$list ?? [], $default];
}
[$printers, $defaultPrinter] = getPrinters();

/* ---------- 远端小程序二维码 ---------- */
$wxQrUrl = 'https://img.zyshare.top/xcx.jpg'; // 换你自己的直链
$wxQrBin = @file_get_contents($wxQrUrl);
$wxQrB64 = $wxQrBin ? base64_encode($wxQrBin) : '';

/* ---------- GET：网页模式 ---------- */
if ($_SERVER['REQUEST_METHOD'] === 'GET' && !isset($_GET['printer'])) {
    /* 读子域名 */
    $frpc = '/etc/frp/frpc.toml';
    $sub  = '';
    if (is_readable($frpc) && preg_match('/subdomain\s*=\s*"([^"]+)"/', file_get_contents($frpc), $m)) $sub = $m[1];
    if (!$sub) die('无法读取 subdomain，请确认 FRP 已部署且 /etc/frp/frpc.toml 可读');
    ?>
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>远程打印中心</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Noto Sans",sans-serif; margin:0; padding:20px; background:#f5f5f5;}
h1{font-size:24px; margin-bottom:10px; text-align:center}
.steps{display:flex; align-items:center; gap:15px; margin:15px 0 25px; background:#fff; border-radius:8px; padding:15px; box-shadow:0 2px 6px rgba(0,0,0,.1)}
.steps ol{margin:0; padding-left:20px; line-height:1.8}
.steps img{border:1px solid #ddd; border-radius:4px}
.printer-card{background:#fff; border-radius:8px; padding:15px; margin:15px 0; box-shadow:0 2px 6px rgba(0,0,0,.1)}
.printer-name{font-weight:600; font-size:18px; margin-bottom:8px}
.print-link{color:#0969da; text-decoration:none; word-break:break-all}
.qr-box{margin-top:10px}
.upload-area{margin-top:30px; text-align:center; background:#fff; border-radius:8px; padding:20px; box-shadow:0 2px 6px rgba(0,0,0,.1)}
.upload-area select{margin:10px 0}
.upload-area input[type=file]{margin:10px 0}
.btn{background:#0969da; color:#fff; border:none; padding:8px 16px; border-radius:4px; cursor:pointer}
.btn:hover{background:#0750b6}
</style>
<script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"></script>
</head>
<body>
<h1>🖨️ 远程打印中心</h1>

<div class="steps">
  <div>
    <h3 style="margin:0 0 6px; font-size:18px;">📱 两步远程打印</h3>
    <ol>
      <li>① 微信扫一扫右侧小程序码</li>
      <li>② 在小程序内<strong>扫描打印机二维码</strong>即可打印</li>
    </ol>
  </div>
  <div>
    <?php if ($wxQrB64): ?>
      <img src="data:image/jpeg;base64,<?= $wxQrB64 ?>" width="120" alt="微信小程序码">
    <?php else: ?>
      <div style="width:120px;height:120px;border:1px solid #ddd;border-radius:4px;display:flex;align-items:center;justify-content:center;font-size:12px;color:#666">小程序码<br>加载失败</div>
    <?php endif; ?>
    <div style="font-size:12px; color:#666; text-align:center; margin-top:4px">微信小程序</div>
  </div>
</div>

<?php foreach ($printers as $p):
    $url = "http://{$sub}.frp.tzishue.tk/print.php?printer=" . urlencode($p); ?>
<div class="printer-card">
  <div class="printer-name"><?= htmlspecialchars($p) ?></div>
  <div>打印链接：
    <a class="print-link" href="<?= $url ?>" target="_blank"><?= $url ?></a>
  </div>
  <div class="qr-box" id="qr-<?= md5($p) ?>"></div>
</div>
<?php endforeach; ?>

<div class="upload-area">
  <h2>直接打印文件</h2>
  <form action="" method="post" enctype="multipart/form-data">
    选择打印机：
    <select name="printer">
      <?php foreach ($printers as $p): ?>
        <option value="<?= htmlspecialchars($p) ?>" <?= $p === $defaultPrinter ? 'selected' : '' ?>><?= htmlspecialchars($p) ?></option>
      <?php endforeach; ?>
    </select>
    <br>
    选择文件：
    <input type="file" name="file" required>
    <br>
    <button type="submit" class="btn">立即打印</button>
  </form>
</div>

<script>
<?php foreach ($printers as $p): ?>
new QRCode(document.getElementById('qr-<?= md5($p) ?>'), {
  text: 'http://<?= $sub ?>.frp.tzishue.tk/print.php?printer=<?= urlencode($p) ?>',
  width: 160,
  height: 160
});
<?php endforeach; ?>
</script>
</body>
</html>
    <?php
    exit;
}

/* ---------- POST：JSON 打印接口（保持原有逻辑） ---------- */
header('Content-Type: application/json; charset=utf-8');

$input = file_get_contents('php://input');
$data  = json_decode($input, true);
if (!$data) {
    echo json_encode(['success' => false, 'message' => '无效的 JSON 数据']);
    exit;
}

$required = ['openid', 'filename', 'file_content_base64'];
foreach ($required as $f) {
    if (!isset($data[$f]) || empty(trim($data[$f]))) {
        echo json_encode(['success' => false, 'message' => "缺少必要字段: {$f}"]);
        exit;
    }
}
$openid              = trim($data['openid']);
$filename            = trim($data['filename']);
$file_content_base64 = trim($data['file_content_base64']);
$file_ext            = isset($data['file_ext']) ? strtolower(trim($data['file_ext'])) : pathinfo($filename, PATHINFO_EXTENSION);

/* 选择打印机 */
$win       = strtoupper(substr(PHP_OS, 0, 3)) === 'WIN';
$qsPrinter = $_GET['printer'] ?? null;
$default   = null;
if ($win) {
    exec('wmic printer where "Default=\'TRUE\'" get name /format:list', $def);
    foreach ($def as $l) if (strpos($l, 'Name=') === 0) {$default = trim(substr($l, 5)); break;}
} else {
    exec('lpstat -d 2>&1', $d); if (preg_match('/system default destination:\s*(\S+)/', implode('', $d), $m)) $default = $m[1];
}
$target = $qsPrinter && in_array($qsPrinter, $printers, true) ? $qsPrinter : ($default ?: null);
if (!$target) {
    echo json_encode(['success' => false, 'message' => '未找到可用打印机']);
    exit;
}

/* 保存临时文件 */
$tmpDir = $win ? 'C:/Windows/Temp/print_jobs/' : '/tmp/print_jobs/';
if (!is_dir($tmpDir)) mkdir($tmpDir, 0755, true);
$tmpFile = $tmpDir . uniqid('print_') . '.' . $file_ext;
$file_content = base64_decode($file_content_base64);
if ($file_content === false || file_put_contents($tmpFile, $file_content) === false) {
    echo json_encode(['success' => false, 'message' => '文件解码或保存失败']);
    exit;
}

/* 打印逻辑（精简版，保持你原有） */
$success = false; $output = []; $method = '';
try {
    $ext = strtolower($file_ext);
    if (in_array($ext, ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'pdf'])) {
        $method = 'direct'; $cmd = "lp -d " . escapeshellarg($target) . " " . escapeshellarg($tmpFile) . " 2>&1";
        exec($cmd, $output, $ret); $success = ($ret === 0);
    } elseif (in_array($ext, ['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp'])) {
        $method = 'libreoffice';
        putenv('HOME=/tmp'); putenv('SHELL=/bin/bash'); putenv('USER=www-data');
        $pdf = $tmpDir . pathinfo($tmpFile, PATHINFO_FILENAME) . '.pdf';
        exec('timeout 60 libreoffice --headless --convert-to pdf --outdir ' . escapeshellarg($tmpDir) . ' ' . escapeshellarg($tmpFile) . ' 2>&1', $cvt, $cvtRet);
        if (!file_exists($pdf)) throw new Exception('LibreOffice 转换失败');
        exec("lp -d " . escapeshellarg($target) . " " . escapeshellarg($pdf) . " 2>&1", $out, $ret);
        $success = ($ret === 0); $output = array_merge($cvt, $out); @unlink($pdf);
    } else {
        $method = 'direct'; $cmd = "lp -d " . escapeshellarg($target) . " " . escapeshellarg($tmpFile) . " 2>&1";
        exec($cmd, $output, $ret); $success = ($ret === 0);
    }
    @unlink($tmpFile);
    if ($success) {
        echo json_encode(['success' => true, 'message' => '打印任务已提交', 'method' => $method, 'printer' => $target]);
    } else {
        throw new Exception('打印失败: ' . implode('; ', $output));
    }
} catch (Exception $e) {
    @unlink($tmpFile);
    echo json_encode(['success' => false, 'message' => $e->getMessage(), 'printer' => $target]);
}
