# 07 - Code Explained

Related:
- [02 - Quickstart](02-quickstart.md)
- [03 - Manual Recovery](03-manual-recovery.md)
- [06 - How It Works](06-how-it-works.md)

## Script Roles

1. `scripts/recover.sh`
- One-command orchestrator.
- Starts recovery service, captures traffic, optionally captures serial, performs cleanup, restores DHCP, probes UI.
- Supports `--dry-run` to print planned actions without changing network/process state.
- Supports `--eth-if` to force interface selection.
- Supports `--post-flash-wait-only` to skip log heuristics and rely on fixed settle wait.

2. `scripts/ar750-recovery.sh`
- TFTP helper with modes `check|prep|serve|stop|run`.
- Selects wired interface, resolves firmware file, sets `192.168.1.2/24`, starts dnsmasq.

3. `scripts/router-recover.sh`
- UART helper (`doctor|watch|send-reset`) and connectivity probe helper.

4. `scripts/uart_term.py`
- Dependency-free UART terminal with raw mode + bidirectional forwarding.

## `recover.sh` Flow

- `parse_args()`: reads safety/control flags (`--yes`, `--dry-run`, `--eth-if`, `--post-flash-wait-only`).
- `pick_firmware()`: enforce exactly one `.bin` in firmware dir.
- `pick_eth_if()`: detect wired interface (`nmcli` fallback to `ip`).
- `confirm_iface_action()`: explicit safety check before flushing/reconfiguring interface.
- `wait_for_transfer_state()`: watch RRQ and dnsmasq transfer logs, then apply post-flash settle wait.
- `cleanup_recovery()`: stop recovery service + tracked background processes.
- `switch_to_dhcp()`: remove static recovery IP, renew DHCP.
- `probe_ui()`: test `192.168.8.1` and `192.168.1.1`.

## Reliability Notes

- The orchestrator tracks PIDs for started captures/watchers and cleans them on exit/interruption.
- Scripts intentionally avoid touching Wi-Fi config directly.
- Interface auto-detection filters out common virtual interfaces.
- `ar750-recovery.sh stop` verifies PID ownership against expected dnsmasq cmdline before kill.

## Why The Code Looks Like This

This code was shaped by real recovery behavior observed during troubleshooting:

1. Bootloader pattern repeatedly observed:
- ARP from `192.168.1.1` to `192.168.1.2`
- ICMP ping check
- TFTP RRQ for `openwrt-gl-ar750.bin`

2. Failure mode observed:
- leaving recovery server running can trigger reflashing loops on subsequent boots

3. Practical constraints observed:
- interface ambiguity on Linux laptops (Wi-Fi + USB Ethernet + virtual adapters)
- unstable UART typing via Arduino Uno while log viewing still worked

Those observations led to:
- explicit interface confirmations before destructive network reconfiguration
- stricter stop logic for dnsmasq PID handling
- recovery detection based on network + transfer logs (not just one signal)

## Future Improvements

1. Add lightweight smoke/integration checks for argument parsing and non-destructive flows.
2. Add CLI flags for RRQ/flash wait times.
3. Add shellcheck CI.
4. Add structured state file in `logs/`.
