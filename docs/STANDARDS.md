# Aturan dasar model

Aturan ini berlaku untuk **setiap** model yang dibuat lewat MCP, mulai dari model contoh pertama. Tujuannya supaya model yang rumit tetap bisa diatur: elemen bisa disembunyikan per jenis, material bisa diganti sekaligus, dan tidak ada geometri yang saling menempel.

`build_floor_plan` sudah mengikuti aturan ini dengan sendirinya. Untuk apa pun yang dibuat lewat `eval_ruby`, pakai helper `SU_MCP.element` (lihat di bawah) dan tutup pekerjaan dengan audit.

## Enam aturan

1. **Satu elemen bangunan = satu grup bernama.** Tidak ada edge atau face lepas di akar model. Nama grup menyebut elemennya: `Dinding W1`, `Pintu W1-1`, `Atap Pelana`.
2. **Geometri mentah selalu Untagged.** Edge dan face di dalam grup tidak diberi tag. Tag hanya dipasang pada grup atau komponen.
3. **Setiap elemen punya tepat satu tag dari daftar baku** di bawah. Jangan membuat tag dengan nama lain.
4. **Setiap elemen punya material bernama `Elemen - Bahan`,** dipasang pada grupnya, bukan dicat per face. Face dibiarkan tanpa material supaya mewarisi material grup; cat per face hanya kalau satu elemen memang punya dua bahan.
5. **Susunan bertingkat:** satu bangunan adalah satu grup wadah, di dalamnya satu grup per lantai, di dalamnya elemen. Benda yang terdiri dari beberapa bagian (satu pintu, satu jendela) juga dibungkus satu grup wadah. Grup wadah tidak diberi tag dan tidak diberi material.
6. **Audit sebelum selesai.** Jalankan `SU_MCP.audit_model` lewat `eval_ruby`. Pekerjaan belum selesai sebelum hasilnya `AUDIT OK`.

```
Rumah Contoh                 (wadah: tanpa tag, tanpa material)
  Lantai 1                   (wadah)
    Dinding W1               [01-Dinding]  Dinding - Cat Putih
    Pintu W1-1               (wadah: satu unit pintu)
      Kusen                  [03-Pintu]    Pintu - Kayu
      Daun                   [03-Pintu]    Pintu - Kayu
    Jendela W1-1             (wadah: satu unit jendela)
      Kusen                  [04-Jendela]  Jendela - Kayu
      Daun 1                 [04-Jendela]  Jendela - Kayu
      Kaca 1                 [04-Jendela]  Jendela - Kaca
    Lantai                   [02-Lantai]   Lantai - Keramik
  Atap Pelana                [05-Atap]     Atap - Genteng
```

## Daftar tag dan material baku

| Jenis (`kind`) | Tag | Material bawaan | Dipakai untuk |
|---|---|---|---|
| `referensi` | `00-Referensi` | (tidak ada) | Figur skala, gambar denah impor, garis bantu |
| `dinding` | `01-Dinding` | `Dinding - Cat Putih` | Dinding, ampig, pagar tembok |
| `lantai` | `02-Lantai` | `Lantai - Keramik` | Pelat lantai, teras |
| `pintu` | `03-Pintu` | `Pintu - Kayu` | Kusen pintu, daun pintu, busur ayun |
| `jendela` | `04-Jendela` | `Jendela - Kaca` | Kaca jendela; kusen dan daun jendela memakai `Jendela - Kayu` |
| `atap` | `05-Atap` | `Atap - Genteng` | Penutup atap, lisplang, plafon |
| `struktur` | `06-Struktur` | `Struktur - Beton` | Kolom, balok, sloof, pondasi |
| `tangga` | `07-Tangga` | `Tangga - Beton` | Tangga, ramp, bordes |
| `furnitur` | `08-Furnitur` | `Furnitur - Kayu` | Perabot dan perlengkapan |
| `tapak` | `09-Tapak` | `Tapak - Rumput` | Tanah, jalan, taman, pagar tapak |
| `anotasi` | `10-Anotasi <nama scene>` | (tidak ada) | Angka ukuran, nama ruang, bidang potong. Dibuat oleh `add_plan_view`, satu tag per tampak denah |

Angka di depan nama tag membuat urutannya tetap di panel Tags. Kalau proyek butuh jenis elemen di luar daftar, pakai pola yang sama (`10-MEP`, `11-Fasad`) dan sebutkan ke pengguna; audit menerima tag berpola `NN-Nama`.

Bahan lain untuk jenis yang sama tetap memakai pola `Elemen - Bahan`: `Dinding - Bata Ekspos`, `Lantai - Kayu`, `Atap - Metal`.

## Helper di `eval_ruby`

Extension menyediakan helper supaya aturan di atas terpenuhi tanpa ditulis ulang setiap kali.

| Helper | Fungsi |
|---|---|
| `SU_MCP.container('Rumah A')` | Mengambil grup wadah bangunan dengan nama itu, atau membuatnya kalau belum ada |
| `SU_MCP.element(nama, jenis, induk) { \|ents\| ... }` | Membuat satu elemen: grup bernama, geometri Untagged, tag dan material sesuai jenis |
| `SU_MCP.element(nama, jenis, induk, 'Dinding - Bata Ekspos', [165, 80, 60]) { ... }` | Sama, dengan material lain (dibuat kalau belum ada) |
| `SU_MCP.tag(jenis)` | Tag baku untuk jenis itu |
| `SU_MCP.material(jenis)` | Material baku untuk jenis itu |
| `SU_MCP.audit_model` | Memeriksa seluruh model terhadap enam aturan |

Contoh kolom beton 30 x 30 cm setinggi 3 m di dalam bangunan `Rumah Contoh`:

```ruby
model = Sketchup.active_model
model.start_operation('Kolom K1', true)
rumah = SU_MCP.container('Rumah Contoh')
SU_MCP.element('Kolom K1', :struktur, rumah) do |ents|
  face = ents.add_face([0, 0, 0], [0.3.m, 0, 0], [0.3.m, 0.3.m, 0], [0, 0.3.m, 0])
  face.reverse! if face.normal.z < 0
  face.pushpull(3.m)
end
model.commit_operation
SU_MCP.audit_model
```

## Audit

```ruby
SU_MCP.audit_model
```

Hasil yang benar:

```
AUDIT OK. 56 elements and 13 containers checked. All rules satisfied.
```

Kalau ada pelanggaran, setiap baris menyebut elemen dan masalahnya:

```
AUDIT FAILED. 25 elements and 1 containers checked. 7 problem(s):
- 1 loose edges/faces at the model root (put them in a named group)
- (unnamed #30908): has no name
- (unnamed #30908): has no tag
- (unnamed #30908): no material (1 faces show the default colour)
- Kolom salah: material 'merah' is not named 'Elemen - Bahan'
- Kolom salah: 1 edges/faces inside carry a tag (raw geometry must stay Untagged)
- Kolom salah: tag 'kolom' is not a standard tag
```

Perbaiki elemen yang disebut, lalu jalankan audit lagi. Elemen di tag `00-Referensi` dan `10-Anotasi ...` tidak diperiksa isinya, jadi figur skala bawaan template cukup dipindahkan ke tag itu:

```ruby
figur = Sketchup.active_model.entities.grep(Sketchup::ComponentInstance).first
figur.layer = SU_MCP.tag(:referensi) if figur
```

## Model yang sudah ada

Kalau pengguna membuka model lama yang tidak mengikuti aturan ini, jangan mengubahnya tanpa diminta. Jalankan audit, laporkan hasilnya, dan tanyakan apakah mau dirapikan. Elemen baru yang kamu tambahkan tetap harus mengikuti aturan.
