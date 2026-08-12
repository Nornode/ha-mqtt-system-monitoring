#!/usr/bin/env bash
# install.sh — installs mqtt-system-monitor as a systemd service + timer
# Usage: sudo ./install.sh

set -euo pipefail

INSTALL_DIR="/opt/mqtt-monitor"
CONFIG_DIR="/etc/mqtt-monitor"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo ./install.sh)" >&2
    exit 1
fi

echo "==> Checking dependencies..."
if ! command -v mosquitto_pub &>/dev/null; then
    echo "    mosquitto_pub not found — installing mosquitto-clients..."
    apt-get install -y mosquitto-clients
else
    echo "    mosquitto-clients: OK"
fi

echo "==> Installing scripts to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
install -m 755 "$SCRIPT_DIR/monitor.sh" "$INSTALL_DIR/monitor.sh"

echo "==> Setting up config at ${CONFIG_DIR}/config.sh..."
mkdir -p "$CONFIG_DIR"
chmod 750 "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.sh" ]]; then
    install -m 640 "$SCRIPT_DIR/config.sh" "$CONFIG_DIR/config.sh"
    echo ""
    echo "    !! Config installed to $CONFIG_DIR/config.sh"
    echo "    !! Edit it now (especially MQTT_BROKER) before starting the service."
    echo ""
else
    echo "    Config already exists — not overwritten."
fi

# Read interval from the installed config
# shellcheck source=/dev/null
source "$CONFIG_DIR/config.sh"
INTERVAL="${INTERVAL:-60}"

echo "==> Writing systemd units (reporting interval: ${INTERVAL}s)..."

cat > "$SYSTEMD_DIR/mqtt-monitor.service" <<EOF
[Unit]
Description=MQTT System Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/monitor.sh
StandardOutput=journal
StandardError=journal
EOF

cat > "$SYSTEMD_DIR/mqtt-monitor.timer" <<EOF
[Unit]
Description=MQTT System Monitor Timer
After=network-online.target

[Timer]
OnBootSec=30
OnUnitActiveSec=${INTERVAL}s
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

echo "==> Enabling and starting timer..."
systemctl daemon-reload
systemctl enable --now mqtt-monitor.timer

echo ""
echo "Installation complete!"
echo ""
echo "  Edit config : $CONFIG_DIR/config.sh"
echo "  Timer status: systemctl status mqtt-monitor.timer"
echo "  Service logs: journalctl -u mqtt-monitor.service -f"
echo "  Run once now: systemctl start mqtt-monitor.service"
echo ""
echo "After editing the config, restart the timer to apply:"
echo "  systemctl restart mqtt-monitor.timer"
