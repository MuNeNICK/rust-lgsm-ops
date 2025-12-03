# Rust LGSM systemd ops helper

Automates system-level (not user-level) systemd services/timers for a Rust server installed via LinuxGSM. Focus: routine ops (monitoring, scheduled restarts with optional updates, wipe schedules, info messages, update-check) without hand-editing unit files.

## What it generates
- monitor / restart (with update) / restart-warning / wipe (full or map) / wipe-warning / wipe-info message / update-check
- Restart flow can run `check-update`, then `update`, then `restart`
- Timezone, times, weekday, messages, base path, and run user are configurable (prompts with defaults)
- Installs units into `/etc/systemd/system/` and enables timers via `systemctl`

## Quick start
```bash
cd /home/rust-admin/rustserver/rust-lgsm-systemd-ops
chmod +x setup.sh
sudo ./setup.sh          # interactive (defaults: current user, current dir)
# Non-interactive example:
sudo ./setup.sh --yes \
  --base /home/rust-admin/rustserver \
  --user rust-admin \
  --tz Asia/Tokyo \
  --restart-time 07:00 --restart-warn-time 06:30 \
  --wipe-day Wed --wipe-time 19:30 --wipe-warn-time 19:20 --wipe-mode full \
  --info-interval 2 \
  --update-check-time 06:45
```

Units go to `/etc/systemd/system/`. Check schedules: `systemctl list-timers --all`.

## Uninstall (disable/remove units)
```bash
cd /home/rust-admin/rustserver/rust-lgsm-systemd-ops
sudo ./uninstall.sh           # interactive (choose features to remove)
# non-interactive example: remove all
sudo YES=1 ./uninstall.sh --all
```

## Notes
- Requires root to install system units. `--user` and `--base` default to the invoking user and current directory if not provided.
- Uses direct RCON via credentials read from `lgsm/config-lgsm/rustserver/rustserver.cfg`.
- Assumes `next-wipe-date.sh` and `scheduled-restart-with-update.sh` will be placed under the base dir; the setup script creates them if missing.
