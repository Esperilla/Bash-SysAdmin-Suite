#!/bin/bash
set -euo pipefail
source "${0%/*}"/messages.sh
###############################################################################
# inventory.sh
# Collects system information: CPU, RAM, disk, OS, and kernel.
# Generates a report in /var/log/inventory_DATE.txt and notifies Telegram.
# Allows execution as a scheduled cron task.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/automated_gestion.log}"
CURL_BIN="${CURL_BIN:-curl}"

# Inventory output file and location where it will be saved.
INVENTORY_REPORT_DIR="/var/log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
INVENTORY_REPORT="$INVENTORY_REPORT_DIR/inventory_$TIMESTAMP.txt"

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
  warning_message "TELEGRAM_BOT_TOKEN is not configured in $CONFIG_FILE"
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ] || [ "$TELEGRAM_CHAT_ID" = "REPLACE_WITH_CHAT_ID" ]; then
  warning_message "TELEGRAM_CHAT_ID is not configured in $CONFIG_FILE"
fi

# Initialize the log file, creating the directory if needed.
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
}

# Send notifications to Telegram; if no configuration exists, only leave a log trace.
send_telegram() {
  local text="$1"
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    log_msg "ERROR: curl is not available to send notifications: $text"
    return 1
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_msg "WARNING: Telegram is not configured; notification will not be sent: $text"
    return 1
  fi
  "$CURL_BIN" -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$text" >/dev/null 2>&1 || true
}

# Create the report file and write the header with date and host.
report_file_init() {
  local dir
  dir="$(dirname "$INVENTORY_REPORT")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" || {
      log_msg "ERROR: could not create directory $dir"
      exit 1
    }
  fi

  # Create report header
  {
    echo "================================================================================"
    info_message "                      SYSTEM INVENTORY REPORT"
    echo "================================================================================"
    # Basic information to identify the system where the script is running.
    echo "Generated: $(date '+%d/%m/%Y %H:%M:%S')"
    echo "Hostname: $(hostname)"
    echo "================================================================================"
  } > "$INVENTORY_REPORT"
}

get_hostname_info() {
  {
    echo ""
    info_message "--- BASIC SYSTEM INFORMATION ---"
    echo "Hostname: $(hostname)"
    echo "FQDN domain: $(hostname -f 2>/dev/null || echo 'Not available')"
  } >> "$INVENTORY_REPORT"
}

# Operating system, kernel and architecture data.
get_os_info() {
  {
    echo ""
    info_message "--- OPERATING SYSTEM ---"
    if [ -f /etc/os-release ]; then
      grep "^PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"'
    else
      lsb_release -d 2>/dev/null | cut -f2 || echo "Not available"
    fi
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
  } >> "$INVENTORY_REPORT"
}

# Extracts CPU data from /proc/cpuinfo and available system tools.
get_cpu_info() {
  {
    echo ""
    info_message "--- CPU INFORMATION ---"

    # CPU model
    if grep -q "model name" /proc/cpuinfo; then
      model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
      echo "Model: $model"
    fi

    # Number of physical cores
    if command -v nproc >/dev/null 2>&1; then
      cores=$(nproc)
      echo "Logical cores: $cores"
    fi

    # CPU speed (if available)
    if grep -q "cpu MHz" /proc/cpuinfo; then
      freq=$(grep "cpu MHz" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs | cut -d. -f1)
      echo "Frequency: ${freq} MHz"
    fi
  } >> "$INVENTORY_REPORT"
}

# Calculates total, used and available memory using /proc/meminfo.
get_memory_info() {
  {
    echo ""
    info_message "--- RAM MEMORY INFORMATION ---"

    # Total RAM
    if [ -f /proc/meminfo ]; then
      total_kb=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
      available_kb=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}')
      used_kb=$((total_kb - available_kb))

      # Convert to MB/GB
      total_mb=$((total_kb / 1024))
      available_mb=$((available_kb / 1024))
      used_mb=$((used_kb / 1024))

      echo "Total RAM: ${total_mb} MB ($(echo "scale=2; $total_mb/1024" | bc) GB)"
      echo "Available RAM: ${available_mb} MB ($(echo "scale=2; $available_mb/1024" | bc) GB)"
      echo "Used RAM: ${used_mb} MB ($(echo "scale=2; $used_mb/1024" | bc) GB)"

      # Usage percentage
      if [ "$total_kb" -gt 0 ]; then
        percent=$((used_kb * 100 / total_kb))
        echo "Usage percentage: ${percent}%"
      fi
    fi
  } >> "$INVENTORY_REPORT"
}

# Shows disk usage in readable format for the report.
get_disk_info() {
  {
    echo ""
    info_message "--- DISK AND PARTITION INFORMATION ---"
    echo ""
    df -h | awk 'NR==1 {next} {
      printf "%-20s %8s %8s %8s %6s %s\n",
      $1, $2, $3, $4, $5, $6
    }' | {
      # Add header
      echo "Filesystem         Size  Used Avail Use% Mounted on"
      echo "---------- ---------- ---------- ------ -----------"
      cat
    }
  } >> "$INVENTORY_REPORT"
}

main() {
  # Initialize the file before writing any section.
  report_file_init

  # Mark the start of the process in the log.
  log_msg "Starting system inventory collection"

  # Collect each system information block.
  get_hostname_info
  get_os_info
  get_cpu_info
  get_memory_info
  get_disk_info

  # Close the report with a visual completion message.
  {
    echo ""
    echo "================================================================================"
    success_message "Report generated successfully"
    echo "================================================================================"
  } >> "$INVENTORY_REPORT"

  # Leave evidence of the generated file.
  log_msg "Inventory report generated: $INVENTORY_REPORT"

  # Build a short summary to send via Telegram.
  summary=$(cat <<EOF
🖥️ *SYSTEM INVENTORY*

*Hostname:* $(hostname)

*OS:* $(grep "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Not available')
*Kernel:* $(uname -r)

*CPU:* $(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo 'Not available')
*Cores:* $(nproc 2>/dev/null || echo 'Not available')

*Total RAM:* $(grep "^MemTotal:" /proc/meminfo 2>/dev/null | awk '{print int($2/1024/1024) "GB"}' || echo 'Not available')
*Available RAM:* $(grep "^MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print int($2/1024/1024) "GB"}' || echo 'Not available')

*Full report:* $INVENTORY_REPORT
EOF
  )

  # Send the summary and log that it was notified.
  send_telegram "$summary"
  log_msg "Inventory notification sent to Telegram"

  # Final console output.
  success_message "Inventory collected successfully"
  info_message "Report saved at: $INVENTORY_REPORT"
  cat "$INVENTORY_REPORT"
  exit 0
}

# Script entry point.
main
