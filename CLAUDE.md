# Petunjuk untuk Claude

Repo ini berisi MCP server yang menghubungkan Claude ke SketchUp di Windows.

- Diminta **memasang** di sebuah komputer: ikuti `docs/INSTALL.md` dari awal sampai Langkah 5, jangan melompati verifikasi.
- Diminta **memodelkan** (terutama dari denah): baca `docs/STANDARDS.md` lalu `docs/MODELING.md`. Setiap elemen harus punya tag dan material baku, dan pekerjaan baru selesai kalau `SU_MCP.audit_model` menjawab `AUDIT OK`. Untuk denah berdimensi urutannya tetap: `check_dimension_chains`, `build_floor_plan` dengan `ref` yang sesuai cara denah diberi ukuran, lalu `verify_dimensions`, dan laporan akurasinya disampaikan ke pengguna. Satuan internal SketchUp adalah inci; `build_floor_plan` memakai meter. Atap dan detail (papan dinding, lis jendela, tiang, tangga, perabot) dibuat dengan tool di `docs/DETAIL.md`, bukan Ruby tulis tangan. Untuk proyek di luar model contoh ikuti `docs/WORKFLOW.md`: posisi tangga dan perabot dibaca dari gambar lalu dicek dengan `check_placement`, dan gambar untuk pengguna diekspor paling akhir dengan `export_views`.
- Diminta **menguji atau mendemokan** kemampuan modelling: setelah model contoh pertama di `docs/MODELING.md` lolos, bangun Caroline's Farmhouse menurut `examples/caroline/README.md` di model baru yang kosong, dan tunjukkan gambarnya ke pengguna.
- Ada yang **tidak jalan**: jalankan `check.ps1`, lalu lihat `docs/TROUBLESHOOTING.md`.

## Struktur

- `su_mcp/su_mcp.rb`, `su_mcp/su_mcp/main.rb`: extension SketchUp (server TCP di 127.0.0.1:9876, semua tool diimplementasikan di sini)
- `src/sketchup_mcp/server.py`: MCP server (stdio) yang meneruskan panggilan ke extension
- `release/su_mcp.rbz`: extension siap pasang. Bangun ulang setiap `main.rb` berubah (zip berisi `su_mcp.rb` dan `su_mcp/main.rb`, pemisah path harus `/`)
- `install.ps1`, `check.ps1`: harus tetap ASCII dan kompatibel dengan Windows PowerShell 5.1 (tanpa `&&`, `||`, `?:`)

## Menguji perubahan

```powershell
uv run --project . python tests/mock_roundtrip.py     # SketchUp harus tertutup
uv run --project . python tests/live_floor_plan.py    # SketchUp terbuka dengan sebuah model
uv run --project . python tests/live_detail.py        # sama, untuk tool atap dan detail
uv run --project . python examples/caroline/build.py  # SketchUp terbuka dengan model BARU yang kosong; 42 langkah harus sesuai
```

Tabel tag dan material ada di `SU_MCP::Standards::TABLE` pada `main.rb`; kalau diubah, ubah juga tabel di `docs/STANDARDS.md`.

Menambah tool berarti mengubah dua tempat: fungsi `@mcp.tool()` di `server.py` dan cabang `when` di `handle_tool_call` pada `main.rb`.
