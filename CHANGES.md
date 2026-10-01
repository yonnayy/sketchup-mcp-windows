# Perubahan dari versi asli

Dasar: [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp) pada commit `aa096f0`. Riwayat commit aslinya dipertahankan di repo ini.

## Perbaikan bug

| Masalah di versi asli | Perbaikan |
|---|---|
| **SketchUp membeku.** Extension memanggil `client.gets` di thread utama SketchUp. Server Python membuka koneksi lalu mendiamkannya, jadi `gets` menunggu selamanya | Loop server ditulis ulang: banyak klien, tanpa blocking (`accept_nonblock`, `IO.select` dengan timeout 0, `read_nonblock`), koneksi dipertahankan antar permintaan |
| **Jawaban bergeser satu.** Server Python mengirim `ping` sebelum tiap permintaan dan tidak pernah membaca balasannya, sehingga balasan itu terbaca sebagai jawaban permintaan berikutnya | Python tidak lagi mengirim ping; keaktifan soket dicek lewat `SO_ERROR` dan `MSG_PEEK`. Extension juga mengabaikan `ping` |
| **Server Python gagal start.** Dependensi `mcp[cli]>=1.3.0` tanpa batas atas menarik `mcp` 2.x yang tidak kompatibel | Dikunci ke `mcp[cli]==1.30.0` (versi yang diuji) |
| `export_scene` tidak mengembalikan lokasi file | Path lengkap dikembalikan di `content[0].text` |
| Ruby Console muncul paksa setiap SketchUp dibuka | Dihapus. Log tetap ditulis ke console kalau dibuka manual |

## Fitur baru

- **`build_floor_plan`**: denah dalam meter menjadi dinding solid dengan bukaan pintu/jendela dan pelat lantai, dalam satu langkah undo. Tidak butuh Solid Tools, jadi jalan di semua edisi SketchUp.
- **Server menyala otomatis** saat SketchUp dibuka (bisa dimatikan di **Extensions > MCP Server > Auto-start on Launch**), plus menu **Status**.
- **`install.ps1` dan `check.ps1`** untuk Windows: pasang dan periksa dengan satu perintah.
- Deskripsi tool ditulis ulang supaya model AI tahu soal satuan inci, arah `pushpull` di z = 0, dan geseran relatif.

## Yang dibuang

`create_mortise_tenon`, `create_dovetail`, dan `create_finger_joint` tidak lagi ditawarkan sebagai tool. Ketiganya tidak pernah berfungsi (memanggil `entities.subtract` yang tidak ada di API SketchUp) dan meninggalkan grup sampah di model setiap kali gagal.

## Yang belum diperbaiki

`transform_component` masih menggeser secara relatif, dan `create_component` masih memakai inci. Perilaku itu dipertahankan supaya kompatibel dengan versi asli; deskripsi tool-nya sudah menjelaskannya.

## Pengujian

- `tests/mock_roundtrip.py`: tanpa SketchUp. Sepuluh panggilan berturut-turut, setiap jawaban harus cocok dengan permintaannya.
- `tests/live_floor_plan.py`: dengan SketchUp terbuka. Membangun rumah dua ruang (5 dinding, 6 bukaan, 1 pelat), memeriksa bahwa semua grup solid, lalu mengekspor PNG.

Diuji di Windows 10, SketchUp 2025 (25.0.660), Python 3.10 dan 3.12, `mcp` 1.30.0.
