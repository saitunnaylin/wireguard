#!/usr/bin/env bash
# Host sysctl + iptables setup for VPN routing.

wg_host_setup() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "SKIP: host setup requires Linux (run on your homelab server)."
    return 0
  fi

  local sudo_cmd lan_if wg_cidr lan_ip conf ipt
  sudo_cmd="$(wg_sudo)"

  lan_if="$(${sudo_cmd} ip route | awk '/^default/ {print $5; exit}')"
  if [[ -z "${lan_if}" ]]; then
    echo "ERROR: Could not detect default network interface." >&2
    return 1
  fi

  wg_cidr="10.8.0.0/24"
  if ${sudo_cmd} ip link show wg0 &>/dev/null; then
    lan_ip="$(${sudo_cmd} ip -4 addr show wg0 | awk '/inet / {print $2; exit}')"
    [[ -n "${lan_ip}" ]] && wg_cidr="${lan_ip}"
  fi

  lan_ip="$(${sudo_cmd} ip -4 addr show "${lan_if}" | awk '/inet / {print $2; exit}')"

  echo "=== Host setup ==="
  echo "LAN interface: ${lan_if} (${lan_ip:-unknown})"
  echo "VPN subnet:    ${wg_cidr}"
  echo ""

  echo "Enabling IP forwarding and rp_filter..."
  ${sudo_cmd} sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ${sudo_cmd} sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null
  ${sudo_cmd} sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
  ${sudo_cmd} sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
  if ${sudo_cmd} ip link show wg0 &>/dev/null; then
    ${sudo_cmd} sysctl -w net.ipv4.conf.wg0.rp_filter=2 >/dev/null
  fi

  conf="/etc/sysctl.d/99-wireguard.conf"
  if ! ${sudo_cmd} grep -q 'net.ipv4.conf.all.rp_filter=2' "${conf}" 2>/dev/null; then
    cat <<'EOF' | ${sudo_cmd} tee "${conf}" >/dev/null
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
    echo "OK: persisted sysctl in ${conf}"
  fi

  echo "Adding iptables rules..."
  while IFS= read -r ipt; do
    [[ -z "${ipt}" ]] && continue
    echo "  backend: ${ipt}"
    wg_ensure_ipt_rule "INPUT from wg0" "${ipt}" "${sudo_cmd}" -C INPUT -i wg0 -j ACCEPT
    wg_ensure_ipt_rule "FORWARD in from wg0" "${ipt}" "${sudo_cmd}" -C FORWARD -i wg0 -j ACCEPT
    wg_ensure_ipt_rule "FORWARD out to wg0" "${ipt}" "${sudo_cmd}" -C FORWARD -o wg0 -j ACCEPT
    wg_ensure_ipt_rule "MASQUERADE ${wg_cidr} -> ${lan_if}" "${ipt}" "${sudo_cmd}" \
      -t nat -C POSTROUTING -s "${wg_cidr}" -o "${lan_if}" -j MASQUERADE

    if ${sudo_cmd} "${ipt}" -L DOCKER-USER -n &>/dev/null; then
      if ! ${sudo_cmd} "${ipt}" -C DOCKER-USER -i wg0 -j ACCEPT 2>/dev/null; then
        ${sudo_cmd} "${ipt}" -I DOCKER-USER 1 -i wg0 -j ACCEPT
        echo "OK: DOCKER-USER in from wg0 via ${ipt} (added)"
      fi
      if ! ${sudo_cmd} "${ipt}" -C DOCKER-USER -o wg0 -j ACCEPT 2>/dev/null; then
        ${sudo_cmd} "${ipt}" -I DOCKER-USER 1 -o wg0 -j ACCEPT
        echo "OK: DOCKER-USER out to wg0 via ${ipt} (added)"
      fi
    fi
  done < <(wg_iptables_cmds)

  if command -v ufw >/dev/null 2>&1; then
    local ufw_status ufw_default
    ufw_status="$(${sudo_cmd} ufw status 2>/dev/null | head -1 || true)"
    echo ""
    echo "UFW: ${ufw_status}"
    if echo "${ufw_status}" | grep -qi active; then
      ufw_default="/etc/default/ufw"
      if ${sudo_cmd} grep -q 'DEFAULT_FORWARD_POLICY="DROP"' "${ufw_default}" 2>/dev/null; then
        ${sudo_cmd} sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "${ufw_default}"
        ${sudo_cmd} ufw reload 2>/dev/null || true
        echo "OK: UFW DEFAULT_FORWARD_POLICY=ACCEPT"
      fi
      ${sudo_cmd} ufw route allow in on wg0 out on "${lan_if}" 2>/dev/null || true
      ${sudo_cmd} ufw allow 51820/udp comment 'WireGuard' 2>/dev/null || true
      ${sudo_cmd} ufw allow in on wg0 2>/dev/null || true
    fi
  fi

  echo ""
  wg_verify_iptables
}
