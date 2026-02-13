#!/usr/bin/env bash
set -euo pipefail

# One-command orchestrator:
# - bring up TFTP recovery service
# - capture recovery traffic
# - optionally capture serial output
# - stop recovery service to avoid reflash loops
# - restore DHCP and probe UI

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"
LOGS_DIR="${LOGS_DIR:-$ROOT_DIR/logs}"
FIRMWARE_DIR="${FIRMWARE_DIR:-$ROOT_DIR/firmware}"

ETH_IF="${ETH_IF:-}"
SER_DEV="${SER_DEV:-/dev/ttyACM0}"
SER_BAUD="${SER_BAUD:-115200}"
FW_NAME="${FW_NAME:-openwrt-gl-ar750.bin}"
ASSUME_YES="${ASSUME_YES:-0}"
POST_FLASH_WAIT_SEC="${POST_FLASH_WAIT_SEC:-120}"
DRY_RUN="${DRY_RUN:-0}"
POST_FLASH_WAIT_ONLY="${POST_FLASH_WAIT_ONLY:-0}"

AR750="$SCRIPTS_DIR/ar750-recovery.sh"
ROUTER="$SCRIPTS_DIR/router-recover.sh"
TCPDUMP_PID=""
SERIAL_WATCH_PID=""
RECOVERY_STARTED=0

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }

usage() {
  cat <<EOF2
Usage: $0 [--yes] [--dry-run] [--eth-if IFACE] [--post-flash-wait-only]

Options:
  -y, --yes                  Skip interactive safety confirmations
  -n, --dry-run              Show planned actions without changing network/process state
      --eth-if IFACE         Use explicit wired interface (skip auto-detect)
      --post-flash-wait-only Skip RRQ/transfer detection and rely on fixed wait timer

Env overrides:
  ETH_IF=<wired iface>
  FW_NAME=openwrt-gl-ar750.bin
  ASSUME_YES=1
  POST_FLASH_WAIT_SEC=120
  DRY_RUN=1
  POST_FLASH_WAIT_ONLY=1
EOF2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      --eth-if)
        [[ $# -ge 2 ]] || { echo "--eth-if requires an interface value" >&2; exit 1; }
        ETH_IF="$2"
        shift 2
        ;;
      --post-flash-wait-only)
        POST_FLASH_WAIT_ONLY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

banner() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

pick_firmware() {
  local bins
  # Enforce exactly one firmware to avoid accidental wrong image selection.
  mapfile -t bins < <(find "$FIRMWARE_DIR" -maxdepth 1 -type f -iname '*.bin' | sort)
  if [[ "${#bins[@]}" -eq 0 ]]; then
    echo "ERROR: No .bin found in: $FIRMWARE_DIR" >&2
    echo "Drop exactly one firmware .bin into firmware/ then re-run." >&2
    exit 1
  fi
  if [[ "${#bins[@]}" -gt 1 ]]; then
    echo "ERROR: Multiple .bin files found in: $FIRMWARE_DIR" >&2
    printf ' - %s\n' "${bins[@]}" >&2
    echo "Leave only one .bin or set FIRMWARE_BIN=..." >&2
    exit 1
  fi
  echo "${bins[0]}"
}

pick_eth_if() {
  if [[ -z "$ETH_IF" ]]; then
    # Prefer connected ethernet first, then any ethernet.
    if command -v nmcli >/dev/null 2>&1; then
      ETH_IF="$(
        nmcli -t -f DEVICE,TYPE,STATE device status \
        | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}'
      )"
      if [[ -z "$ETH_IF" ]]; then
        ETH_IF="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1; exit}')"
      fi
    fi
    if [[ -z "$ETH_IF" ]]; then
      ETH_IF="$(
        ip -o link show \
        | awk -F': ' '{print $2}' \
        | awk '$1 !~ /^(lo|wl|docker|br-|veth|virbr|tun|tap|vmnet|zt|tailscale|wg)/ {print; exit}'
      )"
    fi
  fi
  [[ -n "$ETH_IF" ]] || { echo "Could not auto-detect ethernet interface. Set ETH_IF=..." >&2; exit 1; }
  [[ -e "/sys/class/net/$ETH_IF" ]] || { echo "Interface not found: $ETH_IF" >&2; exit 1; }
}

confirm_iface_action() {
  local ipv4
  local route
  ipv4="$(ip -4 -o addr show dev "$ETH_IF" | awk '{print $4}' | paste -sd ',' -)"
  route="$(ip route | awk -v i="$ETH_IF" '$0 ~ (" dev " i " ") {print}' | head -n 2)"
  [[ -n "$ipv4" ]] || ipv4="<none>"
  [[ -n "$route" ]] || route="<none>"

  echo "Safety check:"
  echo "- target interface: $ETH_IF"
  echo "- current IPv4    : $ipv4"
  echo "- sample routes   : $route"
  echo
  echo "This script will flush/reconfigure this interface for recovery."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry-run mode: confirmation accepted automatically."
    return 0
  fi

  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Non-interactive shell detected. Re-run with --yes if this interface is correct." >&2
    exit 1
  fi

  read -r -p "Continue with interface '$ETH_IF'? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted by user."; exit 1 ;;
  esac
}

start_serial_watch() {
  if [[ -e "$SER_DEV" ]]; then
    banner "Serial device detected: $SER_DEV (starting background watch)"
    echo "Note: Arduino Uno TX is 5V; use caution. 3.3V USB-TTL is preferred."
    (SER_DEV="$SER_DEV" SER_BAUD="$SER_BAUD" ETH_IF="$ETH_IF" "$ROUTER" watch) >"$LOGS_DIR/serial.log" 2>&1 &
    SERIAL_WATCH_PID="$!"
    echo "Serial log: $LOGS_DIR/serial.log"
  else
    echo "Serial not found at $SER_DEV (continuing without UART watch)."
  fi
}

wait_for_transfer_state() {
  local timeout="${1:-180}"
  local pcap_log="$LOGS_DIR/tcpdump-recovery.log"
  local dns_log="$LOGS_DIR/dnsmasq-ar750.log"
  local rrq_pattern sent_pattern
  local start now
  start="$(date +%s)"
  rrq_pattern="RRQ \"$FW_NAME\""
  sent_pattern="sent .*$FW_NAME"
  local rrq_seen=0

  echo "Waiting up to ${timeout}s for recovery activity ..."
  while true; do
    if [[ -f "$pcap_log" ]] && grep -Fq "$rrq_pattern" "$pcap_log"; then
      rrq_seen=1
    fi
    if [[ -f "$dns_log" ]] && grep -Eq "$sent_pattern" "$dns_log"; then
      echo "Detected firmware transfer in dnsmasq log."
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout )); then
      if (( rrq_seen == 1 )); then
        echo "Detected RRQ, but did not confirm transfer completion from logs before timeout."
        return 2
      fi
      echo "No RRQ detected before timeout."
      return 1
    fi
    sleep 2
  done
}

cleanup_recovery() {
  if (( RECOVERY_STARTED == 0 )) && [[ -z "$TCPDUMP_PID" ]] && [[ -z "$SERIAL_WATCH_PID" ]]; then
    return 0
  fi
  banner "Stopping recovery server"
  if (( RECOVERY_STARTED == 1 )); then
    "$AR750" stop || true
  fi
  if [[ -n "$TCPDUMP_PID" ]]; then
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERIAL_WATCH_PID" ]]; then
    sudo kill "$SERIAL_WATCH_PID" 2>/dev/null || true
  fi
}

cleanup_on_exit() {
  # Prevent stale recovery processes if script is interrupted.
  cleanup_recovery || true
}

switch_to_dhcp() {
  banner "Switching $ETH_IF back to DHCP"
  sudo ip addr flush dev "$ETH_IF" || true
  sudo dhclient -r "$ETH_IF" || true
  sudo dhclient -v "$ETH_IF" || true
}

probe_ui() {
  banner "Probing router UI"
  ETH_IF="$ETH_IF" "$ROUTER" probe || true
}

main() {
  parse_args "$@"
  trap cleanup_on_exit EXIT INT TERM
  mkdir -p "$LOGS_DIR" "$ROOT_DIR/tftp-root"

  need sudo
  need tcpdump
  need curl
  need ping
  need ip
  need dhclient

  pick_eth_if
  confirm_iface_action
  local fw
  fw="$(pick_firmware)"

  banner "AR750 Debrick - One Command"
  echo "Repo      : $ROOT_DIR"
  echo "ETH_IF    : $ETH_IF"
  echo "Firmware  : $fw"
  echo "FW_NAME   : $FW_NAME"
  echo "DRY_RUN   : $DRY_RUN"
  echo "WAIT_ONLY : $POST_FLASH_WAIT_ONLY"
  echo

  if [[ "$DRY_RUN" == "1" ]]; then
    banner "Dry Run Plan (no changes applied)"
    cat <<EOF2
Would run:
- ETH_IF="$ETH_IF" FIRMWARE_BIN="$fw" FIRMWARE_DIR="$FIRMWARE_DIR" FW_NAME="$FW_NAME" ASSUME_YES=1 TFTP_DIR="$ROOT_DIR/tftp-root" LOG_DIR="$LOGS_DIR" DNSMASQ_LOG="$LOGS_DIR/dnsmasq-ar750.log" PID_FILE="$LOGS_DIR/dnsmasq-ar750.pid" "$AR750" run
- sudo tcpdump -ni "$ETH_IF" 'arp or icmp or udp port 69' >"$LOGS_DIR/tcpdump-recovery.log"
- Wait mode: $( [[ "$POST_FLASH_WAIT_ONLY" == "1" ]] && echo "fixed timer only" || echo "RRQ/transfer detection + timer" )
- Sleep $POST_FLASH_WAIT_SEC seconds for post-flash settle
- "$AR750" stop
- sudo ip addr flush dev "$ETH_IF"
- sudo dhclient -r "$ETH_IF" || true
- sudo dhclient -v "$ETH_IF"
- ETH_IF="$ETH_IF" "$ROUTER" probe
EOF2
    banner "Dry Run Complete"
    exit 0
  fi

  banner "Step 1: Start TFTP recovery service"
  ETH_IF="$ETH_IF" \
  FIRMWARE_BIN="$fw" \
  FIRMWARE_DIR="$FIRMWARE_DIR" \
  FW_NAME="$FW_NAME" \
  ASSUME_YES=1 \
  TFTP_DIR="$ROOT_DIR/tftp-root" \
  LOG_DIR="$LOGS_DIR" \
  DNSMASQ_LOG="$LOGS_DIR/dnsmasq-ar750.log" \
  PID_FILE="$LOGS_DIR/dnsmasq-ar750.pid" \
  "$AR750" run
  RECOVERY_STARTED=1

  banner "Step 2: Start packet watch"
  sudo tcpdump -ni "$ETH_IF" 'arp or icmp or udp port 69' >"$LOGS_DIR/tcpdump-recovery.log" 2>&1 &
  TCPDUMP_PID="$!"
  echo "tcpdump log: $LOGS_DIR/tcpdump-recovery.log"

  start_serial_watch

  banner "Step 3: Trigger router recovery"
  echo "1) Plug laptop Ethernet into router WAN (first try)."
  echo "2) Power off router for 10 seconds."
  echo "3) Power on router (hold reset if your model requires it)."
  echo "4) Wait."

  local transfer_rc=0
  if [[ "$POST_FLASH_WAIT_ONLY" == "1" ]]; then
    echo "Post-flash wait-only mode enabled; skipping RRQ/transfer detection."
    echo "Sleeping ${POST_FLASH_WAIT_SEC}s for recovery + reboot settle..."
    sleep "$POST_FLASH_WAIT_SEC"
  elif wait_for_transfer_state 240; then
    echo "Waiting an additional ${POST_FLASH_WAIT_SEC}s for flash/reboot to settle..."
    sleep "$POST_FLASH_WAIT_SEC"
  else
    transfer_rc=$?
    if [[ "$transfer_rc" -eq 2 ]]; then
    echo "Proceeding with conservative post-flash wait (${POST_FLASH_WAIT_SEC}s)."
    sleep "$POST_FLASH_WAIT_SEC"
    else
      echo "Recovery request not detected. You can retry with WAN/LAN swap and rerun script."
    fi
  fi

  banner "Step 4: Stop recovery to avoid reflash loops"
  cleanup_recovery
  RECOVERY_STARTED=0

  banner "Step 5: Move cable to router LAN and wait 2-3 minutes"
  echo "Press Enter after moving cable to LAN and waiting..."
  read -r _

  switch_to_dhcp
  probe_ui

  banner "Done"
  echo "Try opening: http://192.168.8.1"
  echo "Logs:"
  echo "- $LOGS_DIR/dnsmasq-ar750.log"
  echo "- $LOGS_DIR/tcpdump-recovery.log"
  echo "- $LOGS_DIR/serial.log (if UART found)"
}

main "$@"
