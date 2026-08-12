#!/usr/bin/env bash
# uninstall.sh — removes mqtt-system-monitor systemd units and installed scripts
# Usage: sudo ./uninstall.sh

set -euo pipefail

INSTALL_DIR="/opt/mqtt-monitor"
SYSTEMD_DIR="/etc/systemd/system"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo ./uninstall.sh)" >&2
    exit 1
fi

echo "==> Stopping and disabling timer..."
systemctl disable --now mqtt-monitor.timer  2>/dev/null || true
systemctl disable --now mqtt-monitor.service 2>/dev/null || true

echo "==> Removing systemd units..."
rm -f "$SYSTEMD_DIR/mqtt-monitor.service" "$SYSTEMD_DIR/mqtt-monitor.timer"
systemctl daemon-reload

echo "==> Removing installed scripts..."
rm -rf "$INSTALL_DIR"

echo ""
echo "Uninstalled."
echo ""
echo "Config preserved at /etc/mqtt-monitor/ — remove manually if desired:"
echo "  rm -rf /etc/mqtt-monitor"
echo ""
echo "Note: retained MQTT discovery topics remain in the broker until overwritten."
echo "To remove sensors from Home Assistant, publish an empty payload to each"
echo "discovery topic, e.g.:"
echo "  mosquitto_pub -h <broker> -r -t 'homeassistant/sensor/<host>_disk_usage/config' -m ''"
