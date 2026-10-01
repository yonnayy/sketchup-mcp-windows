# Pemecahan masalah

Mulai selalu dari pemeriksaan otomatis:

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/yonnayy/sketchup-mcp-windows/main/check.ps1 | iex"
```

| Gejala | Penyebab | Solusi |
|---|---|---|
| `Could not connect to Sketchup` / `Nothing answers on 127.0.0.1:9876` | SketchUp belum dibuka, masih di jendela Welcome, atau server dimatikan | Buka SketchUp dan buka sebuah model. Cek **Extensions > MCP Server > Status**. Kalau `STOPPED`, klik **Start Server** |
| Menu **Extensions > MCP Server** tidak ada | Extension belum terpasang atau dinonaktifkan | Jalankan installer lagi. Lalu **Extension Manager**: aktifkan **Sketchup MCP Server**, buka ulang SketchUp |
| Tool `sketchup` tidak muncul di Claude Desktop | Claude Desktop belum dibuka ulang, atau config salah | Quit dari ikon tray lalu buka lagi. Cek **Settings > Developer**: server `sketchup` harus berstatus running. Kalau `failed`, buka log-nya |
| `Port 9876 is already in use` di Ruby Console | Ada dua jendela SketchUp terbuka | Hanya jendela pertama yang melayani MCP. Tutup jendela yang lain |
| SketchUp membeku, jawaban `No data received` | Yang terpasang masih extension versi asli | Jalankan `check.ps1`. Kalau tertulis `ORIGINAL unpatched version`, jalankan installer lagi dan buka ulang SketchUp |
| Panggilan pertama berhasil, berikutnya `Method not found` | Server Python versi asli (dari PyPI) dipakai bersama extension versi ini, atau sebaliknya | Pastikan `command` di config menunjuk ke `...\.local\bin\sketchup-mcp.exe`, bukan `uvx sketchup-mcp` |
| `Ruby evaluation error: ...` | Kode Ruby yang dikirim salah | Baca pesannya, perbaiki kodenya. Model tidak rusak; kalau ada geometri setengah jadi, Ctrl+Z |
| Model jadi sangat kecil atau sangat besar | Satuan: angka polos dianggap inci | Pakai `.m`, `.cm`, `.mm` di `eval_ruby`. `build_floor_plan` selalu meter |
| Dinding atau pelat masuk ke bawah tanah | `pushpull` pada face di z = 0 | `face.reverse! if face.normal.z < 0` sebelum `pushpull` |
| `Warnings: ... does not fit in the wall` | `offset + width` bukaan melebihi panjang dinding, atau arah `from` ke `to` terbalik dari yang dikira | Hitung ulang `offset` dari titik `from` dinding itu |
| `verify_dimensions` melaporkan `SELISIH` sebesar tebal atau setengah tebal dinding | `ref` dinding tidak sesuai cara denah diberi ukuran, atau arah telusur keliling searah jarum jam | Lihat [MODELING.md](MODELING.md#acuan-ukuran-dinding): telusuri berlawanan arah jarum jam, `right` untuk ukuran luar, `left` untuk ukuran bersih |
| `export_scene` menjawab `No data received` padahal file gambarnya jadi | Versi lama hanya menunggu 15 detik; model besar dengan bayangan butuh lebih lama | Perbarui lewat installer. Sementara itu, gambarnya tetap tersimpan di folder `sketchup_exports` di dalam `%TEMP%` |
| `verify_dimensions` melaporkan `TIDAK TERUKUR` | Titik `at` berada di luar ruang, di dalam dinding, atau ruangnya tidak tertutup dinding di arah itu | Pindahkan titik `at` ke tengah ruang |
| Installer: `No SketchUp profile folder found` | SketchUp belum pernah dibuka di akun Windows ini | Buka SketchUp sekali, tutup, jalankan installer lagi |
| Installer: `... is not valid JSON` | `claude_desktop_config.json` rusak sebelumnya | Perbaiki file itu (cadangan `.bak-...` ada di folder yang sama), lalu jalankan installer lagi |
| Installer gagal mengunduh | Tidak ada internet, atau diblokir proxy/antivirus | Unduh repo sebagai ZIP dari GitHub, ekstrak, jalankan `install.ps1` dari dalam foldernya |

## Kalau SketchUp tidak merespons

Jangan menutup paksa SketchUp, karena modelnya masih utuh. Tutup Claude Desktop dari ikon tray (atau akhiri proses `sketchup-mcp.exe` di Task Manager). SketchUp akan kembali normal, lalu simpan pekerjaan.

## Melihat log

- **SketchUp:** **Extensions > Developer > Ruby Console** (atau **Window > Ruby Console**). Setiap permintaan tercatat dengan awalan `MCP:`.
- **Claude Desktop:** **Settings > Developer > sketchup > Open Logs**, atau file `mcp-server-sketchup.log` di `%APPDATA%\Claude\logs`.

## Memuat ulang extension tanpa menutup SketchUp

**Extensions > MCP Server > Stop Server**, lalu di Ruby Console ketik `load 'su_mcp/main.rb'`, lalu **Start Server**.
