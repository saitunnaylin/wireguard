#!/usr/bin/env bash
# WireGuard homelab helper — single entry point for setup, diagnostics, and validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/scripts/lib"

# shellcheck source=lib/common.sh
source "${LIB}/common.sh"
# shellcheck source=lib/host.sh
source "${LIB}/host.sh"
# shellcheck source=lib/hooks.sh
source "${LIB}/hooks.sh"
# shellcheck source=lib/wireguard.sh
source "${LIB}/wireguard.sh"
# shellcheck source=lib/diagnostics.sh
source "${LIB}/diagnostics.sh"
# shellcheck source=lib/status.sh
source "${LIB}/status.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  setup [password]   Host sysctl + firewall + wg-easy hooks (run after docker compose up)
                     Password = web UI login (required if INIT_PASSWORD removed from .env)
  repair             Start wg0 if down (fixes broken hooks, loads wireguard module)
  status             Show container, firewall, and peer diagnostics
  validate           Check .env and docker compose config

Examples:
  ./scripts/wg.sh validate
  docker compose up -d && sudo ./scripts/wg.sh setup
  sudo ./scripts/wg.sh repair
  ./scripts/wg.sh status

EOF
}

cmd_validate() {
  cd "${ROOT}"
  local errors=0 env_file=".env" example_env=".env.example"

  log_ok() { echo "OK: $*"; }
  log_err() { echo "ERROR: $*" >&2; errors=$((errors + 1)); }

  [[ -f docker-compose.yml ]] || { log_err "Missing docker-compose.yml"; exit 1; }
  [[ -f "${example_env}" ]] || { log_err "Missing ${example_env}"; exit 1; }

  for var in INIT_HOST INIT_PASSWORD INIT_USERNAME; do
    if grep -q "^${var}=" "${example_env}"; then
      log_ok "${example_env} documents ${var}"
    else
      log_err "${example_env} missing ${var}="
    fi
  done

  local compose_env="${example_env}"
  if [[ -f "${env_file}" ]]; then
    compose_env="${env_file}"
    echo "Validating compose with ${env_file}..."
    wg_load_env "${env_file}"
    if [[ -z "${INIT_HOST:-}" || "${INIT_HOST}" == "vpn.example.com" ]]; then
      log_err ".env: INIT_HOST must be your public IP or DDNS hostname"
    else
      log_ok ".env: INIT_HOST=${INIT_HOST}"
    fi
    if [[ -z "${INIT_PASSWORD:-}" ]]; then
      log_err ".env: INIT_PASSWORD is empty (required for first setup)"
    else
      log_ok ".env: INIT_PASSWORD is set"
    fi
    if [[ -z "${INIT_USERNAME:-}" || "${INIT_USERNAME}" == "admin" || "${INIT_USERNAME}" == "yourname" ]]; then
      log_err ".env: INIT_USERNAME must be a non-default login name (not admin or yourname)"
    else
      log_ok ".env: INIT_USERNAME=${INIT_USERNAME}"
    fi
  else
    echo "No .env yet — copy .env.example to .env before deploying."
  fi

  if docker compose --env-file "${compose_env}" config >/dev/null 2>&1; then
    log_ok "docker compose config parses"
  else
    log_err "docker compose config failed"
    docker compose --env-file "${compose_env}" config || true
  fi

  echo ""
  if [[ "${errors}" -gt 0 ]]; then
    echo "Validation finished with ${errors} error(s)."
    exit 1
  fi
  echo "Validation passed."
}

cmd_setup() {
  cd "${ROOT}"
  echo "=== WireGuard setup ==="
  echo ""

  wg_host_setup || return 1

  echo ""
  echo "--- wg-easy hooks (optional) ---"
  wg_apply_hooks "${1:-}" || {
    if wg_host_firewall_ok; then
      echo ""
      echo "Setup complete — host firewall is configured (wg-easy hooks are optional)."
    else
      return 1
    fi
  }

  if ! wg_interface_up; then
    echo ""
    echo "WARN: wg0 is not up — run: sudo ./scripts/wg.sh repair"
  fi

  echo ""
  echo "Done. In the admin UI:"
  echo "  1. Admin → Interface — disable Per-Client Firewall"
  echo "  2. Set Allowed IPs: $(wg_allowed_ips_hint)"
  echo "  3. Create a client, scan QR on phone (mobile data, not home Wi-Fi)"
  echo ""
  echo "Verify: ./scripts/wg.sh status"
}

main() {
  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    setup)   cmd_setup "$@" ;;
    repair)  wg_repair ;;
    status)  wg_status ;;
    validate) cmd_validate ;;
    -h|--help|help|"") usage ;;
    *)
      echo "Unknown command: ${cmd}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
