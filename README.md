# Bash-SysAdmin-Suite - Automated Services Manager with Telegram Notifications

[English](README.md) | [Español](README.es.md)

**Cybersecurity and Computing Infrastructure Engineering**  
_Service Programming for Administration_

Bash-based automation system for comprehensive GNU/Linux service management. It covers user management, automated backups, resource monitoring (CPU/disk), `systemd` service supervision, remote script execution through SSH/SCP, network monitoring (ping and ports), and system inventory. All operations are recorded in a centralized log and relevant events are sent in real time to a Telegram bot.

---

## Test Architecture and Environment

The project uses a multi-container Docker laboratory with a static internal network to simulate a real administration environment.

### Infrastructure

- **`Dockerfile`**: Based on `debian:12-slim` with `systemd` as the init process (`/sbin/init`). It installs the project dependencies (`systemd`, `cron`, `curl`, `bc`, `iputils-ping`, `netcat-openbsd`, `nmap`, `openssh-client/server`, `procps`, `sudo`, `nano`, `iproute2`, `tar`), removes unnecessary systemd units for containers, enables the `ssh` and `cron` services, and creates the `supervisor` test user (password: `password`) with passwordless `sudo`. It also creates test directories and the preconfigured log file.

- **`docker-compose.yml`**: Defines four interconnected containers on the `redProyecto` network (`172.20.0.0/16`):

  | Service    | Container                 | IP           | Role                                    |
  | ---------- | ------------------------- | ------------ | --------------------------------------- |
  | `client`  | `proyecto_admon_client`  | `172.20.0.2` | Main client (mounts `/workspace`)       |
  | `server1` | `proyecto_admon_server1` | `172.20.0.5` | Remote server 1                         |
  | `server2` | `proyecto_admon_server2` | `172.20.0.6` | Remote server 2                         |
  | `server3` | `proyecto_admon_server3` | `172.20.0.7` | Remote server 3                         |

  All containers run in **privileged** mode with cgroup access to support `systemd`.

### Starting the laboratory

1. Build and start all containers:
   ```bash
   docker compose up -d --build
   ```
2. Enter the client container:
   ```bash
   docker compose exec client bash
   ```
3. Enter a remote server, for example:
   ```bash
   docker compose exec server1 bash
   ```

---

## Global Configuration (`config.txt`)

Central configuration file containing the variables used by all scripts. It is organized into the following sections:

| Section       | Variables                                                                                                      |
| ------------- | -------------------------------------------------------------------------------------------------------------- |
| **Telegram**  | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`                                                                       |
| **Logs**      | `LOG_FILE` (default `/var/log/gestion_automatizada.log`)                                                       |
| **Backups**   | `BACKUP_SOURCE_DIRS`, `BACKUP_DEST_DIR`, `BACKUP_PREFIX`                                                       |
| **Monitoring** | `CPU_THRESHOLD`, `DISK_THRESHOLD`, `DISK_PATHS`                                                               |
| **Services**  | `SERVICES` (list of systemd services to monitor)                                                              |
| **Cron**      | `CRON_SCHEDULE`                                                                                                |
| **Remote**    | `HOSTS_FILE`, `LOCAL_SCRIPT`, `SSH_USER`, `SSH_PORT`, `SSH_KEY`, `TARGET_DIR`, `REPORT_DIR`, `CONNECT_TIMEOUT` |
| **Network**   | `NETWORK_HOSTS` (format `IP:port1,port2`), `CRITICAL_PORTS`                                                    |

---

## Message Library (`scripts/messages.sh`)

Shared library that provides ANSI-colored terminal output functions. All main scripts import it with `source messages.sh`.

| Function          | Color       | Usage                                                     |
| ----------------- | ----------- | --------------------------------------------------------- |
| `success_message` | Green       | Successfully completed operations                         |
| `info_message`    | Blue        | General information and process data                      |
| `warning_message` | Yellow      | Non-fatal warnings                                        |
| `error_message`   | Red         | Critical errors (writes to `stderr` and exits the script) |

---

## Scripts

All scripts are located in the `scripts/` directory. Each one works independently, reads its configuration from `config.txt`, records actions in the central log, and sends relevant events through Telegram.

---

### 1. User Management - `scripts/users.sh`

Interactive system user administration. Requires superuser privileges (`sudo`).

- **Features**:
  - Strict username validation using the regular expression (`^[a-z_][a-z0-9_-]{0,31}$`).
  - Existence checks before creating, deleting, or modifying users.
  - Interactive confirmation before deleting accounts.
  - Logging and Telegram notification for every operation.
- **Interactive menu** (`sudo ./users.sh`):
  1. **Create user** - with home directory, GECOS data, and initial password.
  2. **Delete user** - safe deletion with `userdel -r` after confirmation.
  3. **Modify user** - submenu for changing the shell, GECOS data, password, and group membership.
  4. **List users** - displays system users.
  5. **Exit**.

---

### 2. Automated Backups - `scripts/backup.sh`

Automates directory compression with `tar`, verifies the results, and schedules periodic execution with `cron`.

- **Features**:
  - Verifies that source directories exist.
  - Validates the generated archive (exists and has a size greater than zero).
  - Logs events with ISO-8601 timestamps.
  - Sends Telegram notifications with the backup path, size, and date.
  - Automatically installs the task in the current user's `crontab` without requiring `root`.
- **Interactive menu** (`./backup.sh`):
  1. Run backup now
  2. Schedule backup with cron
  3. Show configuration
  4. Exit
- **CLI arguments**:
  - `--backup-now` - Run the backup immediately.
  - `--install-cron` - Install the task in crontab.
  - `--show-config` - Display the current configuration.

---

### 3. Resource Monitoring - `scripts/monitoring.sh`

Monitors CPU and disk usage, records every reading, and sends Telegram alerts when thresholds are exceeded.

- **Features**:
  - CPU readings from `/proc/stat` with a real percentage calculation over a one-second interval.
  - Disk readings with `df` for multiple partitions.
  - Thresholds configurable through `config.txt` or CLI arguments (70% by default).
  - Single-run mode (`--once`, the default) or continuous mode (`--interval`).
  - Clean signal handling (`SIGINT`, `SIGTERM`).
- **CLI arguments**:
  - `--cpu N` - CPU threshold (%).
  - `--disk N` - Disk threshold (%).
  - `--paths P1,P2` - Partitions to monitor, separated by commas.
  - `--interval S` - Interval in seconds; enables continuous mode.
  - `--once` - Run one reading and exit.
- **Example**:
  ```bash
  ./monitoring.sh --cpu 80 --disk 90 --paths "/,/home"
  ./monitoring.sh --interval 30
  ```

---

### 4. Service Supervision - `scripts/services.sh`

Checks the status of `systemd` services, automatically restarts inactive services, and reports the results.

- **Features**:
  - Reads the service list from `config.txt` (`SERVICES` variable).
  - Normalizes service names by removing `.service` when included.
  - Checks that each service exists in `systemd` before querying its status.
  - Automatically restarts services with `systemctl restart`, using `sudo` when not running as root.
  - Performs a post-restart check and reports success or failure.
  - Records all events and sends Telegram notifications.
- **Usage**:
  ```bash
  sudo ./services.sh        # Run the service check
  ./services.sh -h          # Show help
  ```

---

### 5. Remote Execution - `scripts/remote.sh`

Copies a local script and its dependencies to remote hosts through SCP, runs it through SSH, and creates individual reports for each host.

- **Features**:
  - Reads hosts from an external file (`hosts.txt`, one per line, with `#` comments supported).
  - Copies the target script to the remote host with `scp`.
  - Automatically copies the auxiliary `config.txt` and `messages.sh` files when available.
  - Runs the script remotely through `ssh` in batch mode (`BatchMode=yes`).
  - Automatically removes the remote temporary script after execution.
  - Supports SSH key authentication.
  - Validates host formats, file existence, and numeric parameters.
  - Generates an individual report for each host with status, exit code, timestamp, and remote output.
  - Generates a `summary.txt` file with success and failure totals.
  - Sends a Telegram notification with the final summary.
  - Provides a configurable connection timeout.
  - Supports scripts that depend on the project's shared configuration without prior setup on the remote host.

- **CLI arguments**:
  - `-f, --hosts FILE` - Hosts/IPs file.
  - `-s, --script FILE` - Local script to copy and execute.
  - `-u, --user USER` - Remote SSH user.
  - `-p, --port PORT` - SSH port (default: 22).
  - `-i, --identity FILE` - SSH private key.
  - `-d, --remote-dir DIR` - Temporary remote directory (default: `/tmp`).
  - `-o, --output-dir DIR` - Base report directory.
  - `-t, --timeout SEC` - Connection timeout in seconds.

- **Example**:

  ```bash
  ./remote.sh -f /workspace/hosts.txt -s /workspace/scripts/inventory.sh -u supervisor -o /workspace/reports/remote
  ```

---

### 6. Network Monitoring - `scripts/network.sh`

Checks host connectivity with `ping` and verifies ports with `nc` (netcat). It classifies each host and alerts on unavailable critical ports.

- **Features**:
  - Reads hosts from `config.txt` (`NETWORK_HOSTS`, formatted as `IP:port1,port2`) or from an external file.
  - Verifies connectivity with `ping`.
  - Checks open ports with `nc -z`.
  - Classifies each host as **REACHABLE**, **PARTIALLY REACHABLE**, **NO PORTS AVAILABLE**, or **NO RESPONSE**.
  - Sends Telegram alerts when a host does not respond or a critical port (`CRITICAL_PORTS`) is closed.
  - Records detailed results with open-port and total-port counts.
- **Interactive menu** (`./network.sh`):
  1. Run monitoring
  2. Show configuration
  3. Exit
- **CLI arguments**:
  - `--check` - Run monitoring directly.
  - `--show-config` - Show network configuration.

---

### 7. System Inventory - `scripts/inventory.sh`

Collects detailed hardware and software information, generates a plain-text report, and sends a summary through Telegram.

- **Collected information**:
  - **System**: hostname, FQDN, operating system (from `/etc/os-release`), kernel version, and architecture.
  - **CPU**: model (from `/proc/cpuinfo`), number of logical cores (`nproc`), and frequency in MHz.
  - **RAM**: total, available, and used memory (from `/proc/meminfo`) converted to MB and GB, including usage percentage.
  - **Disks**: disk usage per partition in a readable format (`df -h`).
- **Output**:
  - Report saved to `/var/log/inventario_DATE.txt` with readable formatting and visual headers.
  - Summary sent through Telegram with key inventory data.
  - Operation recorded in the central log.
- **Usage**:
  ```bash
  ./inventory.sh
  ```

---

## Auxiliary Files

| File                    | Description                                                                            |
| ----------------------- | -------------------------------------------------------------------------------------- |
| `hosts.txt`             | List of remote server IPs for `remote.sh` (currently `172.20.0.5` and `172.20.0.7`). |
| `scripts/holaMundo.sh`  | Test script for validating remote execution with `remote.sh`.                          |

---

## Notes

### Log File Permissions

The Dockerfile automatically creates the log file and assigns ownership to the `supervisor` user. To recreate it manually:

```bash
sudo touch /var/log/gestion_automatizada.log
sudo chown supervisor:supervisor /var/log/gestion_automatizada.log
```

### SSH Configuration for Remote Execution

To use `remote.sh` between the laboratory containers, generate SSH keys in the client container and copy them to the servers:

```bash
# In the client container (172.20.0.2)
ssh-keygen -t ed25519 -C "supervisor"
ssh-copy-id -i /home/supervisor/.ssh/id_ed25519 supervisor@172.20.0.5
ssh-copy-id -i /home/supervisor/.ssh/id_ed25519 supervisor@172.20.0.6
ssh-copy-id -i /home/supervisor/.ssh/id_ed25519 supervisor@172.20.0.7
```
