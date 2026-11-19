# Syncfony

**Syncfony** adalah aplikasi backup media (foto, video, dan Live Photo) berbasis jaringan lokal yang ringan untuk iOS dan Android—terinspirasi dari Immich, namun tanpa beban pemrosesan AI/ML sehingga cocok dijalankan di perangkat kecil seperti Raspberry Pi atau mini PC dengan RAM terbatas.

---

## Fitur Utama

- **Antarmuka Liquid Glass (iOS):** Permukaan utama memakai efek kaca (blur + tint + garis specular), header kaca penuh berisi logo & status, navigasi kapsul mengambang, dan transisi halaman ala iOS.
- **Logo Ikut Warna Aksen:** Logo di-tint otomatis dengan `BlendMode.color` sehingga hue-nya mengikuti aksen aktif tanpa kehilangan detail line art (ikon peluncur OS tetap statis).
- **Multi-bahasa Berbasis File:** Semua teks UI dibaca dari `assets/i18n/<kode>.json`; menambah bahasa baru cukup dengan menambah satu file JSON + satu entri di `index.json` (tanpa mengubah kode Dart).
- **Tampilan yang Bisa Diatur:** Warna aksen (8 pilihan: hijau, biru, teal, ungu, pink, oranye, merah, grafit), intensitas blur kaca 0–200% (0% mematikan blur untuk menghemat GPU), dan jumlah kolom galeri 2–8 — bisa lewat **Settings** maupun **cubit dua jari** langsung di galeri (dengan indikator kolom sementara).
- **Pencarian & Filter:** Cari media berdasarkan nama file dan filter jenis (semua/foto/video) langsung dari server, sehingga tetap efisien untuk library besar. Tombol filter ada di tab Media dengan penanda filter aktif.
- **Kunci Aplikasi:** Opsional di Settings — meminta biometrik/PIN perangkat (Face ID/Touch ID/fingerprint) saat aplikasi dibuka atau kembali dari latar belakang. Kunci menutupi seluruh UI termasuk viewer.
- **Empat Tab Navigasi:** **Media** (galeri server), **Lokal** (foto/video di perangkat), **Backup** (status & antrean), dan **Settings**.
- **Backup Background:** Tugas periodik (WorkManager) berjalan ±30 menit sekali, termasuk saat aplikasi ditutup, dengan batas 200 item per siklus. Di Android tugas dijalankan sebagai **foreground service** (`dataSync`) beserta notifikasi agar tidak dibunuh OS. Dapat diaktifkan di Settings.
- **Backup & Antrean Otomatis:** Memindai galeri perangkat menggunakan `photo_manager` (hingga 5000 aset per pemindaian) dan mengunggah foto/video secara bertahap dengan kontrol **Play / Pause**, retry otomatis (3 percobaan), serta indikator progress.
- **Backup Selektif:** Tab **Lokal** menampilkan seluruh foto/video perangkat dengan penanda cloud untuk yang sudah ada di server; tekan lama untuk memilih beberapa item lalu unggah sekaligus.
- **Status Backup Terverifikasi Server:** Indeks lokal menyimpan pasangan `assetId → SHA-256` dan dicocokkan ulang dengan daftar hash server setiap kali tab dibuka. Jika database/file di server dihapus langsung, hitungan backup otomatis kembali ke 0.
- **Deduplikasi SHA-256 Berbasis Hash:** Sebelum upload, client menghitung SHA-256 (streaming, hemat memori) dan mencocokkannya dengan indeks hash server, sehingga file yang sudah ada tidak diunggah ulang meskipun cache lokal hilang atau aplikasi dipasang ulang.
- **Perawatan Data:** Saat server start, file sementara (`.tmp`) sisa crash dibersihkan. Menu **Periksa File Yatim** di aplikasi menjalankan rekonsiliasi disk vs database (dry-run dulu, lalu opsi hapus).
- **Upload Streaming di Server:** File multipart ditulis bertahap ke disk sambil dihitung hash-nya, sehingga video besar tidak menahan seluruh isi di RAM.
- **Dukungan Format Luas:** Mendukung gambar standar (JPEG, PNG, WebP, GIF), **HEIC/HEIF**, video (MP4, MOV, MKV, WebM), serta **Live Photo** (foto + klip `.mov` pendamping).
- **Thumbnail Otomatis:** Pembuatan thumbnail gambar dan frame video otomatis di server menggunakan `image`, `heif-rs`, dan `ffmpeg`.
- **Galeri & Media Viewer:**
  - Thumbnail di-cache di memori + disk, sehingga galeri server tetap tampil saat perangkat **offline** untuk item yang sudah pernah dimuat. Aksi **Unduh Thumbnail untuk Offline** menyiapkan seluruh galeri sekaligus.
  - Tombol **Unduh** di viewer menyimpan file asli ke folder `Syncfony` di perangkat.
  - Gambar dibuka dalam resolusi asli (fallback ke thumbnail tersimpan saat offline); video di-stream langsung dari server.
  - Pengelompokan media berdasarkan tanggal (`Today`, `Yesterday`, `dd/MM/yyyy`) dengan **pagination / infinite scroll**.
  - **Swipe antar media:** geser kiri/kanan di viewer untuk berpindah ke foto/video berikutnya (video otomatis di-pause saat berpindah).
  - **Video Player** terintegrasi dengan dukungan streaming HTTP `Range` (`206 Partial Content`), seekbar, dan mute.
  - **Live Photo Player** (tap tombol `LIVE` atau tekan lama pada foto untuk memutar klip).
  - **Sheet Info ala iPhone Gallery** (tap `ⓘ` atau swipe ke atas) menampilkan tanggal, badge format (`HEIC`/`MP4`/`LIVE`/`4K`), dimensi & megapixel, **perangkat & kamera hasil EXIF** (mis. `Apple iPhone 12`, lensa, focal length, aperture, ISO, shutter speed, software), ukuran file, MIME type, dan SHA-256.
  - Hapus media permanen dari server (file dihapus lebih dahulu, baru metadata).
- **Keamanan:** Autentikasi token statis opsional (`SYNCFONY_TOKEN`), CORS nonaktif secara default dan dapat dikonfigurasi, serta batas ukuran upload yang dapat diatur.

---

## Arsitektur & Teknologi

```text
Syncfony/
├── server/   # Backend Rust (Axum + SurrealDB embedded RocksDB)
└── client/   # Aplikasi Mobile Flutter (Android & iOS)
```

- **Server (`server/`):** Rust, `axum`, `tokio`, `tower-http`, `surrealdb` (`kv-rocksdb`), `image`, `heif-rs`, `ffmpeg-sidecar`, `kamadak-exif`, `sha2`.
- **Client (`client/`):** Flutter, `photo_manager`, `video_player`, `workmanager`, `http`, `mime`, `crypto`, `shared_preferences`.

---

## Menjalankan Server

### Prasyarat
- Rust toolchain (`cargo`)
- `libheif` (dibutuhkan oleh `heif-rs`)
- `ffmpeg` / `ffprobe` (diunduh otomatis oleh `ffmpeg-sidecar` saat startup jika belum tersedia)

### Konfigurasi Environment Variable (Opsional)

| Variabel | Default | Keterangan |
|---|---|---|
| `SERVER_BIND_URL` | `0.0.0.0:2026` | Alamat dan port server |
| `STORAGE_PATH` | `./data/storages` | Direktori penyimpanan file media & thumbnail |
| `DATABASE_PATH` | `./data/dblock` | Direktori database SurrealDB (RocksDB) |
| `SYNCFONY_TOKEN` | *(kosong)* | Jika diisi, seluruh endpoint `/api/*` (kecuali `/api/health`) mewajibkan token |
| `MAX_UPLOAD_MB` | `2048` | Batas maksimum ukuran satu request upload (dalam MB) |
| `CORS_ALLOWED_ORIGINS` | *(kosong)* | Nonaktif jika kosong. Isi `*` untuk permisif, atau daftar origin dipisah koma |

### Menjalankan
```bash
cd server
cargo run --release
```

---

## Menjalankan Client (Flutter)

### Prasyarat
- Flutter SDK (`>= 3.x`, Dart SDK `^3.13.7`)
- Emulator/Simulator atau perangkat fisik Android/iOS di jaringan lokal yang sama dengan server

### Menjalankan
```bash
cd client
flutter pub get
flutter run
```

Pada layar awal aplikasi, masukkan URL server lokal (contoh: `http://192.168.1.10:2026`) dan API Token jika `SYNCFONY_TOKEN` diaktifkan di server.

### Konfigurasi Background Backup (Native)

Aktifkan lewat **Settings → Backup Otomatis (Background)**. Agar berjalan saat aplikasi ditutup:

- **iOS** (`ios/Runner/Info.plist`): sudah memuat `BGTaskSchedulerPermittedIdentifiers` (`id.rikyripaldo.syncfony.backup`) dan `UIBackgroundModes` (`fetch`, `processing`). `AppDelegate.swift` mendaftarkan plugin lewat `WorkmanagerPlugin.setPluginRegistrantCallback`.
- **Android**: tidak perlu perubahan manifest; WorkManager didaftarkan otomatis oleh plugin (butuh `minSdk >= 23`, default Flutter sudah 24).
- **Batasan:** penjadwalan sepenuhnya ditentukan OS (iOS sangat konservatif, dan pada simulator background task tidak dijalankan). Backup manual di aplikasi tetap menjadi jalur utama.

---

### Menambah Bahasa Baru (Berbasis File)

Semua teks antarmuka berada di `client/assets/i18n/`.

```text
client/assets/i18n/
├── index.json   # daftar bahasa + kode default
├── id.json      # Bahasa Indonesia (kamus default)
└── en.json      # English
```

**Langkah menambah bahasa (contoh: Jepang):**

1. Salin `assets/i18n/en.json` menjadi `assets/i18n/ja.json`.
2. Terjemahkan nilai (bagian kanan `:`) — **jangan ubah kuncinya**.
3. Daftarkan di `assets/i18n/index.json`:

```json
{
  "default": "id",
  "languages": [
    { "code": "id", "name": "Bahasa Indonesia", "flag": "🇮🇩" },
    { "code": "en", "name": "English", "flag": "🇬🇧" },
    { "code": "ja", "name": "日本語", "flag": "🇯🇵" }
  ]
}
```

4. Jalankan ulang aplikasi (`flutter run` / rebuild). Bahasa baru otomatis muncul di **Settings → Tampilan → Bahasa**.

**Aturan kamus:**

| Hal | Perilaku |
|---|---|
| Kunci hilang di bahasa aktif | Jatuh ke kamus default (`id.json`) |
| Kunci hilang di keduanya | Yang tampil adalah nama kuncinya (mis. `media.loadMore`) |
| Placeholder | `"header.uploading": "Mengunggah {done} dari {total}"` — diisi otomatis |
| Daftar tanggal | `date.months` / `date.days`, dipisah koma (harus 12 & 7 item) |
| File rusak / tidak ada | Aplikasi tetap jalan memakai kamus default |

Urutan pencarian saat runtime: **bahasa aktif → bahasa default → key**. Karena itu Anda bisa menerjemahkan bertahap tanpa membuat aplikasi error.

> Catatan: aset ikut dibundel saat build, jadi menambah bahasa memerlukan rebuild aplikasi. Kalau nanti ingin impor bahasa saat runtime (tanpa rebuild), bisa ditambahkan pembacaan JSON dari folder dokumen aplikasi.

### Konfigurasi Native (Kunci Aplikasi)

`local_auth` memerlukan:

- **Android:** `MainActivity` turunan `FlutterFragmentActivity` (sudah diterapkan) + `MainActivity` tidak memakai `FlutterActivity` biasa.
- **iOS:** kunci `NSFaceIDUsageDescription` di `Info.plist` (sudah ditambahkan).

Jika perangkat tidak memiliki biometrik, aplikasi memakai PIN/pola/kata sandi perangkat (`biometricOnly: false`).

---

### Aset Ikon

Ikon platform sudah dipindahkan ke lokasi standar masing-masing:

| Sumber lama | Lokasi sekarang |
|---|---|
| `icons/android/res/**` | `client/android/app/src/main/res/` (termasuk `mipmap-anydpi-v26/ic_launcher.xml`) |
| `icons/ios/**` | `client/ios/Runner/Assets.xcassets/AppIcon.appiconset/` |
| `icons/macos/AppIcon*.png` | `client/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png` |
| `icons/web/**` | `client/web/` dan `client/web/icons/` |
| Ikon toko & `.icns` | `client/store/` (tidak dibundel ke aplikasi) |

Untuk mengganti ikon launcher nanti, cukup timpa file dengan nama yang sama di lokasi di atas.

---

## Pengujian & CI

```bash
# Server: unit + integration test (upload, dedup, list, delete, auth)
cd server && cargo test

# Client: unit test helper + smoke test layar pembuka
cd client && flutter test
```

CI berjalan otomatis lewat GitHub Actions (`.github/workflows/ci.yml`):

| Job | Langkah |
|---|---|
| Server (Rust) | `cargo check --all-targets` lalu `cargo test` (Ubuntu + `libheif-dev`, `clang`, `ffmpeg`) |
| Client (Flutter) | `flutter pub get`, `flutter analyze`, `flutter test` |

> Catatan: crate `heif-rs` mengunduh bundle libheif saat build pertama, jadi build server butuh akses jaringan sekali.

---

## Tentang

- **Nama:** Syncfony
- **Versi:** 1.0.0
- **Kode sumber:** <https://github.com/Kynonim/Syncfony>

Informasi ini juga tampil di aplikasi pada **Settings → Tentang**, lengkap dengan tombol untuk membuka repositori GitHub.

---

## API Endpoints

Jika `SYNCFONY_TOKEN` diaktifkan, sertakan header `Authorization: Bearer <token>` untuk semua endpoint tulis. Token lewat query parameter (`?token=`) hanya diterima pada request `GET` agar pemutar media tetap bisa memuat file.

| Method | Endpoint | Keterangan |
|---|---|---|
| `GET` | `/api/health` | Cek status server |
| `GET` | `/api/stats` | Statistik jumlah aset, ukuran asli, dan ukuran thumbnail |
| `GET` | `/api/assets?limit=&offset=` | Daftar media terbaru (default 100, maks. 500) + `has_more` dan `total`. Mendukung `q=` (cari nama file) dan `kind=image|video` |
| `GET` | `/api/assets/hashes` | Seluruh hash SHA-256 yang ada di server (untuk cek deduplikasi di client) |
| `POST` | `/api/assets/check` | Cek daftar hash SHA-256 yang sudah ada di server |
| `POST` | `/api/assets/backfill` | Baca ulang EXIF/tag video untuk media lama yang belum punya info kamera |
| `POST` | `/api/maintenance/reconcile?dry_run=true` | Deteksi file yatim di disk; `dry_run=false` menghapusnya |
| `POST` | `/api/upload` | Upload multipart (`file`, opsional `live_file`, `timestamp`, `device_id`) |
| `GET` | `/api/assets/:id/thumb` | Mengambil thumbnail JPEG |
| `GET` | `/api/assets/:id/file` | Mengambil/streaming file asli (mendukung HTTP `Range`) |
| `GET` | `/api/assets/:id/live` | Mengambil/streaming klip video Live Photo |
| `DELETE` | `/api/assets/:id` | Menghapus metadata dan file media dari server |
