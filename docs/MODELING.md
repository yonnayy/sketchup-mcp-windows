# Memodelkan dari denah ke 3D

Panduan untuk Claude saat diminta membuat model SketchUp dari denah.

## Alur kerja

1. **Baca denahnya** (gambar, PDF, atau deskripsi). Tentukan titik asal `[0, 0]`, biasanya sudut kiri bawah bangunan, dengan sumbu x ke kanan dan y ke atas pada denah.
2. **Tanyakan yang tidak tertulis di denah**, jangan menebak: ukuran yang tidak terbaca, tinggi dinding, tebal dinding, tinggi pintu, tinggi ambang dan tinggi jendela. Kalau pengguna tidak tahu, pakai nilai umum di bawah dan sebutkan bahwa itu asumsi.
3. **Susun daftar dinding sebagai garis as** (garis tengah dinding) dalam meter, beri `id` tiap dinding.
4. **Susun bukaan** per dinding: `offset` adalah jarak dari titik `from` dinding ke tepi terdekat bukaan, diukur sepanjang dinding.
5. **Panggil `build_floor_plan`** sekali untuk satu lantai.
6. **Baca jawabannya.** Ukuran total harus cocok dengan denah, dan bagian `Warnings` harus kosong. Bukaan yang tidak muat akan dilewati dan dilaporkan di sana.
7. **Lihat hasilnya** dengan `export_scene` format `png`, lalu perbaiki kalau ada yang salah (Ctrl+Z di SketchUp membatalkan satu denah sekaligus).

Nilai umum kalau tidak disebutkan: tinggi dinding 3,0 m; tebal dinding bata 0,15 m; pintu 0,9 x 2,1 m; jendela lebar 1,2 m, ambang 0,9 m, tinggi 1,2 m; pelat lantai 0,12 m.

## Format `build_floor_plan`

Semua angka dalam **meter**.

```json
{
  "name": "Lantai 1",
  "wall_height": 3.0,
  "wall_thickness": 0.15,
  "base_z": 0,
  "walls": [
    {"id": "W1", "from": [0, 0], "to": [6, 0]},
    {"id": "W2", "from": [6, 0], "to": [6, 4], "thickness": 0.1, "height": 2.8}
  ],
  "openings": [
    {"wall": "W1", "type": "door", "offset": 1.0, "width": 0.9, "height": 2.1},
    {"wall": "W2", "type": "window", "offset": 1.2, "width": 1.5, "sill": 0.9, "height": 1.2}
  ],
  "slab": {"outline": [[0, 0], [6, 0], [6, 4], [0, 4]], "thickness": 0.12}
}
```

| Kunci | Arti |
|---|---|
| `name` | Nama grup hasil. Pakai nama berbeda tiap lantai |
| `wall_height`, `wall_thickness` | Nilai bawaan, bisa ditimpa per dinding lewat `height` dan `thickness` |
| `base_z` | Elevasi lantai. Lantai 2 misalnya `3.2` |
| `walls[].from`, `walls[].to` | Ujung garis as dinding `[x, y]` |
| `walls[].extend` | Bawaan `true`: ujung dinding dipanjangkan setengah tebal supaya sudut tertutup. Isi `false` untuk dinding sekat yang menempel di tengah dinding lain |
| `openings[].wall` | `id` dinding tempat bukaan |
| `openings[].offset` | Jarak dari titik `from` ke tepi bukaan |
| `openings[].sill` | Tinggi ambang. Tanpa `sill` (atau 0) berarti pintu; dengan `sill` berarti jendela |
| `openings[].height` | Tinggi bukaan, diukur dari ambang |
| `slab.outline` | Titik keliling pelat lantai. Permukaan atas pelat ada di `base_z` |

Hasilnya satu grup bernama `name`, berisi satu grup per dinding (`Dinding W1`, ...) di tag **Dinding** dan satu grup `Lantai` di tag **Lantai**. Setiap dinding adalah solid tertutup.

Batasan: dinding lurus saja (dinding lengkung dipecah jadi beberapa segmen pendek), bukaan persegi, tidak membuat daun pintu, kusen, atau atap. Untuk itu pakai `eval_ruby`.

## Uji cepat

Panggil `build_floor_plan` dengan:

```json
{
  "name": "Uji MCP",
  "walls": [
    {"id": "W1", "from": [0, 0], "to": [6, 0]},
    {"id": "W2", "from": [6, 0], "to": [6, 4]},
    {"id": "W3", "from": [6, 4], "to": [0, 4]},
    {"id": "W4", "from": [0, 4], "to": [0, 0]}
  ],
  "openings": [
    {"wall": "W1", "type": "door", "offset": 1.0, "width": 0.9, "height": 2.1},
    {"wall": "W2", "type": "window", "offset": 1.2, "width": 1.5, "sill": 0.9, "height": 1.2}
  ],
  "slab": {"outline": [[0, 0], [6, 0], [6, 4], [0, 4]], "thickness": 0.12}
}
```

Jawaban yang benar: `Built 'Uji MCP': 4 walls, 2 openings, 1 slab. Size 6.15 x 4.15 x 3.12 m (x, y, z).`

## Aturan saat memakai `eval_ruby`

Untuk atap, tangga, kolom, furnitur, dan apa pun di luar `build_floor_plan`.

1. **Satuan internal SketchUp adalah inci.** Selalu tulis `3.m`, `150.mm`, `15.cm`. Angka polos seperti `3` berarti 3 inci. Untuk membaca balik: `panjang.to_m`.
2. **Bungkus perubahan dalam satu operasi** supaya pengguna bisa membatalkannya dengan satu kali Ctrl+Z:
   ```ruby
   model = Sketchup.active_model
   model.start_operation('Atap', true)
   # ... geometri ...
   model.commit_operation
   ```
3. **Face di z = 0 menghadap ke bawah.** `pushpull` dengan angka positif akan masuk ke bawah tanah. Sebelum `pushpull`: `face.reverse! if face.normal.z < 0`.
4. **Satu elemen, satu grup.** `g = model.active_entities.add_group`, lalu gambar di `g.entities`. Geometri lepas akan saling menempel.
5. **Akhiri kode dengan ringkasan** (string berisi jumlah objek dan ukuran) supaya hasilnya bisa diperiksa. Nilai ekspresi terakhir yang dikembalikan.
6. **Satu panggilan paling lama sekitar 15 detik.** Pecah pekerjaan besar jadi beberapa panggilan.
7. **Untuk mencoba tanpa mengotori model:** pakai `model.start_operation('coba', true)` lalu `model.abort_operation` di akhir.

Contoh atap pelana di atas rumah 6 x 4 m (tinggi dinding 3 m, tinggi bubungan 1,5 m, teritis 0,5 m):

```ruby
model = Sketchup.active_model
model.start_operation('Atap pelana', true)
g = model.active_entities.add_group
g.name = 'Atap'
o = 0.5.m
profil = [
  [-o, -o, 3.m],
  [-o, 4.m + o, 3.m],
  [-o, 2.m, 4.5.m]
]
face = g.entities.add_face(profil)
face.pushpull(face.normal.x > 0 ? 6.m + 2 * o : -(6.m + 2 * o))
model.commit_operation
"Atap: #{g.bounds.width.to_m.round(2)} x #{g.bounds.height.to_m.round(2)} x #{g.bounds.depth.to_m.round(2)} m"
```

## Jebakan tool lain

- `create_component`: `position` dan `dimensions` dalam **inci**. Untuk `cylinder`, `position` adalah sudut kotak pembatasnya, bukan titik pusat, dan `dimensions` berisi `[diameter, diabaikan, tinggi]`. Kubus di z = 0 terbentuk ke arah bawah.
- `transform_component`: `position` adalah pergeseran **relatif**, bukan posisi tujuan.
- `set_material`: hanya mengenal red, green, blue, yellow, cyan, magenta, white, black, brown, orange, gray. Warna lain lewat `eval_ruby` dengan `Sketchup::Color.new(r, g, b)`.
- `export_scene`: file ditulis ke `%TEMP%\sketchup_exports`, dan path lengkapnya ada di jawaban. Sebelum mengambil gambar, atur sudut pandang:
  ```ruby
  Sketchup.send_action('viewIso:')
  Sketchup.active_model.active_view.zoom_extents
  ```
  Jalankan itu sebagai panggilan `eval_ruby` tersendiri, baru panggil `export_scene`, karena perubahan sudut pandang baru berlaku setelah panggilan selesai.
