# 02 - Quickstart (Primary Path)

Related:
- [01 - Prerequisites](01-prerequisites.md)
- [Safety Checklist](safety-checklist.md)
- [05 - Troubleshooting](05-troubleshooting.md)
- [04 - UART + Arduino](04-uart-arduino.md)

## Step 1: Run One Command
Optional preflight (recommended):

```bash
./scripts/recover.sh --dry-run
```

If auto-detection picks the wrong adapter, run with explicit interface:

```bash
./scripts/recover.sh --eth-if <wired_iface>
```

```bash
cd /path/to/ar750-debrick-kit
chmod +x scripts/*.sh
./scripts/recover.sh
```

The script will show a safety confirmation before reconfiguring your wired interface.
If you are running in a non-interactive shell, use:

```bash
./scripts/recover.sh --yes
```

What this command does internally:
- selects your wired interface
- configures `192.168.1.2/24` for recovery
- starts TFTP server (`dnsmasq`)
- waits for router recovery request (`openwrt-gl-ar750.bin`)
- verifies transfer activity from recovery logs when possible
- stops recovery service after transfer
- restores DHCP and probes router UI

Fallback mode for unusual systems:

```bash
./scripts/recover.sh --post-flash-wait-only
```

This skips log-based transfer detection and uses the configured wait timer.

Code details: [07 - Code Explained](07-code-explained.md)

## Step 2: Follow Physical Prompt

When prompted during recovery trigger:

1. Connect laptop ethernet -> router **WAN**
2. Power off router for 10 seconds
3. Press and hold router reset
4. Power on router while still holding reset
5. Keep holding reset for about 8-15 seconds, then release
6. If no TFTP request appears, repeat once and try the opposite ethernet port (WAN vs LAN) for trigger

Power rule:
- power router from its own adapter (or its own USB power source), not from Arduino
- do not connect router VCC to Arduino VCC (UART is signal-only + GND)

## Step 3: Watch Success Signals
Network side (from logs):
- ARP from `192.168.1.1`
- ICMP ping to `192.168.1.2`
- TFTP RRQ for `openwrt-gl-ar750.bin`

You should see these in:
- terminal output from `recover.sh`
- `logs/dnsmasq-ar750.log`
- `logs/tcpdump-recovery.log` (if capture is enabled)

UART side (if connected):
- `TFTP from server 192.168.1.2`
- `Bytes transferred = ...`
- `Copy to Flash... done`
- `OK!`

## Step 4: Critical Stop Condition

After successful transfer/flash, recovery service must be stopped.
`recover.sh` does this automatically.

If you run manually:

```bash
./scripts/ar750-recovery.sh stop || true
```

## Step 5: Move to Normal Router Access

1. Move cable from router **WAN** -> **LAN**
2. Wait 2-3 minutes
3. Renew DHCP and test:
```bash
sudo dhclient -r <wired_iface> || true
sudo dhclient -v <wired_iface>
ping -I <wired_iface> -c 3 192.168.8.1
curl --interface <wired_iface> -I --max-time 5 http://192.168.8.1
```

Why this matters:
- recovery mode uses static `192.168.1.2`
- normal router mode usually serves DHCP (often `192.168.8.x`)
- renewing DHCP moves your laptop from recovery network to normal management network

Then open:
- `http://192.168.8.1`

## Step 6: Final Validation

1. Set admin password in UI.
2. Reboot router once.
3. Confirm UI returns at `http://192.168.8.1`.

If anything fails: [05 - Troubleshooting](05-troubleshooting.md)
