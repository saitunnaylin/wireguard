#!/usr/bin/env bash
# Shared helpers for wg.sh — source only, do not execute directly.

wg_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

wg_sudo() {
  if [[ "$(uname -s)" == "Linux" && "${EUID}" -ne 0 ]]; then
    echo sudo
  fi
}

wg_load_env() {
  local root env_file="${1:-.env}"
  root="$(wg_root)"
  cd "${root}"
  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${env_file}"
    set +a
  fi
}

# Suggested client AllowedIPs line from .env (split tunnel default).
wg_allowed_ips_hint() {
  wg_load_env ".env"
  echo "${INIT_ALLOWED_IPS:-10.8.0.0/24,192.168.1.0/24}"
}

# Host LAN IPv4 address (without prefix), for status messages.
wg_host_lan_ip() {
  local sudo_cmd lan_if
  sudo_cmd="$(wg_sudo)"
  lan_if="$(${sudo_cmd} ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  ${sudo_cmd} ip -4 addr show "${lan_if}" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1
}

wg_iptables_cmds() {
  local cmds=()
  command -v iptables-legacy >/dev/null 2>&1 && cmds+=(iptables-legacy)
  command -v iptables >/dev/null 2>&1 && cmds+=(iptables)
  if [[ ${#cmds[@]} -eq 0 ]]; then
    echo "ERROR: iptables not found." >&2
    return 1
  fi
  printf '%s\n' "${cmds[@]}"
}

wg_verify_iptables() {
  local sudo_cmd verify_ipt
  sudo_cmd="$(wg_sudo)"
  verify_ipt="iptables-legacy"
  command -v iptables-legacy >/dev/null 2>&1 || verify_ipt="iptables"

  echo "--- FORWARD (first rules) ---"
  ${sudo_cmd} "${verify_ipt}" -L FORWARD -n -v 2>/dev/null | head -8 || true
  echo "--- NAT MASQUERADE for VPN ---"
  if wg_host_firewall_ok; then
    ${sudo_cmd} "${verify_ipt}" -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E 'MASQUERADE|10\.8\.' || true
    echo "OK: VPN MASQUERADE rule present"
  else
    echo "WARN: no MASQUERADE for 10.8.0.0/24 — run: sudo ./scripts/wg.sh setup"
  fi
}

# Returns 0 when host iptables already allows VPN -> LAN/internet forwarding.
wg_host_firewall_ok() {
  [[ "$(uname -s)" == "Linux" ]] || return 1

  local sudo_cmd verify_ipt lan_if wg_cidr
  sudo_cmd="$(wg_sudo)"
  verify_ipt="iptables-legacy"
  command -v iptables-legacy >/dev/null 2>&1 || verify_ipt="iptables"

  lan_if="$(${sudo_cmd} ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  [[ -n "${lan_if}" ]] || return 1

  wg_cidr="10.8.0.0/24"
  if ${sudo_cmd} ip link show wg0 &>/dev/null; then
    wg_cidr="$(${sudo_cmd} ip -4 addr show wg0 2>/dev/null | awk '/inet / {print $2; exit}')"
  fi
  [[ -n "${wg_cidr}" ]] || wg_cidr="10.8.0.0/24"

  ${sudo_cmd} "${verify_ipt}" -C FORWARD -i wg0 -j ACCEPT 2>/dev/null && \
    ${sudo_cmd} "${verify_ipt}" -t nat -C POSTROUTING -s "${wg_cidr}" -o "${lan_if}" -j MASQUERADE 2>/dev/null
}

wg_ensure_ipt_rule() {
  local desc="$1" ipt="$2" sudo_cmd="$3"
  shift 3
  if ${sudo_cmd} "${ipt}" "$@" 2>/dev/null; then
    echo "OK: ${desc} via ${ipt} (already set)"
  elif ${sudo_cmd} "${ipt}" "${@/-C/-A}" 2>/dev/null; then
    echo "OK: ${desc} via ${ipt} (added)"
  else
    echo "WARN: failed ${desc} via ${ipt}"
  fi
}
