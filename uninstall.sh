#!/usr/bin/env bash
# Uninstall script for Intel I225-V PCIe link drop fix
# Reverses everything deploy.sh does

set -euo pipefail

SCRIPT_DEST="/usr/local/bin/nic-watchdog.sh"
SERVICE_DIR="/etc/systemd/system"
BRIDGE_SERVICE="pcie-bridge-fix.service"
WATCHDOG_SERVICE="nic-watchdog.service"
PERSISTENT_CONFIG="/etc/i225v-bridges.conf"
UDEV_RULE="/etc/udev/rules.d/10-i225v-bridge-pm.rules"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo ./uninstall.sh)"
        exit 1
    fi
}

check_installed() {
    if [[ ! -f "$SCRIPT_DEST" && ! -f "${SERVICE_DIR}/${BRIDGE_SERVICE}" && ! -f "${SERVICE_DIR}/${WATCHDOG_SERVICE}" && ! -f "$UDEV_RULE" ]]; then
        warn "Nothing to uninstall — no installation found"
        exit 0
    fi
}

stop_services() {
    if systemctl is-active --quiet "$WATCHDOG_SERVICE" 2>/dev/null; then
        systemctl stop "$WATCHDOG_SERVICE"
        info "Stopped ${WATCHDOG_SERVICE}"
    fi

    if systemctl is-active --quiet "$BRIDGE_SERVICE" 2>/dev/null; then
        systemctl stop "$BRIDGE_SERVICE"
        info "Stopped ${BRIDGE_SERVICE}"
    fi
}

disable_services() {
    if systemctl is-enabled --quiet "$WATCHDOG_SERVICE" 2>/dev/null; then
        systemctl disable "$WATCHDOG_SERVICE"
        info "Disabled ${WATCHDOG_SERVICE}"
    fi

    if systemctl is-enabled --quiet "$BRIDGE_SERVICE" 2>/dev/null; then
        systemctl disable "$BRIDGE_SERVICE"
        info "Disabled ${BRIDGE_SERVICE}"
    fi
}

remove_files() {
    if [[ -f "${SERVICE_DIR}/${WATCHDOG_SERVICE}" ]]; then
        rm "${SERVICE_DIR}/${WATCHDOG_SERVICE}"
        info "Removed ${SERVICE_DIR}/${WATCHDOG_SERVICE}"
    fi

    if [[ -f "${SERVICE_DIR}/${BRIDGE_SERVICE}" ]]; then
        rm "${SERVICE_DIR}/${BRIDGE_SERVICE}"
        info "Removed ${SERVICE_DIR}/${BRIDGE_SERVICE}"
    fi

    if [[ -f "$SCRIPT_DEST" ]]; then
        rm "$SCRIPT_DEST"
        info "Removed ${SCRIPT_DEST}"
    fi

    if [[ -f "$UDEV_RULE" ]]; then
        rm "$UDEV_RULE"
        info "Removed ${UDEV_RULE}"
    fi

    if [[ -f "$PERSISTENT_CONFIG" ]]; then
        rm "$PERSISTENT_CONFIG"
        info "Removed ${PERSISTENT_CONFIG}"
    fi

    # Clean up runtime state
    rm -f /run/i225v-bridge-chain /run/i225v-rescan-bridge

    udevadm control --reload-rules 2>/dev/null || true
    info "Reloaded udev rules"

    systemctl daemon-reload
    info "Reloaded systemd daemon"

    info "Rebuilding initramfs to remove udev rules..."
    if dracut -f 2>&1; then
        info "Initramfs rebuilt successfully"
    else
        warn "Failed to rebuild initramfs — old udev rules may persist until next kernel update"
    fi
}

restore_power_defaults() {
    local device_id="8086:15f3"
    local slot
    slot=$(lspci -D -d "$device_id" 2>/dev/null | awk '{print $1}' | head -1)

    if [[ -z "$slot" ]]; then
        warn "I225-V not found — skipping power management restore"
        return
    fi

    local syspath
    syspath=$(readlink -f "/sys/bus/pci/devices/${slot}")
    local current="$syspath"

    # Restore auto power management on the bridge chain
    while true; do
        local d3cold="/sys/bus/pci/devices/$(basename "$current")/d3cold_allowed"
        local power="/sys/bus/pci/devices/$(basename "$current")/power/control"

        if [[ -w "$power" ]]; then
            echo auto > "$power" 2>/dev/null || true
        fi
        if [[ -w "$d3cold" ]]; then
            echo 1 > "$d3cold" 2>/dev/null || true
        fi

        current=$(dirname "$current")
        local basename
        basename=$(basename "$current")
        if [[ ! "$basename" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            break
        fi
    done

    warn "Restored default power management — NIC may become unstable again"
}

echo "================================================"
echo "  Intel I225-V Fix — Uninstall"
echo "================================================"
echo ""

check_root
check_installed
stop_services
disable_services
remove_files
restore_power_defaults

echo ""
info "Uninstall complete. All components removed."
warn "The I225-V will revert to default power management on next boot."
