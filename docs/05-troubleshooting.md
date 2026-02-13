# 05 - Troubleshooting

Related:
- [02 - Quickstart](02-quickstart.md)
- [03 - Manual Recovery](03-manual-recovery.md)
- [04 - UART + Arduino](04-uart-arduino.md)

## Symptom: No TFTP RRQ Seen

Likely causes:
- wrong port (not WAN during trigger)
- wrong interface selected
- firmware not present as expected

Actions:
1. Re-run quickstart from trigger step.
2. Use manual capture:

```bash
sudo tcpdump -ni <wired_iface> 'arp or icmp or udp port 69'
```

Why this helps:
- ARP proves router and laptop can see each other on Layer 2.
- ICMP proves basic IP reachability in recovery network.
- UDP/69 RRQ proves bootloader is actually asking for firmware.
- If RRQ is missing, issue is trigger/port/interface state, not firmware file content.

## Symptom: Router Reflashes Every Boot

Cause:
- recovery service still active and/or static `192.168.1.2` left configured

Fix:

```bash
./scripts/ar750-recovery.sh stop || true
sudo ip addr flush dev <wired_iface>
```

Then continue at [02 - Quickstart](02-quickstart.md#step-5-move-to-normal-router-access).

## Symptom: Phone Can Reach Router, Laptop Cannot

Cause:
- laptop interface stuck in old recovery network state

Also, if Wi-Fi is still active on the same subnet, Linux can choose the wrong route/interface (Wi-Fi instead of wired). That can make probes look broken even when router is fine.

Fix:
```bash
sudo ip addr flush dev <wired_iface>
sudo dhclient -r <wired_iface> || true
sudo dhclient -v <wired_iface>
```

This clears stale static recovery IPs and requests a fresh DHCP lease from the router, which restores normal management connectivity.

## Symptom: UART Output Garbled / Cannot Type Reliably
Cause:
- common with Arduino Uno path
- Uno TX is 5V while router UART is 3.3V
- USB-serial passthrough behavior with Uno can be inconsistent
- electrical noise/level mismatch causes dropped or corrupted typed characters

Fix:
- use UART mainly for log viewing
- prefer 3.3V USB-TTL adapter for reliable interactive input
- verify baud is `115200`
- keep router powered by its own adapter, never by Arduino
- if typing is unreliable but logs are visible, complete recovery via TFTP flow and use UART only for monitoring
- if you must send a one-shot command, direct write can work:

```bash
printf '\r\n' | sudo tee /dev/ttyACM0 >/dev/null
printf 'reboot -f\r\n' | sudo tee /dev/ttyACM0 >/dev/null
```

This is a workaround, not a guaranteed interactive fix.

What happened during validation:
- patching `uart_term.py` improved stability and prevented some write-loop failures
- it did not fully fix corrupted interactive typing on Uno
- recovery still succeeded because TFTP flashing was the primary path, and UART was used mainly for visibility

See [04 - UART + Arduino](04-uart-arduino.md).
