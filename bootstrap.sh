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
ROOT_PASSWORD="${ROOT_PASSWORD:-Max112233}"
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
    mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config" "$CADDY_DIR/sites"

    cat > "$CADDY_DIR/Caddyfile" <<CADDYFILE
{
    email $CADDY_EMAIL
    acme_dns cloudflare {env.CF_API_TOKEN}
}

# 1Panel reverse proxy (always on this subdomain)
onepanel.${DOMAIN} {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy http://host.docker.internal:${PANEL_PORT} {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}

# Drop any .caddy file into /opt/1panel/docker/compose/caddy/sites/ to add a
# new subdomain reverse proxy. The wildcard cert + Cloudflare DNS-01 is already
# configured globally above, so per-site blocks only need to declare the
# hostname(s) and reverse_proxy target.
#
# Example /opt/1panel/docker/compose/caddy/sites/grafana.caddy:
#     grafana.${DOMAIN} {
#         tls { dns cloudflare {env.CF_API_TOKEN} }
#         reverse_proxy http://host.docker.internal:3000
#     }
#
# After adding/editing, reload with:
#     docker exec caddy caddy reload --config /etc/caddy/Caddyfile
import /etc/caddy/sites/*.caddy

# Fallback: anything matching the naked domain or any *.DOMAIN that is NOT
# matched by a more specific block above → 301 redirect to 1Panel.
${DOMAIN}, *.${DOMAIN} {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    redir https://onepanel.${DOMAIN}/${PANEL_ENTRANCE} 301
}
CADDYFILE

    # placeholder so /etc/caddy/sites is non-empty on fresh installs
    if [[ ! -f "$CADDY_DIR/sites/README.caddy" ]]; then
        cat > "$CADDY_DIR/sites/README.caddy" <<'SITEREADME'
# Drop one file per subdomain reverse proxy here. Example:
#
#   grafana.example.com {
#       tls { dns cloudflare {env.CF_API_TOKEN} }
#       reverse_proxy http://host.docker.internal:3000
#   }
#
# Reload after changes:
#   docker exec caddy caddy reload --config /etc/caddy/Caddyfile
SITEREADME
    fi

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
      - ./sites:/etc/caddy/sites:ro
      - ./data:/data
      - ./config:/config
    environment:
      CF_API_TOKEN: "${CF_API_TOKEN}"
    extra_hosts:
      - "host.docker.internal:host-gateway"
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
STASHEOF
    umask 022
    chmod 600 /root/.vps-bootstrap.env

    echo "### Caddy up — https://onepanel.${DOMAIN}/${PANEL_ENTRANCE} (cert issuance <60s)"
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

echo "=================================================================="
echo "### bootstrap done $(date -Is)"
echo "=================================================================="
