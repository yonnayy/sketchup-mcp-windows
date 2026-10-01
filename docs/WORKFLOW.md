# Panduan kerja: dari gambar sampai gambar hasil

Panduan ini berlaku untuk setiap proyek, bukan hanya model contoh. Isinya urutan kerja dan dua aturan yang lahir dari kesalahan nyata saat menguji rumah dua lantai (Caroline's Farmhouse):

1. **Tangga dan perabot ditaruh dengan koordinat kira-kira**, tanpa membaca denahnya dulu. Hasilnya tangga menutup pintu kamar mandi dan menembus dinding di bawahnya.
2. **Gambar diekspor, lalu model diubah lagi.** Gambar yang dikirim ke pengguna tidak lagi sama dengan modelnya.

Keduanya sekarang dijaga oleh tool: `check_placement` dan `export_views`.

## Urutan kerja

| # | Langkah | Tool | Selesai kalau |
|---|---|---|---|
| 1 | Baca semua lembar gambar. Catat ukuran, level lantai, posisi tangga, dan arah bukaan pintu | (membaca) | Setiap angka yang dipakai bisa ditunjuk asalnya di gambar |
| 2 | Cek deret ukuran | `check_dimension_chains` | `CHAINS OK`, atau pengguna sudah memutuskan angka mana yang menang |
| 3 | Dinding, bukaan, pelat per lantai | `build_floor_plan` | Tanpa `Warnings` |
| 4 | Bandingkan dengan denah | `verify_dimensions` | `VERIFY OK`, atau selisihnya dijelaskan ke pengguna |
| 5 | Atap, teras, tangga, perabot, tapak | `eval_ruby` dengan `SU_MCP.element` | Tiap elemen bernama, bertag, bermaterial |
| 6 | Cek tangga dan perabot | `check_placement` | `PLACEMENT OK` |
| 7 | Cek aturan model | `SU_MCP.audit_model` | `AUDIT OK` |
| 8 | Buat scene: denah, perspektif, potongan, tampak | `add_plan_view`, `eval_ruby` | Scene ada untuk setiap gambar yang mau ditunjukkan |
| 9 | Simpan model, lalu ekspor semua scene | `export_views` | `VIEWS EXPORTED` |
| 10 | Buka dan lihat **setiap** gambar | (membaca gambar) | Tidak ada yang janggal |
| 11 | Laporkan ke pengguna: akurasi, yang belum sesuai, lokasi gambar | | |

Kalau di langkah 10 ada yang perlu dibetulkan, betulkan modelnya lalu ulangi dari langkah 6. Jangan mengirim gambar dari sebelum perbaikan.

## Aturan 1: jangan menebak koordinat

Sebelum menaruh tangga, perabot, atau apa pun di dalam bangunan:

- Cari lembar gambar yang memuatnya (denah lantai atas untuk tangga, detail tangga, denah perabot) dan baca posisinya dari sana.
- Untuk tangga, catat: jumlah dan tinggi anak tangga (misalnya `14 R @ 7.7"`), titik mulai, arah naik, bordes atau anak tangga putar, dan di mana tangga tiba di lantai atas. Pelat lantai atas harus berlubang di atas tangga.
- Kalau gambar tidak memuat posisinya (perabot sering tidak digambar), tentukan posisi dari dinding, pintu, dan jendela yang **sudah ada di model**, bukan dari ingatan. Baca dulu batas ruangnya, misalnya dengan `verify_dimensions` tanpa `expected`.
- Katakan ke pengguna mana yang dibaca dari gambar dan mana yang ditentukan sendiri.

Lalu jalankan `check_placement`.

### `check_placement`

```json
{ "building": "Caroline", "clearance": 0.6 }
```

Semua elemen bertag `07-Tangga` dan `08-Furnitur` diuji dengan geometri aslinya (bukan kotak pembatas) terhadap pintu dan dinding:

| Tulisan | Artinya |
|---|---|
| `MENGHALANGI PINTU` | Elemen berdiri di ruang bebas depan atau belakang pintu (`clearance` meter dari kusen, default 0,60) |
| `DI AYUNAN PINTU` | Elemen berdiri di area yang disapu daun pintu |
| `MENEMBUS DINDING` | Elemen masuk ke badan dinding lebih dari 1 cm |
| `PERIKSA` | Dua elemen menempati ruang yang sama. Wajar untuk kursi di bawah meja, salah untuk dua kasur. Tidak menggagalkan cek |
| `DITERIMA` | Temuan yang sudah disetujui lewat `accept`. Tidak menggagalkan cek |

Setiap baris menyebut kedua elemen dan titik `[x, y, z]` dalam meter. Jawaban diawali `PLACEMENT OK` atau `PLACEMENT CONFLICT`.

Contoh nyata dari uji Caroline, sebelum diperbaiki:

```
PLACEMENT CONFLICT. 23 elements (tangga, furnitur) checked against 14 doors and 52 walls, door clearance 0.60 m. 3 problem(s):
MENGHALANGI PINTU  Caroline > Tangga is inside the 0.60 m clear passage of Caroline > Lantai 1 > Pintu UW-1 at [6.42, 4.15, 1.76] m
MENEMBUS DINDING   Caroline > Tangga goes into wall Caroline > Lantai 1 > Dinding UW at [5.92, 4.31, 2.35] m
MENEMBUS DINDING   Caroline > Tangga goes into wall Caroline > Lantai 1 > Dinding Bawah Tangga at [6.30, 2.82, 0.78] m
```

Dua temuan terakhir adalah kesalahan model dan diperbaiki. Temuan pertama memang rancangannya: `Pintu UW-1` adalah pintu lemari di bawah tangga, jadi sisi dalamnya tidak butuh ruang bebas. Temuan seperti itu diterima secara tertulis, setelah pengguna setuju:

```json
{ "building": "Caroline", "accept": ["Pintu UW-1"] }
```

Jangan memakai `accept` untuk membungkam temuan yang belum dipahami.

Batasannya:

- Pintu dikenali dari unit bernama `Pintu ...` buatan `build_floor_plan`. Pintu yang digambar sendiri dengan nama lain tidak ikut dicek.
- Dinding miring yang digambar sendiri dengan `eval_ruby` diuji dengan kotak pembatasnya, jadi bisa salah lapor. Dinding buatan `build_floor_plan` tidak bermasalah.
- Yang dicek hanya benturan. Tool ini tidak tahu apakah sofa menghadap ke arah yang masuk akal; itu tetap dilihat di gambar.
- Lewat `eval_ruby`: `SU_MCP.check_placement('building' => 'Caroline')`.

## Aturan 2: gambar diekspor paling akhir, semuanya sekaligus

Ekspor satu per satu dengan `export_scene` di tengah pekerjaan membuat sebagian gambar menunjukkan model lama. Maka:

- Selama bekerja, `export_scene` hanya untuk **memeriksa sendiri**.
- Gambar untuk pengguna selalu dari `export_views`, dijalankan setelah perubahan terakhir.

### `export_views`

```json
{}
```

Tanpa argumen, semua scene diekspor ke folder `<nama model>-gambar` di sebelah file `.skp` (atau ke `%TEMP%\sketchup_exports` kalau model belum pernah disimpan). Argumen yang tersedia: `scenes` (daftar nama scene), `folder`, `width`, `height`.

- Nama file `<nomor scene>-<nama scene>.png`, menimpa ekspor sebelumnya. Folder itu selalu berisi satu set gambar terbaru; gambar scene yang sudah dihapus ikut dibuang.
- Gambar tidak transparan. Scene berproyeksi paralel (denah, tampak) digambar di latar putih tanpa langit dan tanah.
- Jawaban diawali `VIEWS EXPORTED` dan mendaftar semua file.

Sebelum menunjukkan gambar yang diekspor beberapa waktu lalu, tanyakan dulu apakah masih cocok dengan modelnya:

```json
{ "check_only": true }
```

| Jawaban | Artinya |
|---|---|
| `VIEWS CURRENT` | Model tidak berubah sejak ekspor terakhir |
| `VIEWS STALE` | Model sudah berubah. Jalankan `export_views` lagi |
| `VIEWS UNKNOWN` | Belum pernah diekspor di sesi SketchUp ini |

Batasannya: yang dihitung adalah perubahan geometri, material, dan tag (termasuk undo). Mengubah scene saja (kamera, tag yang tampak) tidak terhitung, jadi setelah mengubah scene jalankan `export_views` tanpa menunggu ditanya. Hitungan hilang kalau SketchUp ditutup.

Lewat `eval_ruby`: `SU_MCP.export_views('scenes' => ['Depan'])` dan `SU_MCP.views_status`. Satu panggilan `eval_ruby` dibatasi sekitar 15 detik; tool `export_views` menunggu sampai 5 menit.

## Menyiapkan scene

`export_views` hanya mengekspor scene yang ada. Set yang biasa dipakai:

| Scene | Kamera | Catatan |
|---|---|---|
| `Denah Lantai N` | `add_plan_view` | Sudah berdimensi, tapak dan bayangan disembunyikan |
| `Depan`, `Belakang` | Perspektif, setinggi mata burung | Bayangan menyala |
| `Potongan Lantai N` | Perspektif dari atas, dengan section plane mendatar sedikit di bawah plafon lantai itu | Memperlihatkan interior |
| `Tampak Selatan`, dst. | Paralel, tegak lurus fasad | Sembunyikan tag `09-Tapak` supaya pohon tidak menutupi fasad |

```ruby
model = Sketchup.active_model
model.options['PageOptions']['ShowTransition'] = false
model.entities.active_section_plane = nil
model.active_view.camera = Sketchup::Camera.new([-8.m, -12.m, 5.m], [3.m, 1.5.m, 2.5.m], [0, 0, 1], true, 38)
page = model.pages['Depan'] || model.pages.add('Depan')
model.layers.each { |l| page.set_visibility(l, false) if l.name.start_with?('10-Anotasi') }
page.update
```

Yang perlu diketahui tentang scene di SketchUp:

- **Langit, tanah, dan warna latar adalah milik style**, dan semua scene memakai style yang sama. Mengubah `rendering_options` lalu `page.update` tidak menyimpannya untuk scene itu saja. Atur sekali untuk seluruh model, lalu simpan ke style:

  ```ruby
  ro = model.rendering_options
  ro['DrawHorizon'] = true
  ro['DrawGround'] = true
  ro['GroundTransparency'] = 100
  ro['GroundColor'] = Sketchup::Color.new(120, 150, 90)
  ro['SkyColor'] = Sketchup::Color.new(170, 205, 235)
  model.styles.update_selected_style
  ```

- Section plane aktif, tag yang tampak, dan bayangan **tersimpan per scene**.
- Setiap scene baru harus menyembunyikan tag `10-Anotasi ...` milik denah, seperti di contoh di atas.

## Yang dilaporkan ke pengguna

- Laporan `verify_dimensions`: berapa ukuran yang cocok, mana yang selisih dan sebabnya.
- Hasil `check_placement`, termasuk temuan yang diterima dan alasannya.
- Apa yang dibaca dari gambar dan apa yang ditentukan sendiri.
- Apa yang belum sesuai gambar acuan. Sebutkan terus terang; jangan menunggu ditanya.
- Folder gambar dari `export_views`.
