# MQTT System Monitor

A set of portable bash scripts that publish system metrics from Debian/Linux hosts to an MQTT broker, with automatic sensor discovery for [Home Assistant](https://www.home-assistant.io/integrations/mqtt/).

Each host appears in Home Assistant as a single device, with all its sensors grouped under the hostname.

---

## Requirements

- Debian/Linux with `systemd`
- `mosquitto-clients` (`apt install mosquitto-clients`)
- An MQTT broker reachable from the host (no TLS required)
- Home Assistant with the [MQTT integration](https://www.home-assistant.io/integrations/mqtt/) enabled

---

## Files

| File | Purpose |
|------|---------|
| `config.sh` | All user-facing configuration |
| `monitor.sh` | Collects metrics and publishes MQTT discovery + state |
| `install.sh` | Installs as a systemd service + timer (requires root) |
| `uninstall.sh` | Removes the service cleanly (requires root) |

---

## Installation

**1. Clone or copy the files to the target host.**

**2. Run the installer:**

```bash
sudo ./install.sh
```

This will:
- Install `mosquitto-clients` if not already present
- Copy `monitor.sh` to `/opt/mqtt-monitor/`
- Copy `config.sh` to `/etc/mqtt-monitor/config.sh` (only if it does not already exist)
- Create a systemd one-shot service and a timer that fires it on the configured interval

**3. Edit the config:**

```bash
sudo nano /etc/mqtt-monitor/config.sh
```

At minimum, set `MQTT_BROKER` to your broker's IP address.

**4. Run once to verify:**

```bash
sudo systemctl start mqtt-monitor.service
journalctl -u mqtt-monitor.service -n 50
```

Home Assistant should discover the device within seconds under **Settings → Devices & Services → MQTT**.

**After changing the config, restart the timer:**

```bash
sudo systemctl restart mqtt-monitor.timer
```

---

## Configuration

All options live in `/etc/mqtt-monitor/config.sh` (installed) or `./config.sh` (local use).

```bash
# Required
MQTT_BROKER="192.168.1.100"
MQTT_PORT="1883"

# Optional hostname override (leave empty to use the system hostname)
HOSTNAME_OVERRIDE=""

# How often metrics are reported, in seconds
INTERVAL=60

# Home Assistant MQTT discovery prefix (default matches HA out of the box)
DISCOVERY_PREFIX="homeassistant"

# Space-separated list of systemd services to monitor
MONITORED_SERVICES="ssh nginx"
```

Sensor names in Home Assistant are derived from the hostname: `{hostname}_{metric}`. The hostname is lowercased and non-alphanumeric characters are replaced with `_`.

---

## Sensors

### System sensors

All published to `linux_monitor/{hostname}/state` as a single JSON payload.

| Sensor | Unit | Notes |
|--------|------|-------|
| Disk Usage | `%` | Root mount (`/`) |
| Disk Free | `GiB` | Root mount (`/`) |
| Load 1m | — | From `/proc/loadavg` |
| Load 5m | — | From `/proc/loadavg` |
| Load 15m | — | From `/proc/loadavg` |
| Memory Usage | `%` | Based on available memory (includes page cache) |
| Memory Free | `MiB` | Available memory (includes page cache) |
| Last Seen | timestamp | UTC ISO 8601; goes stale if the host stops reporting |

### Service sensors

Each service in `MONITORED_SERVICES` produces the following sensors. State published to `linux_monitor/{hostname}/service/{name}/state`.

| Sensor | Unit | Notes |
|--------|------|-------|
| state | — | systemd sub-state: `running`, `exited`, `failed`, `dead`, etc. |
| restarts | restarts | Restart count since last boot |
| uptime | `s` | Seconds since the service last entered active state |
| memory | `B` | RSS from cgroup (requires cgroups v2; 0 if unavailable) |
| errors 1m | errors | journald entries at `err` priority or higher in the last 1 minute |
| errors 5m | errors | journald entries at `err` priority or higher in the last 5 minutes |

#### Optional: custom health check

Adds a `check` binary sensor (ON = healthy) for each service that has a command configured.

```bash
# In config.sh
declare -A SERVICE_CHECK_CMD=(
    ["nginx"]="curl -sf http://localhost/health"
    ["postgres"]="pg_isready -q"
    ["myapp"]="/opt/myapp/health_check.sh"
)
```

The command is run with `bash -c` and has a 10-second timeout. Exit 0 = OK, non-zero = fail.

#### Optional: log file error tracking

Adds a `log errors` sensor showing new matching lines per reporting interval (delta, not total). Handles log rotation gracefully.

```bash
# In config.sh
declare -A SERVICE_LOG_FILE=(
    ["nginx"]="/var/log/nginx/error.log"
)

# ERE regex — defaults to "error" if not set
declare -A SERVICE_LOG_PATTERN=(
    ["nginx"]="\\[error\\]|\\[crit\\]"
)
```

State between runs is stored in `/var/lib/mqtt-monitor/`.

---

## MQTT topic layout

```
Discovery (retained):
  homeassistant/sensor/{hostname}_{metric}/config
  homeassistant/sensor/{hostname}_svc_{name}_{metric}/config
  homeassistant/binary_sensor/{hostname}_svc_{name}_check/config

State (not retained):
  linux_monitor/{hostname}/state                          ← system metrics JSON
  linux_monitor/{hostname}/service/{name}/state           ← per-service JSON
```

---

## Uninstallation

```bash
sudo ./uninstall.sh
```

The config at `/etc/mqtt-monitor/` is preserved. Remove it manually if desired:

```bash
sudo rm -rf /etc/mqtt-monitor
```

Retained MQTT discovery topics remain in the broker until explicitly cleared. To remove a sensor from Home Assistant:

```bash
mosquitto_pub -h <broker> -r -t 'homeassistant/sensor/<hostname>_disk_usage/config' -m ''
```

---

## Useful commands

```bash
# Check timer status
systemctl status mqtt-monitor.timer

# Tail service logs
journalctl -u mqtt-monitor.service -f

# Run once immediately (useful after a config change)
sudo systemctl start mqtt-monitor.service

# Subscribe to all topics for this host
mosquitto_sub -h <broker> -t 'linux_monitor/<hostname>/#' -v
```
