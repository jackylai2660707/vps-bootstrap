# vps-bootstrap

Personal one-liner VPS provisioning script for Ubuntu 22.04 / 24.04.

## What it does (in order)

1. Sets the root password (default `Max112233`, override via `ROOT_PASSWORD`)
2. Clears motd / login banners (`/etc/motd`, `/etc/issue`, dynamic motd, PAM bits)
3. Opens the OS firewall fully (flushes iptables INPUT/FORWARD, disables ufw /
   firewalld, persists rules via `iptables-persistent`) while keeping the OCI
   `InstanceServices` chain on OUTPUT intact
4. Moves SSH to port **56767** (rolls back on `sshd -t` failure)
5. Enables BBR + fq congestion control
6. Installs **1Panel v2 + Docker** non-interactively (user `jackylai`, pass
   `Max112233`, entrance `/Jpanel`, port `19810`)
7. Deploys **sing-box** via docker-compose under
   `/opt/1panel/docker/compose/singbox/`:
   - Hysteria2 on **UDP 40001** (self-signed cert, CN `us.yueseng-ys.com`,
     client uses `allowInsecure=true`)
   - VLESS + Reality on **TCP 14433**
8. If `DOMAIN` + `CF_TOKEN` are given:
   - Adds Cloudflare A records for `$DOMAIN` and `*.$DOMAIN` → public IP
   - Deploys **Caddy** via docker-compose at `/opt/1panel/docker/compose/caddy/`
     with the `caddy-dns/cloudflare` plugin
   - Issues a Let's Encrypt SAN certificate (naked + wildcard) via DNS-01
   - Reverse proxies `onepanel.$DOMAIN/Jpanel` → 1Panel
   - 301-redirects everything else on `$DOMAIN` / `*.$DOMAIN` to 1Panel
9. Installs **nvm**, Node **LTS**, and **`@openai/codex`** globally
10. Writes `/root/.codex/config.toml` — provider `openrouter` pointing at
    `https://api.yueseng-ys.com/v1`, model `gpt-5.5`, `approval_policy=never`,
    `sandbox_mode=danger-full-access`, `features.goals=true`

Log goes to `/var/log/vps-bootstrap.log`.

## Usage

### Full one-liner (with DNS + reverse proxy)

```bash
DOMAIN=armus.example.com \
CF_TOKEN=<cloudflare_api_token> \
OPENROUTER_API_KEY=<openrouter_key> \
bash <(curl -fsSL https://raw.githubusercontent.com/jackylai2660707/vps-bootstrap/main/bootstrap.sh)
```

### Minimal (no domain — just SSH/firewall/BBR/1Panel/sing-box/nvm/codex)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jackylai2660707/vps-bootstrap/main/bootstrap.sh)
```

The script will prompt for a domain interactively. Leave blank to skip DNS.

### Persistent Cloudflare token

If you run the script on the same box twice, the token is cached in
`/root/.vps-bootstrap.env` (mode 600) so subsequent runs only need:

```bash
DOMAIN=another.example.com bash <(curl -fsSL https://raw.githubusercontent.com/jackylai2660707/vps-bootstrap/main/bootstrap.sh)
```

## Cloudflare token scopes required

- **Zone → DNS → Edit**
- **Zone → Zone → Read**

Scoped to whichever zone covers your domain.

## Notes

- The Caddy container reaches 1Panel through `host.docker.internal` (mapped to
  the Docker bridge gateway via `extra_hosts: host-gateway`). 1Panel still binds
  on `0.0.0.0:19810` by default; to tighten, edit `/etc/systemd/system/1panel-core.service`
  or front it entirely with Caddy + firewall rule blocking external 19810.
- Codex's model + provider are configured but the API key is left to the user
  to provide. If `OPENROUTER_API_KEY` is passed as an env var, it is written
  into `/root/.bashrc` automatically.
- Idempotent: rerunning refreshes DNS records, sing-box config, Caddyfile, etc.
  1Panel is not reinstalled if already present.
