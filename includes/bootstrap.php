<?php
// Inisialisasi sesi dan konfigurasi aplikasi.
$configFile = dirname(__DIR__) . '/config.php';
$configFromFile = is_file($configFile) ? require $configFile : null;

$GLOBALS['APP_CONFIG'] = $configFromFile;
if (!is_array($GLOBALS['APP_CONFIG'])) {
    $GLOBALS['APP_CONFIG'] = [
        'supabase_url' => getenv('SUPABASE_URL') ?: getenv('NEXT_PUBLIC_SUPABASE_URL') ?: '',
        'supabase_anon_key' => getenv('SUPABASE_ANON_KEY') ?: getenv('NEXT_PUBLIC_SUPABASE_ANON_KEY') ?: '',
        'storage_bucket' => getenv('STORAGE_BUCKET') ?: 'inventory-images',
        'app_name' => getenv('APP_NAME') ?: 'Ruang Stok',
        'session_secure' => filter_var(getenv('SESSION_SECURE') ?: 'false', FILTER_VALIDATE_BOOLEAN),
    ];
}

if (session_status() !== PHP_SESSION_ACTIVE) {
    $config = is_array($GLOBALS['APP_CONFIG'] ?? null) ? $GLOBALS['APP_CONFIG'] : [];
    $isHttps = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') || (!empty($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https');
    $secureCookies = (bool)($config['session_secure'] ?? false) && $isHttps;
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'secure' => $secureCookies,
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
    session_start();
}

if (empty($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

function app_config(): array
{
    $config = $GLOBALS['APP_CONFIG'] ?? null;
    if (!is_array($config)) {
        throw new RuntimeException('Konfigurasi belum dibuat. Salin config.example.php menjadi config.php lalu isi kredensial Supabase.');
    }
    foreach (['supabase_url', 'supabase_anon_key', 'storage_bucket'] as $key) {
        if (empty($config[$key]) || str_contains((string)$config[$key], 'PROJECT-REF') || str_contains((string)$config[$key], 'SUPABASE_PUBLISHABLE')) {
            throw new RuntimeException('Konfigurasi Supabase belum lengkap. Periksa file config.php.');
        }
    }
    return $config;
}

function app_config_is_valid(): bool
{
    try {
        app_config();
        return true;
    } catch (Throwable $e) {
        return false;
    }
}

function json_response(array $data, int $status = 200): never
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store, private');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function request_json(): array
{
    $raw = file_get_contents('php://input');
    if (!$raw) return [];
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

function require_csrf(): void
{
    $sent = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
    $known = $_SESSION['csrf_token'] ?? '';
    if (!$sent || !$known || !hash_equals($known, $sent)) {
        json_response(['ok' => false, 'message' => 'Token keamanan tidak valid. Muat ulang halaman dan coba lagi.'], 419);
    }
}
