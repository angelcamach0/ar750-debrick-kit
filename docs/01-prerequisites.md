# 01 - Prerequisites

Related:
- [README](../README.md)
- [Safety Checklist](safety-checklist.md)
- [02 - Quickstart](02-quickstart.md)
- [04 - UART + Arduino](04-uart-arduino.md)

## Who This Is For

Use this repo if your GL-AR750 is not reachable and you already tried:
- power cycle
- reset button hold
- waiting several minutes after boot

## Required Hardware

- GL-AR750 router
- Router power adapter
- Ethernet cable
- Linux laptop/desktop
- USB Ethernet adapter (if laptop has no ethernet port)

## Optional Hardware (UART fallback) 
- 3.3V USB-TTL adapter (recommended)
- Or Arduino Uno + jumper wires (works for logs, interactive typing can be unstable)

If you already know you need UART right now, jump to:
- [04 - UART + Arduino](04-uart-arduino.md)
- [03 - Manual Recovery](03-manual-recovery.md)

Fastest path for most users is still [02 - Quickstart](02-quickstart.md) first, then add UART only if needed.

## Required Linux Packages

```bash
sudo apt update
sudo apt install -y dnsmasq tcpdump curl isc-dhcp-client iproute2
```

Optional (for nicer interface discovery output):

```bash
sudo apt install -y network-manager
```

## Find Your Interfaces

```bash
ip -br link
nmcli device status
```

Typical names:
- wired: `enx...` or `enp...`
- wifi: `wlp...`

If `nmcli` is unavailable, `ip -br link` is enough.

## Firmware Preparation

1. Put exactly one `.bin` file in `firmware/`.
Choose firmware for your exact model/revision (for example GL-AR750) from either:
- GL.iNet official firmware downloads (stock firmware)
- OpenWrt firmware selector/downloads (OpenWrt firmware)

Do not use firmware for a different model (for example AR300M vs AR750).
If you are unsure which image type to use first, use the GL.iNet stock image for your exact AR750 hardware revision.
2. Confirm:
```bash
ls -lh firmware  
```
This check makes sure `scripts/recover.sh` can auto-pick one firmware file. The script intentionally refuses to run if there are zero files or multiple `.bin` files to prevent flashing the wrong image.

If there are 0 or >1 files, `recover.sh` will stop and explain what to fix.

If you want to skip directly to the fastest recovery execution path after this checklist, continue with:
- [02 - Quickstart / Step 1](02-quickstart.md#step-1-run-one-command)

Safer path before live flashing:
- [Safety Checklist](safety-checklist.md)

## Safety Warnings

- This is router firmware flashing, not PC BIOS work.
- Router UART is 3.3V logic.
- Arduino Uno TX is 5V logic.
- Do not connect UART VCC between router and adapter.

Next: [02 - Quickstart](02-quickstart.md)
