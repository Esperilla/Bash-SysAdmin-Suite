#!/bin/bash
set -euo pipefail
source "${0%/*}"/messages.sh
###############################################################################
# monitoring.sh
# Monitors CPU and disk usage, records readings and alerts via Telegram
# based on configurable thresholds passed as arguments or in `config.txt`.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/automated_gestion.log}"
CURL_BIN="${CURL_BIN:-curl}"

# Alert thresholds and monitoring parameters (overridable by arguments or config.txt).
CPU_THRESHOLD_DEFAULT=70
DISK_THRESHOLD_DEFAULT=70
INTERVAL=60
RUN_ONCE=1
CPU_THRESHOLD=${CPU_THRESHOLD_DEFAULT}
DISK_THRESHOLD=${DISK_THRESHOLD_DEFAULT}
DISK_PATHS="/"

# Try to locate config.txt relative to the script; if it does not exist, use the current directory.
if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  error_message "config.txt was not found, create $CONFIG_FILE"
  exit 1
fi

# Load configuration.
source "$CONFIG_FILE"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ "$TELEGRAM_BOT_TOKEN" = "REPLACE_WITH_BOT_TOKEN" ]; then
  warning_message "ATTENTION: TELEGRAM_BOT_TOKEN is not configured in $CONFIG_FILE"
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ] || [ "$TELEGRAM_CHAT_ID" = "REPLACE_WITH_CHAT_ID" ]; then
  warning_message "ATTENTION: TELEGRAM_CHAT_ID is not configured in $CONFIG_FILE"
fi

# Initialize the log file creating the directory if needed.
log_init() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
  touch "$LOG_FILE" || true
}

# Register events with ISO-8601 timestamp.
log_msg() {
  log_init
  local ts msg
  ts="$(date --iso-8601=seconds)"
  msg="$1"
  echo "$ts - $msg" >> "$LOG_FILE"
  info_message "$ts - $msg"
}

# Send notifications to Telegram; if no configuration exists, only leave log traces.
send_telegram() {
  local text="$1"
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    log_msg "ERROR: curl is not available to notify: $text"
    return 1
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_msg "WARNING: Telegram is not configured; notification will not be sent: $text"
    return 1
  fi
  "$CURL_BIN" -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$text" >/dev/null 2>&1 || true
}

# Display available command-line options.
usage() {
  cat <<EOF
Usage: $0 [--cpu N] [--disk N] [--paths "/ /home"] [--interval S] [--once]
  --cpu N       CPU threshold (%) (default $CPU_THRESHOLD_DEFAULT)
  --disk N      Disk threshold (%) (default $DISK_THRESHOLD_DEFAULT)
  --paths P1,P2 paths to check (default: /)
  --interval S  interval in seconds for periodic reads (default $INTERVAL)
  --once        run once and exit (default)
  --help        show this help
EOF
}

# Process command-line arguments to override default values.
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --cpu)
        CPU_THRESHOLD="$2"; shift 2 ;;
      --disk)
        DISK_THRESHOLD="$2"; shift 2 ;;
      --paths)
        DISK_PATHS="$2"; shift 2 ;;
      --interval)
        INTERVAL="$2"; RUN_ONCE=0; shift 2 ;;
      --once)
        RUN_ONCE=1; shift 1 ;;
      --help|-h)
        usage; exit 0 ;;
      *) warning_message "Invalid option: $1"; usage; exit 1 ;;
    esac
  done
}

# Calculates CPU usage percentage using /proc/stat over a 1-second interval.
cpu_usage_percent() {
  local prev total1 idle1 next total2 idle2 diff_total diff_idle busy pct
  read -r _ prev < <(awk '/^cpu /{print $0}' /proc/stat)
  total1=0; idle1=0
  for v in $prev; do total1=$((total1+v)); done
  idle1=$(echo $prev | awk '{print $4}')
  sleep 1
  read -r _ next < <(awk '/^cpu /{print $0}' /proc/stat)
  total2=0; idle2=0
  for v in $next; do total2=$((total2+v)); done
  idle2=$(echo $next | awk '{print $4}')
  diff_total=$((total2 - total1))
  diff_idle=$((idle2 - idle1))
  busy=$((diff_total - diff_idle))
  if [ $diff_total -le 0 ]; then
    echo 0
    return
  fi
  pct=$((100 * busy / diff_total))
  echo "$pct"
}

# Gets the used disk percentage for a given path.
disk_usage_percent() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo "0"
    return
  fi
  df -P "$path" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo 0
}

# Performs a CPU and disk reading and alerts if thresholds are exceeded.
check_once() {
  local cpu disk pct_cpu pct_disk msg
  pct_cpu=$(cpu_usage_percent)
  msg="CPU: ${pct_cpu}%"
  log_msg "READING: $msg"
  if [ "$pct_cpu" -ge "$CPU_THRESHOLD" ]; then
    send_telegram "[Monitoring.sh] CPU alert: ${pct_cpu}% >= ${CPU_THRESHOLD}%"
    log_msg "ALERT: CPU ${pct_cpu}% >= ${CPU_THRESHOLD}%"
  fi

  IFS=',' read -ra paths <<<"$DISK_PATHS"
  for p in "${paths[@]}"; do
    pct_disk=$(disk_usage_percent "$p")
    log_msg "READING: Disk($p): ${pct_disk}%"
    if [ "$pct_disk" -ge "$DISK_THRESHOLD" ]; then
      send_telegram "[Monitoring.sh] Disk alert $p: ${pct_disk}% >= ${DISK_THRESHOLD}%"
      log_msg "ALERT: Disk($p) ${pct_disk}% >= ${DISK_THRESHOLD}%"
    fi
  done
}

# Allows clean exit with Ctrl+C or termination signals.
trap 'echo; log_msg "Interrupted by signal. Exiting."; exit 0' SIGINT SIGTERM

# Entry point: process arguments and run monitoring once or in a loop.
main() {
  parse_args "$@"

  if ! [[ "$CPU_THRESHOLD" =~ ^[0-9]+$ ]]; then error_message "CPU threshold is invalid"; exit 1; fi
  if ! [[ "$DISK_THRESHOLD" =~ ^[0-9]+$ ]]; then error_message "DISK threshold is invalid"; exit 1; fi

  if [ "$RUN_ONCE" -eq 1 ]; then
    check_once
    exit 0
  fi

  while true; do
    check_once
    sleep "$INTERVAL"
  done
}

main "$@"