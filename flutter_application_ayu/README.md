# AYU Mobile Inventory

Aplikasi Android untuk mengelola inventaris YM THREAD dan Arum Gift Buket dengan Supabase Auth dan RLS aktif.

## Fase saat ini

Fondasi Fase 1 menyediakan:
- setup Flutter + Supabase Auth
- konfigurasi build-time dan validasi saat aplikasi dimulai
- route splash/login/dashboard dengan redirect yang mengikuti perubahan sesi
- login, pendaftaran, dan logout berbasis sesi Supabase

Fase 2 menyediakan workspace, RLS membership, invitation, bootstrap Owner, serta halaman manajemen anggota. Pemilik project mengonfirmasi migration 003 dan tes RLS dua akun berhasil.

Fase 3 menyediakan layar inventaris dengan pencarian/filter, create/edit, arsip, mutasi stok, riwayat movement, foto barang terkompresi, dan statistik dashboard dari data workspace. Pemilik project mengonfirmasi migration 004 dan tes workflow SQL berhasil. Upload foto memakai Storage bucket `inventory-images` di folder business UUID; hasil galeri dikonversi ke JPEG, dibatasi maksimal 2 MB, dan diunggah setelah kompresi.

## Persiapan konfigurasi

Buat file konfigurasi lokal tanpa menaruh secret key di repo:

```bash
mkdir -p config
cp config/dev.example.json config/dev.json
```

Isi file `config/dev.json` dengan project Supabase Anda:

```json
{
  "SUPABASE_URL": "https://your-project.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "your_publishable_key_here"
}
```

Jalankan:

```bash
flutter run --dart-define-from-file=config/dev.json
```

## Migration dan pemeriksaan

Jalankan berurutan pada project test Supabase:
1. `../supabase/migrations/003_business_workspace_multi_user.sql`
2. `../supabase/migrations/004_inventory_workflow.sql`
3. `../supabase/tests/business_workspace_rls.sql`

Skrip tes mengakhiri fixture dengan `ROLLBACK`. Pemilik project mengonfirmasi tes workflow setelah migration 004 berhasil, termasuk create item atomik, akses Staff, mutasi stok, dan adjustment ke saldo nol.

Pemeriksaan lokal:

```bash
flutter analyze
flutter test
```

## Struktur utama

- `lib/app` - theme, router, app bootstrap
- `lib/core/config` - konfigurasi build-time dan validasi
- `lib/core/providers` - auth state dan provider
- `lib/features/auth` - login flow
- `lib/features/business` - membership, invitation, bootstrap Owner
- `lib/features/inventory` - daftar barang, form detail/foto, mutasi stok, dan riwayat
- `lib/features/dashboard` - statistik agregat workspace

## Catatan keamanan

- Tidak menggunakan `service_role` key.
- Hanya publishable key yang dipakai pada aplikasi Android.
- Semua akses yang sensitif tetap harus dikontrol oleh RLS Supabase.
- Foto baru memakai object path `<business_id>/<random>.jpg`; policy Storage workspace dari migration 003 harus aktif.
- Saat mengganti foto, metadata item disimpan terlebih dahulu; object lama baru dihapus setelah update berhasil.
- Repository website PHP tetap dipertahankan dan tidak dihapus.

## Audit database

Lihat dokumentasi di [../supabase/SCHEMA_AUDIT.md](../supabase/SCHEMA_AUDIT.md) untuk catatan existing schema dan rencana migrasi yang aman.

Migration dan rollback yang disiapkan:
- [Migration workspace](../supabase/migrations/003_business_workspace_multi_user.sql)
- [Rollback logis](../supabase/migrations/003_business_workspace_multi_user_rollback.sql)
- [Tes RLS dua akun](../supabase/tests/business_workspace_rls.sql)
- [Migration inventory workflow](../supabase/migrations/004_inventory_workflow.sql)
- [Rollback logis inventory workflow](../supabase/migrations/004_inventory_workflow_rollback.sql)

Jangan masukkan service-role key ke `config/dev.json` atau build Android. Undangan dicatat lewat RPC dengan sesi user; Owner pertama memerlukan grant satu kali yang hanya disiapkan project admin melalui SQL Editor.
