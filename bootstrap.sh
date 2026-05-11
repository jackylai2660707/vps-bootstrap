#!/bin/bash
# Turn a fresh Ubuntu box into my target VPS state in one shot.
#
# Required: none (will prompt for DOMAIN if not set)
# Optional env vars:
#     DOMAIN                domain to bind (e.g. example.com). If set and
#                           CF_TOKEN is also set, DNS records + Caddy reverse
#                           proxy with wildcard TLS are configured.
#     CF_TOKEN              Cloudflare API Token (Zone:DNS:Edit, Zone:Zone:Read)
#     ROOT_PASSWORD         root password to set (default Max112233)
#     OPENROUTER_API_KEY    exported into /root/.bashrc so Codex can use it
#
# Quick invocation:
#     DOMAIN=example.com CF_TOKEN=xxx bash <(curl -fsSL \
#       https://raw.githubusercontent.com/jackylai2660707/vps-bootstrap/main/bootstrap.sh)

set -euo pipefail
LOG=/var/log/vps-bootstrap.log
touch "$LOG" || LOG=/tmp/vps-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
echo "=================================================================="
echo "### bootstrap start $(date -Is)"
echo "=================================================================="

# ============================================================
# parameters (override via env vars)
# ============================================================
ROOT_PASSWORD="${ROOT_PASSWORD:-M@x12493417260707}"
NEW_SSH_PORT="${NEW_SSH_PORT:-56767}"

PANEL_PORT="${PANEL_PORT:-19810}"
PANEL_ENTRANCE="${PANEL_ENTRANCE:-Jpanel}"
PANEL_USERNAME="${PANEL_USERNAME:-jackylai}"
PANEL_PASSWORD="${PANEL_PASSWORD:-Max112233}"

HY2_PORT="${HY2_PORT:-40001}"
HY2_PASSWORD="${HY2_PASSWORD:-Max112233}"
HY2_CERT_CN="${HY2_CERT_CN:-us.yueseng-ys.com}"

VLESS_PORT="${VLESS_PORT:-14433}"
VLESS_UUID="${VLESS_UUID:-fac23f67-a32e-46e3-b7b7-a32c36ad3b3b}"
REALITY_DEST="${REALITY_DEST:-account.gov.mo}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-MGXZhVRfzORg721P6ziQRhj7KC6bAC9a3w49Fz6kaC0}"

DOMAIN="${DOMAIN:-}"
CF_TOKEN="${CF_TOKEN:-}"
CADDY_EMAIL="${CADDY_EMAIL:-}"
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-Max112233}"

[[ $EUID -eq 0 ]] || { echo "### must run as root" >&2; exit 1; }

# If DOMAIN is not set and we have a tty, ask for it. (Piping via curl|bash
# keeps stdin as the pipe, so we read from /dev/tty explicitly.)
if [[ -z "$DOMAIN" && -r /dev/tty ]]; then
    printf "Enter domain to bind (blank to skip DNS + reverse proxy): " > /dev/tty
    read -r DOMAIN < /dev/tty || DOMAIN=""
fi

if [[ -n "$DOMAIN" && -z "$CF_TOKEN" && -f /root/.vps-bootstrap.env ]]; then
    # shellcheck disable=SC1091
    . /root/.vps-bootstrap.env
fi

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. root password + wipe banners/motd
# ============================================================
[[ -n "$ROOT_PASSWORD" ]] && echo "root:$ROOT_PASSWORD" | chpasswd
if [[ -d /etc/update-motd.d ]]; then chmod -x /etc/update-motd.d/* 2>/dev/null || true; fi
: > /etc/motd
: > /etc/issue
: > /etc/issue.net
rm -f /etc/legal 2>/dev/null || true
sed -i -E 's|^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so.*)$|# \1|' /etc/pam.d/sshd 2>/dev/null || true
sed -i -E 's|^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_motd\.so.*)$|# \1|' /etc/pam.d/login 2>/dev/null || true
sed -i -E 's|^([[:space:]]*session[[:space:]]+optional[[:space:]]+pam_lastlog\.so.*)$|# \1|' /etc/pam.d/login 2>/dev/null || true
echo "### banners cleared"

# ============================================================
# 2. open OS firewall (keep OCI InstanceServices chain on OUTPUT)
# ============================================================
iptables -P INPUT ACCEPT
iptables -F INPUT
iptables -P FORWARD ACCEPT
iptables -F FORWARD
ip6tables -P INPUT ACCEPT 2>/dev/null || true
ip6tables -F INPUT 2>/dev/null || true
ip6tables -P FORWARD ACCEPT 2>/dev/null || true
ip6tables -F FORWARD 2>/dev/null || true

mkdir -p /etc/iptables
iptables-save  > /etc/iptables/rules.v4 || true
ip6tables-save > /etc/iptables/rules.v6 || true

if command -v ufw >/dev/null 2>&1; then ufw --force disable || true; fi
if systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
    systemctl disable --now firewalld || true
fi

apt-get update -qq || true
apt-get install -y -qq iptables-persistent netfilter-persistent curl jq openssl expect ca-certificates >/dev/null || true
netfilter-persistent save >/dev/null 2>&1 || true
echo "### firewall opened + persisted"

# ============================================================
# 3. SSH port with rollback on sshd -t failure
# ============================================================
SSHD=/etc/ssh/sshd_config
cp -a "$SSHD" "${SSHD}.bak.$(date +%s)"
sed -i -E '/^[[:space:]]*#?[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PrintMotd|PrintLastLog|Banner)[[:space:]]/d' "$SSHD"
sed -i -E '/^[[:space:]]*#?[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PrintMotd|PrintLastLog|Banner)$/d' "$SSHD"
cat >> "$SSHD" <<EOF

# customized
Port ${NEW_SSH_PORT}
PermitRootLogin yes
PasswordAuthentication yes
PrintMotd no
PrintLastLog no
Banner none
EOF
if ! sshd -t 2>/tmp/sshd_test.err; then
    echo "!!! sshd config test FAILED, rolling back" >&2
    cat /tmp/sshd_test.err >&2
    LATEST_BAK=$(ls -1t ${SSHD}.bak.* | head -n1)
    cp -a "$LATEST_BAK" "$SSHD"
else
    systemctl restart ssh
    echo "### sshd on port ${NEW_SSH_PORT}"
fi

# ============================================================
# 4. BBR
# ============================================================
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null
echo "### BBR cc=$(sysctl -n net.ipv4.tcp_congestion_control) qd=$(sysctl -n net.core.default_qdisc)"

# ============================================================
# 5. 1Panel (non-interactive via expect) + Docker
# ============================================================
if ! command -v 1pctl >/dev/null 2>&1; then
    cd /root
    INSTALL_MODE=stable
    VERSION="$(curl -fsSL "https://resource.1panel.pro/v2/${INSTALL_MODE}/latest")"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)          arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) echo "unsupported arch: $ARCH"; exit 1 ;;
    esac
    PKG="1panel-${VERSION}-linux-${arch}.tar.gz"
    DIR="1panel-${VERSION}-linux-${arch}"
    URL="https://resource.1panel.pro/v2/${INSTALL_MODE}/${VERSION}/release/${PKG}"

    [[ -f "$PKG" ]] || curl -fLOk --retry 3 --retry-delay 3 "$URL"
    rm -rf "$DIR"
    tar zxf "$PKG"
    echo "intl" > "${DIR}/.selected_edition"

    cat > /root/install_1panel.exp <<EXPEOF
#!/usr/bin/expect -f
set timeout 1800
log_user 1
set PANEL_PORT     "${PANEL_PORT}"
set PANEL_ENTRANCE "${PANEL_ENTRANCE}"
set PANEL_USERNAME "${PANEL_USERNAME}"
set PANEL_PASSWORD "${PANEL_PASSWORD}"
set done 0
cd [lindex \$argv 0]
spawn bash install.sh
expect {
    -timeout 30
    -re "Enter the number corresponding to your language choice:" { send -- "1\r" }
    timeout { exit 2 } eof { exit 3 }
}
while {!\$done} {
    expect {
        -timeout 900
        -re "Set the 1Panel installation directory" { send -- "\r"; exp_continue }
        -re "Do you want to configure image acceleration\\?" { send -- "n\r"; exp_continue }
        -re "Do you want to replace the Docker configuration file\\?" { send -- "n\r"; exp_continue }
        -re "Docker is not installed\\. Do you want to install it\\?" { send -- "y\r"; exp_continue }
        -re "Set 1Panel port \\\(default is" { send -- "\$PANEL_PORT\r"; exp_continue }
        -re "Set 1Panel secure entrance \\\(default is" { send -- "\$PANEL_ENTRANCE\r"; exp_continue }
        -re "Set 1Panel panel user \\\(default is" { send -- "\$PANEL_USERNAME\r"; exp_continue }
        -re "Set the 1Panel panel password, then press Enter to continue" {
            foreach c [split \$PANEL_PASSWORD ""] { send -- "\$c"; sleep 0.05 }
            send -- "\r"
            exp_continue
        }
        -re "Internal address:" { set done 1 }
        -re "Error:" { exit 4 }
        timeout { exit 5 }
        eof { set done 1 }
    }
}
catch { wait } result
exit 0
EXPEOF
    chmod +x /root/install_1panel.exp
    /root/install_1panel.exp "/root/$DIR" || true
    # tolerate expect quirks: as long as 1pctl exists afterwards, we're good
    if ! command -v 1pctl >/dev/null 2>&1; then
        echo "!!! 1Panel install reported failure and 1pctl is missing" >&2
        exit 6
    fi
fi
echo "### 1Panel ready"

# ============================================================
# 6. sing-box (hysteria2 + vless-reality)
# ============================================================
SB_DIR="/opt/1panel/docker/compose/singbox"
SB_CFG="${SB_DIR}/config"
mkdir -p "$SB_CFG"

if [[ ! -f "${SB_CFG}/cert.pem" || ! -f "${SB_CFG}/key.pem" ]]; then
    openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
        -nodes -days 3650 \
        -keyout "${SB_CFG}/key.pem" \
        -out    "${SB_CFG}/cert.pem" \
        -subj   "/CN=${HY2_CERT_CN}" \
        -addext "subjectAltName=DNS:${HY2_CERT_CN}" \
        2>/dev/null
    chmod 644 "${SB_CFG}/cert.pem" "${SB_CFG}/key.pem"
fi

cat > "${SB_CFG}/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [ { "password": "${HY2_PASSWORD}" } ],
      "tls": {
        "enabled": true,
        "server_name": "${HY2_CERT_CN}",
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [ { "uuid": "${VLESS_UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DEST}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_DEST}", "server_port": 443 },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [""]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block"  }
  ]
}
EOF

cat > "${SB_DIR}/docker-compose.yml" <<'EOF'
services:
  singbox:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: singbox
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config/config.json:/etc/sing-box/config.json:ro
      - ./config/cert.pem:/etc/sing-box/cert.pem:ro
      - ./config/key.pem:/etc/sing-box/key.pem:ro
    command: ["run", "-c", "/etc/sing-box/config.json"]
EOF

docker run --rm \
    -v "${SB_CFG}/config.json:/etc/sing-box/config.json:ro" \
    -v "${SB_CFG}/cert.pem:/etc/sing-box/cert.pem:ro" \
    -v "${SB_CFG}/key.pem:/etc/sing-box/key.pem:ro" \
    ghcr.io/sagernet/sing-box:latest check -c /etc/sing-box/config.json

(cd "$SB_DIR" && docker compose pull && docker compose up -d)
echo "### sing-box running on ${HY2_PORT}/udp + ${VLESS_PORT}/tcp"

# ============================================================
# 7. Cloudflare DNS + Caddy reverse proxy (optional, needs DOMAIN + CF_TOKEN)
# ============================================================
if [[ -n "$DOMAIN" && -n "$CF_TOKEN" ]]; then
    echo "### setting up CF DNS + Caddy for ${DOMAIN}"

    PUBLIC_IP=$(curl -fsS https://api.ipify.org)
    [[ -n "$PUBLIC_IP" ]] || { echo "could not detect public IP" >&2; exit 10; }
    echo "### detected public IP: ${PUBLIC_IP}"

    ZONE=""; ZONE_ID=""
    CAND="$DOMAIN"
    while [[ "$CAND" == *.* ]]; do
        RESP=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" \
            "https://api.cloudflare.com/client/v4/zones?name=${CAND}")
        if [[ $(echo "$RESP" | jq '.result | length') -gt 0 ]]; then
            ZONE="$CAND"
            ZONE_ID=$(echo "$RESP" | jq -r '.result[0].id')
            break
        fi
        CAND="${CAND#*.}"
    done
    [[ -n "$ZONE" ]] || { echo "no CF zone covering ${DOMAIN}" >&2; exit 11; }
    echo "### CF zone: ${ZONE}"

    upsert_record() {
        local NAME="$1"; local IP="$2"
        local EXISTING REC_ID BODY
        EXISTING=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${NAME}&type=A")
        REC_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')
        BODY=$(jq -n --arg name "$NAME" --arg content "$IP" \
            '{type:"A", name:$name, content:$content, ttl:60, proxied:false}')
        if [[ -n "$REC_ID" ]]; then
            curl -fsS -X PUT \
                -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json" \
                --data "$BODY" \
                "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${REC_ID}" \
                | jq -r '"  updated " + .result.name + " -> " + .result.content'
        else
            curl -fsS -X POST \
                -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json" \
                --data "$BODY" \
                "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                | jq -r '"  created " + .result.name + " -> " + .result.content'
        fi
    }

    upsert_record "$DOMAIN"   "$PUBLIC_IP"
    upsert_record "*.$DOMAIN" "$PUBLIC_IP"

    [[ -n "$CADDY_EMAIL" ]] || CADDY_EMAIL="acme@${DOMAIN}"
    CADDY_DIR=/opt/1panel/docker/compose/caddy
    mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config" "$CADDY_DIR/sites.d"

    # shared docker network so other compose projects can reach caddy by container name
    if ! docker network inspect caddy_net >/dev/null 2>&1; then
        docker network create caddy_net >/dev/null
    fi

    cat > "$CADDY_DIR/Caddyfile" <<CADDYFILE
{
    email $CADDY_EMAIL
    acme_dns cloudflare {env.CF_API_TOKEN}
}

# Per-site reverse proxies live in sites.d/ and are managed with the
# caddy-add / caddy-rm / caddy-reload helpers (see /usr/local/bin/).
import /etc/caddy/sites.d/*.caddy
CADDYFILE

    # built-in: 1Panel reverse proxy
    cat > "$CADDY_DIR/sites.d/00-onepanel.caddy" <<SITEEOF
# onepanel: reverse proxy to 1Panel web UI (entrance = /${PANEL_ENTRANCE})
onepanel.${DOMAIN} {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy http://host.docker.internal:${PANEL_PORT} {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}
SITEEOF

    # built-in: fallback — naked + wildcard domain redirect to panel.
    # Caddy auto-matches the most specific host, so any site block for
    # e.g. grafana.\$DOMAIN defined by the user takes precedence.
    cat > "$CADDY_DIR/sites.d/zz-fallback.caddy" <<FALLEOF
${DOMAIN}, *.${DOMAIN} {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    redir https://onepanel.${DOMAIN}/${PANEL_ENTRANCE} 301
}
FALLEOF

    # remove legacy 'sites' dir + placeholder from earlier script versions
    rm -rf "$CADDY_DIR/sites"

    cat > "$CADDY_DIR/docker-compose.yml" <<'CADDYCOMPOSE'
services:
  caddy:
    image: ghcr.io/caddybuilds/caddy-cloudflare:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./sites.d:/etc/caddy/sites.d:ro
      - ./data:/data
      - ./config:/config
    environment:
      CF_API_TOKEN: "${CF_API_TOKEN}"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - default
      - caddy_net

networks:
  default:
  caddy_net:
    external: true
CADDYCOMPOSE

    umask 077
    cat > "$CADDY_DIR/.env" <<ENVEOF
CF_API_TOKEN=$CF_TOKEN
ENVEOF
    umask 022
    chmod 600 "$CADDY_DIR/.env"

    (cd "$CADDY_DIR" && docker compose pull && docker compose up -d --force-recreate)

    umask 077
    cat > /root/.vps-bootstrap.env <<STASHEOF
# regenerated on each bootstrap run; used only if CF_TOKEN is not passed
CF_TOKEN=$CF_TOKEN
DOMAIN=$DOMAIN
CF_ZONE_ID=$ZONE_ID
STASHEOF
    umask 022
    chmod 600 /root/.vps-bootstrap.env

    echo "### Caddy up — https://onepanel.${DOMAIN}/${PANEL_ENTRANCE} (cert issuance <60s)"

    # --------------------------------------------------------
    # install caddy-add / caddy-rm / caddy-reload helpers
    # --------------------------------------------------------
    cat > /usr/local/bin/caddy-reload <<'HELPEOF'
#!/bin/bash
set -euo pipefail
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
echo "caddy reloaded"
HELPEOF
    chmod +x /usr/local/bin/caddy-reload

    cat > /usr/local/bin/caddy-add <<'HELPEOF'
#!/bin/bash
# caddy-add <fqdn> <backend-url>
#
# Register a subdomain reverse proxy. Safe to re-run (overwrites snippet).
#
# Examples:
#     caddy-add grafana.example.com http://host.docker.internal:3000
#     caddy-add app.example.com http://myservice:8080     # container on caddy_net
#     caddy-add api.example.com https://10.0.0.5:8443     # remote host
set -euo pipefail

if [[ $# -lt 2 ]]; then
    cat >&2 <<USAGE
Usage: caddy-add <fqdn> <backend-url>

Examples:
    caddy-add grafana.example.com http://host.docker.internal:3000
    caddy-add app.example.com http://myservice:8080       # caddy_net container
    caddy-add api.example.com https://10.0.0.5:8443       # any reachable host
USAGE
    exit 1
fi

FQDN="$1"
BACKEND="$2"

STASH=/root/.vps-bootstrap.env
[[ -f "$STASH" ]] && . "$STASH" || true

CADDY_DIR=/opt/1panel/docker/compose/caddy
SITES_DIR="$CADDY_DIR/sites.d"
mkdir -p "$SITES_DIR"

# DNS upsert (only if we have CF credentials cached)
if [[ -n "${CF_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
    PUBLIC_IP=$(curl -fsS https://api.ipify.org || true)
    if [[ -n "$PUBLIC_IP" ]]; then
        EXISTING=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${FQDN}&type=A")
        REC_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')
        BODY=$(jq -n --arg name "$FQDN" --arg content "$PUBLIC_IP" \
            '{type:"A", name:$name, content:$content, ttl:60, proxied:false}')
        if [[ -n "$REC_ID" ]]; then
            curl -fsS -X PUT -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json" --data "$BODY" \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" \
                | jq -r '"DNS updated " + .result.name + " -> " + .result.content'
        else
            curl -fsS -X POST -H "Authorization: Bearer $CF_TOKEN" \
                -H "Content-Type: application/json" --data "$BODY" \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
                | jq -r '"DNS created " + .result.name + " -> " + .result.content'
        fi
    fi
fi

SAFE=$(echo "$FQDN" | tr '/' '_')
SNIPPET="$SITES_DIR/${SAFE}.caddy"
cat > "$SNIPPET" <<SITE
# managed by caddy-add on $(date -Is)
${FQDN} {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy ${BACKEND} {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}
SITE
echo "wrote $SNIPPET"

docker exec caddy caddy reload --config /etc/caddy/Caddyfile
echo "caddy reloaded. Try: curl -I https://${FQDN}"
HELPEOF
    chmod +x /usr/local/bin/caddy-add

    cat > /usr/local/bin/caddy-rm <<'HELPEOF'
#!/bin/bash
# caddy-rm <fqdn> [--dns]
#   removes the Caddy snippet and reloads.
#   Pass --dns to also delete the Cloudflare A record for that FQDN.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "Usage: caddy-rm <fqdn> [--dns]" >&2; exit 1; }

FQDN="$1"
DEL_DNS=0
[[ "${2:-}" == "--dns" ]] && DEL_DNS=1

CADDY_DIR=/opt/1panel/docker/compose/caddy
SITES_DIR="$CADDY_DIR/sites.d"
SAFE=$(echo "$FQDN" | tr '/' '_')
SNIPPET="$SITES_DIR/${SAFE}.caddy"

if [[ -f "$SNIPPET" ]]; then
    rm -f "$SNIPPET"
    echo "removed $SNIPPET"
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile && echo "caddy reloaded"
else
    echo "no snippet at $SNIPPET"
fi

if [[ $DEL_DNS -eq 1 ]]; then
    STASH=/root/.vps-bootstrap.env
    [[ -f "$STASH" ]] && . "$STASH" || true
    if [[ -n "${CF_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
        EXISTING=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${FQDN}&type=A")
        REC_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')
        if [[ -n "$REC_ID" ]]; then
            curl -fsS -X DELETE -H "Authorization: Bearer $CF_TOKEN" \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" \
                | jq -r '"DNS deleted " + .result.id'
        fi
    fi
fi
HELPEOF
    chmod +x /usr/local/bin/caddy-rm

    echo "### caddy-add / caddy-rm / caddy-reload installed to /usr/local/bin"
else
    echo "### skipping DNS + Caddy (no DOMAIN or CF_TOKEN)"
fi

# ============================================================
# 8. nvm + Node LTS + Codex + codex config.toml
# ============================================================
export NVM_DIR="/root/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    echo "### installing nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | PROFILE=/root/.bashrc bash
fi
# nvm's shell functions reference unset vars internally; temporarily relax -u
set +u
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

# install Node LTS if no node is installed yet
if [[ -z "$(nvm ls --no-colors 2>/dev/null | grep -E '^[[:space:]]*v[0-9]' | head -1)" ]]; then
    echo "### installing Node LTS"
    nvm install --lts
    nvm alias default 'lts/*'
fi
nvm use --lts >/dev/null
set -u
echo "### node $(node --version), npm $(npm --version)"

if ! command -v codex >/dev/null 2>&1; then
    echo "### installing @openai/codex globally"
    npm install -g @openai/codex >/dev/null
fi
echo "### codex: $(codex --version 2>/dev/null || echo installed)"

# symlink codex + node + npm into /usr/local/bin so non-interactive shells
# (ssh "cmd", cron, systemd) can find them without sourcing nvm.sh
for bin in codex node npm; do
    target=$(command -v "$bin" || true)
    if [[ -n "$target" && ! -L "/usr/local/bin/$bin" ]]; then
        ln -sf "$target" "/usr/local/bin/$bin"
    fi
done

mkdir -p /root/.codex
cat > /root/.codex/config.toml <<'CODEXCFG'
model_provider = "openrouter"
model = "gpt-5.5"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.openrouter]
name = "openrouter"
base_url = "https://api.yueseng-ys.com/v1"
env_key = "OPENROUTER_API_KEY"

[features]
goals = true
CODEXCFG
chmod 600 /root/.codex/config.toml

if ! grep -q 'NVM_DIR=' /root/.bashrc 2>/dev/null; then
    cat >> /root/.bashrc <<'BASHEOF'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
BASHEOF
fi

if [[ -n "$OPENROUTER_API_KEY" ]]; then
    # strip any existing export and append fresh; also write it into an env file
    # that codex can read independently of the user's shell
    sed -i '/^export OPENROUTER_API_KEY=/d' /root/.bashrc 2>/dev/null || true
    echo "export OPENROUTER_API_KEY='${OPENROUTER_API_KEY}'" >> /root/.bashrc
    umask 077
    echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY}" > /root/.codex/.env
    umask 022
    chmod 600 /root/.codex/.env
    echo "### OPENROUTER_API_KEY saved (bashrc + /root/.codex/.env)"
fi

# ============================================================
# 9. Codex skill: caddy-reverse-proxy
#    Teach codex to expose docker services through Caddy on demand.
# ============================================================
SKILL_DIR=/root/.agents/skills/caddy-reverse-proxy
mkdir -p "$SKILL_DIR"
cat > "$SKILL_DIR/SKILL.md" <<'SKILLEOF'
---
name: caddy-reverse-proxy
description: Operate Caddy as a Docker reverse proxy for local, Docker Compose, 1Panel, or remote services. Use when exposing an app/API/site through a domain, adding or changing Caddyfile reverse_proxy routes, reusing wildcard certificates, connecting backend containers to an existing Caddy network, validating and reloading Caddy, troubleshooting TLS/certificate/upstream connectivity, or installing a persistent Docker Caddy service when none exists.
---

# Caddy Reverse Proxy

## vps-bootstrap Fast Path

If this host was provisioned by `vps-bootstrap` (detect with
`test -x /usr/local/bin/caddy-add && test -f /root/.vps-bootstrap.env`),
prefer the one-shot helpers and skip discovery:

- `caddy-add <fqdn> <backend-url>` — creates the Cloudflare A record
  (using cached `CF_TOKEN`), writes
  `/opt/1panel/docker/compose/caddy/sites.d/<fqdn>.caddy`, and reloads
  Caddy.
- `caddy-rm <fqdn> [--dns]` — removes the snippet and reloads; `--dns`
  also deletes the DNS record.
- `caddy-reload` — plain `caddy reload` wrapper.

Only fall back to the manual workflow below when:
- a site needs directives the helper does not emit (WebSocket-specific
  routing, path rewrites, basic auth, file_server, rate limiting, etc.),
- the user wants to consolidate several subdomains under a shared
  wildcard `*.$DOMAIN` block with host matchers (see "Wildcard
  Certificate Reuse"),
- something in the helper's DNS upsert / Caddyfile snippet / reload
  pipeline went wrong and needs hand-inspection.

When you do hand-edit, the managed files live in
`/opt/1panel/docker/compose/caddy/sites.d/*.caddy`; the top-level
`Caddyfile` only holds the global block and `import sites.d/*.caddy`.
After any manual edit, run `caddy-reload` (or
`docker exec caddy caddy reload --config /etc/caddy/Caddyfile`).

## Operating Principles

- Prefer the existing Docker Caddy container/service. Inspect before creating anything.
- On 1Panel-style hosts, prefer managing Caddy at `/opt/1panel/docker/compose/caddy`.
- Edit the host file mounted to `/etc/caddy/Caddyfile`, even if the mount is read-only inside the container.
- Preserve existing routes and user edits. Add the smallest domain/path block needed.
- Validate before reload. If validation fails, fix the Caddyfile and do not reload.
- Reload Caddy in place; recreate only when mounts, ports, image, or networks changed.
- Prefer private Docker networking for container backends. Do not publish backend ports unless needed for another reason.
- Prefer wildcard certificate/site blocks for sibling subdomains when DNS automation is available; avoid triggering per-subdomain ACME issuance unnecessarily.
- For host-machine backends, verify the service listens on `0.0.0.0` or is reachable from the Caddy container.
- For fresh Docker/Caddy install steps, verify current official documentation first when internet access is available.
- Treat DNS API tokens as secrets: do not print them, do not run `docker compose config` after they are set unless redacting output, and keep `.env` mode `0600`.

## Fast Workflow

1. Load the host profile cache if it exists, then cheaply verify the named Caddy container and Caddyfile path.
2. Discover Caddy only if the cache is missing or stale.
3. Classify the upstream: same Docker network container, host-machine service, or remote URL.
4. Check whether the hostname is covered by an existing wildcard route/certificate; if not, evaluate whether a wildcard can be created first.
5. Verify Caddy can reach the upstream before editing when practical.
6. Add or update the Caddyfile route.
7. Run `caddy validate`, then `caddy reload`.
8. Check the public domain, HTTPS certificate behavior, upstream logs, and update the profile cache.

## Host Profile Cache

Do not rediscover the same VPS on every run:

```bash
PROFILE_DIR="${CODEX_HOME:-$HOME/.codex}/state/caddy-reverse-proxy"
HOST_ID="$(hostname -f 2>/dev/null || hostname)"
PROFILE="$PROFILE_DIR/$HOST_ID.md"
test -f "$PROFILE" && sed -n '1,220p' "$PROFILE"
```

Validate cached facts before trusting them:

```bash
docker ps --format '{{.Names}}' | grep -Fx '<caddy-container-name>'
test -f '<host-caddyfile-path>'
```

Record or update at least:

```markdown
# Caddy Reverse Proxy Host Profile

- hostname:
- last_verified:
- caddy_container:
- compose_project_dir:
- compose_service:
- host_caddyfile_path:
- container_caddyfile_path: /etc/caddy/Caddyfile
- data_volume_or_mount:
- config_volume_or_mount:
- published_ports:
- docker_network:
- host_gateway_for_container:
- host_gateway_alias:
- wildcard_domains:
- wildcard_route_style:
- reload_command:
- validate_command:
- notes:
```

Keep this cache outside the skill directory so one machine's paths do not leak into another.

## Discovery

Use cheap, focused checks first. Common 1Panel and manual Compose roots include `/opt/1panel/docker/compose` and `/root/compose`.

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}' | grep -i caddy || true
find /opt/1panel/docker/compose /root/compose . -maxdepth 4 \( -iname 'Caddyfile' -o -iname 'compose.yml' -o -iname 'docker-compose.yml' \) 2>/dev/null
docker inspect <caddy-container> --format '{{json .Mounts}}'
docker inspect <caddy-container> --format '{{json .NetworkSettings.Networks}}'
```

Identify:

- Caddy container name and, if applicable, Compose project directory/service.
- Host path mounted to `/etc/caddy/Caddyfile`.
- Persistent `/data` and `/config` mounts.
- Published ports, especially `80`, `443`, and `443/udp`.
- Docker network shared with app containers.
- Whether `host.docker.internal` is configured through `host-gateway`.
- Existing wildcard site blocks such as `*.example.com` and how they route subdomains.
- Installed DNS provider modules: `docker exec <caddy-container> caddy list-modules | grep '^dns.providers.' || true`.

If `/etc/caddy/Caddyfile` is not bind-mounted, inspect Compose config and container command before deciding how to persist edits.

## Preferred 1Panel Layout

When the user wants Caddy standardized on a 1Panel host, use:

```text
/opt/1panel/docker/compose/caddy/
├── Caddyfile
├── Dockerfile
├── docker-compose.yml
├── data/
└── config/
```

If an existing Caddy lives elsewhere, copy `Caddyfile`, `data`, and `config` into that directory, recreate the container from the new Compose project, verify domains, then rename the old directory to a timestamped backup. Preserve:

- `container_name: caddy`
- published ports `80:80`, `443:443`, `443:443/udp`
- `/data` and `/config`
- the `caddy_default` Docker network name when other app containers already depend on it
- `extra_hosts: ["host.docker.internal:host-gateway"]`

Use a custom local image when DNS provider modules are needed:

```dockerfile
FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

Compose baseline:

```yaml
services:
  caddy:
    build:
      context: .
    image: local/caddy-cloudflare:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      CLOUDFLARE_API_TOKEN: ${CLOUDFLARE_API_TOKEN:-}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
```

After building, confirm the module exists before changing TLS policy:

```bash
docker run --rm local/caddy-cloudflare:2 caddy list-modules | grep '^dns.providers.cloudflare$'
```

## Upstream Selection

Choose the most private stable upstream:

1. **Backend is a Docker/Compose service**: attach it to Caddy's Docker network and proxy to service/container DNS, e.g. `reverse_proxy app:3000`.
2. **Backend is on the host**: prefer `host.docker.internal:<port>` when Caddy has `extra_hosts: ["host.docker.internal:host-gateway"]`; otherwise use the gateway of Caddy's Docker network, not blindly `172.17.0.1`.
3. **Backend is remote**: proxy to the remote URL/host and preserve Host header only when the upstream requires it.

Do not use a container IP in the Caddyfile unless there is no better option; IPs change after recreation.

For a backend container that should join Caddy's network:

```yaml
services:
  app:
    networks:
      - caddy_default

networks:
  caddy_default:
    external: true
```

For a host-machine process, confirm listening behavior:

```bash
ss -ltnp | grep ':3000'
docker exec <caddy-container> wget -S -O- http://host.docker.internal:3000/ 2>&1 | head
```

If the process only binds `127.0.0.1`, change its server flags/env to bind `0.0.0.0`, or use a deliberate host networking/tunnel approach.

## Caddyfile Patterns

Simple container backend:

```caddyfile
example.com {
    encode zstd gzip
    reverse_proxy app:3000
}
```

Host-machine backend:

```caddyfile
example.com {
    encode zstd gzip
    reverse_proxy host.docker.internal:3000
}
```

Path-scoped backend while preserving an existing site:

```caddyfile
example.com {
    encode zstd gzip

    handle_path /api/* {
        reverse_proxy api:8080
    }

    handle {
        reverse_proxy web:80
    }
}
```

Only add explicit WebSocket matchers when the existing app requires special routing; Caddy normally proxies WebSocket upgrades automatically.

## Wildcard Certificate Reuse

A wildcard certificate for `*.example.com` covers one-label subdomains such as `sub.example.com`; it does not cover `example.com` or `a.b.example.com`.

### Wildcard-First Policy

When the user asks to expose `sub.example.com` and the domain shape suggests repeated sibling subdomains, prefer this order:

1. Reuse an existing `*.example.com` route/certificate.
2. If none exists, create a `*.example.com` wildcard site block when Caddy has a usable DNS provider module and DNS API credentials.
3. If Caddy lacks the DNS module or credentials, explain the blocker and either prepare the Caddy DNS plugin setup or fall back to a one-off `sub.example.com` certificate only if the user still wants immediate exposure.

Do not attempt wildcard ACME issuance with HTTP-01/TLS-ALPN only. Wildcard certificates require DNS validation. In Caddyfile, that means a `tls { dns <provider> ... }` policy, or an equivalent global DNS provider option, and a Caddy build that includes the provider module.

Before creating the wildcard block, determine:

- Parent wildcard name, e.g. `sub.example.com` -> `*.example.com`.
- DNS provider and authoritative zone, using existing user context and commands such as `dig NS example.com`.
- Whether Caddy includes the provider module:

```bash
docker exec <caddy-container> caddy list-modules | grep '^dns.providers.'
```

- Whether the Caddy container has the needed credential env vars or secret files.
- Whether replacing `caddy:2` with a custom Caddy image containing the DNS plugin is in scope. Preserve `/data`, `/config`, ports, networks, and Caddyfile mounts if changing the image.

For Cloudflare-hosted zones, expect `dns.providers.cloudflare` and `CLOUDFLARE_API_TOKEN`. If the token is absent or blank, build/install the plugin and leave exact-host routing in place; do not add `tls { dns cloudflare ... }` until a real token is configured.

On vps-bootstrap hosts, the token is stored as `CF_API_TOKEN` in
`/opt/1panel/docker/compose/caddy/.env` and exposed to Caddy as
`{env.CF_API_TOKEN}` — reuse that variable name rather than
introducing `CLOUDFLARE_API_TOKEN`.

After writing or changing `.env`, recreate Caddy so the environment is present before validating a Caddyfile that uses `{env.CF_API_TOKEN}`:

```bash
chmod 600 /opt/1panel/docker/compose/caddy/.env
docker compose up -d
```

Common wildcard-first route pattern:

```caddyfile
*.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }

    @sub host sub.example.com
    handle @sub {
        reverse_proxy sub-store:3001
    }

    handle {
        abort
    }
}
```

If the apex domain also needs the same certificate policy, include it intentionally:

```caddyfile
example.com, *.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }

    @sub host sub.example.com
    handle @sub {
        reverse_proxy sub-store:3001
    }
}
```

When the requested hostname is covered by an existing wildcard site/certificate, prefer adding a host matcher inside the wildcard site block instead of creating a separate exact hostname block. This keeps routing under the wildcard TLS policy and avoids unnecessary per-subdomain certificate issuance.

Preferred pattern:

```caddyfile
*.example.com {
    encode zstd gzip

    @sub host sub.example.com
    handle @sub {
        reverse_proxy sub-store:3001
    }

    @api host api.example.com
    handle @api {
        reverse_proxy api:8080
    }

    handle {
        abort
    }
}
```

Use a separate `sub.example.com { ... }` block only when there is no wildcard block to reuse, when the user explicitly wants a dedicated certificate/policy, or when the existing Caddyfile architecture already uses exact host blocks and changing it would be broader than the request.

After reload, inspect Caddy logs. Wildcard-first setup should show ACME work for `*.example.com`, not repeated orders for every exact sibling subdomain. A reused wildcard route should not show a new ACME order for the exact subdomain; if it does, revisit the Caddyfile structure before repeating reloads.

## Validate And Reload

Prefer the discovered commands from the profile. Direct container form:

```bash
docker exec <caddy-container> caddy validate --config /etc/caddy/Caddyfile
docker exec <caddy-container> caddy reload --config /etc/caddy/Caddyfile
```

Compose-managed form:

```bash
docker compose exec <caddy-service> caddy validate --config /etc/caddy/Caddyfile
docker compose exec <caddy-service> caddy reload --config /etc/caddy/Caddyfile
```

If Caddy reports formatting warnings only, optionally normalize the host Caddyfile with `caddy fmt`; do not mix formatting churn with unrelated route changes unless it helps reduce future diffs.

## Verification

Check from the Caddy container first, then from the public domain:

```bash
docker exec <caddy-container> wget -S -O- http://app:3000/ 2>&1 | head -40
curl -I --max-time 20 http://example.com
curl -I --max-time 20 https://example.com
docker logs --tail=120 <caddy-container>
docker logs --tail=120 <backend-container>
```

Expected outcomes:

- HTTP normally returns Caddy's `308` redirect to HTTPS.
- HTTPS returns the upstream status, commonly `200`, `204`, `301`, or an app-specific auth redirect.
- Caddy logs show certificate obtain/renew success for new domains, or no new TLS work if a cert already exists.
- When reusing a wildcard certificate, Caddy logs should not show a new ACME order for the exact subdomain.
- For API services, test a real health endpoint, not only `/`.

If HTTPS fails:

- Confirm DNS A/AAAA records point to this server.
- Confirm ports `80` and `443` are reachable externally and published by Caddy.
- Inspect Caddy ACME logs for challenge failures.
- Avoid repeated reload loops that can trigger CA rate limits.

## Install Docker Caddy When Missing

Install only when no usable Caddy container exists. Use persistent `/data` and `/config`, publish HTTP/HTTPS, and add `host.docker.internal` for host backends:

```yaml
services:
  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
```

Start with:

```bash
docker compose up -d
```

If Compose is unavailable but Docker works, use an equivalent `docker run` with the same ports, host-gateway alias, Caddyfile bind mount, and persistent data/config mounts.

## Operational Notes

- Keep certificates persistent by preserving Caddy's `/data`.
- Avoid exposing development/debug servers publicly unless the user explicitly accepts the risk.
- Prefer one domain block per public hostname unless path routing is required.
- Prefer one wildcard block with `host` matchers for many sibling subdomains when a wildcard certificate is already in use.
- When a backend service was just deployed, verify its logs and health before blaming Caddy.
- After successful changes, update the host profile with the current Caddyfile path, network, gateway alias, wildcard domains, and validation/reload commands.
SKILLEOF

echo "### installed codex skill: caddy-reverse-proxy ($SKILL_DIR)"

# ============================================================
# 10. ddns-go (optional, needs DOMAIN + CF_TOKEN)
#     Watches the VPS public IP, updates $DOMAIN and *.$DOMAIN records
#     on Cloudflare whenever the IP changes.
# ============================================================
if [[ -n "$DOMAIN" && -n "$CF_TOKEN" ]]; then
    DDNS_DIR=/opt/1panel/docker/compose/ddns-go
    mkdir -p "$DDNS_DIR/conf"

    cat > "$DDNS_DIR/docker-compose.yml" <<'DDNSCOMPOSE'
services:
  ddns-go:
    image: jeessy/ddns-go:latest
    container_name: ddns-go
    restart: unless-stopped
    # bind only to 127.0.0.1 — the UI is only reached via Caddy reverse proxy
    ports:
      - "127.0.0.1:9876:9876"
    volumes:
      - ./conf:/root
    environment:
      TZ: Asia/Shanghai
DDNSCOMPOSE

    # Pre-seed the ddns-go config so it runs headless: it already knows the
    # Cloudflare provider + token + which domains to keep in sync. The UI
    # (reverse-proxied via Caddy) lets you inspect / edit later.
    # See https://github.com/jeessy2/ddns-go — config.yaml schema.
    # User credentials: jackylai / M@x12493417260707 (BCrypt'ed at runtime by ddns-go).
    cat > "$DDNS_DIR/conf/.ddns_go_config.yaml" <<DDNSCFG
Ipv4:
  Enable: true
  GetType: netInterface
  IPReg: ""
  NetInterface: ""
  Cmd: ""
  URL: "https://myip4.ipip.net|https://api.ipify.org|https://ip4.seeip.org"
  Domains:
    - "$DOMAIN"
    - "*.$DOMAIN"
Ipv6:
  Enable: false
  GetType: netInterface
  IPReg: ""
  NetInterface: ""
  Cmd: ""
  URL: "https://api64.ipify.org"
  Domains: []
DNS:
  Name: cloudflare
  ID: ""
  Secret: "$CF_TOKEN"
User:
  Username: "$PANEL_USERNAME"
  Password: "$PANEL_PASSWORD"
Webhook:
  WebhookURL: ""
  WebhookRequestBody: ""
  WebhookHeaders: ""
TTL: "60"
DDNSCFG
    chmod 600 "$DDNS_DIR/conf/.ddns_go_config.yaml"

    (cd "$DDNS_DIR" && docker compose pull && docker compose up -d)

    # Reverse-proxy the web UI as ddns.\$DOMAIN via Caddy + create the DNS record.
    # caddy-add handles idempotency; safe to re-run.
    if command -v caddy-add >/dev/null 2>&1; then
        caddy-add "ddns.${DOMAIN}" "http://host.docker.internal:9876" || true
    fi

    echo "### ddns-go up — UI at https://ddns.${DOMAIN}  (login: ${PANEL_USERNAME} / ${PANEL_PASSWORD})"
else
    echo "### skipping ddns-go (no DOMAIN or CF_TOKEN)"
fi

echo "=================================================================="
echo "### bootstrap done $(date -Is)"
echo "=================================================================="
