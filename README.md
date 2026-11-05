# AkiGuard

A small, open-source battery charge limiter for MacBooks — Intel **and** Apple Silicon.
Cap charging, run on battery while plugged in, top up to 100% when you need it, and schedule all of it by time and day. Lives in the menu bar.

> 🛒 **[Get AkiGuard Pro](https://wildan17.gumroad.com/l/akiguard)** — one-click signed installer (no Terminal), **battery health** (health %, cycles, temperature) and **heat protection** (pause charging when the battery gets hot). Buying Pro supports development of the free version.

> ⚠️ AkiGuard writes keys to your Mac's SMC (System Management Controller). Use at your own risk.

## Free vs Pro

| | Free (this repo) | [Pro](https://wildan17.gumroad.com/l/akiguard) |
|---|---|---|
| Charge limit 50–100%, sailing | ✅ | ✅ |
| Run on battery while plugged in, auto-discharge | ✅ | ✅ |
| Top up to 100% for 2/4/8 hours | ✅ | ✅ |
| Schedules by time and day | ✅ | ✅ |
| Menu bar app + `akiguard` CLI | ✅ | ✅ |
| Install | Build from source in Terminal | **Signed, notarized one-click installer** |
| Battery health: health %, cycle count, temperature | — | ✅ |
| Heat protection: pause charging above 35–45 °C | — | ✅ |
| Priority support | — | ✅ |

## Features
- **Charge limit** 50–100% (default 80%)
- **Sailing** — charging resumes only after the battery drops N% below the limit, so it doesn't flip on and off
- **Discharge to X%** — run on battery while plugged in, then hold at X%
- **Auto-discharge** — if the battery is above the limit, bring it down first
- **Top up to 100%** for 2/4/8 hours
- **Schedules** — e.g. Mon–Fri 05:30–07:30 charge to 100%; every night 22:00–05:30 hold at 60%
- **Safety** — the adapter is switched back on before your Mac sleeps and when the service stops; below 10% charging is always allowed

Menu bar badges: `⏸` charging paused · `⚡︎` charging · `↓` discharging · `⚠︎` service not running.

## Compatibility

| MacBook | Limit charging | Discharge while plugged in | Limit kept while Mac is off |
|---|---|---|---|
| Intel 2016–2020 | Yes (`BCLM`, `CH0B`/`CH0C`) | Depends on model (`CH0I`) | Yes (`BCLM`) |
| Intel before 2016 | Likely | Often not | Depends on model |
| Apple Silicon (M1–M4) | Yes (`CH0B`/`CH0C` or `CHTE`) | Yes (`CH0I` or `CHIE`) | No |

Needs **macOS 11 (Big Sur)** or newer. Run `akiguard keys` to see what your Mac supports. Some recent firmware updates restrict what any charge limiter can do; `akiguard keys` tells you honestly.

## Install (free edition)
Needs Command Line Tools (`xcode-select --install`).
```bash
git clone https://github.com/wildanlsfs/akiguard.git
cd akiguard
./install.sh
```
You'll be asked for your admin password once. The AkiGuard icon then appears in the menu bar.

Turn off **Optimized Battery Charging** (System Settings › Battery) so it doesn't conflict.

## Terminal commands
```bash
akiguard status       # battery + service status
akiguard keys         # SMC features this Mac supports
sudo akiguard reset   # put everything back to normal
```
- Log: `/Library/Logs/AkiGuard.log`
- Config: `/Library/Application Support/AkiGuard/akiguard.conf` (see [`config/akiguard.conf.default`](config/akiguard.conf.default))

## How it works
- `akiguard daemon` (C, runs as root via launchd) reads the config and battery level every 15 seconds and writes the SMC keys your Mac supports.
- `AkiGuard.app` (Swift, menu bar) only edits the config file, so you don't need a password each time you change a setting.

```
src/
  smc.c / smc.h      AppleSMC access via IOKit
  akiguard.c         daemon + CLI
  main.swift         menu bar app
  pro_stub.c, ProStub.swift   placeholders for Pro-only features
install.sh / uninstall.sh
```

## Uninstall
```bash
./uninstall.sh
```
Stops the service and restores normal charging (charging on, `BCLM` 100%).

## License
MIT — see [LICENSE](LICENSE). Pro-only features are not part of this repository.
