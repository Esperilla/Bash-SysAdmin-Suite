#!/bin/bash
set -euo pipefail
source "${0%/*}"/messages.sh
###############################################################################
# users.sh
# Script to create, delete, and modify system users.
# Reads configuration from config.txt, validates input, records actions, and
# notifies a Telegram bot for each action.
# Requires root privileges to modify users.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/automated_gestion.log}"
CURL_BIN="${CURL_BIN:-curl}"

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

# Check if a user exists by querying its UID.
user_exists() {
  local user="$1"
  if id -u "$user" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# Validate username format with a safe regex.
validate_username() {
  local user="$1"
  if [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    return 0
  else
    return 1
  fi
}

# Create a user with home, bash shell, and initial password.
create_user() {
  read -rp "Username to create: " username
  if ! validate_username "$username"; then
    warning_message "Invalid username. Only lowercase letters, numbers, underscores, and hyphens are allowed."
    return 1
  fi
  if user_exists "$username"; then
    warning_message "The user '$username' already exists."
    return 1
  fi
  read -rp "Full name (GECOS) (optional): " fullname
  read -rsp "Initial password: " password
  echo
  if [ -z "$password" ]; then
    error_message "Empty password. Aborting."; return 1
  fi
  useradd -m -c "$fullname" -s /bin/bash "$username"
  echo "$username:$password" | chpasswd
  if [ $? -eq 0 ]; then
    local msg="User created: $username"
    success_message "$msg"
    log_msg "$msg"
    send_telegram "[Users.sh] $msg"
    return 0
  else
    error_message "Error creating the user."; return 1
  fi
}

# Delete a user and their home after explicit confirmation.
delete_user() {
  read -rp "Username to delete: " username
  if ! user_exists "$username"; then
    warning_message "The user '$username' does not exist."
    return 1
  fi
  read -rp "CONFIRM deletion of $username (type 'yes'): " confirm
  if [ "$confirm" != "yes" ]; then
    warning_message "Deletion cancelled."
    return 1
  fi
  userdel -r "$username" >/dev/null 2>&1 || true
  local msg="User deleted: $username"
  success_message "$msg"
  log_msg "$msg"
  send_telegram "[Users.sh] $msg"
}

# Modify user data: shell, GECOS, password, and group membership.
modify_user() {
  read -rp "Username to modify: " username
  if ! user_exists "$username"; then
    warning_message "The user '$username' does not exist."
    return 1
  fi
  echo "Modification options for $username:"
  echo "  1) Change shell"
  echo "  2) Change full name (GECOS)"
  echo "  3) Change password"
  echo "  4) Add to groups"
  echo "  5) Remove from groups"
  echo "  6) Return"
  read -rp "Choose an option: " opt
  case "$opt" in
    1)
      read -rp "New shell (e.g. /bin/bash): " newshell
      usermod -s "$newshell" "$username"
      msg="Shell changed for $username to $newshell"
      ;;
    2)
      read -rp "New full name (GECOS): " newgecos
      usermod -c "$newgecos" "$username"
      msg="GECOS changed for $username to '$newgecos'"
      ;;
    3)
      read -rsp "New password: " newpass; echo
      if [ -z "$newpass" ]; then error_message "Empty password. Aborting."; return 1; fi
      echo "$username:$newpass" | chpasswd
      msg="Password changed for $username"
      ;;
    4)
      read -rp "Groups to add (comma-separated): " addgr
      usermod -a -G "$addgr" "$username"
      msg="Added $username to groups: $addgr"
      ;;
    5)
      read -rp "Groups to remove (comma-separated): " delgr
      current_groups=$(id -nG "$username" | tr ' ' ',')
      IFS=',' read -ra keep <<<"$current_groups"
      IFS=',' read -ra rem <<<"$delgr"
      newlist=""
      for g in "${keep[@]}"; do
        skip=0
        for r in "${rem[@]}"; do
          if [ "$g" = "$r" ]; then skip=1; break; fi
        done
        if [ $skip -eq 0 ]; then
          if [ -z "$newlist" ]; then newlist="$g"; else newlist+=",$g"; fi
        fi
      done
      usermod -G "$newlist" "$username"
      msg="Updated groups for $username -> $newlist"
      ;;
    6)
      return 0
      ;;
    *) echo "Invalid option"; return 1;;
  esac
  info_message "$msg"
  log_msg "$msg"
  send_telegram "[Users.sh] $msg"
}

# Show all logins recorded in /etc/passwd.
list_users() {
  info_message "System users (logins):"
  cut -d: -f1 /etc/passwd
}

# Allows clean exit on Ctrl+C or termination signals.
trap 'echo; echo "Exiting..."; exit 0' SIGINT SIGTERM

# Main menu with root privilege check and interactive loop.
main_menu() {
  if [ "$EUID" -ne 0 ]; then
    info_message "This script must be run as root. Use sudo."; exit 1
  fi
  while true; do
    echo
    echo "--- User Management ---"
    echo "1) Create user"
    echo "2) Delete user"
    echo "3) Modify user"
    echo "4) List users"
    echo "5) Exit"
    read -rp "Choose an option: " opt
    case "$opt" in
      1) create_user ;;
      2) delete_user ;;
      3) modify_user ;;
      4) list_users ;;
      5) info_message "Goodbye."; exit 0 ;;
      *) warning_message "Invalid option." ;;
    esac
  done
}

main_menu
