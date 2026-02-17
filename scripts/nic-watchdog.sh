#!/usr/bin/env bash
# Intel I225-V (rev 01) PCIe link drop fix and recovery watchdog
# Targets PCI device 8086:15f3 — dynamically discovers parent bridge chain

set -uo pipefail

DEVICE_ID="8086:15f3"
RECOVERY_COOLDOWN=30
LAST_RECOVERY=0
LOG_TAG="i225v-fix"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

find_device_slot() {
    lspci -D -d "$DEVICE_ID" 2>/dev/null | awk '{print $1}' | head -1
}

find_interface_name() {
    local slot="$1"
    local sysdir="/sys/bus/pci/devices/${slot}/net"
    if [[ -d "$sysdir" ]]; then
        ls "$sysdir" | head -1
    fi
}

# Walk the sysfs path from the device up to the root port, collecting all parent bridges
find_bridge_chain() {
    local slot="$1"
    local syspath
    syspath=$(readlink -f "/sys/bus/pci/devices/${slot}")

    local bridges=()
    local current="$syspath"

    while true; do
        current=$(dirname "$current")
        local basename
        basename=$(basename "$current")

        if [[ "$basename" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            bridges+=("$basename")
        else
            break
        fi
    done

    echo "${bridges[@]}"
}

# Find the immediate parent bridge (used for PCIe rescan target)
find_rescan_bridge() {
    local slot="$1"
    local syspath
    syspath=$(readlink -f "/sys/bus/pci/devices/${slot}")
    local parent
    parent=$(dirname "$syspath")

    while true; do
        local basename
        basename=$(basename "$parent")
        if [[ "$basename" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            echo "$basename"
            return
        fi
        parent=$(dirname "$parent")
        if [[ "$parent" == "/sys/devices" || "$parent" == "/" ]]; then
            break
        fi
    done
}

# Find the top-most bridge that fans out to sibling devices (NIC, WiFi, USB)
# This is two levels up from the NIC — the bridge whose children share the subtree
find_subtree_bridge() {
    local slot="$1"
    local syspath
    syspath=$(readlink -f "/sys/bus/pci/devices/${slot}")

    local current="$syspath"
    local prev_bridge=""
    local prev_prev_bridge=""

    while true; do
        current=$(dirname "$current")
        local basename
        basename=$(basename "$current")
        if [[ "$basename" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            prev_prev_bridge="$prev_bridge"
            prev_bridge="$basename"
        else
            break
        fi
    done

    if [[ -n "$prev_prev_bridge" ]]; then
        echo "$prev_prev_bridge"
    else
        echo "$prev_bridge"
    fi
}

apply_power_fix() {
    local device="$1"
    local power_control="/sys/bus/pci/devices/${device}/power/control"
    local d3cold="/sys/bus/pci/devices/${device}/d3cold_allowed"

    if [[ -w "$power_control" ]]; then
        echo on > "$power_control"
    fi
    if [[ -w "$d3cold" ]]; then
        echo 0 > "$d3cold"
    fi
}

apply_all_fixes() {
    local slot
    slot=$(find_device_slot)
    if [[ -z "$slot" ]]; then
        log "ERROR: Intel I225-V (${DEVICE_ID}) not found on PCI bus"
        return 1
    fi

    log "Found I225-V at ${slot}"

    local bridges
    bridges=$(find_bridge_chain "$slot")
    if [[ -z "$bridges" ]]; then
        log "ERROR: Could not discover parent bridge chain"
        return 1
    fi

    log "Bridge chain: ${bridges}"

    # Lock down every bridge in the chain
    for bridge in $bridges; do
        apply_power_fix "$bridge"
        log "Locked bridge ${bridge} — power/control=on, d3cold_allowed=0"
    done

    # Lock down the NIC itself
    apply_power_fix "$slot"
    log "Locked NIC ${slot} — power/control=on, d3cold_allowed=0"

    # Lock down sibling devices behind the subtree bridge
    local subtree_bridge
    subtree_bridge=$(find_subtree_bridge "$slot")
    if [[ -n "$subtree_bridge" ]]; then
        local subtree_path
        subtree_path=$(readlink -f "/sys/bus/pci/devices/${subtree_bridge}")
        for sibling_path in "${subtree_path}"/*/; do
            local sibling
            sibling=$(basename "$sibling_path")
            if [[ "$sibling" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ && "$sibling" != "$slot" ]]; then
                apply_power_fix "$sibling"
                # Also fix endpoints behind sibling bridges
                for endpoint_path in "${sibling_path}"/*/; do
                    local endpoint
                    endpoint=$(basename "$endpoint_path")
                    if [[ "$endpoint" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
                        apply_power_fix "$endpoint"
                    fi
                done
            fi
        done
        log "Locked sibling devices behind bridge ${subtree_bridge}"
    fi

    log "All power management fixes applied"
    return 0
}

recover_nic() {
    local now
    now=$(date +%s)
    local elapsed=$((now - LAST_RECOVERY))

    if [[ $elapsed -lt $RECOVERY_COOLDOWN ]]; then
        log "WARN: Recovery attempted too soon (${elapsed}s since last). Skipping."
        return 1
    fi

    LAST_RECOVERY=$now
    log "=== NIC RECOVERY STARTED ==="

    # Re-apply power fixes to the bridge chain (in case something reset them)
    # The device might be gone so we target bridges by their known paths
    local bridges_file="/run/i225v-bridge-chain"
    local rescan_bridge_file="/run/i225v-rescan-bridge"

    if [[ ! -f "$bridges_file" || ! -f "$rescan_bridge_file" ]]; then
        log "ERROR: Bridge chain state files not found. Cannot recover without rescan target."
        return 1
    fi

    local bridges
    bridges=$(cat "$bridges_file")
    local rescan_bridge
    rescan_bridge=$(cat "$rescan_bridge_file")

    for bridge in $bridges; do
        apply_power_fix "$bridge" 2>/dev/null
    done
    log "Re-applied bridge power fixes"

    # Rescan PCIe bus from the rescan bridge
    local rescan_path="/sys/bus/pci/devices/${rescan_bridge}/rescan"
    if [[ -w "$rescan_path" ]]; then
        echo 1 > "$rescan_path"
        log "PCIe rescan triggered at ${rescan_bridge}"
    else
        log "WARN: Cannot write to ${rescan_path}, trying parent bus rescan"
        echo 1 > /sys/bus/pci/rescan 2>/dev/null
    fi

    sleep 2

    # Reload the igc driver
    if modprobe -r igc 2>/dev/null; then
        log "Unloaded igc driver"
    fi
    if modprobe igc 2>/dev/null; then
        log "Loaded igc driver"
    else
        log "ERROR: Failed to load igc driver"
        return 1
    fi

    sleep 3

    # Find the interface name and reconnect
    local slot
    slot=$(find_device_slot)
    if [[ -z "$slot" ]]; then
        log "ERROR: I225-V not found after recovery"
        return 1
    fi

    apply_power_fix "$slot"

    local iface
    iface=$(find_interface_name "$slot")
    if [[ -z "$iface" ]]; then
        log "ERROR: No network interface found for ${slot}"
        return 1
    fi

    log "Interface ${iface} detected, connecting via NetworkManager"
    nmcli device connect "$iface" 2>/dev/null &
    local nmcli_pid=$!

    # nmcli can hang — give it 15 seconds
    local waited=0
    while kill -0 "$nmcli_pid" 2>/dev/null && [[ $waited -lt 15 ]]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "$nmcli_pid" 2>/dev/null; then
        kill "$nmcli_pid" 2>/dev/null
        log "WARN: nmcli timed out, interface may need manual connection"
    fi

    # Verify recovery
    sleep 2
    if ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
        log "=== NIC RECOVERY SUCCESSFUL — ${iface} is UP ==="
        return 0
    else
        log "WARN: ${iface} is not UP after recovery"
        return 1
    fi
}

save_bridge_state() {
    local slot="$1"
    local bridges
    bridges=$(find_bridge_chain "$slot")
    echo "$bridges" > /run/i225v-bridge-chain

    # Save the bridge closest to the NIC's subtree for targeted rescan
    local subtree_bridge
    subtree_bridge=$(find_subtree_bridge "$slot")
    echo "$subtree_bridge" > /run/i225v-rescan-bridge

    log "Bridge state saved to /run/"
}

watchdog() {
    local slot
    slot=$(find_device_slot)
    if [[ -z "$slot" ]]; then
        log "ERROR: Intel I225-V not found. Watchdog cannot start."
        exit 1
    fi

    log "Watchdog started — monitoring for PCIe link drops on ${slot}"
    save_bridge_state "$slot"

    journalctl -f -k --no-pager -o cat 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -q "igc.*PCIe link lost"; then
            log "DETECTED: PCIe link lost — initiating recovery"
            recover_nic

            # Re-save bridge state after recovery in case slot changed
            local new_slot
            new_slot=$(find_device_slot)
            if [[ -n "$new_slot" ]]; then
                save_bridge_state "$new_slot"
            fi
        fi
    done
}

case "${1:-}" in
    --apply-fixes)
        apply_all_fixes
        ;;
    --watchdog)
        apply_all_fixes
        watchdog
        ;;
    --recover)
        recover_nic
        ;;
    *)
        echo "Intel I225-V (rev 01) PCIe link drop fix"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  --apply-fixes  Apply bridge power management fixes and exit"
        echo "  --watchdog     Apply fixes and monitor for link drops (runs forever)"
        echo "  --recover      Attempt NIC recovery (rescan + driver reload)"
        exit 1
        ;;
esac
