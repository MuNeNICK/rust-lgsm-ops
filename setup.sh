#!/bin/bash
# Setup helper for system-level systemd units used to operate a Rust server installed via LinuxGSM.
# Generates services/timers for monitor, restart (with optional update), warnings, wipe, info, and update-check.
set -euo pipefail

# Defaults: use SUDO_USER if present, otherwise current user; base is parent of this script directory
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
invoking_user="${SUDO_USER:-$(id -un)}"
default_base="$(cd "${script_dir}/.." && pwd)"

# Default params
YES=""
RUN_USER="${invoking_user}"
BASE_DIR="${default_base}"
TZ_NAME="Asia/Tokyo"
MONITOR_BOOT_DELAY="1min"
MONITOR_INTERVAL="5min"
RESTART_TIME="07:00"
RESTART_WARN_TIME="06:30"
RESTART_WARN_MSG="[WARNING] Server will restart soon"
WIPE_MODE="full" # or map
WIPE_DAY="Wed"
WIPE_TIME="19:30"
WIPE_WARN_TIME="19:20"
WIPE_WARN_MSG="[WARNING] Server will wipe in 30 minutes"
INFO_INTERVAL_H="2"
UPDATE_CHECK_TIME="06:45"
CONFIG_FILE=""
ENABLE_MONITOR=1
ENABLE_RESTART=1
ENABLE_RESTART_WARNING=1
ENABLE_WIPE=1
ENABLE_WIPE_WARNING=1
ENABLE_INFO=1
ENABLE_UPDATE_CHECK=1

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --base) BASE_DIR="$2"; shift ;;
    --user) RUN_USER="$2"; shift ;;
    --tz) TZ_NAME="$2"; shift ;;
    --restart-time) RESTART_TIME="$2"; shift ;;
    --restart-warn-time) RESTART_WARN_TIME="$2"; shift ;;
    --restart-warn-msg) RESTART_WARN_MSG="$2"; shift ;;
    --wipe-mode) WIPE_MODE="$2"; shift ;;
    --wipe-day) WIPE_DAY="$2"; shift ;;
    --wipe-time) WIPE_TIME="$2"; shift ;;
    --wipe-warn-time) WIPE_WARN_TIME="$2"; shift ;;
    --wipe-warn-msg) WIPE_WARN_MSG="$2"; shift ;;
    --info-interval) INFO_INTERVAL_H="$2"; shift ;;
    --update-check-time) UPDATE_CHECK_TIME="$2"; shift ;;
    --config) CONFIG_FILE="$2"; shift ;;
    --enable)
      IFS=',' read -ra arr <<< "$2"
      for f in monitor restart restart-warning wipe wipe-warning info update-check; do
        eval "ENABLE_${f^^//-/_}=0"
      done
      for item in "${arr[@]}"; do
        key="${item//-/_}"
        case "$key" in
          monitor) ENABLE_MONITOR=1 ;;
          restart) ENABLE_RESTART=1 ;;
          restart_warning) ENABLE_RESTART_WARNING=1 ;;
          wipe) ENABLE_WIPE=1 ;;
          wipe_warning) ENABLE_WIPE_WARNING=1 ;;
          info) ENABLE_INFO=1 ;;
          update_check) ENABLE_UPDATE_CHECK=1 ;;
          *) echo "Unknown feature in --enable: $item" >&2; exit 1 ;;
        esac
      done
      shift
      ;;
    --disable)
      IFS=',' read -ra arr <<< "$2"
      for item in "${arr[@]}"; do
        key="${item//-/_}"
        case "$key" in
          monitor) ENABLE_MONITOR=0 ;;
          restart) ENABLE_RESTART=0 ;;
          restart_warning) ENABLE_RESTART_WARNING=0 ;;
          wipe) ENABLE_WIPE=0 ;;
          wipe_warning) ENABLE_WIPE_WARNING=0 ;;
          info) ENABLE_INFO=0 ;;
          update_check) ENABLE_UPDATE_CHECK=0 ;;
          *) echo "Unknown feature in --disable: $item" >&2; exit 1 ;;
        esac
      done
      shift
      ;;
    --help)
      echo "Usage: sudo ./setup.sh [--yes] [--base PATH] [--user USER] [--tz TZ] [--restart-time HH:MM] [--restart-warn-time HH:MM] [--restart-warn-msg MSG] [--wipe-mode full|map] [--wipe-day Wed] [--wipe-time HH:MM] [--wipe-warn-time HH:MM] [--wipe-warn-msg MSG] [--info-interval HOURS] [--update-check-time HH:MM] [--config FILE] [--enable feature1,feature2] [--disable feature1,feature2]"
      echo "Features: monitor,restart,restart-warning,wipe,wipe-warning,info,update-check"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root (system units)." >&2
  exit 1
fi

prompt() {
  local var="$1" prompt_text="$2" default="$3"
  if [ -n "$YES" ]; then
    echo "$var=${!var}"
    return
  fi
  read -r -p "$prompt_text [$default]: " reply || true
  if [ -n "$reply" ]; then
    printf -v "$var" '%s' "$reply"
  else
    printf -v "$var" '%s' "$default"
  fi
}

prompt_yesno() {
  local var="$1" prompt_text="$2" default="$3" # default Y/N
  if [ -n "$YES" ]; then
    echo "$var=${!var}"
    return
  fi
  local suffix="[Y/n]"
  if [ "$default" = "N" ]; then suffix="[y/N]"; fi
  read -r -p "${prompt_text} ${suffix}: " reply || true
  if [ -z "$reply" ]; then reply="$default"; fi
  case "$reply" in
    Y|y|yes) printf -v "$var" '%s' "1" ;;
    N|n|no)  printf -v "$var" '%s' "0" ;;
    *) printf -v "$var" '%s' "$default" ;;
  esac
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

extract_cfg() {
  local key="$1" file="$2"
  sed -n "s/^${key}=\"\\(.*\\)\"/\\1/p" "$file" | head -n1
}

ensure_mcrcon() {
  local dest="$1"
  if [ -x "$dest" ]; then return; fi
  mkdir -p "$(dirname "$dest")"
  local url="https://github.com/Tiiffi/mcrcon/releases/download/v0.7.1/mcrcon-0.7.1-linux-x86-64.tar.gz"
  echo "Downloading mcrcon from ${url}"
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' RETURN
  curl -fsSL "$url" | tar -xz -C "$tmpdir"
  local src
  src="$(find "$tmpdir" -type f -name mcrcon | head -n1 || true)"
  if [ -z "$src" ]; then
    echo "Failed to find mcrcon in archive" >&2
    exit 1
  fi
  mv "$src" "$dest"
  chmod +x "$dest"
}

write_file() { local path="$1" content="$2"; echo "$content" > "$path"; }

main() {
  require_cmd curl

  prompt RUN_USER "Run as user" "$RUN_USER"
  prompt BASE_DIR "Rust base dir" "$BASE_DIR"
  prompt TZ_NAME "Timezone (TZ database name)" "$TZ_NAME"

  # Feature toggles and their settings inline
  prompt_yesno ENABLE_MONITOR "Enable monitor" "${ENABLE_MONITOR}"
  if [ "$ENABLE_MONITOR" -eq 1 ]; then
    prompt MONITOR_BOOT_DELAY "Monitor start delay (OnBootSec)" "$MONITOR_BOOT_DELAY"
    prompt MONITOR_INTERVAL "Monitor interval (OnUnitActiveSec)" "$MONITOR_INTERVAL"
  fi

  prompt_yesno ENABLE_RESTART "Enable restart (with update)" "${ENABLE_RESTART}"
  if [ "$ENABLE_RESTART" -eq 1 ]; then
    prompt RESTART_TIME "Daily restart time (HH:MM)" "$RESTART_TIME"
  fi

  prompt_yesno ENABLE_RESTART_WARNING "Enable restart warning" "${ENABLE_RESTART_WARNING}"
  if [ "$ENABLE_RESTART_WARNING" -eq 1 ]; then
    prompt RESTART_WARN_TIME "Restart warning time (HH:MM)" "$RESTART_WARN_TIME"
    prompt RESTART_WARN_MSG "Restart warning message" "$RESTART_WARN_MSG"
  fi

  prompt_yesno ENABLE_WIPE "Enable wipe" "${ENABLE_WIPE}"
  if [ "$ENABLE_WIPE" -eq 1 ]; then
    prompt WIPE_MODE "Wipe mode (full/map)" "$WIPE_MODE"
    prompt WIPE_DAY "Wipe weekday (Mon..Sun)" "$WIPE_DAY"
    prompt WIPE_TIME "Wipe time (HH:MM)" "$WIPE_TIME"
  fi

  prompt_yesno ENABLE_WIPE_WARNING "Enable wipe warning" "${ENABLE_WIPE_WARNING}"
  if [ "$ENABLE_WIPE_WARNING" -eq 1 ]; then
    prompt WIPE_WARN_TIME "Wipe warning time (HH:MM)" "$WIPE_WARN_TIME"
    prompt WIPE_WARN_MSG "Wipe warning message" "$WIPE_WARN_MSG"
  fi

  prompt_yesno ENABLE_INFO "Enable wipe-info message" "${ENABLE_INFO}"
  if [ "$ENABLE_INFO" -eq 1 ]; then
    prompt INFO_INTERVAL_H "Wipe info interval hours" "$INFO_INTERVAL_H"
  fi

  prompt_yesno ENABLE_UPDATE_CHECK "Enable update-check" "${ENABLE_UPDATE_CHECK}"
  if [ "$ENABLE_UPDATE_CHECK" -eq 1 ]; then
    prompt UPDATE_CHECK_TIME "Update-check time (HH:MM)" "$UPDATE_CHECK_TIME"
  fi

  if [ ! -d "$BASE_DIR" ]; then
    echo "Base dir not found: $BASE_DIR" >&2
    exit 1
  fi

  local cfg="${CONFIG_FILE:-${BASE_DIR}/lgsm/config-lgsm/rustserver/rustserver.cfg}"
  if [ ! -f "$cfg" ]; then
    echo "Config not found: $cfg" >&2
    echo "Please re-run with the correct base dir (e.g. --base /home/<user>/rustserver) or --config <path>." >&2
    exit 1
  fi

  local rcon_host rcon_port rcon_pass
  rcon_host="$(extract_cfg ip "$cfg")"
  rcon_port="$(extract_cfg rconport "$cfg")"
  rcon_pass="$(extract_cfg rconpassword "$cfg")"
  # If ip is 0.0.0.0 (common in LGSM), prefer loopback for RCON client connections.
  if [ "$rcon_host" = "0.0.0.0" ] || [ -z "$rcon_host" ]; then
    rcon_host="127.0.0.1"
  fi
  if [ -z "$rcon_host" ] || [ -z "$rcon_port" ] || [ -z "$rcon_pass" ]; then
    echo "Failed to extract RCON settings from $cfg" >&2
    exit 1
  fi

  local bin_dir="$BASE_DIR/rust-lgsm-systemd-ops/bin"
  local helper_dir="$bin_dir"
  local mcrcon_bin="$bin_dir/mcrcon"
  ensure_mcrcon "$mcrcon_bin"

  mkdir -p "$bin_dir"
  cat > "$bin_dir/send-rcon.sh" <<'EOSH'
#!/bin/bash
set -euo pipefail
msg="$*"
host="${RCON_HOST:-127.0.0.1}"
port="${RCON_PORT:-28025}"
pass="${RCON_PASS:?RCON_PASS is required}"
exec "$(dirname "$0")/mcrcon" -H "$host" -P "$port" -p "$pass" "say $msg"
EOSH
  chmod +x "$bin_dir/send-rcon.sh"

  cat > "$helper_dir/scheduled-restart-with-update.sh" <<'EOSH'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[scheduled-restart] checking for updates..."
if ./rustserver check-update | tee /tmp/rust-check-update.log | grep -qi "update available"; then
  echo "[scheduled-restart] update available -> running update"
  ./rustserver update
else
  echo "[scheduled-restart] no update available -> skipping update"
fi

echo "[scheduled-restart] restarting server"
./rustserver restart
echo "[scheduled-restart] done"
EOSH
  chmod +x "$helper_dir/scheduled-restart-with-update.sh"

  cat > "$helper_dir/next-wipe-date.sh" <<'EOSH'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

current_day=$(date +"%u")
if [ "$current_day" -eq 3 ]; then
  wipe_date=$(date +"%Y-%m-%d")
else
  wipe_date=$(date -d "next Wednesday" +"%Y-%m-%d")
fi

msg="[INFO] Next wipe is Wednesday (${wipe_date}) at 20:00 JST (11:00 UTC)"
RCON_PASS="${RCON_PASS:?RCON_PASS is required}" \
RCON_HOST="${RCON_HOST:-127.0.0.1}" \
RCON_PORT="${RCON_PORT:-28025}" \
"$(dirname "$0")/send-rcon.sh" "$msg"
EOSH
  chmod +x "$helper_dir/next-wipe-date.sh"

  local unit_dir="/etc/systemd/system"

  if [ "$ENABLE_MONITOR" -eq 1 ]; then
    write_file "$unit_dir/rust-monitor.service" "[Unit]
Description=Rust Server Monitor
After=network.target

[Service]
Type=forking
User=${RUN_USER}
WorkingDirectory=${BASE_DIR}
ExecStart=${BASE_DIR}/rustserver monitor

[Install]
WantedBy=multi-user.target"

  write_file "$unit_dir/rust-monitor.timer" "[Unit]
Description=Run Rust Server Monitor
After=network.target

[Timer]
OnBootSec=${MONITOR_BOOT_DELAY}
OnUnitActiveSec=${MONITOR_INTERVAL}
Unit=rust-monitor.service

[Install]
WantedBy=timers.target"
  fi

  if [ "$ENABLE_RESTART" -eq 1 ]; then
    write_file "$unit_dir/rust-restart.service" "[Unit]
Description=Rust Server Restart (with update)
After=network.target

[Service]
Type=oneshot
User=${RUN_USER}
WorkingDirectory=${BASE_DIR}
ExecStart=${BASE_DIR}/rust-lgsm-systemd-ops/bin/scheduled-restart-with-update.sh

[Install]
WantedBy=multi-user.target"

    write_file "$unit_dir/rust-restart.timer" "[Unit]
Description=Run Rust Server Restart daily at ${RESTART_TIME} ${TZ_NAME}
After=network.target

[Timer]
OnCalendar=*-*-* ${RESTART_TIME}:00 ${TZ_NAME}
Persistent=true
Unit=rust-restart.service

[Install]
WantedBy=timers.target"
  fi

  if [ "$ENABLE_RESTART_WARNING" -eq 1 ]; then
    write_file "$unit_dir/rust-restart-warning.service" "[Unit]
Description=Rust Server Restart Warning
After=network.target

[Service]
Type=oneshot
User=${RUN_USER}
WorkingDirectory=${BASE_DIR}
Environment=RCON_HOST=${rcon_host}
Environment=RCON_PORT=${rcon_port}
Environment=RCON_PASS=${rcon_pass}
ExecStart=${bin_dir}/send-rcon.sh \"${RESTART_WARN_MSG}\"

[Install]
WantedBy=multi-user.target"

    write_file "$unit_dir/rust-restart-warning.timer" "[Unit]
Description=Run Rust Server Restart Warning
After=network.target

[Timer]
OnCalendar=*-*-* ${RESTART_WARN_TIME}:00 ${TZ_NAME}
Unit=rust-restart-warning.service

[Install]
WantedBy=timers.target"
  fi

  if [ "$ENABLE_WIPE" -eq 1 ]; then
    write_file "$unit_dir/rust-wipe.service" "[Unit]
Description=Rust Server ${WIPE_MODE^} Wipe
After=network.target

[Service]
Type=forking
User=${RUN_USER}
WorkingDirectory=${BASE_DIR}
ExecStart=${BASE_DIR}/rustserver ${WIPE_MODE}-wipe

[Install]
WantedBy=multi-user.target"

    write_file "$unit_dir/rust-wipe.timer" "[Unit]
Description=Run Rust Server ${WIPE_MODE^} Wipe on ${WIPE_DAY}s at ${WIPE_TIME} ${TZ_NAME}
After=network.target

[Timer]
OnCalendar=${WIPE_DAY} *-*-* ${WIPE_TIME}:00 ${TZ_NAME}
Unit=rust-wipe.service

[Install]
WantedBy=timers.target"
  fi

  if [ "$ENABLE_WIPE_WARNING" -eq 1 ]; then
    write_file "$unit_dir/rust-wipe-warning.service" "[Unit]
Description=Rust Server ${WIPE_MODE^} Wipe Warning
After=network.target

[Service]
Type=oneshot
User=${RUN_USER}
WorkingDirectory=${BASE_DIR}
Environment=RCON_HOST=${rcon_host}
Environment=RCON_PORT=${rcon_port}
Environment=RCON_PASS=${rcon_pass}
ExecStart=${bin_dir}/send-rcon.sh \"${WIPE_WARN_MSG}\"

[Install]
WantedBy=multi-user.target"

    write_file "$unit_dir/rust-wipe-warning.timer" "[Unit]
Description=Run Rust Server ${WIPE_MODE^} Wipe Warning on ${WIPE_DAY}s at ${WIPE_WARN_TIME} ${TZ_NAME}
After=network.target

[Timer]
OnCalendar=${WIPE_DAY} *-*-* ${WIPE_WARN_TIME}:00 ${TZ_NAME}
Unit=rust-wipe-warning.service

[Install]
WantedBy=timers.target"
  fi

  if [ "$ENABLE_INFO" -eq 1 ]; then
    write_file "$unit_dir/rust-wipe-info.service" "[Unit]
Description=Rust Server Wipe Info Message
After=network.target

[Service]
Type=oneshot
User=${RUN_USER}
WorkingDirectory=${BASE_DIR}
Environment=RCON_HOST=${rcon_host}
Environment=RCON_PORT=${rcon_port}
Environment=RCON_PASS=${rcon_pass}
ExecStart=${BASE_DIR}/rust-lgsm-systemd-ops/bin/next-wipe-date.sh

[Install]
WantedBy=multi-user.target"

    write_file "$unit_dir/rust-wipe-info.timer" "[Unit]
Description=Run Rust Server Wipe Info Message every ${INFO_INTERVAL_H}h
After=network.target

[Timer]
OnCalendar=*-*-* 00/${INFO_INTERVAL_H}:00:00 ${TZ_NAME}
Unit=rust-wipe-info.service

[Install]
WantedBy=timers.target"
  fi

  if [ "$ENABLE_UPDATE_CHECK" -eq 1 ]; then
    write_file "$unit_dir/rust-update-check.service" "[Unit]
Description=Rust Server Update Check
After=network.target

[Service]
Type=oneshot
User=${RUN_USER}
WorkingDirectory=${BASE_DIR}
ExecStart=${BASE_DIR}/rustserver check-update

[Install]
WantedBy=multi-user.target"

    write_file "$unit_dir/rust-update-check.timer" "[Unit]
Description=Run Rust Server Update Check daily at ${UPDATE_CHECK_TIME} ${TZ_NAME}
After=network.target

[Timer]
OnCalendar=*-*-* ${UPDATE_CHECK_TIME}:00 ${TZ_NAME}
Persistent=true
Unit=rust-update-check.service

[Install]
WantedBy=timers.target"
  fi

  echo "Reloading systemd and enabling timers..."
  systemctl daemon-reload
  enable_list=()
  [ "$ENABLE_MONITOR" -eq 1 ] && enable_list+=("rust-monitor.timer")
  [ "$ENABLE_RESTART" -eq 1 ] && enable_list+=("rust-restart.timer")
  [ "$ENABLE_RESTART_WARNING" -eq 1 ] && enable_list+=("rust-restart-warning.timer")
  [ "$ENABLE_WIPE" -eq 1 ] && enable_list+=("rust-wipe.timer")
  [ "$ENABLE_WIPE_WARNING" -eq 1 ] && enable_list+=("rust-wipe-warning.timer")
  [ "$ENABLE_INFO" -eq 1 ] && enable_list+=("rust-wipe-info.timer")
  [ "$ENABLE_UPDATE_CHECK" -eq 1 ] && enable_list+=("rust-update-check.timer")
  if [ "${#enable_list[@]}" -gt 0 ]; then
    systemctl enable --now "${enable_list[@]}"
  else
    echo "No timers selected; units installed but not enabled."
  fi

  echo "Done. Current timers:"
  systemctl list-timers --all | grep rust || true
  echo "To check later: sudo systemctl list-timers --all | grep rust"
}

main "$@"
