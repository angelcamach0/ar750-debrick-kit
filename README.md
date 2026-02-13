# ar750-debrick-kit

Recover and reflash a GL-AR750 using a guided, script-first workflow.

## Start Here

1. Read [01-prerequisites.md](docs/01-prerequisites.md)
2. Run [safety-checklist.md](docs/safety-checklist.md)
3. Run [02-quickstart.md](docs/02-quickstart.md)
4. If anything fails, jump to [05-troubleshooting.md](docs/05-troubleshooting.md)

## Quick Command

```bash
cd ar750-debrick-kit
chmod +x scripts/*.sh
./scripts/recover.sh
```

Preview planned actions only:

```bash
./scripts/recover.sh --dry-run
```

Pin to a specific wired interface:

```bash
./scripts/recover.sh --eth-if enx00e04c6876c4
```

If transfer logs are unreliable on your system, use fixed timer mode:

```bash
./scripts/recover.sh --post-flash-wait-only
```

For unattended/non-interactive runs:

```bash
./scripts/recover.sh --yes
```

Fast SSH helper (auto-detect iface + host):

```bash
./scripts/ssh-router.sh
```

If routing is ambiguous, pin interface and optionally bring Wi-Fi down during checks:

```bash
./scripts/ssh-router.sh --iface enx00e04c6876c4 --down-wifi
```

## Safety First

- This repo flashes **router firmware** (not PC BIOS).
- Router UART is 3.3V logic; Arduino Uno TX is 5V logic.
- Do not connect UART VCC between devices.
- Router must be powered by its own power supply.

For wiring details, read [04-uart-arduino.md](docs/04-uart-arduino.md).
Pinout image: [docs/assets/ar750-pinout.jpg](docs/assets/ar750-pinout.jpg).

## Documentation Map

- [01-prerequisites.md](docs/01-prerequisites.md): hardware/software checklist, firmware prep, interface discovery
- [02-quickstart.md](docs/02-quickstart.md): primary guided path (one command)
- [safety-checklist.md](docs/safety-checklist.md): preflight checks + dry-run before live flashing
- [03-manual-recovery.md](docs/03-manual-recovery.md): manual fallback without one-command orchestrator
- [04-uart-arduino.md](docs/04-uart-arduino.md): exact UART wiring + `uart_term.py` explanation
- [05-troubleshooting.md](docs/05-troubleshooting.md): symptom -> fix matrix
- [06-how-it-works.md](docs/06-how-it-works.md): conceptual architecture
- [07-code-explained.md](docs/07-code-explained.md): script-level implementation walkthrough

## Scripts

- `scripts/recover.sh`: one-command orchestrator
- `scripts/ar750-recovery.sh`: TFTP service helper
- `scripts/router-recover.sh`: UART/probe helper
- `scripts/uart_term.py`: minimal dependency-free UART terminal
- `scripts/ssh-router.sh`: reachability + DHCP retry + SSH launcher

## Runtime Logs

- `logs/dnsmasq-ar750.log`
- `logs/tcpdump-recovery.log`
- `logs/serial.log` (if UART watch started)

## Important Post-Flash Rule

If flash succeeds, stop recovery services immediately.
If recovery remains active, the router can reflash again on the next boot.

## Legal

- License: [MIT](LICENSE)
- Safety + liability disclaimer: [docs/disclaimer.md](docs/disclaimer.md)
