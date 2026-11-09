# Audit schema existing dan rencana migrasi

Tanggal audit: 2026-11-09

## Ringkasan repository

- Website PHP dan API Supabase saat ini berada di root repository.
- Fondasi Flutter berada di folder `flutter_application_ayu/`, menggunakan Supabase Auth dan publishable key melalui konfigurasi build-time.
- `flutter analyze` dan widget test lulus; login belum diverifikasi secara langsung terhadap project Supabase atau perangkat Android.
- Tidak ada perubahan schema database yang dilakukan oleh script migrasi otomatis dalam repository ini.
- Data existing harus dipertahankan dan tidak boleh dihapus atau diubah secara destruktif.

## Tabel dan fungsi yang sudah ada

### `public.inventory_items`

Kolom utama:
- `id`
- `user_id`
- `category`
- `name`
- `variant`
- `color`
- `sku`
- `unit`
- `stock_qty`
- `min_stock`
- `purchase_price`
- `stem_price`
- `selling_price`
- `description`
- `image_url`
- `image_path`
- `is_active`
- `archived_at`
- `archived_by`
- `created_at`
- `updated_at`

Kategorinya masih mencakup:
- `hijab`
- `flower`
- `tool`
- `packaging`
- `finished_product`

### `public.stock_movements`

Kolom utama:
- `id`
- `user_id`
- `item_id`
- `movement_type`
- `quantity`
- `stock_before`
- `stock_after`
- `note`
- `created_at`

Jenis movement yang saat ini valid:
- `OPENING`
- `IN`
- `OUT`
- `ADJUSTMENT`

### Fungsi SQL

- `public.set_updated_at()`
- `public.register_stock_movement(p_item_id, p_movement_type, p_quantity, p_note)`
- `public.archive_item(p_item_id)`

### Security model

- Sebelum migration 003, RLS membatasi inventory dan movement berdasarkan `user_id = auth.uid()`.
- Setelah migration 003, akses inventory dan movement memakai membership workspace; write stok dilakukan melalui RPC yang memvalidasi membership.
- Storage menerima folder lama berbasis user UUID dan folder baru berbasis business UUID, dengan akses anggota melalui membership.

## Catatan migration yang aman

1. Jangan menjalankan SQL destruktif atau `drop table`.
2. Jangan menonaktifkan RLS.
3. Sebelum migration 003, RLS membatasi `inventory_items` dan `stock_movements` berdasarkan `user_id = auth.uid()`.
4. Gunakan migration baru di `supabase/migrations/` untuk menambahkan model workspace multi-user; jangan mengganti policy owner-only sebelum membership dan data backfill siap.
5. Backfill data lama harus dilakukan bertahap setelah pemilik bisnis dan akun anggota dikonfirmasi.
6. Item lama harus dipetakan ke business dan unit yang tepat sebelum aplikasi mengandalkan akses berbasis membership.

## Fase 2: workspace multi-user

Migration berada di [migrations/003_business_workspace_multi_user.sql](migrations/003_business_workspace_multi_user.sql). Pemetaan yang disepakati adalah satu workspace `AYU BUSINESS` dengan unit `YM THREAD` dan `Arum Gift Buket`. Pemilik melaporkan migration dan skenario RLS dua akun berhasil dijalankan.

Dampak pada data:
- Tidak ada row atau tabel existing yang dihapus.
- ID, stok, harga, metadata, dan riwayat movement dipertahankan.
- `inventory_items` mendapatkan `business_id`, `business_unit_id`, dan `created_by`; `stock_movements` mendapatkan `business_id`, `actor_user_id`, dan `created_by`.
- Seluruh row lama dipetakan ke AYU dan unit `Umum / Belum dipetakan`; klasifikasi ke dua unit bisnis dilakukan Owner setelah ditinjau.
- Semua akun yang muncul sebagai pemilik row lama menjadi anggota aktif `STAFF`. Owner pertama dipilih melalui grant bootstrap satu kali.
- Akses Storage untuk folder berbasis UUID user tetap berlaku; folder baru berbasis UUID business dapat dikelola semua anggota workspace. Bucket public tetap public seperti konfigurasi lama.

### Bootstrap Owner pertama

Migration membuat tabel grant pada schema `private`, yang tidak dapat dibaca/ditulis client authenticated. Setelah migration ditinjau dan dijalankan, project admin memberi grant satu kali kepada user ID Auth yang sudah diverifikasi melalui SQL Editor:

```sql
insert into private.business_bootstrap_grants (user_id, business_id, business_name)
select
	'GANTI_DENGAN_AUTH_USER_UUID'::uuid,
	business.id,
	'AYU BUSINESS'
from public.businesses business
where business.slug = 'ayu'
on conflict (user_id) do update
set business_id = excluded.business_id,
	business_name = excluded.business_name,
	consumed_at = null;
```

User tersebut login lalu memilih `Aktifkan workspace Owner` di halaman Anggota Bisnis. Fungsi `bootstrap_ayu_owner()` hanya berhasil untuk grant aktif itu, mengunci grant, menolak bila workspace sudah punya Owner, lalu mengonsumsi grant. Tidak ada service-role key atau bootstrap secret di aplikasi.

### Invitation dan role

Owner membuat undangan Staff dari halaman Anggota Bisnis. RPC menyimpan undangan berdasarkan email; Supabase Auth admin API dan service-role key tidak digunakan. Aplikasi tidak mengirim email otomatis: penerima harus mendaftar atau login dengan email yang diundang, kemudian menerima undangan di halaman yang sama. Setelah aktif, Owner dapat mengubah role atau mencabut membership. Perubahan langsung ke tabel membership tidak diberi privilege; Staff tidak dapat mengubah role Owner.

### Pengujian dan rollback

- Skenario dua akun awal di [tests/business_workspace_rls.sql](tests/business_workspace_rls.sql) dilaporkan lulus oleh pemilik project.
- Pemilik project mengonfirmasi migration 004 dan tes workflow terbaru berhasil, termasuk RPC pembuatan item serta adjustment saldo nol.
- Rollback logis tersedia di [migrations/003_business_workspace_multi_user_rollback.sql](migrations/003_business_workspace_multi_user_rollback.sql). Ia mengembalikan policy owner-only dan Storage UID-folder tanpa menghapus tabel, kolom, membership, atau data bisnis. Setelah rollback, akses inventory kembali terpisah per user.
- Tabel transaksi baru wajib memiliki `business_id` foreign key, `created_by` untuk pencipta record, dan `actor_user_id` untuk tindakan pengguna; RLS harus menggunakan `is_business_member(business_id)` dan tidak boleh menerima `business_id` tanpa pemeriksaan membership.
- Jalankan migration saat trafik website/app ke `inventory_items` dan `stock_movements` dihentikan sementara. DDL mengubah kedua tabel tersebut dalam satu transaksi; request gabungan atau RPC stok yang sedang berjalan dapat memegang lock dalam urutan berbeda dan menyebabkan deadlock. Migration menetapkan `lock_timeout` 500 ms agar konflik lock gagal cepat dan transaksinya dapat diulang saat sepi.

## Fase 3: alur inventory

Migration additive [migrations/004_inventory_workflow.sql](migrations/004_inventory_workflow.sql) menambahkan `create_inventory_item()`. RPC memeriksa membership dan unit bisnis, lalu membuat item dan saldo awal dalam satu transaksi melalui `register_stock_movement()`. Migration juga membolehkan adjustment ke saldo akhir nol, sementara IN/OUT/OPENING tetap harus positif.

Migration 004 menghapus FK satu kolom yang redundant pada unit/item; composite FK workspace tetap menegakkan integritas dan menghindari relasi PostgREST ganda.

- Jalankan migration 004 setelah 003.
- Layar Flutter memakai RPC create item, query inventory berdasarkan `business_id`, filter unit/kategori, edit detail, arsip, dan RPC stok masuk/keluar/adjustment.
- Form barang memilih foto dari galeri, mengompresnya menjadi JPEG (maksimum output 2 MB), lalu mengunggah ke bucket `inventory-images` dengan path `<business_id>/<random>.jpg`. Upload memakai sesi user; tidak menggunakan service-role key. Object lama hanya dihapus setelah metadata baru berhasil disimpan.
- Untuk rollback logis, [migrations/004_inventory_workflow_rollback.sql](migrations/004_inventory_workflow_rollback.sql) mencabut akses create RPC. Fungsi movement dan constraint adjustment nol dipertahankan agar data adjustment nol yang mungkin sudah tercatat tidak membuat rollback merusak data.
- Tes gabungan [tests/business_workspace_rls.sql](tests/business_workspace_rls.sql) kini memerlukan migration 003 dan 004, dan harus dijalankan ulang sebelum mengklaim workflow terbaru teruji live.

## Status saat ini

- Audit awal berdasarkan schema/migration di repository; koneksi langsung untuk introspeksi schema live tidak tersedia.
- Migration 003, migration 004, dan tes workflow dua akun dilaporkan berhasil oleh pemilik project.
- Dashboard, riwayat, dan upload Storage masih memerlukan pengujian manual di perangkat Android dengan konfigurasi Supabase live.
- API PHP lama masih memfilter beberapa daftar berdasarkan `user_id`; pembagian data lintas akun pada web belum diverifikasi atau diubah.
