# Setup Windows

## 1. Install Godot

- Download Godot 4.x standard version for Windows.
- Extract ke folder mana saja.

## 2. Jalankan Proyek

- Buka `Godot.exe`
- `Import`
- pilih file `project.godot` di folder ini
- klik `Run`

## 3. Test Cepat

- tekan `1`, `2`, `3`, `8`, `9`, `0`, `R`, `F`
- lihat event feed di kanan
- pastikan audio Windows aktif karena alert dan event besar sekarang punya suara bawaan

## 4. Test Webhook

PowerShell:

```powershell
.\tools\send_event.ps1 -Action spawn_boss -User andi
```

Atau:

```powershell
Invoke-RestMethod -Uri "http://127.0.0.1:8787/event" `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"type":"comment","comment":"!tank","user":"andi"}'
```

## 5. Sambungkan Connector TikTok

Kalau connector kamu sudah bisa kirim webhook lokal, arahkan ke:

```text
http://127.0.0.1:8787/event
```

Payload yang diterima game:

Direct action:

```json
{
  "action": "spawn_tank",
  "user": "andi"
}
```

Comment resolver:

```json
{
  "type": "comment",
  "comment": "!boss",
  "user": "andi"
}
```

Gift resolver:

```json
{
  "type": "gift",
  "gift": "Galaxy",
  "user": "andi"
}
```

Follow resolver:

```json
{
  "type": "follow",
  "user": "andi"
}
```

## 6. Ubah Mapping Event

Edit file:

- `config/event_router.json`

Di situ kamu bisa ganti keyword comment, nama gift, dan action internal tanpa menyentuh script game.

## 7. Feedback Visual dan Audio

MVP ini sekarang sudah punya:

- banner alert besar di bagian atas untuk event penting
- flash merah saat bomb / boss / kehancuran base
- shake ringan saat boss muncul
- tone procedural untuk support, sabotage, boss, dan game over

Kalau kamu ingin tone diganti jadi sound effect file `.wav`, langkah itu bisa ditambah di iterasi berikutnya.
