#!/usr/bin/env bash
# Deploy script for Intel I225-V PCIe link drop fix
# Idempotent — safe to run multiple times
# Handles the NIC being alive OR already dead at install time

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE_ID="8086:15f3"
SCRIPT_DEST="/usr/local/bin/nic-watchdog.sh"
SERVICE_DIR="/etc/systemd/system"
BRIDGE_SERVICE="pcie-bridge-fix.service"
WATCHDOG_SERVICE="nic-watchdog.service"
PERSISTENT_CONFIG="/etc/i225v-bridges.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo ./deploy.sh)"
        exit 1
    fi
}

check_existing() {
    local installed=0
    if [[ -f "$SCRIPT_DEST" ]]; then
        installed=1
    fi
    if [[ -f "${SERVICE_DIR}/${BRIDGE_SERVICE}" ]]; then
        installed=1
    fi
    if [[ -f "${SERVICE_DIR}/${WATCHDOG_SERVICE}" ]]; then
        installed=1
    fi

    if [[ $installed -eq 1 ]]; then
        warn "Previous installation detected — upgrading in place"
        systemctl stop "$WATCHDOG_SERVICE" 2>/dev/null || true
        systemctl stop "$BRIDGE_SERVICE" 2>/dev/null || true
    fi
}

install_files() {
    cp "${SCRIPT_DIR}/scripts/nic-watchdog.sh" "$SCRIPT_DEST"
    chmod 755 "$SCRIPT_DEST"
    info "Installed ${SCRIPT_DEST}"

    cp "${SCRIPT_DIR}/services/${BRIDGE_SERVICE}" "${SERVICE_DIR}/${BRIDGE_SERVICE}"
    chmod 644 "${SERVICE_DIR}/${BRIDGE_SERVICE}"
    info "Installed ${SERVICE_DIR}/${BRIDGE_SERVICE}"

    cp "${SCRIPT_DIR}/services/${WATCHDOG_SERVICE}" "${SERVICE_DIR}/${WATCHDOG_SERVICE}"
    chmod 644 "${SERVICE_DIR}/${WATCHDOG_SERVICE}"
    info "Installed ${SERVICE_DIR}/${WATCHDOG_SERVICE}"
}

# Run the fix script immediately — this handles all 3 scenarios:
# 1. NIC alive: discovers bridges, locks them, saves config
# 2. NIC dead + saved config: reads config, rescans, recovers
# 3. NIC dead + no config: scans empty bridges, rescans, recovers
apply_fixes_now() {
    info "Applying PCIe bridge fixes..."
    if "$SCRIPT_DEST" --apply-fixes; then
        info "Bridge power management locked down"

        local slot
        slot=$(lspci -D -d "$DEVICE_ID" 2>/dev/null | awk '{print $1}' | head -1)
        if [[ -n "$slot" ]]; then
            local rev
            rev=$(lspci -d "$DEVICE_ID" -vv 2>/dev/null | grep -oP 'rev \K[0-9a-f]+' | head -1)
            info "Intel I225-V (rev ${rev:-unknown}) online at ${slot}"
        fi

        if [[ -f "$PERSISTENT_CONFIG" ]]; then
            info "Bridge config saved to ${PERSISTENT_CONFIG}"
        fi
    else
        error "Failed to apply bridge fixes"
        error "The I225-V may not be recoverable without a power cycle"
        return 1
    fi
}

enable_services() {
    systemctl daemon-reload
    info "Reloaded systemd daemon"

    systemctl enable "$BRIDGE_SERVICE"
    info "Enabled ${BRIDGE_SERVICE}"

    systemctl enable "$WATCHDOG_SERVICE"
    info "Enabled ${WATCHDOG_SERVICE}"

    systemctl start "$BRIDGE_SERVICE"
    info "Started ${BRIDGE_SERVICE}"

    systemctl start "$WATCHDOG_SERVICE"
    info "Started ${WATCHDOG_SERVICE}"
}

verify() {
    local ok=0

    if systemctl is-active --quiet "$BRIDGE_SERVICE"; then
        info "${BRIDGE_SERVICE} is active"
    else
        error "${BRIDGE_SERVICE} failed to start"
        journalctl -u "$BRIDGE_SERVICE" --no-pager -n 5
        ok=1
    fi

    if systemctl is-active --quiet "$WATCHDOG_SERVICE"; then
        info "${WATCHDOG_SERVICE} is active"
    else
        error "${WATCHDOG_SERVICE} failed to start"
        journalctl -u "$WATCHDOG_SERVICE" --no-pager -n 5
        ok=1
    fi

    if [[ $ok -eq 0 ]]; then
        echo ""
        info "Deployment complete. Bridge power management locked down, watchdog running."
        info "Check status: journalctl -u nic-watchdog -f"
    else
        echo ""
        error "Deployment completed with errors — check output above"
    fi

    return $ok
}

echo "================================================"
echo "  Intel I225-V (rev 01) PCIe Link Drop Fix"
echo "  Locks PCIe bridge power management + watchdog"
echo "================================================"
echo ""

check_root
check_existing
install_files
apply_fixes_now
enable_services
verify
