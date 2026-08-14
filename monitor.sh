#!/usr/bin/env bash
# mqtt-system-monitor — collects system metrics and publishes them via MQTT
# with Home Assistant auto-discovery payloads.
#
# Run manually:  ./monitor.sh
# Deployed via:  systemd timer (see install.sh)
#
# Requires: mosquitto-clients (apt install mosquitto-clients)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
for _candidate in /etc/mqtt-monitor/config.sh "$SCRIPT_DIR/config.sh"; do
    [[ -f "$_candidate" ]] && { CONFIG_FILE="$_candidate"; break; }
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo "ERROR: config.sh not found." \
         "Expected at /etc/mqtt-monitor/config.sh or next to this script." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

if ! command -v mosquitto_pub &>/dev/null; then
    echo "ERROR: mosquitto_pub not found. Install with: sudo apt install mosquitto-clients" >&2
    exit 1
fi

# Ensure optional per-service arrays exist even if config.sh omitted them
declare -A SERVICE_CHECK_CMD 2>/dev/null || true
declare -A SERVICE_LOG_FILE  2>/dev/null || true
declare -A SERVICE_LOG_PATTERN 2>/dev/null || true

# ---------------------------------------------------------------------------
# Hostname (sanitised: lowercase, non-alphanumeric/underscore → underscore)
# ---------------------------------------------------------------------------

HOST="${HOSTNAME_OVERRIDE:-$(hostname -s)}"
HOST="${HOST,,}"
HOST="${HOST//[^a-z0-9_]/_}"

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

DEVICE_JSON="{\"identifiers\":[\"mqtt_monitor_${HOST}\"],\"name\":\"${HOST}\",\"manufacturer\":\"linux-monitor\",\"model\":\"bash-mqtt-monitor\"}"

# Parse MONITORED_SERVICES into an array (handles empty value safely)
SERVICES=()
[[ -n "${MONITORED_SERVICES:-}" ]] && IFS=' ' read -ra SERVICES <<< "$MONITORED_SERVICES"

# State directory for tracking log file positions between runs
STATE_DIR="/var/lib/mqtt-monitor"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

mqtt_pub() {
    local topic="$1" payload="$2" retain="${3:-}"
    mosquitto_pub \
        -h "$MQTT_BROKER" \
        -p "$MQTT_PORT" \
        -t "$topic" \
        -m "$payload" \
        ${retain:+-r}
}

# Coerce any value to a non-negative integer, defaulting to 0.
to_int() {
    local v="${1:-0}"
    v="${v//[[:space:]]/}"
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    echo "$v"
}

# Count journald entries for a unit at or above 'warning' priority in the given window.
# Window examples: "1 minute", "5 minutes"
count_journal_errors() {
    local unit="$1" window="$2"
    # Pre-compute an absolute timestamp with GNU date.
    # Passing "X ago" directly to journalctl --since is unreliable: journalctl's
    # own time parser varies across systemd versions and silently returns nothing
    # when it can't parse the string, making the count always 0.
    local since
    since=$(date --date="${window} ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || { echo 0; return; }
    local count
    # '; true' prevents set -o pipefail from triggering on a non-zero journalctl
    # exit, which would otherwise cause a double-write into the command substitution.
    count=$(journalctl -u "$unit" --since "$since" -p warning -q --no-pager 2>/dev/null | wc -l; true)
    to_int "${count:-0}"
}

# Run a custom health-check command (timeout 10 s). Prints "ok" or "fail".
run_check() {
    local cmd="$1"
    if timeout 10 bash -c "$cmd" &>/dev/null 2>&1; then
        echo "ok"
    else
        echo "fail"
    fi
}

# Count NEW lines matching ERE pattern in a log file since the last run.
# Stores previous total in STATE_DIR; handles log rotation by clamping to 0.
get_log_errors() {
    local svc="$1" log_file="$2" pattern="$3"
    local state_file="${STATE_DIR}/${HOST}_svc_${svc}_log_count"

    if [[ ! -f "$log_file" ]]; then
        echo 0
        return
    fi

    local current
    current=$(grep -cE "$pattern" "$log_file" 2>/dev/null || echo 0)
    current=$(to_int "$current")

    local previous
    previous=$(to_int "$(cat "$state_file" 2>/dev/null)")
    # On first run previous defaults to current so delta = 0 (avoids a spike)
    [[ "$previous" -eq 0 && ! -f "$state_file" ]] && previous=$current

    local delta=$(( current - previous ))
    [[ $delta -lt 0 ]] && delta=0   # log rotation reset

    echo "$current" > "$state_file"
    echo "$delta"
}

# Build a comma-joined string from an array (no IFS side-effects).
join_fields() {
    local result=""
    for f in "$@"; do
        result+="${result:+,}${f}"
    done
    echo "$result"
}

# ---------------------------------------------------------------------------
# Discovery — system sensors
# ---------------------------------------------------------------------------

# publish_sensor_discovery suffix display_name json_key unit device_class icon
# All system sensors share state topic: linux_monitor/{HOST}/state
publish_sensor_discovery() {
    local suffix="$1" display_name="$2" json_key="$3"
    local unit="$4" dev_class="$5" icon="$6"

    local extras=""
    [[ -n "$unit" ]]      && extras+="\"unit_of_measurement\":\"${unit}\","
    [[ -n "$dev_class" ]] && extras+="\"device_class\":\"${dev_class}\","
    [[ "$dev_class" != "timestamp" ]] && extras+="\"state_class\":\"measurement\","
    [[ -n "$icon" ]]      && extras+="\"icon\":\"${icon}\","

    local payload="{\"name\":\"${HOST} ${display_name}\",\"unique_id\":\"${HOST}_${suffix}\",\"state_topic\":\"linux_monitor/${HOST}/state\",\"value_template\":\"{{ value_json.${json_key} }}\",${extras}\"expire_after\":180,\"device\":${DEVICE_JSON}}"
    mqtt_pub "${DISCOVERY_PREFIX}/sensor/${HOST}_${suffix}/config" "$payload" "retain"
}

# ---------------------------------------------------------------------------
# Discovery — per-service sensors
# ---------------------------------------------------------------------------

# Registers all HA sensors for one systemd service.
# State topic: linux_monitor/{HOST}/service/{svc}/state  (JSON)
register_service_sensors() {
    local svc="$1"
    local state_t="linux_monitor/${HOST}/service/${svc}/state"

    # Helper: publish a sensor config for this service
    _svc_sensor() {
        local id="$1" name="$2" key="$3" unit="$4" dev_class="$5" icon="$6"
        local ex=""
        [[ -n "$unit" ]]      && ex+="\"unit_of_measurement\":\"${unit}\","
        [[ -n "$dev_class" ]] && ex+="\"device_class\":\"${dev_class}\","
        [[ -n "$dev_class" && "$dev_class" != "timestamp" ]] && ex+="\"state_class\":\"measurement\","
        [[ -z "$dev_class" ]] && ex+="\"state_class\":\"measurement\","
        [[ -n "$icon" ]]      && ex+="\"icon\":\"${icon}\","
        local p="{\"name\":\"${HOST} svc ${svc} ${name}\",\"unique_id\":\"${HOST}_svc_${svc}_${id}\",\"state_topic\":\"${state_t}\",\"value_template\":\"{{ value_json.${key} }}\",${ex}\"expire_after\":180,\"device\":${DEVICE_JSON}}"
        mqtt_pub "${DISCOVERY_PREFIX}/sensor/${HOST}_svc_${svc}_${id}/config" "$p" "retain"
    }

    # Active sub-state (string: running / exited / failed / dead / …)
    # No unit, no state_class — it's an enum, not a measurement
    local p="{\"name\":\"${HOST} svc ${svc} state\",\"unique_id\":\"${HOST}_svc_${svc}_state\",\"state_topic\":\"${state_t}\",\"value_template\":\"{{ value_json.active_sub_state }}\",\"icon\":\"mdi:cog-outline\",\"expire_after\":180,\"device\":${DEVICE_JSON}}"
    mqtt_pub "${DISCOVERY_PREFIX}/sensor/${HOST}_svc_${svc}_state/config" "$p" "retain"

    _svc_sensor "restarts"   "restarts"       "restart_count"       "restarts"  ""           "mdi:restart"
    _svc_sensor "uptime"     "uptime"         "uptime_seconds"      "s"         "duration"   ""
    _svc_sensor "memory"     "memory"         "memory_bytes"        "B"         "data_size"  "mdi:memory"
    _svc_sensor "errors_1m"  "errors 1m"      "journal_errors_1m"   "errors"    ""           "mdi:alert-circle-outline"
    _svc_sensor "errors_5m"  "errors 5m"      "journal_errors_5m"   "errors"    ""           "mdi:alert-circle-outline"

    # Optional: custom health check → binary_sensor
    if [[ -n "${SERVICE_CHECK_CMD[$svc]:-}" ]]; then
        p="{\"name\":\"${HOST} svc ${svc} check\",\"unique_id\":\"${HOST}_svc_${svc}_check\",\"state_topic\":\"${state_t}\",\"value_template\":\"{{ value_json.check_ok }}\",\"payload_on\":\"ok\",\"payload_off\":\"fail\",\"device_class\":\"running\",\"expire_after\":180,\"device\":${DEVICE_JSON}}"
        mqtt_pub "${DISCOVERY_PREFIX}/binary_sensor/${HOST}_svc_${svc}_check/config" "$p" "retain"
    fi

    # Optional: log file error delta
    if [[ -n "${SERVICE_LOG_FILE[$svc]:-}" ]]; then
        _svc_sensor "log_errors" "log errors" "log_errors" "errors" "" "mdi:file-alert-outline"
    fi
}

register_sensors() {
    #           suffix            display name    json key           unit   device_class  icon
    publish_sensor_discovery \
        "disk_usage"    "Disk Usage"    "disk_usage_pct"    "%"    ""           "mdi:harddisk"
    publish_sensor_discovery \
        "disk_free"     "Disk Free"     "disk_free_gib"     "GiB"  "data_size"  "mdi:harddisk"
    publish_sensor_discovery \
        "load_1m"       "Load 1m"       "load_1m"           ""     ""           "mdi:gauge"
    publish_sensor_discovery \
        "load_5m"       "Load 5m"       "load_5m"           ""     ""           "mdi:gauge"
    publish_sensor_discovery \
        "load_15m"      "Load 15m"      "load_15m"          ""     ""           "mdi:gauge"
    publish_sensor_discovery \
        "memory_usage"  "Memory Usage"  "memory_usage_pct"  "%"    ""           "mdi:memory"
    publish_sensor_discovery \
        "memory_free"   "Memory Free"   "memory_free_mib"   "MiB"  "data_size"  "mdi:memory"
    publish_sensor_discovery \
        "last_seen"     "Last Seen"     "last_seen"         ""     "timestamp"  ""

    for svc in "${SERVICES[@]}"; do
        # Retire the old single binary_sensor (active/inactive) — replaced below
        mqtt_pub "${DISCOVERY_PREFIX}/binary_sensor/${HOST}_svc_${svc}/config" "" "retain"
        register_service_sensors "$svc"
    done
}

# ---------------------------------------------------------------------------
# Metrics — system
# ---------------------------------------------------------------------------

collect_metrics() {
    # -- Disk (root mount) --
    # df -k gives 1 KiB blocks; field 5 = Use%, field 4 = Available KiB
    local disk_raw
    disk_raw=$(df -k / | awk 'NR==2 {gsub(/%/,""); print $5, $4}')
    local disk_usage_pct="${disk_raw% *}"
    local disk_avail_kb="${disk_raw#* }"
    local disk_free_gib
    disk_free_gib=$(awk "BEGIN {printf \"%.1f\", ${disk_avail_kb} / 1048576}")

    # -- Load averages --
    local load_1m load_5m load_15m
    read -r load_1m load_5m load_15m _ < /proc/loadavg

    # -- Memory --
    # free -k: field 2 = total KiB, field 7 = available KiB
    local mem_raw
    mem_raw=$(free -k | awk 'NR==2 {print $2, $7}')
    local mem_total_kb="${mem_raw% *}"
    local mem_avail_kb="${mem_raw#* }"
    local mem_free_mib
    mem_free_mib=$(awk "BEGIN {printf \"%.0f\", ${mem_avail_kb} / 1024}")
    local mem_usage_pct
    mem_usage_pct=$(awk "BEGIN {printf \"%.1f\", (${mem_total_kb} - ${mem_avail_kb}) / ${mem_total_kb} * 100}")

    # -- Timestamp --
    local last_seen
    last_seen=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)

    local state_json="{\"disk_usage_pct\":${disk_usage_pct},\"disk_free_gib\":${disk_free_gib},\"load_1m\":${load_1m},\"load_5m\":${load_5m},\"load_15m\":${load_15m},\"memory_usage_pct\":${mem_usage_pct},\"memory_free_mib\":${mem_free_mib},\"last_seen\":\"${last_seen}\"}"
    mqtt_pub "linux_monitor/${HOST}/state" "$state_json"

    for svc in "${SERVICES[@]}"; do
        collect_service_metrics "$svc"
    done
}

# ---------------------------------------------------------------------------
# Metrics — per service
# ---------------------------------------------------------------------------

collect_service_metrics() {
    local svc="$1"

    # Fetch all needed systemd properties in a single call
    local show_raw
    show_raw=$(systemctl show "$svc" \
        --property=SubState,NRestarts,ActiveEnterTimestampMonotonic,MemoryCurrent \
        2>/dev/null) || show_raw=""

    local sub_state restart_count enter_mono_us mem_bytes
    sub_state=$(echo    "$show_raw" | awk -F= '/^SubState=/{print $2}')
    restart_count=$(echo "$show_raw" | awk -F= '/^NRestarts=/{print $2}')
    enter_mono_us=$(echo "$show_raw" | awk -F= '/^ActiveEnterTimestampMonotonic=/{print $2}')
    mem_bytes=$(echo    "$show_raw" | awk -F= '/^MemoryCurrent=/{print $2}')

    sub_state="${sub_state:-dead}"
    restart_count=$(to_int "$restart_count")
    enter_mono_us=$(to_int "$enter_mono_us")

    # MemoryCurrent returns max-uint64 (18446744073709551615) when cgroups v2
    # tracking is unavailable; treat anything above 9 TiB as "not available".
    mem_bytes=$(to_int "$mem_bytes")
    [[ "$mem_bytes" -gt 9000000000000 ]] && mem_bytes=0

    # Uptime in seconds via monotonic timestamps
    local current_mono_us uptime_seconds
    current_mono_us=$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)
    if [[ "$enter_mono_us" -gt 0 ]]; then
        uptime_seconds=$(( (current_mono_us - enter_mono_us) / 1000000 ))
        [[ $uptime_seconds -lt 0 ]] && uptime_seconds=0
    else
        uptime_seconds=0
    fi

    local journal_errors_1m journal_errors_5m
    journal_errors_1m=$(count_journal_errors "$svc" "1 minute")
    journal_errors_5m=$(count_journal_errors "$svc"  "5 minutes")

    # Core fields (always present)
    local fields=(
        "\"active_sub_state\":\"${sub_state}\""
        "\"restart_count\":${restart_count}"
        "\"uptime_seconds\":${uptime_seconds}"
        "\"memory_bytes\":${mem_bytes}"
        "\"journal_errors_1m\":${journal_errors_1m}"
        "\"journal_errors_5m\":${journal_errors_5m}"
    )

    # Optional: custom health check
    if [[ -n "${SERVICE_CHECK_CMD[$svc]:-}" ]]; then
        local check_ok
        check_ok=$(run_check "${SERVICE_CHECK_CMD[$svc]}")
        fields+=("\"check_ok\":\"${check_ok}\"")
    fi

    # Optional: log file error delta
    if [[ -n "${SERVICE_LOG_FILE[$svc]:-}" ]]; then
        local log_pattern="${SERVICE_LOG_PATTERN[$svc]:-error}"
        local log_errors
        log_errors=$(get_log_errors "$svc" "${SERVICE_LOG_FILE[$svc]}" "$log_pattern")
        fields+=("\"log_errors\":${log_errors}")
    fi

    mqtt_pub "linux_monitor/${HOST}/service/${svc}/state" "{$(join_fields "${fields[@]}")}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

register_sensors
collect_metrics
