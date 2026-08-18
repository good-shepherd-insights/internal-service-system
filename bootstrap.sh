#!/usr/bin/env bash
# Internal Service System — one-shot bootstrap.
# Idempotent. Re-running on a configured host is safe.
#
# Variables come from .env (see .env.example):
#   CA_HOSTNAME   - mDNS hostname of the CA host (also daemons's host-name)
#   CA_NAME       - CA cert subject O
#   CA_IP         - CA host's LAN IP
#   JOIN_AS_CA    - true on CA host, false on join hosts
#   HERMES_HOUSEHOLD_PASSWORD - shared password for the enroll page
#   HERMES_P12_PASSWORD - .p12 install password

set -euo pipefail
trap 'echo "BOOTSTRAP FAILED at line $LINENO" >&2' ERR

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "FATAL: .env not found. Run: cp .env.example .env and fill in values." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"

: "${CA_HOSTNAME:?must be set}"
: "${CA_NAME:?must be set}"
: "${CA_IP:?must be set}"
: "${HERMES_HOUSEHOLD_PASSWORD:?must be set}"
: "${HERMES_P12_PASSWORD:?must be set}"
: "${JOIN_AS_CA:=true}"

IS_CA_HOST=false
if [[ "$JOIN_AS_CA" == "true" && "$CA_HOSTNAME" == "$(hostname -s)" ]]; then
  IS_CA_HOST=true
fi

apt-get update -y
apt-get install -y avahi-daemon avahi-utils curl wget ca-certificates gnupg

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

if ! command -v step >/dev/null 2>&1; then
  STEP_CLI_VERSION=0.30.6
  STEP_CA_VERSION=0.30.2
  cd /tmp
  wget -q "https://github.com/smallstep/cli/releases/download/v${STEP_CLI_VERSION}/step-cli_${STEP_CLI_VERSION}_amd64.deb"
  wget -q "https://github.com/smallstep/certificates/releases/download/v${STEP_CA_VERSION}/step-ca_${STEP_CA_VERSION}_amd64.deb"
  apt-get install -y "./step-cli_${STEP_CLI_VERSION}_amd64.deb" "./step-ca_${STEP_CA_VERSION}_amd64.deb"
  rm -f /tmp/step-cli_*.deb /tmp/step-ca_*.deb
fi

if [[ ! -x /usr/local/bin/traefik ]]; then
  TRAEFIK_VERSION=3.6.25
  wget -q -O /tmp/traefik.tar.gz "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz"
  tar -xzf /tmp/traefik.tar.gz -C /tmp traefik
  install -m 0755 /tmp/traefik /usr/local/bin/traefik
  rm -f /tmp/traefik /tmp/traefik.tar.gz
fi

mkdir -p /root/.step
mkdir -p /etc/traefik/dynamic
mkdir -p /etc/traefik/certs
mkdir -p /etc/hermes
mkdir -p /home/dev/.hermes/scripts
mkdir -p /home/dev/certs
mkdir -p /var/lib/hermes-enroll

# Set the host's avahi name from CA_HOSTNAME so it broadcasts as <CA_HOSTNAME>.local.
sed -i "s|^host-name=.*|host-name=${CA_HOSTNAME}|" /etc/avahi/avahi-daemon.conf 2>/dev/null || true

if $IS_CA_HOST; then
  if [[ ! -f /root/.step/config/ca.json ]]; then
    openssl rand -base64 32 > /root/.step-pw
    chmod 0600 /root/.step-pw
    STEPPATH=/root/.step /usr/bin/step ca init --name="${CA_NAME}" \
      --dns="ca.local,localhost,127.0.0.1,${CA_IP}" \
      --address="127.0.0.1:8443" \
      --provisioner="admin" \
      --password-file=/root/.step-pw
    python3 -c "
import json
p='/root/.step/config/ca.json'
d=json.load(open(p))
d['crl']={'enabled':True,'path':'/root/.step/crl.pem'}
d['authority']['claims']=d.get('authority',{}).get('claims',{})
d['authority']['claims']['maxTLSCertDuration']='8760h0m0s'
d['authority']['claims']['defaultTLSCertDuration']='8760h0m0s'
json.dump(d, open(p,'w'), indent=2)
"
    STEPPATH=/root/.step /usr/bin/step ca provisioner add acme --type ACME \
      --ca-url https://ca.local:8443 --root /root/.step/certs/root_ca.crt \
      --password-file /root/.step-pw
    grep -q "^ca.local" /etc/hosts || echo "127.0.0.1 ca.local" >> /etc/hosts
  fi

  DASHBOARD_HOSTNAME="${CA_HOSTNAME}.local"
  STEPPATH=/root/.step /usr/bin/step ca certificate "${DASHBOARD_HOSTNAME}" \
    /etc/traefik/certs/${CA_HOSTNAME}.local.pem \
    /etc/traefik/certs/${CA_HOSTNAME}.local-key.pem \
    --provisioner admin \
    --provisioner-password-file /root/.step-pw \
    --san "${DASHBOARD_HOSTNAME}" --san "${CA_IP}" --not-after 2160h
  cp /root/.step/certs/root_ca.crt /etc/traefik/dynamic/root_ca.crt
  cp /root/.step/certs/intermediate_ca.crt /etc/traefik/dynamic/intermediate_ca.crt

  # Substitute CA_HOSTNAME placeholder into the committed configs.
  sed -i "s|<CA_HOSTNAME>|${CA_HOSTNAME}|g; s|<CA_IP>|${CA_IP}|g" \
    /etc/traefik/dynamic/hermes.yml /etc/traefik/traefik.yml \
    /etc/systemd/system/hermes-enroll.service /etc/systemd/system/hermes-dashboard.service \
    /etc/systemd/system/step-ca.service || true
  mv /etc/systemd/system/hermes-enroll.service "/etc/systemd/system/${CA_HOSTNAME}-enroll.service" 2>/dev/null || true
  mv /etc/systemd/system/hermes-dashboard.service "/etc/systemd/system/${CA_HOSTNAME}-dashboard.service" 2>/dev/null || true
fi

if ! $IS_CA_HOST; then
  if [[ ! -f /etc/traefik/dynamic/root_ca.crt ]]; then
    scp "dev@${CA_HOSTNAME}.local:/root/.step/certs/root_ca.crt" /etc/traefik/dynamic/root_ca.crt
    scp "dev@${CA_HOSTNAME}.local:/root/.step/certs/intermediate_ca.crt" /etc/traefik/dynamic/intermediate_ca.crt
  fi

  sed -i "s|<CA_HOSTNAME>|${CA_HOSTNAME}|g; s|<CA_IP>|${CA_IP}|g" \
    /etc/traefik/dynamic/hermes.yml /etc/traefik/traefik.yml || true
fi

if [[ ! -f /etc/hermes/acl.json ]]; then
  install -m 0644 "$REPO_ROOT/templates/acl.json" /etc/hermes/acl.json
  sed -i "s|<CA_HOSTNAME>|${CA_HOSTNAME}|g" /etc/hermes/acl.json || true
fi

if [[ ! -f /home/dev/.hermes/scripts/hermes-enroll.js ]]; then
  install -m 0755 "$REPO_ROOT/scripts/hermes-enroll.js" /home/dev/.hermes/scripts/hermes-enroll.js
fi

if [[ ! -d /home/dev/.hermes/scripts/node_modules ]]; then
  cd /home/dev/.hermes/scripts
  npm init -y >/dev/null 2>&1
  npm install hono @hono/node-server >/dev/null 2>&1
fi

cat > /etc/systemd/system/${CA_HOSTNAME}-enroll.service.d/env.conf <<EOF
[Service]
Environment=STEPPATH=/root/.step
Environment=HERMES_HOUSEHOLD_PASSWORD=${HERMES_HOUSEHOLD_PASSWORD}
Environment=HERMES_P12_PASSWORD=${HERMES_P12_PASSWORD}
EOF

systemctl daemon-reload

if $IS_CA_HOST; then
  systemctl enable --now step-ca
  systemctl enable --now avahi-daemon
  systemctl enable --now "${CA_HOSTNAME}-dashboard"
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
  for svc in step-ca "${CA_HOSTNAME}-dashboard" "${CA_HOSTNAME}-enroll"; do
    systemctl --no-pager --full status "$svc" 2>&1 | head -3 || true
    echo "---"
  done
fi

echo
echo "=== Verification ==="
curl -ksf https://ca.local:8443/health >/dev/null && echo "step-ca: OK" || echo "step-ca: FAIL"
curl -sf http://127.0.0.1:9120/api/health >/dev/null && echo "enroll: OK" || echo "enroll: FAIL"
curl -k --cacert /etc/traefik/dynamic/root_ca.crt -sf https://${CA_HOSTNAME}.local/api/status >/dev/null && echo "${CA_HOSTNAME}.local (no client cert): unexpectedly OK" || echo "${CA_HOSTNAME}.local: rejects without client cert (expected)"

echo
echo "Bootstrap complete."
