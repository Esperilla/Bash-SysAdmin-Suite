#!/bin/bash
set -euo pipefail
source "${0%/*}"/messages.sh
###############################################################################
# remote.sh
# Copies a local script to remote hosts via SCP, runs it over SSH, and creates
# individual per-host reports with results and timestamp.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
CURL_BIN="${CURL_BIN:-curl}"

# Base values for the remote flow; they can be overridden from config.txt or arguments.
LOG_FILE="${LOG_FILE:-/var/log/automated_gestion.log}"
HOSTS_FILE=""
LOCAL_SCRIPT=""
SSH_USER=""
SSH_PORT="22"
SSH_KEY=""
TARGET_DIR="/tmp"
REPORT_DIR=""
CONNECT_TIMEOUT="8"

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

# Return a uniform timestamp for logs and reports.
timestamp() {
date --iso-8601=seconds
}

# Initialize the log file creating the directory if needed.
log_init() {
local dir
dir="$(dirname "$LOG_FILE")"
mkdir -p "$dir" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
}

# Record remote process events in the local log.
log_msg() {
log_init
local msg="$1"
if [ -w "$LOG_FILE" ] || [ ! -e "$LOG_FILE" ]; then
echo "$(timestamp) - $msg" >> "$LOG_FILE" 2>/dev/null || true
fi
}

# Send notifications to Telegram; if there is no configuration, only leave a log trace.
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

# Show how to execute the script and what variables it expects in config.txt.
usage() {
cat <<EOF
Usage: $(basename "$0") -f HOSTS_FILE -s LOCAL_SCRIPT [options]

Options:
-f, --hosts FILE         File with hosts/IPs (one per line)
-s, --script FILE        Local script to copy and run remotely
-u, --user USER          Remote SSH user (default: $SSH_USER)
-p, --port PORT          SSH port (default: 22)
-i, --identity FILE      SSH private key
-d, --remote-dir DIR     Remote temporary directory (default: /tmp)
-o, --output-dir DIR     Base directory for reports
-t, --timeout SEG        Connection timeout in seconds (default: 8)
-h, --help               Show this help

You can also define values in config.txt:
HOSTS_FILE, LOCAL_SCRIPT, SSH_USER, SSH_PORT,
SSH_KEY, TARGET_DIR, REPORT_DIR, CONNECT_TIMEOUT.
EOF
}

# Convert a host to a safe name for report files.
sanitize_host() {
echo "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

# Accept only simple host names without special characters.
is_valid_host() {
local host="$1"
[[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]
}

# Process arguments and override default configuration.
parse_args() {
while [ $# -gt 0 ]; do
case "$1" in
-f|--hosts)
HOSTS_FILE="${2:-}"
shift 2
;;
-s|--script)
LOCAL_SCRIPT="${2:-}"
shift 2
;;
-u|--user)
SSH_USER="${2:-}"
shift 2
;;
-p|--port)
SSH_PORT="${2:-}"
shift 2
;;
-i|--identity)
SSH_KEY="${2:-}"
shift 2
;;
-d|--remote-dir)
TARGET_DIR="${2:-}"
shift 2
;;
-o|--output-dir)
REPORT_DIR="${2:-}"
shift 2
;;
-t|--timeout)
CONNECT_TIMEOUT="${2:-}"
shift 2
;;
-h|--help)
usage
exit 0
;;
*)
warning_message "Invalid option: $1"
usage
exit 1
;;
esac
done
}

# Read the host file, remove comments and spaces, and keep only valid entries.
read_hosts() {
local file="$1"
local line
HOSTS=()

while IFS= read -r line || [ -n "$line" ]; do
line="$(echo "$line" | tr -d '\r')"
line="${line%%#*}"
line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
[ -z "$line" ] && continue
HOSTS+=("$line")
done < "$file"
}

# Save the result for each host in an individual report file.
write_report() {
local host="$1"
local safe_host="$2"
local status="$3"
local exit_code="$4"
local output="$5"
local report_file="$6"

{
echo "HOST=$host"
echo "TIMESTAMP=$(timestamp)"
echo "STATUS=$status"
echo "EXIT_CODE=$exit_code"
echo "LOCAL_SCRIPT=$LOCAL_SCRIPT"
echo "REMOTE_USER=$SSH_USER"
echo "SSH_PORT=$SSH_PORT"
echo ""
echo "--- REMOTE OUTPUT ---"
echo "$output"
} > "$report_file"

log_msg "Report generated for $host ($status): $report_file"
echo "[$safe_host] $status -> $report_file"
}

# Copy the script to the host, run it, and record the final result.
copy_and_execute_host() {
local host="$1"
local safe_host
local report_file
local remote_name
local remote_path
local remote_config_path
local local_config_path
local local_messages_path
local output
local rc

safe_host="$(sanitize_host "$host")"
report_file="$RUN_REPORT_DIR/${safe_host}_$(date +%Y%m%d_%H%M%S).txt"

if ! is_valid_host "$host"; then
write_report "$host" "$safe_host" "INVALID_HOST" "1" "Host with invalid format" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi

remote_name="$(basename "$LOCAL_SCRIPT")"
remote_path="$TARGET_DIR/${remote_name%.*}_$$_$(date +%s).sh"
remote_config_path="$TARGET_DIR/config.txt"
local_config_path="$SCRIPT_DIR/../config.txt"
local_messages_path="$(dirname "$LOCAL_SCRIPT")/messages.sh"

SCP_CMD=(scp -P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT")
SSH_CMD=(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT")

if [ -n "$SSH_KEY" ]; then
SCP_CMD+=( -i "$SSH_KEY" )
SSH_CMD+=( -i "$SSH_KEY" )
fi

if ! "${SCP_CMD[@]}" "$LOCAL_SCRIPT" "${SSH_USER}@${host}:${remote_path}" >/tmp/remote_scp_$$.log 2>&1; then
output="$(cat /tmp/remote_scp_$$.log 2>/dev/null || true)"
rm -f /tmp/remote_scp_$$.log
write_report "$host" "$safe_host" "SCP_ERROR" "1" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi

rm -f /tmp/remote_scp_$$.log

if [ -f "$local_messages_path" ]; then
if ! "${SCP_CMD[@]}" "$local_messages_path" "${SSH_USER}@${host}:${TARGET_DIR}/messages.sh" >/tmp/remote_scp_$$.log 2>&1; then
output="$(cat /tmp/remote_scp_$$.log 2>/dev/null || true)"
rm -f /tmp/remote_scp_$$.log
write_report "$host" "$safe_host" "SCP_ERROR" "1" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi
rm -f /tmp/remote_scp_$$.log
fi
if [ -f "$local_config_path" ]; then
if ! "${SCP_CMD[@]}" "$local_config_path" "${SSH_USER}@${host}:${remote_config_path}" >/tmp/remote_scp_$$.log 2>&1; then
output="$(cat /tmp/remote_scp_$$.log 2>/dev/null || true)"
rm -f /tmp/remote_scp_$$.log
write_report "$host" "$safe_host" "SCP_ERROR" "1" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi
rm -f /tmp/remote_scp_$$.log
fi

set +e
output="$(${SSH_CMD[@]} "${SSH_USER}@${host}" "cd '$TARGET_DIR' && bash '$remote_path' 2>&1; rc=\$?; rm -f '$remote_path'; exit \$rc" 2>&1)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
write_report "$host" "$safe_host" "OK" "$rc" "$output" "$report_file"
OK_COUNT=$((OK_COUNT + 1))
else
write_report "$host" "$safe_host" "SSH_ERROR" "$rc" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
fi
}

# Validate that required parameters are provided and resolve relative local paths before execution.
validate_inputs() {
if [ -z "$HOSTS_FILE" ]; then
error_message "Error: hosts file is missing (-f)."
usage
exit 1
fi
if [ -z "$LOCAL_SCRIPT" ]; then
error_message "Error: local script is missing (-s)."
usage
exit 1
fi
if [ ! -f "$HOSTS_FILE" ]; then
error_message "Error: host file does not exist: $HOSTS_FILE"
exit 1
fi
if [ -z "$SSH_USER" ]; then
    error_message "Error: SSH user is missing (-u)."
    exit 1
fi
if [ -z "$REPORT_DIR" ]; then
error_message "Error: reports directory is missing (-o)."
exit 1
fi

if [ ! -f "$LOCAL_SCRIPT" ]; then
if [ -f "$SCRIPT_DIR/$LOCAL_SCRIPT" ]; then
LOCAL_SCRIPT="$SCRIPT_DIR/$LOCAL_SCRIPT"
elif [ -f "$PWD/$LOCAL_SCRIPT" ]; then
LOCAL_SCRIPT="$PWD/$LOCAL_SCRIPT"
else
error_message "Error: local script does not exist: $LOCAL_SCRIPT"
warning_message "Make sure you pass the correct path or use an absolute path."
exit 1
fi
fi

if command -v realpath >/dev/null 2>&1; then
LOCAL_SCRIPT="$(realpath "$LOCAL_SCRIPT")"
fi
if [ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ]; then
error_message "Error: SSH key does not exist: $SSH_KEY"
exit 1
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
error_message "Error: invalid SSH port: $SSH_PORT"
exit 1
fi
if ! [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]]; then
error_message "Error: invalid timeout: $CONNECT_TIMEOUT"
exit 1
fi
}

# Main flow: read arguments, validate inputs, execute per host, and summarize results.
parse_args "$@"
validate_inputs

mkdir -p "$REPORT_DIR"
RUN_REPORT_DIR="$REPORT_DIR/execution_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_REPORT_DIR"

log_msg "Starting remote.sh | hosts=$HOSTS_FILE | script=$LOCAL_SCRIPT | output=$RUN_REPORT_DIR"

read_hosts "$HOSTS_FILE"
if [ "${#HOSTS[@]}" -eq 0 ]; then
error_message "Error: no valid hosts in $HOSTS_FILE"
exit 1
fi

OK_COUNT=0
FAIL_COUNT=0

for host in "${HOSTS[@]}"; do
info_message "Processing host: $host"
copy_and_execute_host "$host"
done

SUMMARY_FILE="$RUN_REPORT_DIR/summary.txt"
{
echo "TIMESTAMP=$(timestamp)"
echo "TOTAL_HOSTS=${#HOSTS[@]}"
echo "SUCCESS=${OK_COUNT}"
echo "FAILURES=${FAIL_COUNT}"
echo "REPORTS_DIR=$RUN_REPORT_DIR"
} > "$SUMMARY_FILE"

msg="remote.sh completed: $OK_COUNT successful, $FAIL_COUNT failed. Details in $RUN_REPORT_DIR"
send_telegram "$msg"

log_msg "End remote.sh | total=${#HOSTS[@]} | success=$OK_COUNT | failures=$FAIL_COUNT"

echo ""
info_message "Execution summary"
echo "  Total hosts : ${#HOSTS[@]}"
echo "  Success     : $OK_COUNT"
echo "  Failures    : $FAIL_COUNT"
echo "  Reports     : $RUN_REPORT_DIR"

if [ "$FAIL_COUNT" -gt 0 ]; then
exit 1
fi
exit 0