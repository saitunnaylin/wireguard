#!/usr/bin/env bash
# WireGuard interface helpers.

wg_docker_exec() {
  docker exec wg-easy "$@" 2>&1
}

wg_docker_wg() {
  wg_docker_exec wg "$@"
}

wg_interface_up() {
  local sudo_cmd
  sudo_cmd="$(wg_sudo)"
  ${sudo_cmd} ip link show wg0 &>/dev/null
}

wg_load_wireguard_module() {
  local sudo_cmd
  sudo_cmd="$(wg_sudo)"
  if ${sudo_cmd} modprobe wireguard 2>/dev/null; then
    echo "OK: wireguard kernel module loaded"
    return 0
  fi
  if ${sudo_cmd} lsmod 2>/dev/null | grep -q '^wireguard'; then
    echo "OK: wireguard kernel module already loaded"
    return 0
  fi
  echo "ERROR: could not load wireguard module — install wireguard-tools:" >&2
  echo "  Debian/Ubuntu: sudo apt install wireguard-tools" >&2
  echo "  EL9/EL10 (RHEL, AlmaLinux, Rocky): sudo dnf install wireguard-tools" >&2
  return 1
}

# Reset wg-easy hooks to a known-good PostUp and restart the container.
wg_reset_hooks_and_restart() {
  local root db sql
  root="$(wg_root)"
  db="${root}/data/wg-easy.db"

  if [[ ! -f "${db}" ]]; then
    echo "WARN: ${db} not found" >&2
    return 1
  fi

  sql="UPDATE hooks_table SET pre_up='', post_up='${wg_post_up}', pre_down='', post_down='${wg_post_down}', updated_at=datetime('now') WHERE id='wg0';"

  echo "Resetting wg-easy hooks to safe defaults..."
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "${db}" "${sql}" || return 1
  else
    wg_docker_exec sh -c "apk add --no-cache sqlite >/dev/null 2>&1; sqlite3 /etc/wireguard/wg-easy.db \"${sql}\"" || return 1
  fi

  echo "Restarting wg-easy..."
  docker restart wg-easy >/dev/null
  sleep 6
  wg_wait_for_ui "${PORT:-51821}" 2>/dev/null || true
}

wg_try_bring_up() {
  echo "Attempting to start wg0..."
  wg_load_wireguard_module || return 1

  if wg_docker_exec test -f /etc/wireguard/wg0.conf; then
    wg_docker_exec wg-quick down wg0 2>/dev/null || true
    if wg_docker_exec wg-quick up wg0; then
      sleep 1
      if wg_interface_up; then
        echo "OK: wg0 is up"
        return 0
      fi
    fi
  fi

  echo "WARN: wg-quick up failed — resetting hooks and restarting container..."
  wg_reset_hooks_and_restart || return 1
  sleep 3

  if wg_interface_up; then
    echo "OK: wg0 is up after restart"
    return 0
  fi

  echo "ERROR: wg0 still down — check logs below" >&2
  docker compose logs --tail 25 wg-easy 2>/dev/null || docker logs --tail 25 wg-easy 2>/dev/null || true
  return 1
}

wg_repair() {
  local root
  root="$(wg_root)"
  cd "${root}"

  echo "=== WireGuard repair ==="
  echo ""

  if ! docker ps --format '{{.Names}}' | grep -qx wg-easy; then
    echo "Starting container..."
    docker compose up -d
    sleep 5
  fi

  wg_host_setup 2>/dev/null || wg_host_setup || true
  wg_fix_server_allowed_ips
  wg_try_bring_up
}
