#!/bin/bash
set -euo pipefail
source "${0%/*}"/messages.sh
###############################################################################
# services.sh
# Reviews a list of services defined in config.txt, tries to restart them
# if they are inactive, notifies through Telegram and records the event in the log.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/automated_gestion.log}"
CURL_BIN="${CURL_BIN:-curl}"

# List of services to review, can be redefined from config.txt.
SERVICES="ssh nginx mysql"

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
}

# Register events with ISO-8601 timestamp.
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

# Show how to run this script and which config variable it expects.
usage() {
    cat <<EOF
Usage: $(basename "$0")
Reads the service list from config.txt from the SERVICES variable.
Options:
  -h    Show this help
EOF
}

# Allows a clean exit on Ctrl+C or termination signals.
trap 'log_msg "Script interrupted"; exit 1' INT TERM

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

# If SERVICES is empty, there is nothing to review and the script stops with a clear message.
if [ -z "$SERVICES" ]; then
    error_message "The SERVICES variable is not defined in $CONFIG_FILE."
    info_message "Add a line like: SERVICES=\"ssh nginx mysql\""
    log_msg "SERVICES not defined in config.txt. Aborting."
    exit 1
fi

# Start the service review: iterate through each defined service and act according to its status.
log_msg "Starting service review: $SERVICES"

for svc in $SERVICES; do
    svc_name="$svc"
    svc_name="${svc_name%.service}"

    if ! systemctl list-units --type=service --all | grep -q "${svc_name}.service"; then
        msg="Service ${svc_name} not found in systemd"
        info_message "$msg"
        log_msg "$msg"
        send_telegram "[Services.sh] ${msg}"
        continue
    fi

    status=$(systemctl is-active "$svc_name" 2>/dev/null || echo unknown)
    if [ "$status" = "active" ]; then
        msg="Service ${svc_name} is active"
        info_message "$msg"
        log_msg "$msg"
        continue
    fi

    msg="Service ${svc_name} is inactive (status: $status). Trying to restart..."
    warning_message "$msg"
    log_msg "$msg"

    if [ "$(id -u)" -eq 0 ]; then
        restart_cmd=(systemctl restart "$svc_name")
    else
        if command -v sudo >/dev/null 2>&1; then
            restart_cmd=(sudo systemctl restart "$svc_name")
        else
            restart_cmd=(systemctl restart "$svc_name")
        fi
    fi

    if "${restart_cmd[@]}"; then
        sleep 1
        new_status=$(systemctl is-active "$svc_name" 2>/dev/null || echo unknown)
        if [ "$new_status" = "active" ]; then
            result_msg="Restart successful: ${svc_name} is active now"
            success_message "$result_msg"
            log_msg "$result_msg"
            send_telegram "[Services.sh] Service ${svc_name} restarted successfully."
        else
            result_msg="Restart failed for ${svc_name}. Current status: $new_status"
            error_message "$result_msg"
            log_msg "$result_msg"
            send_telegram "[Services.sh] Error restarting ${svc_name}: status ${new_status}"
        fi
    else
        err_msg="Error while executing restart for ${svc_name}"
        error_message "$err_msg"
        log_msg "$err_msg"
        send_telegram "[Services.sh] Restart of ${svc_name} could not be executed. Check permissions." || true
    fi
done

log_msg "End of service review"

exit 0
