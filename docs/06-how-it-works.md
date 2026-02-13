# 06 - How It Works

Related:
- [02 - Quickstart](02-quickstart.md)
- [07 - Code Explained](07-code-explained.md)

1. AR750 bootloader recovery mode requests firmware from `192.168.1.2` via TFTP.
2. `scripts/ar750-recovery.sh` configures wired interface and starts dnsmasq TFTP.
3. `scripts/recover.sh` orchestrates watch/trigger/cleanup/probe.
4. Router pulls `openwrt-gl-ar750.bin`, flashes it, then reboots.
5. Recovery service must be stopped to avoid reflashing loops.
6. Laptop wired interface is returned to DHCP and router UI is probed.

This model separates:
- beginner execution flow
- manual recovery flow
- code-level implementation details
