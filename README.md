# AkiGuard

Pengatur charging MacBook yang ringan dan open source — alternatif [AlDente](https://apphousekitchen.com/) buatan sendiri.
Batasi charging, discharge walau charger terpasang, top up sementara, dan **jadwalkan** kapan Mac charging atau discharging.

> *English: AkiGuard is a small open-source battery charge limiter for macOS (Intel & Apple Silicon). It caps charging, forces discharge while plugged in, supports temporary top-ups and time-based schedules, and lives in the menu bar. UI and docs are in Indonesian.*

> ⚠️ **Status: eksperimental.** Program ini menulis kunci SMC (System Management Controller) Mac Anda. Gunakan dengan risiko sendiri.

## Fitur
- **Batas charging** 50–100% (default 80%)
- **Sailing** — charging nyala lagi hanya setelah baterai turun N% di bawah batas, supaya tidak bolak-balik
- **Discharge sampai X%** — Mac memakai baterai walau charger terpasang, lalu ditahan di X%
- **Auto-discharge** — kalau baterai di atas batas, diturunkan dulu
- **Top up ke 100%** selama 2/4/8 jam
- **Jadwal** — mis. Sen–Jum 05:30–07:30 isi penuh; setiap malam 22:00–05:30 tahan di 60%
- **Pengaman** — charger dinyalakan lagi sebelum Mac sleep dan saat daemon berhenti; di bawah 10% charging selalu dibuka

Arti ikon di menu bar: `⏸` charging ditahan · `⚡︎` charging · `↓` discharge · `⚠︎` daemon tidak jalan.

## Kompatibilitas

| MacBook | Batasi charging | Discharge saat dicolok | Batas berlaku saat Mac mati |
|---|---|---|---|
| Intel 2016–2020 | Ya (`BCLM`, `CH0B`/`CH0C`) | Tergantung model (`CH0I`) | Ya (`BCLM`) |
| Intel sebelum 2016 | Kemungkinan | Sering tidak | Tergantung model |
| Apple Silicon (M1–M4) | Ya (`CH0B`/`CH0C` atau `CHTE`) | Ya (`CH0I` atau `CHIE`) | Tidak |

Butuh **macOS 11 (Big Sur)** atau lebih baru. Jalankan `akiguard keys` untuk melihat fitur yang didukung Mac Anda.

## Pasang
Perlu Command Line Tools (`xcode-select --install`).
```bash
git clone https://github.com/wildanlsfs/akiguard.git
cd akiguard
./install.sh
```
Password admin diminta sekali untuk memasang daemon. Setelah selesai, ikon AkiGuard muncul di menu bar.

Matikan **Optimized Battery Charging** (System Settings › Battery) agar tidak bentrok.

## Perintah terminal
```bash
akiguard status       # baterai + status daemon
akiguard keys         # fitur SMC yang didukung Mac ini
sudo akiguard reset   # kembalikan semua ke normal
```
- Log: `/Library/Logs/AkiGuard.log`
- Konfigurasi: `/Library/Application Support/AkiGuard/akiguard.conf` (lihat contoh di [`config/akiguard.conf.default`](config/akiguard.conf.default))

## Cara kerja
- `akiguard daemon` (C, jalan sebagai root lewat launchd) membaca konfigurasi dan persentase baterai setiap 15 detik, lalu menulis kunci SMC yang tersedia.
- `AkiGuard.app` (Swift, menu bar) hanya mengubah file konfigurasi, jadi tidak perlu password setiap kali mengubah pengaturan.

```
src/
  smc.c / smc.h        akses AppleSMC lewat IOKit
  akiguard.c           daemon + CLI
  AkiGuardMenu.swift   aplikasi menu bar
install.sh / uninstall.sh
```

## Hapus
```bash
./uninstall.sh
```
Daemon dihentikan dan semua kunci SMC dikembalikan normal (charging aktif, `BCLM` 100%).

## Lisensi
MIT — lihat [LICENSE](LICENSE).
