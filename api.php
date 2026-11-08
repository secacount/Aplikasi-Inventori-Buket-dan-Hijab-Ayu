<?php
require_once __DIR__ . '/includes/supabase.php';

function delete_storage_object_by_path(string $token, string $path): void
{
    $path = trim($path);
    if ($path === '') return;
    $bucket = app_config()['storage_bucket'];
    $encodedPath = implode('/', array_map('rawurlencode', explode('/', $path)));
    try {
        sb_request('DELETE', 'storage/v1/object/' . rawurlencode($bucket) . '/' . $encodedPath, null, $token);
    } catch (Throwable $ignored) {
        // Biarkan file lama tertinggal bila operasi penghapusan gagal; tidak memaksa data utama ikut terhapus.
    }
}

function fetch_owned_item(string $token, string $itemId, string $userId): array
{
    $result = sb_assert(
        sb_request('GET', 'rest/v1/inventory_items?id=eq.' . sb_path_id($itemId) . '&user_id=eq.' . rawurlencode($userId) . '&select=id,image_path,image_url,user_id', null, $token),
        'Barang tidak ditemukan atau bukan milik akun ini.'
    );
    $items = is_array($result) ? $result : [];
    if (!isset($items[0])) {
        throw new InvalidArgumentException('Barang tidak ditemukan atau bukan milik akun ini.');
    }
    return $items[0];
}

$action = $_GET['action'] ?? '';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

try {
    // Endpoint state hanya mengembalikan metadata sesi dan token CSRF, bukan token Supabase.
    if ($action === 'state' && $method === 'GET') {
        $token = current_access_token();
        json_response([
            'ok' => true,
            'csrf' => $_SESSION['csrf_token'],
            'user' => $token ? ($_SESSION['sb_user'] ?? null) : null,
            'configured' => app_config_is_valid(),
        ]);
    }

    if ($method !== 'POST') json_response(['ok' => false, 'message' => 'Metode tidak diizinkan.'], 405);
    require_csrf();
    $input = request_json();

    if ($action === 'signup') {
        $email = trim((string)($input['email'] ?? ''));
        $password = (string)($input['password'] ?? '');
        $business = trim((string)($input['business_name'] ?? ''));
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('Format email belum benar.');
        if (strlen($password) < 8) throw new InvalidArgumentException('Kata sandi minimal 8 karakter.');
        $result = sb_request('POST', 'auth/v1/signup', [
            'email' => $email,
            'password' => $password,
            'data' => ['business_name' => $business],
        ]);
        $auth = sb_assert($result, 'Pendaftaran gagal.');
        if (!empty($auth['access_token'])) {
            save_auth_session($auth);
            json_response(['ok' => true, 'user' => $auth['user'], 'message' => 'Akun berhasil dibuat.']);
        }
        json_response(['ok' => true, 'user' => null, 'message' => 'Akun dibuat. Periksa email untuk konfirmasi, lalu login.']);
    }

    if ($action === 'login') {
        $email = trim((string)($input['email'] ?? ''));
        $password = (string)($input['password'] ?? '');
        $result = sb_request('POST', 'auth/v1/token?grant_type=password', ['email' => $email, 'password' => $password]);
        $auth = sb_assert($result, 'Email atau kata sandi tidak cocok.');
        save_auth_session($auth);
        json_response(['ok' => true, 'user' => $auth['user'], 'message' => 'Login berhasil.']);
    }

    if ($action === 'logout') {
        $token = current_access_token();
        if ($token) {
            try { sb_request('POST', 'auth/v1/logout', null, $token); } catch (Throwable $ignored) {}
        }
        clear_auth_session();
        json_response(['ok' => true, 'message' => 'Anda sudah logout.']);
    }

    $auth = require_user();
    $token = $auth['token'];
    $userId = $auth['user']['id'];

    if ($action === 'items_list') {
        $data = sb_assert(sb_request('GET', 'rest/v1/inventory_items?select=*&user_id=eq.' . rawurlencode($userId) . '&is_active=eq.true&order=updated_at.desc', null, $token), 'Gagal mengambil data stok.');
        json_response(['ok' => true, 'items' => $data ?? []]);
    }

    if ($action === 'item_save') {
        $id = trim((string)($input['id'] ?? ''));
        $category = (string)($input['category'] ?? '');
        $allowed = ['hijab', 'flower', 'tool', 'packaging', 'finished_product'];
        if (!in_array($category, $allowed, true)) throw new InvalidArgumentException('Kategori barang tidak dikenali.');
        $name = trim((string)($input['name'] ?? ''));
        if ($name === '') throw new InvalidArgumentException('Nama barang wajib diisi.');

        $currentImagePath = null;
        if ($id !== '') {
            $currentItem = fetch_owned_item($token, $id, $userId);
            $currentImagePath = (string)($currentItem['image_path'] ?? '');
        }

        $initialStock = max(0, (float)($input['stock_qty'] ?? 0));
        $payload = [
            'user_id' => $userId,
            'category' => $category,
            'name' => substr($name, 0, 120),
            'variant' => trim((string)($input['variant'] ?? '')) ?: null,
            'color' => trim((string)($input['color'] ?? '')) ?: null,
            'sku' => trim((string)($input['sku'] ?? '')) ?: null,
            'unit' => trim((string)($input['unit'] ?? 'pcs')) ?: 'pcs',
            'stock_qty' => $initialStock,
            'min_stock' => max(0, (float)($input['min_stock'] ?? 0)),
            'purchase_price' => max(0, (float)($input['purchase_price'] ?? 0)),
            'stem_price' => max(0, (float)($input['stem_price'] ?? 0)),
            'selling_price' => max(0, (float)($input['selling_price'] ?? 0)),
            'description' => trim((string)($input['description'] ?? '')) ?: null,
            'image_url' => trim((string)($input['image_url'] ?? '')) ?: null,
            'image_path' => trim((string)($input['image_path'] ?? '')) ?: null,
            'is_active' => true,
        ];
        if ($id !== '') {
            unset($payload['stock_qty'], $payload['user_id']);
            $query = 'rest/v1/inventory_items?id=eq.' . sb_path_id($id) . '&user_id=eq.' . rawurlencode($userId);
            $data = sb_assert(sb_request('PATCH', $query, $payload, $token, ['Prefer: return=representation']), 'Gagal memperbarui barang.');
            $newImagePath = trim((string)($payload['image_path'] ?? ''));
            if ($newImagePath !== '' && $newImagePath !== $currentImagePath && $currentImagePath !== '') {
                delete_storage_object_by_path($token, $currentImagePath);
            }
        } else {
            $data = sb_assert(sb_request('POST', 'rest/v1/inventory_items', $payload, $token, ['Prefer: return=representation']), 'Gagal menyimpan barang.');
            $createdItem = is_array($data) ? ($data[0] ?? null) : null;
            if ($createdItem && $initialStock > 0) {
                $movement = sb_assert(sb_request('POST', 'rest/v1/rpc/register_stock_movement', [
                    'p_item_id' => $createdItem['id'],
                    'p_movement_type' => 'OPENING',
                    'p_quantity' => $initialStock,
                    'p_note' => 'Saldo awal barang',
                ], $token), 'Gagal mencatat saldo awal barang.');
                if (isset($createdItem['stock_qty']) && $createdItem['stock_qty'] !== $initialStock) {
                    $createdItem['stock_qty'] = $initialStock;
                }
            }
        }
        json_response(['ok' => true, 'item' => is_array($data) ? ($data[0] ?? null) : null, 'message' => 'Data barang berhasil disimpan.']);
    }

    if ($action === 'item_delete') {
        $id = trim((string)($input['id'] ?? ''));
        $existing = fetch_owned_item($token, $id, $userId);
        $archiveResult = sb_assert(sb_request('POST', 'rest/v1/rpc/archive_item', ['p_item_id' => $id], $token), 'Gagal mengarsipkan barang.');
        if (!empty($existing['image_path'])) {
            delete_storage_object_by_path($token, (string)$existing['image_path']);
        }
        json_response(['ok' => true, 'message' => 'Barang berhasil diarsipkan.']);
    }

    if ($action === 'stock_move') {
        $id = trim((string)($input['item_id'] ?? ''));
        if ($id === '') throw new InvalidArgumentException('ID barang wajib diisi.');
        fetch_owned_item($token, $id, $userId);
        $type = strtoupper((string)($input['movement_type'] ?? ''));
        if (!in_array($type, ['IN', 'OUT', 'ADJUSTMENT'], true)) throw new InvalidArgumentException('Jenis perubahan stok tidak valid.');
        $qty = (float)($input['quantity'] ?? 0);
        if ($qty <= 0) throw new InvalidArgumentException('Jumlah harus lebih besar dari nol.');
        $payload = [
            'p_item_id' => $id,
            'p_movement_type' => $type,
            'p_quantity' => $qty,
            'p_note' => trim((string)($input['note'] ?? '')) ?: null,
        ];
        $result = sb_assert(sb_request('POST', 'rest/v1/rpc/register_stock_movement', $payload, $token), 'Gagal mencatat perubahan stok.');
        json_response(['ok' => true, 'movement' => $result, 'message' => 'Perubahan stok berhasil dicatat.']);
    }

    if ($action === 'movements_list') {
        $data = sb_assert(sb_request('GET', 'rest/v1/stock_movements?select=*,inventory_items(name,category,color,unit)&user_id=eq.' . rawurlencode($userId) . '&order=created_at.desc&limit=100', null, $token), 'Gagal mengambil riwayat stok.');
        json_response(['ok' => true, 'movements' => $data ?? []]);
    }

    if ($action === 'image_upload') {
        if (empty($_FILES['image']) || !is_uploaded_file($_FILES['image']['tmp_name']) || $_FILES['image']['error'] !== UPLOAD_ERR_OK) throw new InvalidArgumentException('Pilih gambar yang valid untuk diunggah.');
        $file = $_FILES['image'];
        if ($file['size'] > 5 * 1024 * 1024) throw new InvalidArgumentException('Ukuran gambar maksimal 5 MB.');
        $finfo = new finfo(FILEINFO_MIME_TYPE);
        $mime = $finfo->file($file['tmp_name']);
        $extensions = ['image/jpeg' => 'jpg', 'image/png' => 'png', 'image/webp' => 'webp'];
        if (!isset($extensions[$mime])) throw new InvalidArgumentException('Format gambar harus JPG, PNG, atau WEBP.');
        $bucket = app_config()['storage_bucket'];
        $path = $userId . '/' . bin2hex(random_bytes(16)) . '.' . $extensions[$mime];
        $encodedPath = implode('/', array_map('rawurlencode', explode('/', $path)));
        $bytes = file_get_contents($file['tmp_name']);
        if ($bytes === false) throw new InvalidArgumentException('File gambar tidak dapat dibaca.');
        $result = sb_request('POST', 'storage/v1/object/' . rawurlencode($bucket) . '/' . $encodedPath, $bytes, $token, [
            'Content-Type: ' . $mime,
            'x-upsert: false',
            'Cache-Control: max-age=3600',
        ], true);
        sb_assert($result, 'Gagal mengunggah gambar. Periksa kebijakan Supabase Storage.');
        $url = rtrim(app_config()['supabase_url'], '/') . '/storage/v1/object/public/' . rawurlencode($bucket) . '/' . $encodedPath;
        json_response(['ok' => true, 'image_url' => $url, 'image_path' => $path, 'message' => 'Foto berhasil diunggah.']);
    }

    json_response(['ok' => false, 'message' => 'Aksi tidak ditemukan.'], 404);
} catch (InvalidArgumentException $e) {
    json_response(['ok' => false, 'message' => $e->getMessage()], 422);
} catch (Throwable $e) {
    error_log('[Ruang Stok] ' . $e->getMessage());
    json_response(['ok' => false, 'message' => $e->getMessage()], 500);
}
