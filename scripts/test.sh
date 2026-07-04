#!/usr/bin/env bash
# Integration smoke test — run on Linux homelab host with Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PASS=0
FAIL=0

ok() { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

cleanup() {
  if [[ "${KEEP_RUNNING:-}" != "1" ]]; then
    docker compose down >/dev/null 2>&1 || true
    rm -f .env.test
    if [[ "${KEEP_DATA:-}" != "1" ]]; then
      rm -rf data
    fi
  fi
}
trap cleanup EXIT

echo "=== WireGuard smoke test ==="
echo ""

if docker compose --env-file .env.example config >/dev/null 2>&1; then
  ok "docker compose config parses"
else
  bad "docker compose config failed"
  docker compose --env-file .env.example config || true
fi

RESOLVED="$(docker compose --env-file .env.example config 2>/dev/null | grep 'INIT_ALLOWED_IPS:' | awk '{print $2}')"
if echo "${RESOLVED}" | grep -q '10.8.0.0/24' && echo "${RESOLVED}" | grep -q '192.168.1.0/24'; then
  ok "INIT_ALLOWED_IPS includes VPN + LAN subnets (${RESOLVED})"
else
  bad "INIT_ALLOWED_IPS missing expected subnets (got: ${RESOLVED})"
fi

cp .env.example .env.test
if [[ "$(uname -s)" == "Darwin" ]]; then
  sed -i '' 's/INIT_PASSWORD=$/INIT_PASSWORD=smoke-test-pass/' .env.test
  sed -i '' 's/INIT_HOST=vpn.example.com/INIT_HOST=127.0.0.1/' .env.test
  sed -i '' 's/INIT_USERNAME=yourname/INIT_USERNAME=smoke-test-user/' .env.test
else
  sed -i 's/INIT_PASSWORD=$/INIT_PASSWORD=smoke-test-pass/' .env.test
  sed -i 's/INIT_HOST=vpn.example.com/INIT_HOST=127.0.0.1/' .env.test
  sed -i 's/INIT_USERNAME=yourname/INIT_USERNAME=smoke-test-user/' .env.test
fi
rm -rf data

if ! docker compose --env-file .env.test up -d --force-recreate 2>&1; then
  bad "docker compose up failed"
  exit 1
fi
ok "container started"

# Wait for web UI / API to be ready
for i in $(seq 1 30); do
  HTTP_CODE="$(docker exec wg-easy node -e "
const http=require('http');
http.get('http://127.0.0.1:51821/',r=>{console.log(r.statusCode);process.exit(0)}).on('error',()=>{console.log('000');process.exit(0)});
" 2>/dev/null || echo 000)"
  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
    break
  fi
  sleep 1
done

for i in $(seq 1 30); do
  if docker exec wg-easy wg show wg0 2>/dev/null | grep -q "listening port"; then
    break
  fi
  sleep 1
done

if docker exec wg-easy wg show wg0 2>/dev/null | grep -q "listening port"; then
  ok "wg0 interface is up"
else
  bad "wg0 interface not running"
  docker compose logs --tail 30 wg-easy || true
fi

# Web UI: test from inside container (host network on Docker Desktop Mac won't bind to Mac localhost)
HTTP_CODE="$(docker exec wg-easy node -e "
const http=require('http');
http.get('http://127.0.0.1:51821/',r=>{console.log(r.statusCode);process.exit(0)}).on('error',()=>{console.log('000');process.exit(0)});
" 2>/dev/null || echo 000)"
if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
  ok "web UI responds inside container (HTTP ${HTTP_CODE})"
else
  bad "web UI not reachable (HTTP ${HTTP_CODE})"
fi

# Apply firewall hooks (Linux homelab only — skipped on macOS Docker Desktop)
if [[ "$(uname -s)" == "Linux" ]]; then
  if ENV_FILE=.env.test sudo "${ROOT}/scripts/wg.sh" setup smoke-test-pass 2>&1; then
    ok "wg.sh setup succeeded"
  else
    bad "wg.sh setup failed"
  fi
  sleep 2
  if [[ -f data/wg0.conf ]] && grep -q 'INPUT -i wg0' data/wg0.conf; then
    ok "wg0.conf PostUp accepts INPUT on wg0"
  elif source "${ROOT}/scripts/lib/common.sh" && wg_host_firewall_ok; then
    ok "host iptables configured (wg-easy hooks optional)"
  else
    bad "neither wg0.conf hooks nor host iptables firewall found"
    grep PostUp data/wg0.conf 2>/dev/null || true
  fi
else
  echo "SKIP: wg.sh setup (requires Linux host with real wg0)"
fi

# Create client and verify AllowedIPs via API
CLIENT_OUT="$(docker exec wg-easy node -e "
const http=require('http');
function req(method,path,body,cookie){
  return new Promise((res,rej)=>{
    const data=body?JSON.stringify(body):null;
    const r=http.request({hostname:'127.0.0.1',port:51821,path,method,headers:{'Content-Type':'application/json','Content-Length':data?Buffer.byteLength(data):0,...(cookie?{Cookie:cookie}:{})}},x=>{
      let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,headers:x.headers,body:b}));
    });
    r.on('error',rej); if(data) r.write(data); r.end();
  });
}
(async()=>{
  const login=await req('POST','/api/session',{username:'smoke-test-user',password:'smoke-test-pass',remember:false});
  const cookie=(login.headers['set-cookie']||[]).map(c=>c.split(';')[0]).join('; ');
  const created=await req('POST','/api/client',{name:'smoke-test',expiresAt:null},cookie);
  const list=await req('GET','/api/client',null,cookie);
  const clients=JSON.parse(list.body);
  const id=clients[clients.length-1]?.id||1;
  const conf=await req('GET','/api/client/'+id+'/configuration',null,cookie);
  console.log(conf.body);
})();
" 2>/dev/null)"

if echo "${CLIENT_OUT}" | grep -q '10.8.0.0/24' && echo "${CLIENT_OUT}" | grep -q '192.168.1.0/24'; then
  ok "client config includes VPN + LAN AllowedIPs"
else
  bad "client config missing expected AllowedIPs"
  echo "${CLIENT_OUT}" | head -20 >&2
fi

sleep 2
STATUS="$(docker inspect -f '{{.State.Status}}' wg-easy 2>/dev/null || echo unknown)"
if [[ "${STATUS}" == "running" ]]; then
  ok "container stable (not crash-looping)"
else
  bad "container status: ${STATUS}"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
