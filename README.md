# Rust LGSM systemd ops helper

System-level systemd service/timer generator for a Rust server managed by LinuxGSM. It automates routine ops (monitoring, scheduled restart with optional update, wipe schedule, wipe warnings, wipe info message, update-check) without hand-writing unit files.

- Installs units into `/etc/systemd/system/` (root required)
- Uses direct RCON (reads `lgsm/config-lgsm/rustserver/rustserver.cfg` for RCON host/port/password)
- Helpers (mcrcon, notifier, restart-with-update, wipe-info) live under `bin/` and are generated if missing
- Feature toggles per function; prompts or CLI flags control which timers to enable

## Requirements
- Run as root (`sudo ./setup.sh`)
- Rust server installed via LinuxGSM; config at `lgsm/config-lgsm/rustserver/rustserver.cfg`
- Network access to download `mcrcon` (once)

## Features
- monitor: runs `rustserver monitor` on a fixed schedule (OnBootSec/OnUnitActiveSec). Confirms server status and restarts if crashed (LGSM behavior).
- restart: daily restart with update (`check-update` → `update` → `restart`).
- restart-warning: RCON say before restart at a configured time.
- wipe: weekly wipe (full or map) on chosen weekday/time (`rustserver full-wipe` or `map-wipe`).
- wipe-warning: RCON say before the wipe at a configured time.
- wipe-info: periodic RCON say with next wipe date/time (auto-computes next Wednesday by default; adjust script if you change wipe day).
- update-check: daily `rustserver check-update`.

### What each prompt/configures
- Run as user / Rust base dir / TZ: sets `User=` and `WorkingDirectory=` in units; OnCalendar uses the TZ.
- monitor: start delay (OnBootSec) and interval (OnUnitActiveSec).
- restart: daily time (HH:MM).
- restart-warning: warning time (HH:MM) and message.
- wipe: mode (full/map), weekday, time.
- wipe-warning: warning time (HH:MM) and message.
- wipe-info: interval hours (e.g., `2` = every 2h) for the “next wipe” message.
- update-check: daily time (HH:MM).

## Quick start (interactive)
```bash
cd /home/rust-admin/rustserver/rust-lgsm-systemd-ops
chmod +x setup.sh
sudo ./setup.sh
```
- Defaults: user = sudo caller (`$SUDO_USER` if set), base dir = script parent (`/home/.../rustserver`), TZ = Asia/Tokyo
- Prompts ask which features to enable and their schedules/messages

## Quick start (non-interactive example)
```bash
sudo YES=1 ./setup.sh \
  --base /home/rust-admin/rustserver \
  --user rust-admin \
  --tz Asia/Tokyo \
  --monitor-boot 1min --monitor-interval 5min \
  --restart-time 07:00 --restart-warn-time 06:30 --restart-warn-msg "[WARN] Restart soon" \
  --wipe-mode full --wipe-day Wed --wipe-time 19:30 \
  --wipe-warn-time 19:20 --wipe-warn-msg "[WARN] Wipe in 30 minutes" \
  --info-interval 2 \
  --update-check-time 06:45 \
  --disable restart-warning,wipe-warning  # optional
```

### Feature flags
- `--enable monitor,restart,...` : only listed features enabled, others disabled
- `--disable monitor,...` : disable listed features
- Features: `monitor,restart,restart-warning,wipe,wipe-warning,wipe-info,update-check`

### Prompts
- Runs as user / Rust base dir / TZ
- For each enabled feature, asks for schedule/message (monitor intervals, restart time, warnings, wipe mode/day/time, info interval, update-check time)

### Outputs
- Systemd units in `/etc/systemd/system/`: `rust-*.service` / `rust-*.timer`
- Helper scripts in `bin/`: `mcrcon`, `send-rcon.sh`, `scheduled-restart-with-update.sh`, `next-wipe-date.sh`
- Timers are enabled/started unless you disabled all
- At the end shows current timers and a reminder: `sudo systemctl list-timers --all | grep rust`

## Uninstall
```bash
sudo ./uninstall.sh           # interactive (choose features to remove)
# Remove everything non-interactively
sudo YES=1 ./uninstall.sh --all
```
- Supports `--enable/--disable` to select features to remove (same feature names as setup)
- Disables timers/services, removes unit files, reloads systemd
- Shows remaining timers and reminder command

## Notes / tips
- If you rerun `setup.sh`, units and helper scripts are overwritten with new settings.
- If you change RCON password/port in LGSM config, rerun `setup.sh` so services pick up new env.
- For different timezones, set `--tz <TZ>` (e.g., `UTC` or `Europe/Berlin`).
- If you don't want update-before-restart, run `setup.sh` and disable `restart` or replace the helper script with a plain restart.
- To inspect logs: `journalctl -u rust-monitor.service` (system scope)

## Included files
- `setup.sh` : installer/generator for systemd units
- `uninstall.sh` : disable/remove selected units
- `bin/` : helper binaries/scripts (generated)
- `.gitignore` : ignores `bin/` and generated helpers
