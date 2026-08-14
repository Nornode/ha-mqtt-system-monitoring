#!/usr/bin/env bash
# mqtt-system-monitor configuration
# Copy this file to /etc/mqtt-monitor/config.sh after running install.sh,
# or keep it next to monitor.sh for local/manual use.

# MQTT broker IP address (required)
MQTT_BROKER="192.168.1.100"
MQTT_PORT="1883"

# Optional hostname override.
# Leave empty to use the system's hostname (recommended).
# Use only letters, numbers, and hyphens — special characters are replaced with _.
HOSTNAME_OVERRIDE=""

# Reporting interval in seconds (used by the systemd timer).
INTERVAL=60

# Home Assistant MQTT discovery prefix — must match your HA configuration.
# The default is "homeassistant" and works without any HA changes.
DISCOVERY_PREFIX="homeassistant"

# Space-separated list of systemd service names to monitor (without the .service suffix).
# Leave empty to disable service monitoring.
MONITORED_SERVICES="ssh AdGuardHome adguardhome-sync"

# ---------------------------------------------------------------------------
# Per-service optional configuration
# Keys must exactly match names in MONITORED_SERVICES.
# ---------------------------------------------------------------------------

# Custom health check command per service.
# The command is run with 'bash -c'; exit 0 = healthy (check_ok = "ok").
# Use 'curl -sf' for HTTP endpoints, or any command that exits non-zero on failure.
# Timeout: 10 seconds.
#
# Examples:
#   SERVICE_CHECK_CMD["nginx"]="curl -sf http://localhost/health"
#   SERVICE_CHECK_CMD["postgres"]="pg_isready -q"
#   SERVICE_CHECK_CMD["myapp"]="/opt/myapp/health_check.sh"
declare -A SERVICE_CHECK_CMD=()

# AdGuardHome REST API — /control/status returns 200 when DNS is running.
# Requires Basic Auth; replace AGH_USER and AGH_PASS with your credentials.
# Default web port is 80 after initial setup (3000 is only used during first-run wizard).
SERVICE_CHECK_CMD["AdGuardHome"]="curl -sf -u 'AGH_USER:AGH_PASS' http://localhost/control/status"

# adguardhome-sync exposes an unauthenticated /healthz endpoint on port 8080.
# Returns 200 when healthy, 503 if any replica is unreachable.
SERVICE_CHECK_CMD["adguardhome-sync"]="curl -sf http://localhost:8080/healthz"

# Log file path to monitor for errors per service.
# On each run the script counts NEW matching lines since the last run
# (delta per interval, not total). Handles log rotation gracefully.
#
# Examples:
#   SERVICE_LOG_FILE["nginx"]="/var/log/nginx/error.log"
#   SERVICE_LOG_FILE["myapp"]="/var/log/myapp/app.log"
declare -A SERVICE_LOG_FILE=()

# AdGuardHome writes stderr (errors, fatals, panics) to a dedicated file.
SERVICE_LOG_FILE["AdGuardHome"]="/var/log/AdGuardHome.err"

# adguardhome-sync log path — confirm with: ls /var/log/ | grep -i sync
# SERVICE_LOG_FILE["adguardhome-sync"]="/var/log/SYNC_LOG_FILE"

# ERE regex pattern to match error lines in the log file.
# Defaults to "error" (case-sensitive) if not specified for a service.
#
# Examples:
#   SERVICE_LOG_PATTERN["nginx"]="\\[error\\]|\\[crit\\]"
#   SERVICE_LOG_PATTERN["myapp"]="ERROR|FATAL"
declare -A SERVICE_LOG_PATTERN=()

# AdGuardHome uses Go's logger which prefixes severity as [error] / [fatal].
# Also catches panic: which indicates a crash.
SERVICE_LOG_PATTERN["AdGuardHome"]="\\[error\\]|\\[fatal\\]|panic:"
