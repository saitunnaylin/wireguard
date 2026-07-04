# WireGuard Homelab VPN

Docker Compose stack for a home WireGuard server with a web admin UI ([wg-easy v15](https://github.com/wg-easy/wg-easy)). Access your homelab from a phone or laptop over an encrypted tunnel.

Tested on Linux (bare metal, VM, NAS) with dynamic public IP and Cloudflare DNS.

## Features

- **wg-easy v15** — web UI for clients, QR codes, and config downloads
- **Host networking** — reliable LAN routing and NAT (required for homelab access)
- **Split tunnel by default** — only VPN + home LAN traffic goes through the tunnel
- **`scripts/wg.sh`** — one CLI for setup, repair, status, and validation
- **Docker + iptables aware** — handles Ubuntu/Debian and EL9/EL10 (RHEL, AlmaLinux, Rocky) hosts running Docker

## Architecture

```
Phone ──UDP 51820──► Router (port forward) ──► wg-easy (host network) ──► Home LAN
Admin ──TCP 51821──► Web UI (keep on LAN or VPN only)
```

## Requirements

- Linux host with Docker Compose v2 (Debian/Ubuntu **or** EL9/EL10 — RHEL, AlmaLinux, Rocky)
- Router port-forward: **UDP 51820** → homelab host IP
- Public IP or DDNS hostname (`INIT_HOST`) — **DNS only**, not Cloudflare proxied
- WireGuard tools on the host (see [Platform setup](#platform-setup) below)

## Platform setup

The Docker stack and `./scripts/wg.sh` commands are the same on all Linux distros. Only **host packages** and **optional firewall UI lockdown** differ.

### Debian / Ubuntu

```bash
# Docker (if not installed): https://docs.docker.com/engine/install/ubuntu/
sudo apt update
sudo apt install -y docker.io docker-compose-plugin wireguard-tools

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # log out/in after this
```

### EL9 / EL10 — RHEL, AlmaLinux, Rocky (RPM)

RPM-based setup is documented for **Enterprise Linux 9 and 10 only** (RHEL 9/10, AlmaLinux 9/10, Rocky Linux 9/10). Other RPM distros (Fedora, CentOS Stream, EL8) are not supported here.

**EL9** (RHEL 9, AlmaLinux 9, Rocky Linux 9):

```bash
# Docker: https://docs.docker.com/engine/install/rhel/
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # log out/in after this

sudo dnf install -y wireguard-tools
```

**EL10** (RHEL 10, AlmaLinux 10, Rocky Linux 10):

```bash
# Docker: https://docs.docker.com/engine/install/rhel/
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Minimal EL10 installs may need extra kernel modules for Docker networking
sudo dnf install -y kernel-modules-extra
sudo reboot   # reboot if modprobe xt_addrtype fails after install

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # log out/in after this

sudo dnf install -y wireguard-tools
```

> WireGuard kernel module is built-in on EL9/EL10. If `wg0` fails to start with SELinux, check `sudo ausearch -m avc -ts recent`.

### After platform packages — same on all distros

```bash
git clone <this-repo-url>
cd wireguard
cp .env.example .env
# Edit .env — set INIT_HOST, INIT_PASSWORD, LAN_SUBNET, INIT_ALLOWED_IPS

./scripts/wg.sh validate
docker compose up -d
sudo ./scripts/wg.sh setup
```

## Quick start

Same as [Platform setup → After platform packages](#after-platform-packages--same-on-all-distros) above.

Open **http://\<homelab-ip\>:51821**, log in, create a client, scan the QR code on your phone.

After the first successful start, **remove `INIT_PASSWORD` from `.env`** and run `docker compose up -d` again.

## Configuration

Copy `.env.example` to `.env` and customize:

| Variable | Description |
|----------|-------------|
| `INIT_HOST` | Public IP or DDNS hostname in client configs (e.g. `vpn.example.com`) |
| `INIT_PASSWORD` | Web UI password (first boot only — remove after setup) |
| `LAN_SUBNET` | Your home network (e.g. `192.168.1.0/24`) |
| `INIT_ALLOWED_IPS` | Routes pushed to clients — include VPN subnet + LAN |

**Split tunnel (default):**

```bash
LAN_SUBNET=192.168.1.0/24
INIT_ALLOWED_IPS=10.8.0.0/24,192.168.1.0/24
```

**Full tunnel** (add only after split tunnel works):

```bash
INIT_ALLOWED_IPS=10.8.0.0/24,192.168.1.0/24,0.0.0.0/0
```

> `INIT_*` variables apply on **first boot only** (when `./data` is empty). After that, change settings in the web UI and recreate clients.

## Scripts

| Command | Description |
|---------|-------------|
| `./scripts/wg.sh validate` | Check `.env` and compose config |
| `sudo ./scripts/wg.sh setup` | Host firewall + optional wg-easy hooks |
| `sudo ./scripts/wg.sh repair` | Fix wg0 down / bad server AllowedIPs |
| `./scripts/wg.sh status` | Diagnostics — run with phone VPN ON |
| `./scripts/test.sh` | Smoke test (Docker required) |

## Cloudflare DDNS (dynamic IP)

Use a **dedicated VPN subdomain** with **DNS only** (grey cloud):

```
wg.example.com   A   <your-public-ip>   Proxied: OFF
```

WireGuard uses **UDP** — Cloudflare orange-cloud proxy **breaks** the VPN (resolves to `104.21.x.x`).

Your other domains can stay proxied. Grey cloud on `wg.*` only exposes your IP for the VPN endpoint; it does not expose homelab services.

DDNS update scripts must set `"proxied": false` in the Cloudflare API.

Verify:

```bash
dig +short wg.example.com   # must equal your public IP, not a Cloudflare IP
```

## Security & hardening

### Priority 1 — Do these first

**1. Lock down the admin UI (port 51821)**

The web UI manages keys and clients — treat it like root access. Do **not** port-forward 51821 on your router.

Option A — LAN only (simplest):

<details>
<summary>Debian / Ubuntu (UFW)</summary>

```bash
# Adjust LAN_SUBNET to match .env (e.g. 192.168.1.0/24)
sudo ufw allow from 192.168.1.0/24 to any port 51821 proto tcp
sudo ufw allow 51820/udp comment 'WireGuard'
sudo ufw enable
```

</details>

<details>
<summary>EL9 / EL10 — RHEL, AlmaLinux, Rocky (firewalld)</summary>

```bash
# Adjust source to your LAN_SUBNET (e.g. 192.168.1.0/24)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="51821" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-port=51820/udp
sudo firewall-cmd --reload
```

Default zone should be `public`. Do **not** add 51821/tcp without a source restriction.

</details>

> VPN forwarding/NAT is handled by `sudo ./scripts/wg.sh setup` on both families (iptables). The rules above only restrict who can reach the **admin UI**.

Option B — localhost + SSH tunnel (strongest):

```bash
# .env
HOST=127.0.0.1
PORT=51821
```

Then from your laptop: `ssh -L 51821:127.0.0.1:51821 user@homelab-ip` → open http://localhost:51821

**2. DNS for VPN hostname — grey cloud only**

```
wg.example.com   A   <public-ip>   Proxied: OFF
```

Orange cloud breaks WireGuard and does not protect homelab services.

**3. Split tunnel (default)**

Only route VPN + home LAN through the tunnel — not all internet traffic:

```bash
INIT_ALLOWED_IPS=10.8.0.0/24,192.168.1.0/24
```

**4. Secrets**

- Strong `INIT_PASSWORD`, then **remove it from `.env`** after first boot
- Never commit `.env` or `./data/`
- One client profile per device; delete unused clients

**5. Router**

- Forward **UDP only** `INIT_PORT` (default 51820) → homelab host IP
- No other inbound ports to the homelab

---

### Priority 2 — Recommended

| Hardening | How |
|-----------|-----|
| Non-default WireGuard port | `.env` → `INIT_PORT=51830`, update router forward, recreate clients |
| Non-default UI port | `.env` → `PORT=52821` (still block from WAN) |
| Change admin username | `.env` → `INIT_USERNAME=yourname` (first boot only) |
| Disable IPv6 | Already set: `DISABLE_IPV6=true` |
| Host firewall | `sudo ./scripts/wg.sh setup` after every deploy |
| Verify regularly | `./scripts/wg.sh status` with phone on mobile data |

**Optional — Per-client firewall** (after VPN works):

Admin → Interface → enable Per-Client Firewall, then per client set Firewall Allowed IPs to your LAN subnet only (e.g. `192.168.1.0/24, 10.8.0.0/24`).

---

### Priority 3 — Operational

- **Backup** `./data/` encrypted off-site (contains private keys)
- **Updates:** `docker compose pull && docker compose up -d && sudo ./scripts/wg.sh setup`
- **Revoke access:** delete client in UI immediately when a device is lost
- **No public listing** of your VPN hostname — obscurity is not security, but reduces noise
- **CGNAT:** if port forwarding cannot work, use Tailscale/Headscale or a VPS relay instead

---

### What WireGuard already gives you

- Modern cryptography (Noise protocol) — no obsolete VPN ciphers
- No open port without a valid key — probes on 51820 are harmless without your client config
- Authenticated peers only — random internet hosts cannot join

Changing ports adds minor scan-noise reduction; **blocking the admin UI and using split tunnel matter more.**

---

### Quick hardening checklist

- [ ] Admin UI not reachable from internet (firewall or `HOST=127.0.0.1`)
- [ ] Only UDP WireGuard port forwarded on router
- [ ] `INIT_HOST` DNS is grey cloud / points to public IP
- [ ] Split tunnel configured
- [ ] `INIT_PASSWORD` removed from `.env` after setup
- [ ] `./scripts/wg.sh status` shows handshake + traffic from phone
- [ ] Unused clients deleted
- [ ] `./data/` backed up securely

## Troubleshooting

```bash
./scripts/wg.sh status          # run while phone VPN is ON (mobile data)
sudo ./scripts/wg.sh repair     # wg0 down or bad server peer config
sudo ./scripts/wg.sh setup      # re-apply host firewall / NAT
```

| Symptom | Fix |
|---------|-----|
| `handshake=0` | DNS (grey cloud), router UDP port forward, or CGNAT |
| DNS shows `104.21.x.x` | Cloudflare proxied — set DNS only on VPN subdomain |
| `wg0 not up` | `sudo ./scripts/wg.sh repair` |
| `wg0 not up` on EL9/EL10 + SELinux | `sudo dnf install wireguard-tools`; check `sudo ausearch -m avc -ts recent` |
| Connected, no traffic | `sudo ./scripts/wg.sh setup` (iptables/NAT) |
| Stale client after changes | Delete client in UI, create new, re-scan QR |
| Test on home Wi-Fi | Use **mobile data only** |

**Packet capture** (phone VPN ON, mobile data):

```bash
sudo timeout 15 tcpdump -ni eth0 udp port 51820 -c 5
```

No packets → router/CGNAT. Packets but no handshake → re-scan QR.

**Fresh start:**

```bash
docker compose down && rm -rf data
docker compose up -d && sudo ./scripts/wg.sh setup
```

## Project layout

```
.
├── docker-compose.yml
├── .env.example
├── LICENSE
├── scripts/
│   ├── wg.sh              # CLI entry point
│   ├── test.sh            # smoke test
│   └── lib/
│       ├── common.sh      # shared helpers
│       ├── host.sh        # sysctl + iptables
│       ├── hooks.sh       # wg-easy PostUp hooks
│       ├── wireguard.sh   # wg0 repair
│       ├── diagnostics.sh # DNS / reachability checks
│       └── status.sh      # status output
└── data/                  # git-ignored — WireGuard state
```

## Updating

```bash
docker compose pull
docker compose up -d
sudo ./scripts/wg.sh setup
```

## License

MIT — see [LICENSE](LICENSE). [wg-easy](https://github.com/wg-easy/wg-easy) is licensed separately.
