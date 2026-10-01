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

- **`build_floor_plan`**: denah dalam meter menjadi dinding solid dengan bukaan, daun pintu, kaca jendela, dan pelat lantai, dalam satu langkah undo. Tidak butuh Solid Tools, jadi jalan di semua edisi SketchUp.
- **Aturan dasar model** ([docs/STANDARDS.md](docs/STANDARDS.md)): tag baku bernomor, material bernama `Elemen - Bahan` yang dipasang di grup, geometri mentah Untagged, susunan bangunan > lantai > elemen. `build_floor_plan` mengikutinya dengan sendirinya; untuk `eval_ruby` ada helper `SU_MCP.container`, `SU_MCP.element`, `SU_MCP.tag`, `SU_MCP.material`.
- **`SU_MCP.audit_model`**: memeriksa seluruh model terhadap aturan itu dan menyebut tiap pelanggaran.
- **Acuan ukuran dinding** (`ref`): garis dinding bisa berarti garis as, muka kiri, atau muka kanan, sehingga denah yang diberi ukuran luar atau ukuran bersih ruang bisa dimasukkan apa adanya. Ujung dinding dipanjangkan atau dipotong otomatis di setiap sudut dan pertemuan T, tanpa tumpang-tindih.
- **`check_dimension_chains`**: sebelum memodelkan, memeriksa apakah deret ukuran di denah cocok dengan ukuran totalnya.
- **`verify_dimensions`**: sesudah memodelkan, mengukur model yang sudah jadi (ukuran luar dan ukuran bersih ruang, dengan sinar ukur di beberapa ketinggian supaya bukaan pintu tidak mengacaukan hasil) dan membandingkannya dengan denah.
- **Pintu dan jendela dengan kusen**: tiap bukaan menjadi satu unit berisi kusen 6/12, daun (pintu panel atau polos; jendela berangka dengan kaca, satu sampai beberapa daun, atau jendela mati), semuanya solid dan dibuat tanpa plugin lain. Ukuran kusen, model daun, dan jumlah daun bisa diatur per bukaan.
- **Arah bukaan pintu**: `hinge` dan `swing` pada bukaan pintu. Daun pintu digambar terbuka di engselnya, dengan busur ayun di lantai seperti di gambar denah.
- **`add_plan_view`**: tampak denah berdimensi sebagai scene (tampak atas, proyeksi paralel, potongan 1,2 m), berisi ukuran luar, ukuran bersih tiap ruang yang dibaca dari model, dan nama ruang, di tag tersendiri per denah (`10-Anotasi <nama scene>`). Gambar dibingkai pada bangunan yang diminta. Scene `3D` dibuat untuk kembali.
- **Perbaikan dari uji rumah dua lantai**: sinar ukur `verify_dimensions` dan `add_plan_view` berhenti di 2,3 m supaya tidak mengukur dinding lantai di atasnya; scene denah mematikan bayangan dan menyembunyikan tapak; `export_scene` menunggu sampai 120 detik karena model besar dengan bayangan butuh lebih dari 15 detik untuk dirender; dan server di SketchUp sekarang membuang klien yang putus dengan error soket apa pun (dulu klien yang menyerah menunggu membuat semua klien berikutnya tidak terlayani).
- **Atap dan detail jadi tool** ([docs/DETAIL.md](docs/DETAIL.md)), supaya tidak lagi ditulis tangan lewat `eval_ruby`: `build_roof` (pelana, perisai, sandar dengan sudut jurai untuk teras keliling, datar; garis rusuk seng; ampig; lisplang), `add_siding` (papan susun atau bilah tegak hanya di muka luar dinding, yang dicari sendiri, plus papan sudut), `add_window_trim` (lis atas, lis bawah, shutter berkisi), `add_posts` (tiang bubut, persegi, bulat), `build_stairs` (lurus, putar, bordes, dengan pemeriksaan jumlah injakan), `place_furniture` (13 jenis perabot dan saniter, langsung dicek dengan `check_placement`).
- **`check_placement`**: menguji tangga dan perabot (geometri aslinya, bukan kotak pembatas) terhadap ruang bebas pintu, ayunan daun pintu, dan badan dinding, lalu menyebut tiap benturan beserta titiknya. Dibuat setelah tangga yang ditaruh dengan koordinat kira-kira menutup pintu dan menembus dinding.
- **`export_views`**: mengekspor semua scene ke satu folder dalam satu langkah (nama file tetap, tidak transparan, denah dan tampak di latar putih), dan dengan `check_only` melaporkan apakah gambar terakhir masih cocok dengan model (`VIEWS CURRENT` / `VIEWS STALE`). Dibuat setelah sebuah gambar terkirim dari sebelum perubahan terakhir.
- **[docs/WORKFLOW.md](docs/WORKFLOW.md)**: panduan kerja untuk setiap proyek, dari membaca gambar sampai gambar hasil.
- **Server menyala otomatis** saat SketchUp dibuka (bisa dimatikan di **Extensions > MCP Server > Auto-start on Launch**), plus menu **Status**.
- **`install.ps1` dan `check.ps1`** untuk Windows: pasang dan periksa dengan satu perintah.
- Deskripsi tool ditulis ulang supaya model AI tahu soal satuan inci, arah `pushpull` di z = 0, dan geseran relatif.

## Yang dibuang

`create_mortise_tenon`, `create_dovetail`, dan `create_finger_joint` tidak lagi ditawarkan sebagai tool. Ketiganya tidak pernah berfungsi (memanggil `entities.subtract` yang tidak ada di API SketchUp) dan meninggalkan grup sampah di model setiap kali gagal.

## Yang belum diperbaiki

`transform_component` masih menggeser secara relatif, dan `create_component` masih memakai inci. Perilaku itu dipertahankan supaya kompatibel dengan versi asli; deskripsi tool-nya sudah menjelaskannya.

## Pengujian

- `tests/mock_roundtrip.py`: tanpa SketchUp. Cek rantai dimensi (satu cocok, satu bentrok), lalu sepuluh panggilan berturut-turut yang setiap jawabannya harus cocok dengan permintaannya.
- `tests/live_detail.py`: dengan SketchUp terbuka. Membangun rumah 8 x 6 m dengan atap pelana dan ampig, teras bertiang dengan atap sandar, papan dinding dan papan sudut, lis dan shutter jendela, tangga dengan belokan putar, dan perabot; memeriksa tinggi bubungan, bahwa dinding dalam tidak dipapani, bahwa menjalankan ulang tidak menggandakan apa pun, bahwa jumlah injakan yang salah diperingatkan, bahwa perabot di depan pintu tertangkap, dan bahwa atap, tiang, tangga, dan papan sudut adalah solid tertutup.
- `tests/live_floor_plan.py`: dengan SketchUp terbuka. Membangun rumah dua ruang (5 dinding, 2 pintu, 4 jendela, 1 pelat; 35 elemen solid setelah atap) dengan dinding luar beracuan muka luar, memeriksa bahwa ukuran luar persis 7 x 5 m dan ukuran bersih kedua ruang cocok, memastikan ukuran yang sengaja salah tertangkap, menambah atap, memeriksa bahwa semua elemen solid dan audit lolos, memastikan audit menangkap pelanggaran yang sengaja dibuat, memeriksa isi tiap unit pintu dan jendela, posisi daun pintu yang terbuka, dan bahwa kayu jendela tidak ikut transparan, membuat tampak denah berdimensi dan memeriksa scene-nya, mengekspor PNG, lalu menghapus semua yang dibuatnya.

Diuji di Windows 10, SketchUp 2025 (25.0.660), Python 3.10 dan 3.12, `mcp` 1.30.0.
