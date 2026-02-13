#!/usr/bin/env bash
set -euo pipefail

# AR750 TFTP recovery helper.
# - Refuses wireless interfaces.
# - Sets ETH_IF to 192.168.1.2/24.
# - Serves FW_NAME over TFTP with dnsmasq.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ETH_IF="${ETH_IF:-}"
FW_NAME="${FW_NAME:-openwrt-gl-ar750.bin}"
FIRMWARE_DIR="${FIRMWARE_DIR:-$ROOT_DIR/firmware}"
FIRMWARE_BIN="${FIRMWARE_BIN:-}"
TFTP_DIR="${TFTP_DIR:-$ROOT_DIR/tftp-root}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
PID_FILE="${PID_FILE:-$LOG_DIR/dnsmasq-ar750.pid}"
DNSMASQ_LOG="${DNSMASQ_LOG:-$LOG_DIR/dnsmasq-ar750.log}"
ASSUME_YES="${ASSUME_YES:-0}"

need_cmd() {
  # Fail fast on missing runtime dependencies.
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

pick_eth_if() {
  # Default to the first ethernet interface. Prefer nmcli, fallback to ip.
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

validate_if() {
  # Refuse wireless interfaces to avoid accidentally reconfiguring Wi-Fi.
  [[ -n "$ETH_IF" ]] || { echo "Set ETH_IF=<wired_interface>." >&2; exit 1; }
  [[ -e "/sys/class/net/$ETH_IF" ]] || { echo "Interface not found: $ETH_IF" >&2; exit 1; }
  if [[ -d "/sys/class/net/$ETH_IF/wireless" ]]; then
    echo "Refusing wireless interface: $ETH_IF" >&2
    exit 1
  fi
}

confirm_iface_reconfig() {
  local ipv4
  local route
  ipv4="$(ip -4 -o addr show dev "$ETH_IF" | awk '{print $4}' | paste -sd ',' -)"
  route="$(ip route | awk -v i="$ETH_IF" '$0 ~ (" dev " i " ") {print}' | head -n 2)"
  [[ -n "$ipv4" ]] || ipv4="<none>"
  [[ -n "$route" ]] || route="<none>"

  echo "About to reconfigure interface: $ETH_IF"
  echo "Current IPv4: $ipv4"
  echo "Sample routes: $route"

  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Non-interactive shell; set ASSUME_YES=1 if this interface is correct." >&2
    exit 1
  fi

  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted by user."; exit 1 ;;
  esac
}

resolve_firmware_bin() {
  # Prefer explicit path, otherwise auto-pick exactly one .bin from firmware dir.
  if [[ -n "$FIRMWARE_BIN" ]]; then
    [[ -f "$FIRMWARE_BIN" ]] || { echo "Firmware not found: $FIRMWARE_BIN" >&2; exit 1; }
    return
  fi

  mapfile -t bins < <(find "$FIRMWARE_DIR" -maxdepth 1 -type f -iname '*.bin' | sort)

  if [[ "${#bins[@]}" -eq 0 ]]; then
    echo "No .bin firmware found in: $FIRMWARE_DIR" >&2
    echo "Put exactly one firmware .bin in firmware/ or set FIRMWARE_BIN=/path/file.bin" >&2
    exit 1
  fi

  if [[ "${#bins[@]}" -gt 1 ]]; then
    echo "Multiple .bin files found in: $FIRMWARE_DIR" >&2
    printf ' - %s\n' "${bins[@]}" >&2
    echo "Leave exactly one .bin, or pass FIRMWARE_BIN explicitly." >&2
    exit 1
  fi

  FIRMWARE_BIN="${bins[0]}"
}

mode_check() {
  # Non-destructive diagnostics for current runtime configuration.
  pick_eth_if
  validate_if
  resolve_firmware_bin || true

  echo "ETH_IF=$ETH_IF"
  echo "FW_NAME=$FW_NAME"
  echo "FIRMWARE_DIR=$FIRMWARE_DIR"
  [[ -n "$FIRMWARE_BIN" ]] && echo "FIRMWARE_BIN=$FIRMWARE_BIN"
  echo "TFTP_DIR=$TFTP_DIR"
  echo "DNSMASQ_LOG=$DNSMASQ_LOG"
  echo
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f DEVICE,TYPE,STATE device status
  else
    ip -br link
  fi
}

mode_prep() {
  # Prepare TFTP payload and static recovery IP.
  pick_eth_if
  validate_if
  confirm_iface_reconfig
  resolve_firmware_bin
  need_cmd sudo
  need_cmd ip

  mkdir -p "$TFTP_DIR" "$LOG_DIR"
  cp -f "$FIRMWARE_BIN" "$TFTP_DIR/$FW_NAME"
  echo "Copied firmware: $FIRMWARE_BIN"
  echo "TFTP file ready: $TFTP_DIR/$FW_NAME"

  echo "Configuring $ETH_IF to 192.168.1.2/24 ..."
  sudo ip addr flush dev "$ETH_IF"
  sudo ip addr add 192.168.1.2/24 dev "$ETH_IF"
  sudo ip link set "$ETH_IF" up
  echo "Done."
}

mode_serve() {
  # Start dnsmasq in TFTP-only mode bound to the recovery interface.
  pick_eth_if
  validate_if
  need_cmd sudo
  need_cmd dnsmasq

  [[ -f "$TFTP_DIR/$FW_NAME" ]] || {
    echo "Missing TFTP firmware: $TFTP_DIR/$FW_NAME" >&2
    echo "Run: $0 prep" >&2
    exit 1
  }

  mkdir -p "$LOG_DIR"

  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "dnsmasq already running with PID $(cat "$PID_FILE")"
    exit 0
  fi

  sudo rm -f "$DNSMASQ_LOG"
  sudo touch "$DNSMASQ_LOG"
  sudo chmod 640 "$DNSMASQ_LOG"

  echo "Starting dnsmasq TFTP on $ETH_IF ..."
  sudo dnsmasq \
    --interface="$ETH_IF" \
    --bind-interfaces \
    --port=0 \
    --enable-tftp \
    --tftp-root="$TFTP_DIR" \
    --log-queries \
    --log-dhcp \
    --pid-file="$PID_FILE" \
    --log-facility="$DNSMASQ_LOG"

  echo "TFTP server started"
  echo "Log: $DNSMASQ_LOG"
}

mode_stop() {
  need_cmd sudo
  if [[ -f "$PID_FILE" ]]; then
    local pid
    local cmdline
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
      echo "Invalid pid file contents: $PID_FILE" >&2
      sudo rm -f "$PID_FILE"
      exit 1
    fi

    if sudo kill -0 "$pid" 2>/dev/null; then
      cmdline="$(sudo tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
      if [[ "$cmdline" == *dnsmasq* && "$cmdline" == *"--pid-file=$PID_FILE"* ]]; then
        sudo kill "$pid" 2>/dev/null || true
        echo "Stopped dnsmasq (pid $pid)."
      else
        echo "Refusing to kill pid $pid: command line does not match expected recovery dnsmasq." >&2
        echo "Cmdline: $cmdline" >&2
        exit 1
      fi
    else
      echo "No running process for pid in $PID_FILE."
    fi
    sudo rm -f "$PID_FILE"
  else
    echo "No pid file: $PID_FILE"
  fi
}

mode_run() {
  mode_prep
  mode_serve
}

usage() {
  cat <<USAGE
Usage: $0 {check|prep|serve|stop|run}

Env vars:
  ETH_IF=<wired iface>
  FIRMWARE_BIN=/path/file.bin
  FIRMWARE_DIR=$FIRMWARE_DIR
  FW_NAME=$FW_NAME
  TFTP_DIR=$TFTP_DIR
  LOG_DIR=$LOG_DIR
  PID_FILE=$PID_FILE
  DNSMASQ_LOG=$DNSMASQ_LOG
USAGE
}

main() {
  need_cmd ip
  case "${1:-}" in
    check) mode_check ;;
    prep) mode_prep ;;
    serve) mode_serve ;;
    stop) mode_stop ;;
    run) mode_run ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
