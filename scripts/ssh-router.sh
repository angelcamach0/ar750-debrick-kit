#!/usr/bin/env bash
set -euo pipefail

# Router SSH helper:
# - Discover or accept explicit wired interface
# - Probe common router management IPs
# - Optionally refresh DHCP lease and probe again
# - Optionally bring Wi-Fi down to avoid ambiguous routing
# - Launch SSH once a reachable router IP is found

HOSTS_CSV="${HOSTS_CSV:-192.168.8.1,192.168.1.1}"
IFACE="${IFACE:-}"
USER_NAME="${USER_NAME:-root}"
SSH_PORT="${SSH_PORT:-22}"
DRY_RUN="${DRY_RUN:-0}"
RUN_DHCP="${RUN_DHCP:-1}"
DOWN_WIFI="${DOWN_WIFI:-0}"
SSH_EXTRA="${SSH_EXTRA:-}"
WIFI_IFS_DOWN=()

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

usage() {
  cat <<EOF2
Usage: $0 [options]

Options:
  --iface IFACE          Use this interface directly
  --hosts CSV            Hosts to try (default: $HOSTS_CSV)
  --user USER            SSH user (default: $USER_NAME)
  --port PORT            SSH port (default: $SSH_PORT)
  --no-dhcp              Do not run DHCP renew attempts
  --down-wifi            Temporarily bring Wi-Fi down during checks
  --dry-run              Print intended actions only
  -h, --help             Show help

Env:
  HOSTS_CSV, IFACE, USER_NAME, SSH_PORT, DRY_RUN, RUN_DHCP, DOWN_WIFI, SSH_EXTRA
EOF2
}

parse_args() {
  # Keep flags simple and explicit; unknown args fail fast.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iface)
        [[ $# -ge 2 ]] || { echo "--iface requires a value" >&2; exit 1; }
        IFACE="$2"
        shift 2
        ;;
      --hosts)
        [[ $# -ge 2 ]] || { echo "--hosts requires a value" >&2; exit 1; }
        HOSTS_CSV="$2"
        shift 2
        ;;
      --user)
        [[ $# -ge 2 ]] || { echo "--user requires a value" >&2; exit 1; }
        USER_NAME="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 1; }
        SSH_PORT="$2"
        shift 2
        ;;
      --no-dhcp)
        RUN_DHCP=0
        shift
        ;;
      --down-wifi)
        DOWN_WIFI=1
        shift
        ;;
      --dry-run|-n)
        DRY_RUN=1
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

pick_iface() {
  # If user gave an interface, trust it but verify it exists.
  if [[ -n "$IFACE" ]]; then
    [[ -e "/sys/class/net/$IFACE" ]] || {
      echo "Interface not found: $IFACE" >&2
      exit 1
    }
    return
  fi

  # Prefer connected ethernet first because it is usually the intended path.
  if command -v nmcli >/dev/null 2>&1; then
    IFACE="$(
      nmcli -t -f DEVICE,TYPE,STATE device status \
      | awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}'
    )"
    if [[ -z "$IFACE" ]]; then
      IFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet" {print $1; exit}')"
    fi
  fi

  # Fallback for systems without NetworkManager/nmcli.
  if [[ -z "$IFACE" ]]; then
    IFACE="$(
      ip -o link show \
      | awk -F': ' '{print $2}' \
      | awk '$1 !~ /^(lo|wl|docker|br-|veth|virbr|tun|tap|vmnet|zt|tailscale|wg)/ {print; exit}'
    )"
  fi

  [[ -n "$IFACE" ]] || {
    echo "Could not auto-detect wired interface. Pass --iface <name>." >&2
    exit 1
  }
}

down_wifi_if_requested() {
  [[ "$DOWN_WIFI" == "1" ]] || return 0

  local wifs=()
  # Match common Linux Wi-Fi interface names.
  mapfile -t wifs < <(ip -o link show | awk -F': ' '{print $2}' | awk '$1 ~ /^(wl|wlan|wlp)/ {print}')
  [[ "${#wifs[@]}" -gt 0 ]] || return 0

  for wi in "${wifs[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] would run: sudo ip link set $wi down"
    else
      sudo ip link set "$wi" down || true
      WIFI_IFS_DOWN+=("$wi")
    fi
  done
}

restore_wifi() {
  # Best-effort cleanup on script exit.
  [[ "${#WIFI_IFS_DOWN[@]}" -gt 0 ]] || return 0
  for wi in "${WIFI_IFS_DOWN[@]}"; do
    sudo ip link set "$wi" up || true
  done
}

run_dhcp() {
  local iface="$1"
  if [[ "$RUN_DHCP" == "0" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] would run: sudo dhclient -r $iface || true"
    echo "[dry-run] would run: sudo dhclient -v $iface"
    return 0
  fi

  # Best-effort lease refresh; may fail harmlessly if no DHCP server exists.
  sudo dhclient -r "$iface" || true
  sudo dhclient -v "$iface" || true
}

reachable() {
  local iface="$1"
  local host="$2"
  ping -I "$iface" -c 1 -W 1 "$host" >/dev/null 2>&1
}

print_iface_state() {
  local iface="$1"
  echo "Using interface: $iface"
  ip -4 -o addr show dev "$iface" | sed -n '1,3p' || true
  ip route | awk -v i="$iface" '$0 ~ (" dev " i " ") {print}' | sed -n '1,3p' || true
}

main() {
  parse_args "$@"
  need_cmd ip
  need_cmd ping
  need_cmd ssh

  trap restore_wifi EXIT INT TERM

  pick_iface
  down_wifi_if_requested
  print_iface_state "$IFACE"

  IFS=',' read -r -a hosts <<< "$HOSTS_CSV"

  local found_host=""
  # Pass 1: probe without touching DHCP state.
  for host in "${hosts[@]}"; do
    if reachable "$IFACE" "$host"; then
      found_host="$host"
      break
    fi
  done

  if [[ -z "$found_host" ]]; then
    echo "No target host reachable yet; trying DHCP renew on $IFACE ..."
    run_dhcp "$IFACE"

    # Pass 2: probe again after lease refresh.
    for host in "${hosts[@]}"; do
      if reachable "$IFACE" "$host"; then
        found_host="$host"
        break
      fi
    done
  fi

  if [[ -z "$found_host" ]]; then
    echo "Router not reachable on any host in: $HOSTS_CSV" >&2
    echo "Try: cable to router LAN, then re-run with --iface <wired_iface>." >&2
    exit 1
  fi

  # Build SSH command as an array to avoid accidental word-splitting issues.
  local ssh_cmd=(ssh -o StrictHostKeyChecking=accept-new -p "$SSH_PORT")
  if [[ -n "$SSH_EXTRA" ]]; then
    # Intended for advanced users; split by shell words.
    # shellcheck disable=SC2206
    local extra_arr=($SSH_EXTRA)
    ssh_cmd+=("${extra_arr[@]}")
  fi
  ssh_cmd+=("${USER_NAME}@${found_host}")

  echo "Connecting: ${ssh_cmd[*]}"
  if [[ "$DRY_RUN" == "1" ]]; then
    exit 0
  fi

  exec "${ssh_cmd[@]}"
}

main "$@"
