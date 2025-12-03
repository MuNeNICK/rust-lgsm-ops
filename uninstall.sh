#!/bin/bash
# Uninstall helper: disable and remove system-level systemd units for Rust LGSM ops.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must run as root (system units)." >&2
  exit 1
fi

YES="${YES:-}"
REMOVE_ALL=0
ENABLE_MONITOR=1
ENABLE_RESTART=1
ENABLE_RESTART_WARNING=1
ENABLE_WIPE=1
ENABLE_WIPE_WARNING=1
ENABLE_INFO=1
ENABLE_UPDATE_CHECK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --all) REMOVE_ALL=1 ;;
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
      echo "Usage: sudo ./uninstall.sh [--yes] [--all] [--enable feature1,feature2] [--disable feature1,feature2]"
      echo "Features: monitor,restart,restart-warning,wipe,wipe-warning,info,update-check"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

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

if [ "$REMOVE_ALL" -eq 1 ] && [ -z "$YES" ]; then
  echo "REMOVE_ALL is set; proceeding without prompts."
  YES=1
fi

if [ -z "$YES" ] && [ "$REMOVE_ALL" -ne 1 ]; then
  prompt_yesno ENABLE_MONITOR "Remove monitor" "Y"
  prompt_yesno ENABLE_RESTART "Remove restart" "Y"
  prompt_yesno ENABLE_RESTART_WARNING "Remove restart-warning" "Y"
  prompt_yesno ENABLE_WIPE "Remove wipe" "Y"
  prompt_yesno ENABLE_WIPE_WARNING "Remove wipe-warning" "Y"
  prompt_yesno ENABLE_INFO "Remove wipe-info" "Y"
  prompt_yesno ENABLE_UPDATE_CHECK "Remove update-check" "Y"
fi

units=()
[ "$ENABLE_MONITOR" -eq 1 ] && units+=("rust-monitor.timer" "rust-monitor.service")
[ "$ENABLE_RESTART" -eq 1 ] && units+=("rust-restart.timer" "rust-restart.service")
[ "$ENABLE_RESTART_WARNING" -eq 1 ] && units+=("rust-restart-warning.timer" "rust-restart-warning.service")
[ "$ENABLE_WIPE" -eq 1 ] && units+=("rust-wipe.timer" "rust-wipe.service")
[ "$ENABLE_WIPE_WARNING" -eq 1 ] && units+=("rust-wipe-warning.timer" "rust-wipe-warning.service")
[ "$ENABLE_INFO" -eq 1 ] && units+=("rust-wipe-info.timer" "rust-wipe-info.service")
[ "$ENABLE_UPDATE_CHECK" -eq 1 ] && units+=("rust-update-check.timer" "rust-update-check.service")

if [ "${#units[@]}" -eq 0 ]; then
  echo "Nothing selected to remove."
  exit 0
fi

echo "Disabling units..."
systemctl disable --now "${units[@]}" 2>/dev/null || true

echo "Removing unit files..."
for u in "${units[@]}"; do
  rm -f "/etc/systemd/system/${u}"
done

systemctl daemon-reload

echo "Done. Remaining rust timers:"
systemctl list-timers --all | grep rust || true
echo "To check later: sudo systemctl list-timers --all | grep rust"
