#!/usr/bin/env bash
# Diagnostics: container health, firewall, and live peer stats.

wg_status() {
  local sudo_cmd root dump hs_ok wg_out peer_count lan_if lan_ip
  root="$(wg_root)"
  cd "${root}"
  sudo_cmd="$(wg_sudo)"
  hs_ok=0
  lan_if=""
  lan_ip=""

  echo "=== WireGuard status ==="
  echo ""

  if ! docker ps --format '{{.Names}}' | grep -qx wg-easy; then
    echo "ERROR: wg-easy container is not running."
    echo "Start with: docker compose up -d"
    return 1
  fi

  echo "--- Container ---"
  docker inspect -f 'Status: {{.State.Status}} (restarted {{.RestartCount}} times)' wg-easy 2>/dev/null || true

  if [[ "$(uname -s)" == "Linux" ]]; then
    echo ""
    echo "--- Host sysctl ---"
    ${sudo_cmd} sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter 2>/dev/null || true

    lan_if="$(${sudo_cmd} ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
    lan_ip="$(${sudo_cmd} ip -4 addr show "${lan_if}" 2>/dev/null | awk '/inet / {print $2; exit}')"
    echo ""
    echo "--- LAN interface: ${lan_if:-unknown} ---"
    echo "    ${lan_ip:-unknown}"
  fi

  echo ""
  echo "--- wg0 ---"
  if wg_interface_up; then
    ${sudo_cmd} ip -4 addr show wg0 | grep inet || true
  else
    echo "ERROR: wg0 is NOT up — run: sudo ./scripts/wg.sh repair"
  fi

  echo ""
  wg_verify_iptables

  echo ""
  wg_print_reachability

  echo ""
  echo "--- WireGuard peers ---"
  wg_out="$(wg_docker_wg show wg0 2>&1)" || true
  echo "${wg_out:-"(empty)"}"

  peer_count="$(wg_peer_count)"
  wg_load_env ".env"
  local ui_host="${lan_ip%/*}"
  [[ -z "${ui_host}" ]] && ui_host="$(wg_host_lan_ip)"
  [[ -z "${ui_host}" ]] && ui_host="<homelab-ip>"

  echo ""
  echo "--- Peer traffic (phone on mobile data, VPN toggled ON) ---"
  dump="$(wg_docker_wg show wg0 dump 2>/dev/null || true)"
  if [[ "${peer_count}" == "0" ]]; then
    echo "ERROR: no peers on wg0 — create a client in http://${ui_host}:51821 and scan QR"
  else
    echo "${dump}"
    hs_ok=0
    while IFS=$'\t' read -r _ _ endpoint allowed hs rx tx _; do
      [[ -z "${allowed:-}" ]] && continue
      echo "  endpoint=${endpoint:-none} allowed_ips=${allowed} handshake=${hs:-0} rx=${rx:-0} tx=${tx:-0}"
      [[ "${hs:-0}" != "0" && "${hs:-0}" != "off" ]] && hs_ok=1
      [[ "${rx:-0}" != "0" || "${tx:-0}" != "0" ]] && hs_ok=1
    done < <(echo "${dump}" | awk -F'\t' 'NF >= 8')

    if [[ "${hs_ok}" -eq 1 ]]; then
      echo "OK: handshake or traffic — VPN path is working"
    else
      echo ""
      echo "ERROR: handshake=0 — phone packets are NOT arriving at this server"
      echo "  Server side is OK. Fix inbound path:"
      echo "  1. dig +short ${INIT_HOST:-your-host}  must equal $(curl -sf --max-time 2 https://ifconfig.me 2>/dev/null || echo 'public IP')"
      echo "  2. Router: UDP ${INIT_PORT:-51820} → ${ui_host} (not TCP)"
      echo "  3. Phone on mobile data, VPN ON, then re-run status"
      echo "  4. Re-scan QR after any INIT_HOST change"
    fi
  fi

  if grep -q 'AllowedIPs = .*0\.0\.0\.0/0' ./data/wg0.conf 2>/dev/null; then
    echo ""
    echo "WARN: server peer has 0.0.0.0/0 — run: sudo ./scripts/wg.sh repair"
  fi

  echo ""
  echo "--- Recent logs ---"
  docker compose logs --tail 10 wg-easy 2>/dev/null || docker logs --tail 10 wg-easy 2>/dev/null || true

  echo ""
  echo "=== Next steps ==="
  if ! wg_interface_up; then
    echo "  sudo ./scripts/wg.sh repair"
  elif [[ "${peer_count}" == "0" ]]; then
    echo "  Create client: http://${ui_host}:51821 → New Client → scan QR"
  elif [[ "${hs_ok:-0}" != "1" ]]; then
    echo "  Fix DNS + router port forward, then re-scan QR on mobile data"
    echo "  sudo ./scripts/wg.sh repair"
  else
    echo "  VPN working — browse http://${ui_host} from phone"
  fi
}
