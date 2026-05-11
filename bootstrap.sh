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
description: Expose a Docker service or any HTTP backend at a subdomain of the host's main domain using Caddy with Cloudflare DNS-01 wildcard TLS. Use this when the user asks to "reverse proxy", "expose", "publish", "put behind HTTPS", "map a subdomain to", or otherwise route an HTTPS subdomain to a service (container, localhost port, or remote host). Works on VPS provisioned by vps-bootstrap (Caddy container lives at /opt/1panel/docker/compose/caddy, main domain stored in /root/.vps-bootstrap.env as DOMAIN, Cloudflare token as CF_TOKEN).
---

# Caddy reverse proxy on this VPS

## When to use

Trigger whenever the user asks to expose an HTTP(S) service at a subdomain of
the VPS main domain. Examples:

- "Put grafana at grafana.example.com"
- "Expose this container on its own subdomain"
- "Set up HTTPS for my n8n service"
- "Reverse proxy port 5678 to something.example.com"

Do **not** use this skill to expose raw TCP/UDP or non-HTTP services
(SSH, databases, sing-box inbounds, etc).

## Prerequisites to assume

The VPS was provisioned by `vps-bootstrap`, which means:

- Caddy runs as a docker container named `caddy`, managed by compose at
  `/opt/1panel/docker/compose/caddy/`.
- The main domain is stored in `/root/.vps-bootstrap.env` (`DOMAIN=...`).
- Cloudflare token is cached there too (`CF_TOKEN=...`, `CF_ZONE_ID=...`).
- A wildcard DNS record `*.$DOMAIN` already points to this host's public IP.
- Helper commands `caddy-add`, `caddy-rm`, `caddy-reload` live in `/usr/local/bin`.
- Caddy is attached to an external docker network called `caddy_net` so
  other compose projects can reach it by container name.

Check these with: `cat /root/.vps-bootstrap.env`, `docker ps --filter name=caddy`,
`ls /opt/1panel/docker/compose/caddy/sites.d/`.

## Canonical workflow

### Step 1 — Pick the subdomain

The FQDN is `<service>.$DOMAIN`. Use a short, service-identifying slug for
`<service>` (e.g. `grafana`, `n8n`, `api`, `dashboard`). Ask the user if unclear.

### Step 2 — Pick the backend URL

Caddy needs a URL it can reach. Choose based on how the backend is deployed:

| Backend layout | Backend URL Caddy should use |
| --- | --- |
| Docker container, same `caddy_net` network | `http://<container_name>:<container_port>` |
| Docker container, different network (e.g. ports mapped to host) | `http://host.docker.internal:<host_port>` |
| Process on this host listening on 127.0.0.1 or 0.0.0.0 | `http://host.docker.internal:<port>` |
| Remote host reachable from this box | `http://<host>:<port>` or `https://<host>:<port>` |

If in doubt, ask the user how the backend is exposed. Prefer joining the
container to `caddy_net` (cleaner, no host port exposed):

```yaml
# in the target service's docker-compose.yml
services:
  <svc>:
    ...
    networks:
      - caddy_net
    # remove any ports: stanza, it's not needed
networks:
  caddy_net:
    external: true
```

After editing, `docker compose up -d` the target service to reattach.

### Step 3 — Register the site

Call the helper:

```bash
caddy-add <fqdn> <backend-url>
```

The helper will:

1. Upsert a Cloudflare A record `<fqdn>` -> this host's public IP (using
   cached `CF_TOKEN`).
2. Write `/opt/1panel/docker/compose/caddy/sites.d/<fqdn>.caddy` with a
   site block using DNS-01 for TLS.
3. Run `docker exec caddy caddy reload`.

### Step 4 — Verify

```bash
curl -sI https://<fqdn> | head -5
docker logs --tail 30 caddy | grep -iE 'certificate|error' || true
```

The first request may take 5-30 seconds while Caddy completes the DNS-01
challenge. Subsequent requests reuse the cached certificate.

## Removing a site

```bash
caddy-rm <fqdn>          # remove Caddy snippet + reload
caddy-rm <fqdn> --dns    # also delete the Cloudflare A record
```

## Common edits (beyond what caddy-add does)

If a service needs custom Caddy directives (websockets, path rewrites,
basic auth, etc), edit the snippet directly:

```bash
${EDITOR:-vim} /opt/1panel/docker/compose/caddy/sites.d/<fqdn>.caddy
caddy-reload
```

Always keep the `tls { dns cloudflare {env.CF_API_TOKEN} }` stanza so the
cert auto-renews via DNS-01. The environment variable `CF_API_TOKEN` is
already injected into the Caddy container from
`/opt/1panel/docker/compose/caddy/.env`.

## Things not to do

- Don't manually add A records in Cloudflare UI for new subdomains;
  `caddy-add` handles it and keeps snippet + DNS in sync.
- Don't edit `/opt/1panel/docker/compose/caddy/Caddyfile` — it only
  imports `sites.d/*.caddy`. All per-service config goes in the snippet.
- Don't remove `sites.d/zz-fallback.caddy` (it serves the naked domain
  and unmatched subdomains) or `sites.d/00-onepanel.caddy` (1Panel UI).
- Don't bind 80/443 to any other container — Caddy owns those ports.
- Don't use Cloudflare proxy (orange cloud); the A records are written
  with `proxied=false` so Caddy can terminate TLS itself.
SKILLEOF

echo "### installed codex skill: caddy-reverse-proxy ($SKILL_DIR)"

echo "=================================================================="
echo "### bootstrap done $(date -Is)"
echo "=================================================================="
