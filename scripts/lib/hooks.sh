#!/usr/bin/env bash
# Apply wg-easy PostUp/PostDown hooks (optional — host firewall from wg.sh setup is what matters).

# wg-easy runs these inside its container; use plain iptables (not iptables-legacy).
# DOCKER-USER rules are applied separately by scripts/lib/host.sh on the host.
wg_post_up='iptables -A INPUT -i wg0 -j ACCEPT; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s {{ipv4Cidr}} -o {{device}} -j MASQUERADE'

wg_post_down='iptables -D INPUT -i wg0 -j ACCEPT; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s {{ipv4Cidr}} -o {{device}} -j MASQUERADE'

wg_wait_for_ui() {
  local port="${1:-51821}" i http_code
  echo "Waiting for wg-easy web UI on port ${port}..."
  for i in $(seq 1 60); do
    http_code="$(docker exec wg-easy node -e "
const http=require('http');
http.get('http://127.0.0.1:${port}/',r=>{console.log(r.statusCode);process.exit(0)})
  .on('error',()=>{console.log('000');process.exit(0)});
" 2>/dev/null || echo 000)"
    if [[ "${http_code}" == "200" || "${http_code}" == "302" ]]; then
      echo "OK: web UI ready (HTTP ${http_code})"
      return 0
    fi
    sleep 1
  done
  echo "WARN: web UI not responding on 127.0.0.1:${port}" >&2
  return 1
}

wg_hooks_already_ok() {
  [[ -f data/wg0.conf ]] && grep -q 'INPUT -i wg0' data/wg0.conf
}

wg_apply_hooks_via_api() {
  local password="$1" port="$2" username="$3"
  local post_up_b64 post_down_b64

  post_up_b64="$(printf '%s' "${wg_post_up}" | base64 | tr -d '\n')"
  post_down_b64="$(printf '%s' "${wg_post_down}" | base64 | tr -d '\n')"

  docker exec \
    -e "WG_USER=${username}" \
    -e "WG_PASS=${password}" \
    -e "WG_PORT=${port}" \
    -e "WG_POST_UP_B64=${post_up_b64}" \
    -e "WG_POST_DOWN_B64=${post_down_b64}" \
    wg-easy node -e '
const http=require("http");
const user=process.env.WG_USER;
const pass=process.env.WG_PASS;
const port=Number(process.env.WG_PORT||51821);
const postUp=Buffer.from(process.env.WG_POST_UP_B64,"base64").toString();
const postDown=Buffer.from(process.env.WG_POST_DOWN_B64,"base64").toString();

function req(method,path,body,headers){
  return new Promise((res,rej)=>{
    const data=body?JSON.stringify(body):null;
    const r=http.request({hostname:"127.0.0.1",port,path,method,headers:{
      "Content-Type":"application/json",
      "Content-Length":data?Buffer.byteLength(data):0,
      ...headers
    }},x=>{
      let b="";x.on("data",d=>b+=d);x.on("end",()=>res({status:x.statusCode,headers:x.headers,body:b}));
    });
    r.on("error",rej); if(data) r.write(data); r.end();
  });
}

async function applyWithAuth(authHeaders){
  const login=await req("POST","/api/session",{username:user,password:pass,remember:false},authHeaders);
  if(login.status!==200){
    console.error("login",login.status,login.body);
    return false;
  }
  const cookie=(login.headers["set-cookie"]||[]).map(c=>c.split(";")[0]).join("; ");
  const sessionHeaders={...authHeaders,Cookie:cookie};
  const hooks=await req("POST","/api/admin/hooks",{preUp:"",postUp,preDown:"",postDown},sessionHeaders);
  if(hooks.status!==200){
    console.error("hooks",hooks.status,hooks.body);
    return false;
  }
  console.error("OK: hooks saved via API");
  const restart=await req("POST","/api/admin/interface/restart",{},sessionHeaders);
  if(restart.status!==200){
    console.error("WARN: interface restart returned",restart.status,"— hooks saved, restart skipped");
  }
  return true;
}

(async()=>{
  if(await applyWithAuth({Authorization:pass})) process.exit(0);
  if(await applyWithAuth({})) process.exit(0);
  process.exit(1);
})();
'
}

wg_sqlite_update_hooks() {
  local db_path="$1"
  local sql="UPDATE hooks_table SET pre_up='', post_up='${wg_post_up}', pre_down='', post_down='${wg_post_down}', updated_at=datetime('now') WHERE id='wg0';"

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "${db_path}" "${sql}"
    return $?
  fi

  docker exec wg-easy sh -c "apk add --no-cache sqlite >/dev/null 2>&1; sqlite3 ${db_path} \"${sql}\""
}

wg_apply_hooks_via_db() {
  local root db
  root="$(wg_root)"
  db="${root}/data/wg-easy.db"

  if [[ ! -f "${db}" ]]; then
    echo "SKIP: ${db} not found" >&2
    return 1
  fi

  echo "Applying hooks via SQLite..."
  if ! wg_sqlite_update_hooks "${db}"; then
    echo "WARN: could not update ${db}" >&2
    return 1
  fi

  echo "Restarting wg-easy to regenerate wg0.conf..."
  docker restart wg-easy >/dev/null
  sleep 5
  wg_wait_for_ui "${PORT:-51821}" || true

  if wg_hooks_already_ok; then
    echo "OK: hooks applied via database"
    return 0
  fi

  echo "WARN: database updated (wg0.conf may update on next wg-easy restart)" >&2
  return 0
}

wg_apply_hooks() {
  local password="${1:-}" port username env_file root hooks_ok=1
  env_file="${ENV_FILE:-.env}"
  root="$(wg_root)"
  cd "${root}"
  wg_load_env "${env_file}"

  port="${PORT:-51821}"
  username="${INIT_USERNAME:-}"
  password="${password:-${INIT_PASSWORD:-}}"

  if [[ -z "${username}" ]]; then
    echo "ERROR: INIT_USERNAME is not set in ${env_file}" >&2
    return 1
  fi

  if wg_hooks_already_ok; then
    echo "OK: wg0.conf already has firewall hooks (INPUT -i wg0)"
    return 0
  fi

  if wg_host_firewall_ok; then
    echo "NOTE: host firewall is already configured — wg-easy hooks are optional"
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx wg-easy; then
    if wg_host_firewall_ok; then
      echo "SKIP: container not running, but host firewall is OK"
      return 0
    fi
    echo "ERROR: wg-easy container is not running. Start with: docker compose up -d" >&2
    return 1
  fi

  wg_wait_for_ui "${port}" || true

  if [[ -n "${password}" ]]; then
    echo "Trying wg-easy API (optional)..."
    local attempt
    for attempt in 1 2 3; do
      if wg_apply_hooks_via_api "${password}" "${port}" "${username}"; then
        sleep 2
        if wg_hooks_already_ok; then
          echo "OK: hooks applied via API"
          return 0
        fi
        echo "OK: hooks saved via API"
        return 0
      fi
      sleep 2
    done
    echo "WARN: wg-easy API could not save hooks (restart 500 is common — not fatal if host firewall is OK)" >&2
  else
    echo "SKIP: no password — wg-easy hooks not updated via API" >&2
    echo "  Optional: sudo ./scripts/wg.sh setup 'your-ui-password'" >&2
  fi

  if wg_apply_hooks_via_db; then
    return 0
  fi

  if wg_host_firewall_ok; then
    echo "OK: skipping wg-easy hooks — host iptables/NAT is configured and sufficient"
    return 0
  fi

  echo "ERROR: host firewall and wg-easy hooks both need attention" >&2
  return 1
}
