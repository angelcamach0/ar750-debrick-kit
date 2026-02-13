#!/usr/bin/env bash
set -euo pipefail

# UART helper + network probe helper.
# Keeps serial and probe logic separate from TFTP server control.

SER_DEV="${SER_DEV:-/dev/ttyACM0}"
SER_BAUD="${SER_BAUD:-115200}"
ETH_IF="${ETH_IF:-}"

pick_eth_if() {
  # Best-effort ethernet auto-detection for single-adapter setups.
  [[ -n "$ETH_IF" ]] && return
  if command -v nmcli >/dev/null 2>&1; then
    ETH_IF="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1; exit}')"
  fi
  if [[ -z "$ETH_IF" ]]; then
    ETH_IF="$(
      ip -o link show \
      | awk -F': ' '{print $2}' \
      | awk '$1 !~ /^(lo|wl|docker|br-|veth|virbr|tun|tap|vmnet|zt|tailscale|wg)/ {print; exit}'
    )"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

serial_setup() {
  # Raw serial settings expected by router console.
  sudo stty -F "$SER_DEV" "$SER_BAUD" cs8 -cstopb -parenb -ixon -ixoff -crtscts -echo raw
}

serial_send() {
  local payload="$1"
  printf '%b' "$payload" | sudo tee "$SER_DEV" >/dev/null
}

mode_doctor() {
  # Quick environment check before serial/probe actions.
  pick_eth_if
  echo "Serial: $SER_DEV"
  [[ -e "$SER_DEV" ]] && ls -l "$SER_DEV" || echo "Serial not found"
  echo
  echo "ETH_IF=${ETH_IF:-<none>}"
  [[ -n "$ETH_IF" ]] && ip -4 addr show dev "$ETH_IF" | sed -n '1,40p' || true
}

mode_watch() {
  # Passive serial log view; useful even when interactive typing is unstable.
  serial_setup
  echo "Watching serial on $SER_DEV @ $SER_BAUD (Ctrl+C to stop)..."
  sudo cat "$SER_DEV"
}

mode_send_reset() {
  # Send common OpenWrt reset + reboot sequence via UART.
  serial_setup
  echo "Sending reset sequence over $SER_DEV..."
  serial_send '\r\n'
  sleep 1
  serial_send 'firstboot -y\r\n'
  sleep 2
  serial_send 'jffs2reset -y\r\n'
  sleep 2
  serial_send 'sync\r\n'
  sleep 1
  serial_send 'reboot -f\r\n'
  echo "Reset sequence sent."
}

mode_probe() {
  # Non-destructive reachability checks on common recovery/stock subnets.
  pick_eth_if
  [[ -n "$ETH_IF" ]] || { echo "No ethernet interface detected." >&2; exit 1; }

  echo "WAN/ETH status ($ETH_IF):"
  ip -4 addr show dev "$ETH_IF" | sed -n '1,80p' || true
  echo
  echo "Routes:"
  ip route | sed -n '1,120p'
  echo
  echo "Ping 192.168.1.1 via $ETH_IF"
  ping -I "$ETH_IF" -c 3 192.168.1.1 || true
  echo
  echo "Ping 192.168.8.1 via $ETH_IF"
  ping -I "$ETH_IF" -c 3 192.168.8.1 || true
  echo
  echo "HTTP HEAD 192.168.1.1 via $ETH_IF"
  curl --interface "$ETH_IF" -I --max-time 5 http://192.168.1.1 || true
  echo
  echo "HTTP HEAD 192.168.8.1 via $ETH_IF"
  curl --interface "$ETH_IF" -I --max-time 5 http://192.168.8.1 || true
}

mode_full() {
  mode_send_reset
  echo "Waiting 90s for reboot..."
  sleep 90
  mode_probe
}

usage() {
  cat <<EOF2
Usage: $0 {doctor|watch|send-reset|probe|full}

Env overrides:
  SER_DEV=/dev/ttyACM0
  SER_BAUD=115200
  ETH_IF=<wired-iface>
EOF2
}

main() {
  need_cmd sudo
  need_cmd stty
  need_cmd ip
  need_cmd ping
  need_cmd curl

  case "${1:-}" in
    doctor) mode_doctor ;;
    watch) mode_watch ;;
    send-reset) mode_send_reset ;;
    probe) mode_probe ;;
    full) mode_full ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
