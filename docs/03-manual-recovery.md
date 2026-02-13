# 03 - Manual Recovery (No One-Command Orchestrator)

Related:
- [02 - Quickstart](02-quickstart.md)
- [05 - Troubleshooting](05-troubleshooting.md)

Use this when you need explicit control over each stage.

## 1) Start TFTP Recovery Service

```bash
./scripts/ar750-recovery.sh check
./scripts/ar750-recovery.sh run
```

If running non-interactively, add `ASSUME_YES=1`:

```bash
ASSUME_YES=1 ./scripts/ar750-recovery.sh run
```

## 2) Watch Recovery Traffic

```bash
sudo tcpdump -ni <wired_iface> 'arp or icmp or udp port 69'
```

## 3) Trigger Recovery

- Connect cable to router WAN
- Power-cycle router (10s off, then on)
- Hold reset during boot only if required by your unit

## 4) Optional UART Monitoring

```bash
./scripts/router-recover.sh doctor
sudo ./scripts/uart_term.py /dev/ttyACM0 115200
```

Exit UART terminal with `Ctrl+]`.

## 5) Stop Recovery Service Immediately After Success

```bash
./scripts/ar750-recovery.sh stop || true
```

`stop` now validates that the PID file belongs to the expected recovery `dnsmasq` process before killing it.

## 6) Restore DHCP + Probe UI

```bash
sudo ip addr flush dev <wired_iface>
sudo dhclient -r <wired_iface> || true
sudo dhclient -v <wired_iface>
./scripts/router-recover.sh probe
```

If needed, continue with [05 - Troubleshooting](05-troubleshooting.md).
