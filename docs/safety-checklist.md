# Safety Checklist (Run Before Flash)

Related:
- [01 - Prerequisites](01-prerequisites.md)
- [02 - Quickstart](02-quickstart.md)
- [03 - Manual Recovery](03-manual-recovery.md)

Use this checklist to reduce mistakes before running recovery scripts.

## 1) Confirm Hardware and Power

- Router is GL-AR750 (correct model/revision for the firmware you selected).
- Router has its own power source (not powered from Arduino).
- UART VCC is not connected.
- If using Arduino Uno, understand it is best for log viewing; interactive typing can be unstable.

## 2) Confirm Firmware File

- Exactly one `.bin` file exists in `firmware/`.
- File is for GL-AR750 (not another model).

Check:

```bash
ls -lh firmware
```

## 3) Confirm Target Wired Interface

Identify interface names:

```bash
ip -br link
nmcli device status
```

Know which interface you expect recovery scripts to use (for example `enx...`).

## 4) Dry-Run The Orchestrator First

Run:

```bash
./scripts/recover.sh --dry-run
```

What this gives you:
- shows selected interface
- shows selected firmware
- shows exact commands that would run
- does **not** change network settings or start recovery services
- still validates basic prerequisites (interface selection + firmware presence)

If interface or firmware looks wrong, stop and fix that first.

## 5) Use Explicit Overrides If Needed

If auto-detection is wrong, set explicit values:

```bash
./scripts/recover.sh --eth-if <wired_iface>
```

For non-interactive environments:

```bash
ASSUME_YES=1 ./scripts/recover.sh --yes --eth-if <wired_iface>
```

If your environment does not produce reliable transfer log lines, use:

```bash
./scripts/recover.sh --post-flash-wait-only --eth-if <wired_iface>
```

## 6) Post-Flash Safety Rule

After successful transfer, recovery service must be stopped to avoid reflashing loops.
The orchestrator does this automatically; manual flow requires explicit stop.

Next: [02 - Quickstart](02-quickstart.md)
