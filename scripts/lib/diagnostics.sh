#!/usr/bin/env bash
# Reachability and client-config diagnostics.

wg_sqlite() {
  local sql="$1" db
  db="$(wg_root)/data/wg-easy.db"
  [[ -f "${db}" ]] || return 1

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "${db}" "${sql}"
  else
    wg_docker_exec sh -c "apk add --no-cache sqlite >/dev/null 2>&1; sqlite3 /etc/wireguard/wg-easy.db \"${sql}\"" 2>/dev/null
  fi
}

wg_peer_count() {
  local dump
  dump="$(wg_docker_wg show wg0 dump 2>/dev/null || true)"
  echo "${dump}" | awk -F'\t' 'NF >= 8 {n++} END {print n+0}'
}

wg_db_client_count() {
  wg_sqlite "SELECT COUNT(*) FROM clients_table;" 2>/dev/null || echo "?"
}

# Remove 0.0.0.0/0 from server-side peer routes (breaks routing; client AllowedIPs only).
wg_fix_server_allowed_ips() {
  local root db fixed
  root="$(wg_root)"
  db="${root}/data/wg-easy.db"
  [[ -f "${db}" ]] || return 0

  echo "Fixing server AllowedIPs (remove 0.0.0.0/0 from server peers)..."
  if command -v sqlite3 >/dev/null 2>&1; then
    fixed="$(sqlite3 "${db}" "UPDATE clients_table SET server_allowed_ips = '[]' WHERE server_allowed_ips LIKE '%0.0.0.0%' OR server_allowed_ips LIKE '%::/0%'; SELECT changes();")"
  else
    fixed="$(wg_docker_exec sh -c "apk add --no-cache sqlite >/dev/null 2>&1; sqlite3 /etc/wireguard/wg-easy.db \"UPDATE clients_table SET server_allowed_ips = '[]' WHERE server_allowed_ips LIKE '%0.0.0.0%' OR server_allowed_ips LIKE '%::/0%'; SELECT changes();\"" 2>/dev/null || echo 0)"
  fi
  if [[ "${fixed:-0}" -gt 0 ]]; then
    echo "OK: cleared bad server_allowed_ips on ${fixed} client(s)"
    docker restart wg-easy >/dev/null
    sleep 5
  else
    echo "OK: no bad server_allowed_ips in database"
  fi
}

wg_print_reachability() {
  local sudo_cmd init_host init_port lan_ip public_ip peer_count db_clients
  sudo_cmd="$(wg_sudo)"
  wg_load_env ".env"

  init_host="${INIT_HOST:-}"
  init_port="${INIT_PORT:-51820}"
  lan_ip="$(${sudo_cmd} ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1)"
  [[ -z "${lan_ip}" ]] && lan_ip="$(${sudo_cmd} ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
  public_ip="$(curl -sf --max-time 4 https://ifconfig.me 2>/dev/null || curl -sf --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  peer_count="$(wg_peer_count)"
  db_clients="$(wg_db_client_count)"

  echo "--- Reachability (handshake requires this) ---"
  echo "Homelab LAN IP:     ${lan_ip:-unknown} (port-forward target)"
  echo "INIT_HOST (.env):   ${init_host:-NOT SET}"
  echo "WireGuard port:     UDP ${init_port}"
  echo "Phone Endpoint:     ${init_host:-?}:${init_port}"
  [[ -n "${public_ip}" ]] && echo "Home public IP:     ${public_ip}"
  echo "DB clients:         ${db_clients}"
  echo "Active wg peers:    ${peer_count}"

  if [[ "${db_clients}" == "0" ]]; then
    echo ""
    echo "ERROR: No VPN clients in database — create one in the web UI:"
    echo "  http://${lan_ip:-<host>}:51821 → New Client → scan QR on phone"
  elif [[ "${peer_count}" == "0" && "${db_clients}" != "0" ]]; then
    echo ""
    echo "WARN: clients exist in DB but none loaded on wg0 — run: sudo ./scripts/wg.sh repair"
  fi

  if [[ -z "${init_host}" || "${init_host}" == "vpn.example.com" ]]; then
    echo ""
    echo "ERROR: INIT_HOST is not set — phone cannot find your server"
    echo "  Set INIT_HOST to your home public IP or DDNS in .env AND wg-easy Admin → General"
  elif [[ "${init_host}" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    echo ""
    echo "ERROR: INIT_HOST is a private LAN address (${init_host})"
    echo "  Remote phones need your PUBLIC IP or DDNS, not ${init_host}"
    [[ -n "${public_ip}" ]] && echo "  Try: INIT_HOST=${public_ip}"
  elif [[ -n "${public_ip}" && "${init_host}" != "${public_ip}" ]]; then
    echo ""
    echo "NOTE: INIT_HOST (${init_host}) differs from detected public IP (${public_ip})"
    echo "  OK if DDNS is correct; broken if DNS is stale or wrong"
  fi

  if [[ -n "${init_host}" && "${init_host}" != "vpn.example.com" && ! "${init_host}" =~ ^[0-9.]+$ ]]; then
    local dns_a dns_aaaa
    dns_a="$(dig +short "${init_host}" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
    dns_aaaa="$(dig +short "${init_host}" AAAA 2>/dev/null | head -1 || true)"
    echo ""
    echo "--- DNS for ${init_host} ---"
    if [[ -n "${dns_a}" ]]; then
      echo "A record:           ${dns_a}"
      if [[ -n "${public_ip}" && "${dns_a}" == "${public_ip}" ]]; then
        echo "OK: DNS points to current public IP"
      elif [[ "${dns_a}" == 104.21.* || "${dns_a}" == 172.6[4-7].* || "${dns_a}" == 103.2[12].* || "${dns_a}" == 141.101.* || "${dns_a}" == 108.162.* || "${dns_a}" == 162.158.* || "${dns_a}" == 198.41.* ]]; then
        echo "ERROR: ${init_host} resolves to Cloudflare (${dns_a}) — WireGuard cannot use proxied DNS"
        echo "  In Cloudflare DNS: set the record to DNS only (grey cloud), value ${public_ip}"
        echo "  Or use INIT_HOST=${public_ip} and re-create the phone client"
      elif [[ -n "${public_ip}" ]]; then
        echo "ERROR: DNS (${dns_a}) != public IP (${public_ip}) — update DDNS or fix INIT_HOST"
      fi
    else
      echo "ERROR: ${init_host} has no A record — phone cannot connect"
    fi
    [[ -n "${dns_aaaa}" ]] && echo "AAAA record:        ${dns_aaaa} (disable IPv6 on phone if issues)"
  fi

  echo ""
  echo "--- UDP ${init_port} listening ---"
  if ${sudo_cmd} ss -ulnp 2>/dev/null | grep -q ":${init_port} "; then
    ${sudo_cmd} ss -ulnp 2>/dev/null | grep ":${init_port} " || true
    echo "OK: something is listening on UDP ${init_port}"
  else
    echo "ERROR: nothing listening on UDP ${init_port}"
  fi

  echo ""
  echo "Router must port-forward: UDP ${init_port} → ${lan_ip:-homelab-ip}"
  echo ""
  echo "If handshake=0 with VPN ON on phone (mobile data):"
  echo "  • Port forward missing/wrong on router (most common)"
  echo "  • DDNS not pointing to ${public_ip:-your public IP}"
  echo "  • ISP CGNAT (router WAN IP differs from public IP — port forward impossible)"
  echo "  • Run status again while phone VPN toggle is ON"
}
