#!/bin/bash
set -euo pipefail
source "${0%/*}"/messages.sh
###############################################################################
# network.sh
# Monitors host connectivity using ping and port checks.
# Classifies hosts as reachable, partially reachable or unresponsive.
# Sends Telegram alerts when a host or critical port fails.
# Records all results in the system log.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/automated_gestion    .log}"
CURL_BIN="${CURL_BIN:-curl}"
HOSTS_FILE="${HOSTS_FILE:-${NETWORK_HOSTS_FILE:-}}"

# Ping timeout can be adjusted from the environment.
PING_COUNT="${PING_COUNT:-2}"
HOSTS=()

# Try to locate config.txt relative to the script; if it does not exist, use the current directory.
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    error_message "config.txt was not found. Create $CONFIG_FILE"
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

# Read hosts from a file or the NETWORK_HOSTS variable, ignoring comments and spaces.
parse_hosts() {
    HOSTS=()

    if [ -n "$HOSTS_FILE" ]; then
        if [ ! -f "$HOSTS_FILE" ]; then
            error_message "The host file was not found: $HOSTS_FILE"
            return 1
        fi

        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            line="${line#${line%%[![:space:]]*}}"
            line="${line%${line##*[![:space:]]}}"

            if [ -n "$line" ]; then
                HOSTS+=("$line")
            fi
        done < "$HOSTS_FILE"

        if [ "${#HOSTS[@]}" -eq 0 ]; then
            return 1
        fi

        return 0
    fi

    local raw_hosts="${NETWORK_HOSTS:-}"

    if [ -z "$raw_hosts" ]; then
        return 1
    fi

    read -r -a HOSTS <<< "$raw_hosts"
}

# Verify minimum dependencies and that at least one network entry exists to check.
validate_config() {
    if ! parse_hosts; then
        warning_message "NETWORK_HOSTS is empty in config.txt"
        return 1
    fi

    if ! command -v ping >/dev/null 2>&1; then
        error_message "ping is not installed."
        return 1
    fi

    if ! command -v nc >/dev/null 2>&1; then
        error_message "nc (netcat) is not installed."
        return 1
    fi
}

# Checks a TCP port using netcat with a short timeout.
check_port() {
    local host="$1"
    local port="$2"
    nc -z -w 2 "$host" "$port" >/dev/null 2>&1
}

# Iterates through all hosts, tests ping and then validates the ports defined in each entry.
check_hosts() {

    local entry
    local host
    local ports
    local total_ports
    local open_ports
    local classification

    for entry in "${HOSTS[@]}"; do

        host="${entry%%:*}"
        ports="${entry#*:}"

        if [ "$host" = "$ports" ]; then
            ports=""
        fi

        echo
        info_message "Checking $host ..."
        total_ports=0
        open_ports=0
        classification="NO RESPONSE"

        if ping -c "$PING_COUNT" -W 2 "$host" >/dev/null 2>&1; then

            if [ -n "$ports" ]; then
                IFS=',' read -ra PORT_LIST <<< "$ports"

                for port in "${PORT_LIST[@]}"; do
                    total_ports=$((total_ports + 1))

                    if check_port "$host" "$port"; then
                        open_ports=$((open_ports + 1))
                    else
                        if [[ " ${CRITICAL_PORTS:-} " =~ " ${port} " ]]; then
                            send_telegram "NETWORK ALERT: Critical port $port is closed on $host"
                        fi
                    fi
                done
            fi

            if [ "$total_ports" -eq 0 ]; then
                classification="REACHABLE"
            elif [ "$open_ports" -eq "$total_ports" ]; then
                classification="REACHABLE"
            elif [ "$open_ports" -gt 0 ]; then
                classification="PARTIALLY REACHABLE"
            else
                classification="NO PORTS AVAILABLE"
            fi

        else
            classification="NO RESPONSE"
            send_telegram "NETWORK ALERT: Host not responding -> $host"
        fi

        info_message "$host => $classification"

        log_msg "Host=$host Status=$classification OpenPorts=$open_ports/$total_ports"
    done
}

# Shows the active configuration for easier explanation and diagnosis.
show_config() {
    info_message "Hosts: ${NETWORK_HOSTS:-<empty>}"
    info_message "Critical ports: ${CRITICAL_PORTS:-<empty>}"
    info_message "Log: $LOG_FILE"
}

# Interactive menu to run monitoring without passing arguments.
menu() {
    while true; do
        echo
        echo "--- Network Monitoring ---"
        echo "1) Run monitoring"
        echo "2) Show configuration"
        echo "3) Exit"

        read -rp "Choose an option: " opt

        case "$opt" in
            1) check_hosts ;;
            2) show_config ;;
            3) exit 0 ;;
            *) warning_message "Invalid option." ;;
        esac
    done
}

# Entry point: validate configuration and decide between direct execution or menu.
main() {
    if ! validate_config; then
        exit 1
    fi

    case "${1:-}" in
        --check)
            check_hosts
            ;;
        --show-config)
            show_config
            ;;
        "")
            menu
            ;;
        *)
            warning_message "Usage: $0 [--check|--show-config]"
            exit 1
            ;;
    esac
}

main "$@"