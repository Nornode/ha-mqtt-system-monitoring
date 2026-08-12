#!/usr/bin/env bash
# check-deps.sh — dependency and compatibility check for mqtt-system-monitor
# Exit 0 = all required checks passed; Exit 1 = one or more failures detected
# Safe to run without root.

set -uo pipefail

_errors=0
_warnings=0

pass() { printf "  [  OK  ] %s\n"      "$1"; }
warn() { printf "  [ WARN ] %s — %s\n" "$1" "$2"; _warnings=$(( _warnings + 1 )); }
fail() { printf "  [ FAIL ] %s — %s\n" "$1" "$2" >&2; _errors=$(( _errors + 1 )); }

echo "============================================"
echo "  mqtt-system-monitor — dependency check"
echo "============================================"
echo ""

# ── 1. Operating system ────────────────────────────────────────────────────
echo "OS / Kernel"

if [[ "$(uname -s)" == "Linux" ]]; then
    pass "Operating system (Linux)"
else
    fail "Operating system" "Linux required; detected $(uname -s)"
fi

if [[ -r /proc/loadavg ]]; then
    pass "/proc/loadavg readable"
else
    fail "/proc/loadavg" "not readable — load average collection will fail"
fi

if [[ -r /proc/uptime ]]; then
    pass "/proc/uptime readable"
else
    fail "/proc/uptime" "not readable — service uptime calculation will fail"
fi
echo ""

# ── 2. Shell ───────────────────────────────────────────────────────────────
echo "Shell"

bash_major="${BASH_VERSINFO[0]:-0}"
if [[ "$bash_major" -ge 4 ]]; then
    pass "bash >= 4.0 (found ${BASH_VERSION})"
else
    fail "bash >= 4.0" "found ${BASH_VERSION:-unknown} — associative arrays (declare -A) require bash 4+"
fi
echo ""

# ── 3. Required tools ──────────────────────────────────────────────────────
echo "Required tools"

for cmd in awk free df date hostname wc grep; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd"
    else
        fail "$cmd" "not found — install the package that provides this command"
    fi
done
echo ""

# ── 4. systemd ─────────────────────────────────────────────────────────────
echo "systemd"

if command -v systemctl &>/dev/null; then
    sys_state=$(systemctl is-system-running 2>/dev/null || echo "unknown")
    case "$sys_state" in
        running)
            pass "systemd (state: running)" ;;
        degraded)
            warn "systemd" "state is degraded — some units failed, but installation can proceed" ;;
        *)
            warn "systemd" "state is '${sys_state}' — timer may not start correctly (container?)" ;;
    esac
else
    fail "systemctl" "not found — service monitoring and systemd timer require systemd"
fi

if command -v journalctl &>/dev/null; then
    pass "journalctl"
else
    fail "journalctl" "not found — journal error counting will fail"
fi
echo ""

# ── 5. MQTT client ─────────────────────────────────────────────────────────
echo "MQTT client"

if command -v mosquitto_pub &>/dev/null; then
    pass "mosquitto_pub"
else
    if command -v apt-get &>/dev/null; then
        warn "mosquitto_pub" "not found — install.sh will install mosquitto-clients via apt-get"
    else
        fail "mosquitto_pub" "not found and apt-get unavailable — install mosquitto-clients manually before running install.sh"
    fi
fi
echo ""

# ── 6. Optional / informational ────────────────────────────────────────────
echo "Optional"

if grep -q cgroup2 /proc/mounts 2>/dev/null || [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    pass "cgroups v2 (service memory tracking)"
elif [[ -d /sys/fs/cgroup/memory ]]; then
    pass "cgroups v1 (service memory tracking)"
else
    warn "cgroups" "memory subsystem not detected — service memory_bytes will report 0"
fi
echo ""

# ── 7. Configuration ───────────────────────────────────────────────────────
echo "Configuration"

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_FILE=""
for _c in /etc/mqtt-monitor/config.sh "$_SELF_DIR/config.sh"; do
    [[ -f "$_c" ]] && { _CONFIG_FILE="$_c"; break; }
done

if [[ -z "$_CONFIG_FILE" ]]; then
    fail "config.sh" "not found at /etc/mqtt-monitor/config.sh or next to this script"
else
    pass "config.sh found (${_CONFIG_FILE})"
    # shellcheck source=/dev/null
    source "$_CONFIG_FILE"

    # MQTT_BROKER
    if [[ -z "${MQTT_BROKER:-}" ]]; then
        fail "MQTT_BROKER" "empty — set it to your broker's IP or hostname"
    elif [[ "${MQTT_BROKER}" == "192.168.1.100" ]]; then
        warn "MQTT_BROKER" "still set to the default placeholder (192.168.1.100) — update before first run"
    else
        pass "MQTT_BROKER (${MQTT_BROKER})"
    fi

    # MQTT_PORT
    if [[ "${MQTT_PORT:-}" =~ ^[0-9]+$ ]] && [[ "${MQTT_PORT}" -ge 1 && "${MQTT_PORT}" -le 65535 ]]; then
        pass "MQTT_PORT (${MQTT_PORT})"
    else
        fail "MQTT_PORT" "invalid value '${MQTT_PORT:-}' — must be an integer between 1 and 65535"
    fi

    # INTERVAL
    if [[ "${INTERVAL:-}" =~ ^[0-9]+$ ]] && [[ "${INTERVAL}" -gt 0 ]]; then
        pass "INTERVAL (${INTERVAL}s)"
    else
        fail "INTERVAL" "invalid value '${INTERVAL:-}' — must be a positive integer"
    fi

    echo ""

    # Per-service checks (require bash 4+ for associative array iteration)
    if [[ "$bash_major" -lt 4 ]]; then
        warn "Per-service config" "skipped — bash 4+ required for associative array iteration"
    else
        # Build SERVICES array from MONITORED_SERVICES
        _SERVICES=()
        [[ -n "${MONITORED_SERVICES:-}" ]] && IFS=' ' read -ra _SERVICES <<< "$MONITORED_SERVICES"

        echo "MONITORED_SERVICES"
        if [[ ${#_SERVICES[@]} -eq 0 ]]; then
            pass "MONITORED_SERVICES (none configured — service monitoring disabled)"
        else
            for _svc in "${_SERVICES[@]}"; do
                if systemctl show "${_svc}.service" --property=Id &>/dev/null 2>&1; then
                    pass "service '${_svc}' — systemd unit found"
                else
                    warn "service '${_svc}'" "unit not found via systemctl — verify the name (no .service suffix needed)"
                fi
            done
        fi
        echo ""

        # SERVICE_CHECK_CMD
        echo "SERVICE_CHECK_CMD"
        if [[ ${#SERVICE_CHECK_CMD[@]} -eq 0 ]]; then
            pass "SERVICE_CHECK_CMD (none configured)"
        else
            for _svc in "${!SERVICE_CHECK_CMD[@]}"; do
                if [[ ! " ${_SERVICES[*]:-} " =~ " ${_svc} " ]]; then
                    fail "SERVICE_CHECK_CMD['${_svc}']" "key '${_svc}' is not listed in MONITORED_SERVICES"
                elif [[ -z "${SERVICE_CHECK_CMD[$_svc]:-}" ]]; then
                    fail "SERVICE_CHECK_CMD['${_svc}']" "command is empty"
                else
                    _cmd_bin="${SERVICE_CHECK_CMD[$_svc]%% *}"
                    if command -v "$_cmd_bin" &>/dev/null; then
                        pass "SERVICE_CHECK_CMD['${_svc}'] — command '${_cmd_bin}' found"
                    else
                        warn "SERVICE_CHECK_CMD['${_svc}']" "first word '${_cmd_bin}' not found in PATH — check the command"
                    fi
                fi
            done
        fi
        echo ""

        # SERVICE_LOG_FILE
        echo "SERVICE_LOG_FILE"
        if [[ ${#SERVICE_LOG_FILE[@]} -eq 0 ]]; then
            pass "SERVICE_LOG_FILE (none configured)"
        else
            for _svc in "${!SERVICE_LOG_FILE[@]}"; do
                if [[ ! " ${_SERVICES[*]:-} " =~ " ${_svc} " ]]; then
                    fail "SERVICE_LOG_FILE['${_svc}']" "key '${_svc}' is not listed in MONITORED_SERVICES"
                else
                    _lf="${SERVICE_LOG_FILE[$_svc]}"
                    if [[ -z "$_lf" ]]; then
                        fail "SERVICE_LOG_FILE['${_svc}']" "path is empty"
                    elif [[ ! -e "$_lf" ]]; then
                        warn "SERVICE_LOG_FILE['${_svc}']" "file '${_lf}' does not exist yet — will be checked at runtime"
                    elif [[ ! -r "$_lf" ]]; then
                        warn "SERVICE_LOG_FILE['${_svc}']" "file '${_lf}' not readable by current user — monitor.sh runs as root so may be fine"
                    else
                        pass "SERVICE_LOG_FILE['${_svc}'] (${_lf} readable)"
                    fi
                fi
            done
        fi
        echo ""

        # SERVICE_LOG_PATTERN
        echo "SERVICE_LOG_PATTERN"
        if [[ ${#SERVICE_LOG_PATTERN[@]} -eq 0 ]]; then
            pass "SERVICE_LOG_PATTERN (none configured — defaults to 'error')"
        else
            for _svc in "${!SERVICE_LOG_PATTERN[@]}"; do
                if [[ ! " ${_SERVICES[*]:-} " =~ " ${_svc} " ]]; then
                    fail "SERVICE_LOG_PATTERN['${_svc}']" "key '${_svc}' is not listed in MONITORED_SERVICES"
                else
                    _pat="${SERVICE_LOG_PATTERN[$_svc]}"
                    if [[ -z "$_pat" ]]; then
                        fail "SERVICE_LOG_PATTERN['${_svc}']" "pattern is empty — remove the key or set a valid ERE"
                    else
                        # Test if pattern is valid ERE: grep exits 2 on invalid regex, 0 or 1 otherwise
                        grep -E "$_pat" /dev/null &>/dev/null
                        _grep_ret=$?
                        if [[ $_grep_ret -eq 2 ]]; then
                            fail "SERVICE_LOG_PATTERN['${_svc}']" "invalid ERE pattern: '${_pat}'"
                        else
                            pass "SERVICE_LOG_PATTERN['${_svc}'] — valid ERE ('${_pat}')"
                        fi
                    fi
                fi
            done
        fi
        echo ""
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo "============================================"
if [[ $_errors -gt 0 ]]; then
    printf "  RESULT: FAILED  (%d error(s), %d warning(s))\n" "$_errors" "$_warnings"
    echo "============================================"
    echo ""
    echo "  Resolve the errors above before running install.sh."
    echo ""
    exit 1
elif [[ $_warnings -gt 0 ]]; then
    printf "  RESULT: PASSED  (%d warning(s))\n" "$_warnings"
    echo "============================================"
    echo ""
else
    echo "  RESULT: ALL CHECKS PASSED"
    echo "============================================"
    echo ""
fi

exit 0
