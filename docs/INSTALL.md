# Pemasangan

Dokumen ini ditulis supaya bisa diikuti oleh Claude (atau agent lain) maupun manusia. Kerjakan berurutan, dan jangan lanjut ke langkah berikutnya sebelum verifikasi langkah sekarang berhasil.

## Catatan untuk agent

- **Kalau kamu bisa menjalankan perintah** (Claude Desktop tab Code, Claude Code, Cowork): jalankan perintah di bawah sendiri lewat PowerShell.
- **Kalau kamu tidak bisa menjalankan perintah** (mode chat biasa): minta pengguna membuka PowerShell, menempel perintahnya, lalu menempelkan hasilnya kembali ke kamu.
- Ada tiga hal yang hanya bisa dilakukan pengguna, jadi minta dengan jelas saat waktunya tiba: membuka SketchUp, melewati jendela Welcome SketchUp, dan menutup lalu membuka ulang Claude Desktop.
- Installer aman dijalankan berulang kali. Ia membuat cadangan `claude_desktop_config.json` sebelum mengubahnya dan tidak menyentuh server MCP lain di file itu.

## Syarat

| Syarat | Cara cek |
|---|---|
| Windows 10 atau 11 | |
| SketchUp desktop (diuji di 2025; 2021 ke atas seharusnya jalan), **sudah pernah dibuka minimal sekali** | Folder `%APPDATA%\SketchUp\SketchUp 20xx` ada |
| Claude Desktop terpasang | |
| Internet (untuk mengunduh `uv` dan paket Python, sekitar 60 MB) | |

SketchUp Web dan SketchUp for iPad tidak didukung karena tidak bisa memuat extension Ruby.

## Langkah 1: jalankan installer

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/yonnayy/sketchup-mcp-windows/main/install.ps1 | iex"
```

Atau dari salinan repo yang sudah diunduh:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Yang dilakukan installer:

1. Menyalin extension ke `%APPDATA%\SketchUp\SketchUp 20xx\SketchUp\Plugins\` (`su_mcp.rb` dan `su_mcp\main.rb`) untuk setiap versi SketchUp yang ada.
2. Memasang `uv` kalau belum ada.
3. Memasang server MCP sebagai `%USERPROFILE%\.local\bin\sketchup-mcp.exe`.
4. Menambahkan entri `sketchup` ke `claude_desktop_config.json` (versi installer biasa dan versi Microsoft Store).

**Verifikasi:** baris terakhir tiap bagian berawalan `[OK]`, dan installer berakhir dengan `== Done. Next steps`. Baris `[!!]` adalah peringatan: baca isinya, biasanya berarti SketchUp belum pernah dibuka atau sedang berjalan.

## Langkah 2: buka SketchUp

Minta pengguna untuk:

1. Menutup SketchUp kalau sedang terbuka, lalu membukanya lagi.
2. **Memilih template atau membuka file** di jendela Welcome. Extension baru dimuat setelah jendela model muncul.

Server MCP menyala sendiri sekitar satu detik setelah model terbuka. Untuk memastikan: menu **Extensions > MCP Server > Status** harus menampilkan `RUNNING on 127.0.0.1:9876`.

Kalau menu **MCP Server** tidak ada: buka **Extensions > Extension Manager**, aktifkan **Sketchup MCP Server**, lalu buka ulang SketchUp.

## Langkah 3: buka ulang Claude Desktop

Claude Desktop hanya membaca daftar server MCP saat dinyalakan. Minta pengguna untuk klik kanan ikon Claude di **system tray** (pojok kanan bawah) > **Quit**, lalu membukanya lagi. Menutup jendela saja tidak cukup.

## Langkah 4: jalankan pemeriksaan

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/yonnayy/sketchup-mcp-windows/main/check.ps1 | iex"
```

Hasil yang diharapkan:

```
[PASS] Extension (patched) present for SketchUp 2025
[PASS] Registered in C:\Users\...\Claude\claude_desktop_config.json
[PASS] SketchUp is running
[PASS] SketchUp answered: SketchUp 25.0.660 | model: 1 entities

ALL CHECKS PASSED.
```

Setiap `[FAIL]` disertai baris `->` yang menjelaskan perbaikannya. Lihat juga [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Langkah 5: uji dari Claude Desktop

Di percakapan **baru** di Claude Desktop, tool `sketchup` harus muncul di daftar tool/connector. Lalu uji berurutan:

1. **Koneksi.** Panggil `eval_ruby` dengan kode `Sketchup.version`. Hasilnya nomor versi SketchUp.
2. **Berurutan.** Panggil `get_selection`, lalu `eval_ruby` dengan `Sketchup.active_model.entities.length`, lalu `get_selection` lagi. Ketiganya harus menjawab sesuai pertanyaannya (versi asli gagal di panggilan kedua).
3. **Model contoh pertama.** Baca [STANDARDS.md](STANDARDS.md), lalu kerjakan tiga langkah di [MODELING.md](MODELING.md#model-contoh-pertama) pada model kosong: denah (`Built 'Lantai 1': 8 walls, 4 doors, 7 windows, 1 slab`), atap, lalu gambar.
4. **Audit.** `SU_MCP.audit_model` lewat `eval_ruby` harus menjawab `AUDIT OK. 23 elements and 2 containers checked. All rules satisfied.`

Kalau keempatnya berhasil, pemasangan selesai. Tunjukkan gambarnya ke pengguna. Model contoh boleh dihapus (hapus grup `Rumah Contoh`) atau disimpan sebagai acuan.

## Pemasangan manual (kalau installer tidak bisa dipakai)

1. **Extension:** di SketchUp, **Extensions > Extension Manager > Install Extension**, pilih `release/su_mcp.rbz` dari repo ini. Buka ulang SketchUp.
2. **uv:** `powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"`
3. **Server:** `uv tool install --force --reinstall-package sketchup-mcp --python 3.12 "sketchup-mcp @ https://github.com/yonnayy/sketchup-mcp-windows/archive/refs/heads/main.zip"`
4. **Config:** di Claude Desktop, **Settings > Developer > Edit Config**, tambahkan (ganti `NAMA` dengan nama pengguna Windows):

```json
{
  "mcpServers": {
    "sketchup": {
      "command": "C:\\Users\\NAMA\\.local\\bin\\sketchup-mcp.exe",
      "args": []
    }
  }
}
```

Pakai path lengkap. Claude Desktop sering tidak menemukan program lewat PATH.

## Memakai dari Claude Code (opsional)

```powershell
claude mcp add --scope user sketchup -- "$env:USERPROFILE\.local\bin\sketchup-mcp.exe"
```

## Memperbarui dan menghapus

- **Memperbarui:** jalankan installer lagi, lalu buka ulang SketchUp dan Claude Desktop.
- **Menghapus:** `uv tool uninstall sketchup-mcp`, hapus `su_mcp.rb` dan folder `su_mcp` dari folder Plugins SketchUp, lalu hapus entri `sketchup` dari `claude_desktop_config.json`.
