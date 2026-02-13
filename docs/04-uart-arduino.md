# 04 - UART + Arduino

Related:
- [01 - Prerequisites](01-prerequisites.md)
- [02 - Quickstart](02-quickstart.md)
- [05 - Troubleshooting](05-troubleshooting.md)
- [07 - Code Explained](07-code-explained.md)

UART is optional for TFTP recovery, but useful for visibility.

## Electrical Warning (Read First)

- AR750 UART is 3.3V logic.
- Arduino Uno TX is 5V logic.
- Prefer a 3.3V USB-TTL adapter for stable and safer interactive serial.
- Do not connect VCC between router and adapter.

## Pins Used In This Recovery Build

AR750 UART header labels:
- `GND`
- `RX` (GPIO10)
- `TX` (GPIO9)

Session wiring used:
- Router `GND` -> Arduino `GND`
- Router `TX` -> Arduino `RX`
- Router `RX` -> Arduino `TX` (worked, but unstable for typing)

Router power:
- Router must use its own power input.
- Do not power router from Arduino.

## Optional Uno Bridge Trick

Some users tie Arduino `RESET` to `GND` so USB-serial passes through more directly.
Use at your own risk and remove jumper when done.

## UART Terminal Command
```bash
cd /path/to/ar750-debrick-kit
sudo ./scripts/uart_term.py /dev/ttyACM0 115200
```

Exit with `Ctrl+]`.

What this command does:
- opens serial device `/dev/ttyACM0` at `115200` baud
- switches your terminal to raw mode
- forwards bytes both ways between keyboard and router UART
- prints bootloader/kernel logs in real time

Why firmware placement still matters:
- bootloader requests `openwrt-gl-ar750.bin` over TFTP
- recovery scripts copy your selected `.bin` to that exact expected filename
- if firmware selection is wrong, UART logs will show failed TFTP or repeated boot loops

## What Good UART Recovery Output Looks Like

- `TFTP from server 192.168.1.2`
- `Filename 'openwrt-gl-ar750.bin'`
- `Bytes transferred = ...`
- `Copy to Flash... done`
- `OK!`

After `OK!`, wait a few minutes. Flash + first boot initialization takes time. Do not unplug power during this phase. Let the router finish booting and settle before UI checks.

After that, return to [02 - Quickstart](02-quickstart.md#step-5-move-to-normal-router-access).

## `uart_term.py` Code Walkthrough (Short)

1. Parses serial device + baud (`/dev/ttyACM0`, `115200` defaults).
2. Opens serial device nonblocking.
3. Configures raw 8N1 serial via `termios`.
4. Sets stdin to raw mode.
5. Uses `select()` loop to forward serial<->keyboard bytes.
6. `write_all()` handles partial writes and EAGAIN safely.
7. Restores terminal settings in `finally` block.

Why typing can still be unstable:
- I patched script I/O handling (`write_all` + better nonblocking write behavior), which reduced crashes and partial-write issues
- but unstable typing still occurred in some sessions due to electrical/interface limits (Uno 5V TX and passthrough behavior), not just code
- practical outcome: `uart_term.py` is reliable for reading logs, while interactive typing is best with a proper 3.3V USB-TTL adapter
