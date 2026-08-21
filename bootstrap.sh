#!/usr/bin/env bash
# Internal Service System — one-shot bootstrap.
# Idempotent. Re-running on a configured host is safe.
#
# Variables come from .env (see .env.example):
#   CA_HOSTNAME         - mDNS hostname of the CA host (avahi host-name)
#   CA_NAME             - CA cert subject O (Organization)
#   CA_IP               - CA host's LAN IP
#   JOIN_AS_CA          - true on CA host, false on join hosts
#   ENROLL_HOUSEHOLD_PASSWORD - shared password for the enroll page
#   ENROLL_P12_PASSWORD  - .p12 install password
#   ISS_USER            - Linux user the app runs as
#   ISS_HOME            - Linux user's home dir
#   ISS_CONFIG_DIR      - config dir (default /etc/iss)
#   ISS_STATE_DIR       - runtime state dir (default /var/lib/iss)

set -euo pipefail
trap 'echo "BOOTSTRAP FAILED at line $LINENO" >&2' ERR

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
[ -f "$REPO_ROOT/.env" ] || { echo "FATAL: .env not found at $REPO_ROOT/.env" >&2; exit 1; }
source "$REPO_ROOT/.env"

: "${CA_HOSTNAME:?must be set}"
: "${CA_NAME:?must be set}"
: "${CA_IP:?must be set}"
: "${ENROLL_HOUSEHOLD_PASSWORD:?must be set}"
: "${ENROLL_P12_PASSWORD:?must be set}"
: "${JOIN_AS_CA:=true}"
: "${DASHBOARD_PORT:=8080}"
: "${ENROLL_PORT:=8081}"
: "${ISS_USER:=dev}"
: "${ISS_HOME:=/home/dev}"
: "${ISS_CONFIG_DIR:=/etc/iss}"
: "${ISS_STATE_DIR:=/var/lib/iss}"
: "${ISS_NAME:=ISS}"

# step-cli 0.30.x requires OpenSSL >= 3.5 for chain validation. Older
# OpenSSL (e.g. Ubuntu 24.04 ships 3.0) causes cert verify failures.
_OPENSSL_VERSION=$(openssl version | awk '{print $2}')
_OPENSSL_MAJOR=$(echo "$_OPENSSL_VERSION" | cut -d. -f1)
_OPENSSL_MINOR=$(echo "$_OPENSSL_VERSION" | cut -d. -f2)
if [[ "$_OPENSSL_MAJOR" -lt 3 || ("$_OPENSSL_MAJOR" -eq 3 && "$_OPENSSL_MINOR" -lt 5) ]]; then
  echo "FATAL: OpenSSL $_OPENSSL_VERSION is too old. step-cli 0.30.x needs >= 3.5." >&2
  echo "Use Ubuntu 26.04 or newer, or install OpenSSL 3.5+ from source." >&2
  exit 1
fi

# Validate CA_HOSTNAME: single label, lowercase, digits, hyphens.
if [[ ! "$CA_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "FATAL: CA_HOSTNAME must be a single label (lowercase, digits, hyphens; no leading/trailing hyphen)." >&2
  exit 1
fi

IS_CA_HOST=false
if [[ "$JOIN_AS_CA" == "true" && "$CA_HOSTNAME" == "$(hostname -s)" ]]; then
  IS_CA_HOST=true
fi

ISS_SCRIPTS_DIR="$ISS_HOME/.local/share/iss/scripts"
ENROLL_BASENAME="enroll.js"

# Package installs.
if ! dpkg -l nodejs 2>/dev/null | grep -q "^ii"; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y nodejs
fi

# Install the enroll app's npm dependencies once.
mkdir -p "$ISS_HOME/.local/share/iss/npm"
cat > "$ISS_HOME/.local/share/iss/npm/package.json" <<'EOF'
{
  "name": "iss-enroll",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "dependencies": {
    "hono": "^4.0.0",
    "@hono/node-server": "^1.0.0"
  }
}
EOF
cd "$ISS_HOME/.local/share/iss/npm"
npm install --silent --no-audit --no-fund

if ! command -v step >/dev/null 2>&1; then
  STEP_CLI_VERSION=0.30.6
  STEP_CA_VERSION=0.30.2
  cd /tmp
  wget -q "https://github.com/smallstep/cli/releases/download/v${STEP_CLI_VERSION}/step-cli_${STEP_CLI_VERSION}-1_amd64.deb"
  wget -q "https://github.com/smallstep/certificates/releases/download/v${STEP_CA_VERSION}/step-ca_${STEP_CA_VERSION}-1_amd64.deb"
  # Verify downloads look like valid .deb files (DPKG magic = "!<arch>\n").
  for deb in /tmp/step-cli_${STEP_CLI_VERSION}-1_amd64.deb /tmp/step-ca_${STEP_CA_VERSION}-1_amd64.deb; do
    if ! head -c 7 "$deb" | grep -q '^!<arch>'; then
      echo "ERROR: $deb is not a valid .deb (release URL/version mismatch?)" >&2
      exit 1
    fi
  done
  apt-get install -y "./step-cli_${STEP_CLI_VERSION}-1_amd64.deb" "./step-ca_${STEP_CA_VERSION}-1_amd64.deb"
  rm -f /tmp/step-cli-*.deb /tmp/step-ca-*.deb
fi

if [[ ! -x /usr/local/bin/traefik ]]; then
  TRAEFIK_VERSION=3.6.25
  cd /tmp
  wget -q -O /tmp/traefik.tar.gz "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz"
  # Verify it's actually a gzip archive (magic bytes 1f 8b).
  if [[ "$(head -c 2 /tmp/traefik.tar.gz | od -An -tx1 | tr -d ' ')" != "1f8b" ]]; then
    echo "ERROR: traefik download is not a valid gzip archive (release URL/version mismatch?)" >&2
    exit 1
  fi
  tar -xzf /tmp/traefik.tar.gz -C /tmp traefik
  install -m 0755 /tmp/traefik /usr/local/bin/traefik
  rm -f /tmp/traefik /tmp/traefik.tar.gz
fi

apt-get install -y avahi-daemon avahi-utils curl wget ca-certificates gnupg

# Ensure operator user exists.
if ! id -u "$ISS_USER" >/dev/null 2>&1; then
  useradd -m -d "$ISS_HOME" "$ISS_USER"
fi

# Ensure home dir exists even if user existed but home was deleted.
install -d -o "$ISS_USER" -g "$ISS_USER" "$ISS_HOME"

mkdir -p "$ISS_CONFIG_DIR/certs" "$ISS_CONFIG_DIR/dynamic"
mkdir -p /etc/traefik              # Traefik config dir (system location)
mkdir -p "$ISS_HOME/.local/share/iss/scripts"
mkdir -p "$ISS_STATE_DIR/enroll"

# Avahi host-name from CA_HOSTNAME. The committed config has no host-name=
# line; bootstrap appends it under [server]. Only on CA host — join hosts
# publish their own hostname via avahi-publish-address unit.
if $IS_CA_HOST; then
  if ! grep -q "^host-name=" /etc/avahi/avahi-daemon.conf; then
    sed -i "/^\[server\]/a host-name=${CA_HOSTNAME}" /etc/avahi/avahi-daemon.conf
  else
    sed -i "s|^host-name=.*|host-name=${CA_HOSTNAME}|" /etc/avahi/avahi-daemon.conf
  fi
fi

if $IS_CA_HOST; then
  if [[ ! -f /root/.step/config/ca.json ]]; then
    openssl rand -base64 32 > /root/.step-pw
    chmod 0600 /root/.step-pw
    STEPPATH=/root/.step /usr/bin/step ca init --name="${CA_NAME}" \
      --dns="ca.local,localhost,127.0.0.1,${CA_IP}" \
      --address="127.0.0.1:8443" \
      --provisioner="admin" \
      --password-file=/root/.step-pw
  fi

  # Patch ca.json to enable CRL export and longer default durations.
  python3 - <<PYEOF
import json
p='/root/.step/config/ca.json'
d=json.load(open(p))
d['crl']={'enabled':True,'path':'/root/.step/crl.pem'}
a=d.setdefault('authority',{})
c=a.setdefault('claims',{})
c['maxTLSCertDuration']='8760h0m0s'
c['defaultTLSCertDuration']='8760h0m0s'
json.dump(d, open(p,'w'), indent=2)
PYEOF

  if ! grep -qE "[[:space:]]ca\.local([[:space:]]|$)" /etc/hosts; then
    echo "127.0.0.1 ca.local" >> /etc/hosts
  fi

  # Install step-ca unit and start the daemon.
  install -m 0644 "$REPO_ROOT/etc/systemd/system/step-ca.service" /etc/systemd/system/step-ca.service
  systemctl daemon-reload
  systemctl enable --now step-ca

  for _ in $(seq 1 30); do
    if curl --max-time 3 --connect-timeout 3 -ksf https://ca.local:8443/health >/dev/null 2>&1; then break; fi
    sleep 1
  done

  # Add ACME provisioner (idempotent — silently skip if already exists).
  if ! STEPPATH=/root/.step /usr/bin/step ca provisioner list 2>/dev/null | grep -q '^acme'; then
    STEPPATH=/root/.step /usr/bin/step ca provisioner add acme --type ACME \
      --ca-url https://ca.local:8443 --root /root/.step/certs/root_ca.crt \
      --password-file /root/.step-pw || {
        echo "WARNING: ACME provisioner setup failed" >&2
      }
  fi

  # Issue the CA host's server cert (skip if both cert+key already issued).
  if [[ ! -f "$ISS_CONFIG_DIR/certs/${CA_HOSTNAME}.local.pem" \
     || ! -f "$ISS_CONFIG_DIR/certs/${CA_HOSTNAME}.local-key.pem" ]]; then
    STEPPATH=/root/.step /usr/bin/step ca certificate "${CA_HOSTNAME}.local" \
      "$ISS_CONFIG_DIR/certs/${CA_HOSTNAME}.local.pem" \
      "$ISS_CONFIG_DIR/certs/${CA_HOSTNAME}.local-key.pem" \
      --provisioner admin --provisioner-password-file /root/.step-pw \
      --san "${CA_HOSTNAME}.local" --san "${CA_IP}" --not-after 2160h --force
  fi

  cp /root/.step/certs/root_ca.crt "$ISS_CONFIG_DIR/dynamic/root_ca.crt"
  cp /root/.step/certs/intermediate_ca.crt "$ISS_CONFIG_DIR/dynamic/intermediate_ca.crt"
fi

# Traefik configs (used on both CA and join hosts).
install -m 0644 "$REPO_ROOT/etc/traefik/traefik.yml" /etc/traefik/traefik.yml
install -m 0644 "$REPO_ROOT/etc/traefik/dynamic/iss.yml" "$ISS_CONFIG_DIR/dynamic/iss.yml"

# Substitute placeholders in Traefik static config.
sed -i -e "s|<ISS_CONFIG_DIR>|${ISS_CONFIG_DIR}|g" /etc/traefik/traefik.yml

# Substitute placeholders in the dynamic config.
sed -i \
  -e "s|<CA_HOSTNAME>|${CA_HOSTNAME}|g" \
  -e "s|<DASHBOARD_PORT>|${DASHBOARD_PORT}|g" \
  -e "s|<ENROLL_PORT>|${ENROLL_PORT}|g" \
  -e "s|<HOME_DIR>|${ISS_HOME}|g" \
  -e "s|<ISS_CONFIG_DIR>|${ISS_CONFIG_DIR}|g" \
  -e "s|<ISS_HOME>|${ISS_HOME}|g" \
  "$ISS_CONFIG_DIR/dynamic/iss.yml"

# Optional separate-hostname enroll router (only if ENROLL_HOSTNAME set).
if [[ -n "${ENROLL_HOSTNAME:-}" ]]; then
  cat > "$ISS_CONFIG_DIR/dynamic/enroll.yml" <<EOF
http:
  routers:
    enroll:
      rule: "Host(\`${ENROLL_HOSTNAME}\`)"
      entryPoints: [web]
      service: enroll-svc
  services:
    enroll-svc:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:${ENROLL_PORT}"
EOF
fi

if ! $IS_CA_HOST; then
  if [[ ! -f "$ISS_CONFIG_DIR/dynamic/root_ca.crt" ]]; then
    scp "root@${CA_IP}:/root/.step/certs/root_ca.crt" "$ISS_CONFIG_DIR/dynamic/root_ca.crt"
    scp "root@${CA_IP}:/root/.step/certs/intermediate_ca.crt" "$ISS_CONFIG_DIR/dynamic/intermediate_ca.crt"
  fi
fi

# Traefik unit (uses operator paths).
cat > /etc/systemd/system/traefik.service <<EOF
[Unit]
Description=Traefik reverse proxy (Internal Service System)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml --providers.file.directory=${ISS_CONFIG_DIR}/dynamic
Restart=on-failure
RestartSec=3
LimitNOFILE=8192
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

if $IS_CA_HOST; then
  # Install the enroll app script alongside node_modules.
  install -m 0755 "$REPO_ROOT/scripts/iss-enroll.js" "$ISS_HOME/.local/share/iss/npm/${CA_HOSTNAME}-enroll.js"

  # Render systemd unit from template.
  ENROLL_RENDERED=$(mktemp)
  sed \
    -e "s|<CA_HOSTNAME>|${CA_HOSTNAME}|g" \
    -e "s|<ISS_HOME>|${ISS_HOME}|g" \
    -e "s|<ISS_USER>|${ISS_USER}|g" \
    -e "s|<HOME_DIR>|${ISS_HOME}|g" \
    -e "s|<ENROLL_PORT>|${ENROLL_PORT}|g" \
    -e "s|<ISS_NAME>|${ISS_NAME}|g" \
    -e "s|<ISS_SCRIPTS_DIR>|${ISS_HOME}/.local/share/iss/npm|g" \
    "$REPO_ROOT/etc/systemd/system/iss-enroll.service" > "$ENROLL_RENDERED"
  install -m 0644 "$ENROLL_RENDERED" "/etc/systemd/system/${CA_HOSTNAME}-enroll.service"
  rm -f "$ENROLL_RENDERED"

  # Drop-in with secrets and runtime paths.
  mkdir -p "/etc/systemd/system/${CA_HOSTNAME}-enroll.service.d"
  cat > "/etc/systemd/system/${CA_HOSTNAME}-enroll.service.d/env.conf" <<EOF
[Service]
Environment=STEPPATH=/root/.step
Environment=STEPPATH_FILE=/root/.step-pw
Environment=ISS_STATE_DIR=${ISS_STATE_DIR}
Environment=ISS_CONFIG_DIR=${ISS_CONFIG_DIR}
Environment=CA_HOSTNAME=${CA_HOSTNAME}
Environment=CA_IP=${CA_IP}
Environment=CA_NAME=${CA_NAME}
Environment=ISS_NAME=${ISS_NAME}
Environment=ENROLL_PORT=${ENROLL_PORT}
EnvironmentFile=-${ISS_CONFIG_DIR}/enroll-secrets.env
EOF
  install -m 0600 /dev/null "${ISS_CONFIG_DIR}/enroll-secrets.env"
  chmod 0600 "${ISS_CONFIG_DIR}/enroll-secrets.env"
  cat > "${ISS_CONFIG_DIR}/enroll-secrets.env" <<EOF
ENROLL_HOUSEHOLD_PASSWORD=${ENROLL_HOUSEHOLD_PASSWORD}
ENROLL_P12_PASSWORD=${ENROLL_P12_PASSWORD}
EOF

  # Install acl.json template if missing.
  if [[ ! -f "$ISS_CONFIG_DIR/acl.json" ]]; then
    install -m 0644 "$REPO_ROOT/templates/acl.json" "$ISS_CONFIG_DIR/acl.json"
    sed -i "s|<CA_HOSTNAME>|${CA_HOSTNAME}|g" "$ISS_CONFIG_DIR/acl.json"
  fi

  # Write trailing service enable at the end (after units installed).
  :
fi

systemctl daemon-reload

if $IS_CA_HOST; then
  systemctl enable --now avahi-daemon
  systemctl enable --now "${CA_HOSTNAME}-enroll"
  systemctl enable --now traefik
else
  systemctl enable --now avahi-daemon
  systemctl enable --now traefik
fi

sleep 2
echo
echo "=== Service status ==="
for svc in traefik avahi-daemon; do
  systemctl --no-pager --full status "$svc" 2>&1 | head -3 || true
  echo "---"
done
if $IS_CA_HOST; then
  for svc in step-ca "${CA_HOSTNAME}-enroll"; do
    systemctl --no-pager --full status "$svc" 2>&1 | head -3 || true
    echo "---"
  done
fi

echo
echo "=== Verification ==="
if curl --max-time 3 --connect-timeout 3 -ksf https://ca.local:8443/health >/dev/null 2>&1; then
  echo "step-ca: OK"
else
  echo "step-ca: FAIL"
fi
if $IS_CA_HOST; then
  if curl -sf "http://127.0.0.1:${ENROLL_PORT}/api/health" >/dev/null 2>&1; then
    echo "enroll: OK"
  else
    echo "enroll: FAIL"
  fi
fi

echo
echo "Bootstrap complete."
