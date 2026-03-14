# Intel I225-V (rev 01) PCIe Link Drop Fix

A systemd-based fix for the Intel I225-V Ethernet controller (rev 01) that suffers from random PCIe link drops, causing the NIC to completely detach from the system and become unrecoverable without a reboot.

## The Problem

The Intel I225-V revision 01 (PCI ID `8086:15f3`) has a well-documented hardware defect where the PCIe link between the NIC and the motherboard drops unexpectedly. When this happens:

- The NIC vanishes from the PCI bus entirely
- The network interface disappears
- Toggling the interface off/on does nothing — the hardware is gone
- The only recovery is a full system reboot

This typically manifests after periods of idle usage (e.g., leaving the PC on overnight) and is particularly common when the I225-V sits deep in the PCIe topology behind multiple bridges.

## Root Cause

The issue is **not** isolated to the NIC itself. Investigation of kernel logs reveals that when the NIC drops, sibling devices behind the same PCIe bridge (WiFi controllers, USB controllers) often die simultaneously or within seconds of each other.

The actual cause is **PCIe bridge power management**. The parent bridges in the PCIe topology have runtime power management (`power/control=auto`) and deep sleep (`d3cold_allowed=1`) enabled by default. When the kernel puts a bridge into a low-power state, the I225-V rev 01 silicon fails to recover from the link state transition, and the PCIe link is permanently lost.

Example failure pattern from kernel logs:

```
xhci_hcd 0000:0f:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT]  # USB controller dies
igc 0000:0c:00.0 enp12s0: PCIe link lost, device now detached  # NIC dies 2s later
xhci_hcd 0000:0f:00.0: HC died; cleaning up                    # USB confirmed dead
iwlwifi 0000:0d:00.0: Hardware error detected. Restarting.      # WiFi dies same second
```

All three devices share a common parent bridge — when the bridge enters a bad power state, everything downstream is lost.

## The Fix

This project provides a three-layer defense: a udev rule for timing-critical boot protection, a systemd service as a safety net, and a watchdog daemon for runtime recovery.

### 1. udev Rule — Early Boot Bridge Lockdown (`10-i225v-bridge-pm.rules`)

The most critical layer. A udev rule that fires the moment each PCIe bridge appears in sysfs — **before** `80-drivers.rules` loads the `igc` module. It uses inline `ATTR{}=` writes (no subprocess) to immediately set:

- `d3cold_allowed=0` — prevents the bridge from entering deep sleep (D3cold)
- `power/control=on` — prevents runtime power management from suspending the bridge

Without this, the kernel's PCIe PM transitions bridges into D3cold during early boot, and by the time any systemd service can run, the `igc` driver has already tried to probe the NIC and found it electrically dead (`Unable to change power state from D3cold to D0, device inaccessible`).

The udev rule is generated at deploy time from the discovered bridge topology. It contains per-bridge rules matching specific PCI slot addresses, plus a static vendor:device rule for the I225-V itself that works without any saved config.

### 2. Bridge Power Lockdown Service (`pcie-bridge-fix.service`)

Safety net that runs at boot after udev trigger. Dynamically discovers the I225-V on the PCI bus, walks the sysfs topology to find every parent bridge, and locks them all down. Also locks sibling devices behind the shared bridge and regenerates the udev rules if the PCIe topology has changed (e.g., after a BIOS update).

If the NIC has already dropped off the bus, the service uses a saved bridge configuration from a previous run to lock down known bridges and rescan the PCIe bus to recover the device.

### 3. Watchdog and Auto-Recovery (`nic-watchdog.service`)

A persistent daemon that monitors kernel messages via `journalctl` for the `PCIe link lost` event. When a drop is detected, it automatically:

1. Re-applies bridge power management fixes
2. Triggers a PCIe bus rescan to re-enumerate the device
3. Reloads the `igc` driver for a clean re-initialization
4. Reconnects via NetworkManager
5. Verifies the interface is back up

The watchdog has a 30-second cooldown between recovery attempts to prevent tight loops.

### Recovery Escalation

When the NIC is not on the PCI bus, the script escalates through 4 recovery strategies:

1. **Saved config rescan** — reads the persistent bridge config and rescans from the deepest known bridge
2. **Empty bridge scan** — finds all PCI bridges with no downstream devices and rescans each one
3. **Aggressive remove + rescan** — removes the empty bridge and rescans from the root port, forcing full re-enumeration
4. **Full PCI bus rescan** — last resort, rescans the entire bus

If all 4 strategies fail, the hardware is stuck in a bad power state and requires a full power cycle (not just a reboot).

## Compatibility

- **Affected hardware**: Intel I225-V rev 01 (PCI ID `8086:15f3`). Later revisions (02, 03) fixed the silicon bug.
- **Tested on**: Fedora with kernel 6.x
- **Should work on**: Any Linux distribution with systemd, on any motherboard with the I225-V rev 01
- **Bridge discovery is fully dynamic** — no hardcoded PCI addresses. The script walks the sysfs topology at runtime, so it works regardless of motherboard PCIe layout.

## Installation

```bash
git clone https://github.com/TheReaperJay/intel-i225v-fix.git
cd intel-i225v-fix
sudo ./deploy.sh
```

The deploy script:
- Detects and upgrades any previous installation (idempotent)
- Applies bridge power fixes immediately (recovering the NIC if needed)
- Saves the bridge chain to `/etc/i225v-bridges.conf` for future boots
- Generates udev rules at `/etc/udev/rules.d/10-i225v-bridge-pm.rules`
- Installs the watchdog script to `/usr/local/bin/`
- Installs both service files to `/etc/systemd/system/`
- Enables and starts both services
- Verifies everything is running

**Note:** For the best first-time install experience, run `deploy.sh` while the NIC is still alive. If the NIC has already dropped and the script cannot recover it, a full power cycle (PSU off, wait 10 seconds, power on) may be needed before deploying.

## Uninstallation

```bash
sudo ./uninstall.sh
```

This stops and disables both services, removes all installed files (including udev rules and saved bridge config), and restores default PCIe power management settings.

## Verifying It Works

Check that udev rules are installed:

```bash
cat /etc/udev/rules.d/10-i225v-bridge-pm.rules
```

Check that the bridge fix applied at boot:

```bash
sudo journalctl -u pcie-bridge-fix --no-pager
```

Check that the watchdog is running:

```bash
sudo journalctl -u nic-watchdog -f
```

Check that bridge power management is locked down:

```bash
cat /sys/bus/pci/devices/<bridge-slot>/power/control   # should be "on"
cat /sys/bus/pci/devices/<bridge-slot>/d3cold_allowed   # should be "0"
```

If a recovery event occurs, you'll see it in the logs:

```bash
sudo journalctl -t i225v-fix --no-pager
```

## Manual Recovery

If you need to manually recover the NIC without rebooting:

```bash
sudo /usr/local/bin/nic-watchdog.sh --recover
```

Re-apply bridge power fixes:

```bash
sudo /usr/local/bin/nic-watchdog.sh --apply-fixes
```

Regenerate udev rules from saved bridge config (e.g., after a BIOS update):

```bash
sudo /usr/local/bin/nic-watchdog.sh --generate-udev
```

## Project Structure

```
intel-i225v-fix/
├── deploy.sh                          # Install script (idempotent)
├── uninstall.sh                       # Uninstall script (restores defaults)
├── scripts/
│   └── nic-watchdog.sh                # Core script: bridge fix + watchdog + recovery
└── services/
    ├── pcie-bridge-fix.service        # Boot-time bridge power lockdown
    └── nic-watchdog.service           # Persistent watchdog daemon
```

## Why Not Just `pcie_aspm=off`?

Disabling ASPM via kernel parameter is a commonly suggested fix, but it only addresses one part of the problem. The PCIe link drops are caused by **runtime power management and D3cold on the parent bridges**, not just ASPM on the NIC endpoint. In testing, ASPM was already disabled at the endpoint while the link drops continued. The bridge-level power management lockdown is what actually prevents the failure.
