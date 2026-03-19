# Chat Defense

`Chat Defense` adalah game TikTok Live berbasis Godot 4 untuk Windows dengan format auto-defense. Base dan turret berjalan otomatis, lalu viewer memengaruhi permainan lewat comment, gift, follow, like milestone, atau payload action langsung.

Proyek ini sudah disiapkan supaya bisa langsung dipakai sebagai MVP:

- proyek Godot siap import
- arena dan UI sudah ada
- sprite gameplay stylized untuk base, turret, bullet, dan enemy
- UI live panel yang lebih tegas untuk stream
- wave enemy otomatis
- queue event dengan cooldown global per action
- HTTP listener lokal di `127.0.0.1:8787`
- resolver payload mentah TikTok lewat file config
- audio procedural built-in untuk heal, bomb, tank, boss, dan game over
- alert banner dan flash visual untuk event besar
- helper script untuk test dari Windows / Python

## Folder Penting

- `project.godot`: entry proyek
- `scenes/main.tscn`: scene utama
- `scripts/main.gd`: gameplay dan HTTP listener
- `config/event_router.json`: mapping comment/gift/follow/like ke action internal
- `docs/SETUP_WINDOWS.md`: panduan setup cepat
- `tools/send_event.py`: helper kirim event
- `tools/send_event.ps1`: helper PowerShell
- `assets/icon.svg`: icon proyek
- `assets/sprites/`: sprite SVG gameplay yang siap diganti / dikustom

## Cara Pakai Cepat

1. Install Godot 4.x di Windows.
2. Import folder ini lewat `project.godot`.
3. Jalankan game.
4. Tes lokal dengan keyboard:
   - `1` heal
   - `2` turret
   - `3` bomb
   - `8` runner pack
   - `9` tank
   - `0` boss
   - `R` ranged pair
   - `F` fog
   - `Space` restart
5. Kalau sudah oke, arahkan connector TikTok ke `http://127.0.0.1:8787/event`.

## Payload yang Didukung

### Direct action

```json
{
  "action": "spawn_tank",
  "user": "andi"
}
```

### Comment payload

```json
{
  "type": "comment",
  "comment": "!boss",
  "user": "andi"
}
```

### Gift payload

```json
{
  "type": "gift",
  "gift": "Galaxy",
  "user": "andi"
}
```

### Follow payload

```json
{
  "type": "follow",
  "user": "andi"
}
```

### Like payload

```json
{
  "type": "like",
  "count": 200,
  "user": "andi"
}
```

## Action Internal

- `heal_base`
- `spawn_turret_temp`
- `drop_bomb`
- `spawn_runner_pack`
- `spawn_tank`
- `spawn_ranged_pair`
- `fog`
- `spawn_boss`

## Tes Manual

Python:

```bash
python tools/send_event.py spawn_boss topgifter
python tools/send_event.py '{"type":"comment","comment":"!tank","user":"andi"}'
```

PowerShell:

```powershell
.\tools\send_event.ps1 -Action spawn_boss -User topgifter
```

## Catatan

- cooldown saat ini masih global per action, belum per user
- visual gameplay sekarang sudah memakai sprite SVG stylized bawaan proyek
- kalau ingin style lain, aset di `assets/sprites/` bisa diganti tanpa ubah loop gameplay utama
- langkah setup detail ada di [docs/SETUP_WINDOWS.md](docs/SETUP_WINDOWS.md)
