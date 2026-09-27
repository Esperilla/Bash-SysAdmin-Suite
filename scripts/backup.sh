#!/bin/bash
set -euo pipefail
source "${0%/*}"/messages.sh
###############################################################################
# backup.sh
# Script to compress one or more directories with tar, verify the backup,
# notify via Telegram, and log the result in the system log.
# It also allows scheduling periodic execution with cron for the current user,
# without requiring root privileges.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/automated_gestion.log}"
CURL_BIN="${CURL_BIN:-curl}"
               
# Default backup parameters; they can be overridden from config.txt or the environment.
BACKUP_PREFIX="${BACKUP_PREFIX:-backup}"
BACKUP_DEST_DIR="${BACKUP_DEST_DIR:-$HOME/backups}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

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

# Record events with ISO-8601 timestamp.
log_msg() {
  log_init
  local ts msg
  ts="$(date --iso-8601=seconds)"
  msg="$1"
  echo "$ts - $msg" >> "$LOG_FILE"
}

# Send notifications to Telegram; if no configuration exists, only leave a log trace.
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

# Convert the backup source list into a Bash array.
parse_sources() {
  local raw_sources="${BACKUP_SOURCE_DIRS:-}"
  if [ -z "$raw_sources" ]; then
    return 1
  fi
  BACKUP_SOURCES=( $raw_sources )
}

# Verify that sources are defined and all exist before compressing.
validate_sources() {
  local src
  if ! parse_sources; then
    warning_message "BACKUP_SOURCE_DIRS is empty in config.txt"
    return 1
  fi
  for src in "${BACKUP_SOURCES[@]}"; do
    if [ ! -d "$src" ]; then
      warning_message "Directory does not exist: $src"
      return 1
    fi
  done
}

# Generate the compressed archive, validate that it exists, and log the result.
do_backup() {
  local ts archive archive_size
  if ! validate_sources; then
    log_msg "BACKUP FAILED: invalid directories"
    return 1
  fi

  mkdir -p "$BACKUP_DEST_DIR"
  ts="$(date +%Y%m%d_%H%M%S)"
  archive="$BACKUP_DEST_DIR/${BACKUP_PREFIX}_${ts}.tar.gz"

  if tar -czf "$archive" -P "${BACKUP_SOURCES[@]}"; then
    if [ -f "$archive" ] && [ -s "$archive" ]; then
      archive_size="$(du -h "$archive" | awk '{print $1}')"
      local msg="Backup created: $archive | Size: $archive_size | Date: $(date --iso-8601=seconds)"
      success_message "$msg"
      log_msg "$msg"
      send_telegram "[Backup.sh] $msg"
      return 0
    fi
  fi

  rm -f "$archive" 2>/dev/null || true
  log_msg "BACKUP FAILED: no valid archive was generated"
  error_message "Error: the compressed archive was not created correctly."
  return 1
}

# Install a cron entry to run the backup automatically.
install_cron() {
  local script_path cron_line current_cron
  if ! command -v crontab >/dev/null 2>&1; then
    warning_message "crontab is not installed in this environment."
    return 1
  fi

  script_path="$(realpath "$0")"
  cron_line="$CRON_SCHEDULE /bin/bash \"$script_path\" --backup-now >> \"$LOG_FILE\" 2>&1"

  current_cron="$(crontab -l 2>/dev/null || true)"
  current_cron="$(printf '%s\n' "$current_cron" | grep -vF "$script_path" || true)"

  printf '%s\n%s\n' "$current_cron" "$cron_line" | sed '/^$/d' | crontab -
  log_msg "Cron installed to run backup: $cron_line"
  success_message "Cron configured successfully for the current user."
}

# Display the values used by the script to generate the backup.
show_config() {
  info_message "Destination directory: $BACKUP_DEST_DIR"
  info_message "Prefix: $BACKUP_PREFIX"
  info_message "Cron: $CRON_SCHEDULE"
  info_message "Sources: ${BACKUP_SOURCE_DIRS:-<empty>}"
}

# Interactive menu to operate the script without remembering arguments.
menu() {
  while true; do
    echo
    echo "--- Backup Management ---"
    echo "1) Run backup now"
    echo "2) Schedule backup with cron"
    echo "3) Show configuration"
    echo "4) Exit"
    read -rp "Choose an option: " opt
    case "$opt" in
      1) do_backup ;;
      2) install_cron ;;
      3) show_config ;;
      4) exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# Entry point: decide between direct arguments or interactive menu.
main() {
  case "${1:-}" in
    --backup-now) do_backup ;;
    --install-cron) install_cron ;;
    --show-config) show_config ;;
    "") menu ;;
    *)
      echo "Usage: $0 [--backup-now|--install-cron|--show-config]"
      exit 1
      ;;
  esac
}

main "$@"
