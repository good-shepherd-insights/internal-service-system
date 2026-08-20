---
name: iss-deploy
description: Deploy the Internal Service System (ISS) plug-and-play mTLS template onto a fresh Ubuntu host. Triggers when an operator asks to install, deploy, bootstrap, or set up the LAN mTLS stack from this repo.
---

# ISS Deploy

This skill deploys the Internal Service System (ISS) plug-and-play mTLS template onto a fresh Ubuntu host. The template provides step-ca as the cert authority, Traefik as the mTLS gate, and a Hono enroll app for issuing user certs via a shared password.

## When to use

The operator says one of:
- "Deploy ISS"
- "Install the LAN mTLS template"
- "Set up the cert authority from this repo"
- "Bootstrap internal-service-system"
- "Run the ISS bootstrap"

The repo path is `/home/dev/internal-service-system` by default. If the operator gives a different path, use that.

## Prerequisites

- Ubuntu 26.04 or later. step-cli 0.30.x requires OpenSSL ≥ 3.5. Ubuntu 24.04 ships OpenSSL 3.0; bootstrap refuses to run.
- The repo is already cloned.
- The operator has filled in `.env`. See [Step 1](#step-1-validate-env).

If the repo is not at `/home/dev/internal-service-system`, ask the operator for the path.

## Variables

Read these from `.env`:
- `CA_HOSTNAME` — single-label hostname. Used as `<CA_HOSTNAME>.local` on the LAN.
- `CA_NAME` — the cert subject O (organization). Shows up in every issued cert.
- `CA_IP` — the CA host's LAN IP. Stable. Used in cert SANs.
- `JOIN_AS_CA` — `true` on the CA host, `false` on every join host.
- `ISS_USER` — operator's Linux account. Default `dev`.
- `ISS_HOME` — operator's home dir. Default `/home/dev`.
- `ISS_CONFIG_DIR` — config root. Default `/etc/iss`.
- `ISS_STATE_DIR` — runtime state root. Default `/var/lib/iss`.
- `ISS_NAME` — short brand shown in the enroll page `<title>`.
- `DASHBOARD_PORT` — backend port. Default `8080`.
- `ENROLL_PORT` — Hono enroll app port. Default `8081`.
- `ENROLL_HOUSEHOLD_PASSWORD` — shared password users type at the enroll page. Required.
- `ENROLL_P12_PASSWORD` — the `.p12` install password. Mac users type this on import. Required.

## Step 1: Validate `.env`

`bootstrap.sh` will refuse to run if any required var is empty or matches `REPLACE_ME`. Confirm before running.

```bash
cd /home/dev/internal-service-system

# Make validated values available to later commands.
set -a
source .env
set +a

required=(CA_HOSTNAME CA_NAME CA_IP JOIN_AS_CA ISS_USER ISS_HOME \
          ISS_CONFIG_DIR ISS_STATE_DIR ISS_NAME \
          ENROLL_HOUSEHOLD_PASSWORD ENROLL_P12_PASSWORD)

missing=()
for v in "${required[@]}"; do
  val=$(grep -E "^${v}=" .env | head -1 | cut -d= -f2-)
  if [[ -z "$val" || "$val" == *"REPLACE_ME"* ]]; then
    missing+=("$v")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing or placeholder values in .env:"
  printf '  %s\n' "${missing[@]}"
  echo "Edit .env and fill in real values."
  exit 1
fi
```

If anything is missing, **stop and ask the operator** which value to use. Do not guess.

## Step 2: Install validation deps + syntax check

```bash
# Validation tools.
command -v bash >/dev/null || { echo "bash missing"; exit 1; }
command -v node >/dev/null || apt-get install -y nodejs
command -v python3 >/dev/null || apt-get install -y python3
python3 -c "import yaml" 2>/dev/null || apt-get install -y python3-yaml

# Syntax checks (all must exit 0).
bash -n bootstrap.sh
node --check scripts/iss-enroll.js
python3 -c "import yaml; yaml.safe_load(open('etc/traefik/dynamic/iss.yml'))"
```

All three must exit 0. If any fails, **stop and report the error**.

## Step 3: Run bootstrap

```bash
set -o pipefail
sudo ./bootstrap.sh 2>&1 | tee /tmp/iss-bootstrap.log
rc=${PIPESTATUS[0]}
exit $rc
```

`PIPESTATUS[0]` preserves the bootstrap's exit status so the agent can
react to failures instead of silently getting `tee`'s 0.

The script is idempotent. Re-running on a configured host is safe. New vars in `.env` are picked up on the next run; existing values are not overwritten.

The script will:

- Refuse to run on OpenSSL < 3.5 (Ubuntu 24.04 and older).
- Install `avahi-daemon`, `avahi-utils`, `nodejs`, `step-cli`, `step-ca`, Traefik 3.6.25.
- `step ca init` if `/root/.step/config/ca.json` does not exist. The CA name comes from `.env:CA_NAME`.
- Configure step-ca: **8760h CA cert** (step-cli default), **2160h user/server certs** (explicit `--not-after 2160h`), CRL enabled, ACME provisioner `acme`.
- Issue a server cert for `<CA_HOSTNAME>.local`.
- Render the systemd unit for the enroll app from the template `etc/systemd/system/iss-enroll.service`. Placeholders substituted: `<ISS_NAME>`, `<ISS_USER>`, `<ISS_HOME>`, `<ISS_CONFIG_DIR>`, `<CA_HOSTNAME>`, `<ENROLL_PORT>`.
- Render the Traefik dynamic config from `etc/traefik/dynamic/iss.yml`. Placeholders substituted: `<ISS_CONFIG_DIR>`, `<CA_HOSTNAME>`, `<DASHBOARD_PORT>`, `<ENROLL_PORT>`.
- Enable and start: `step-ca`, `traefik`, `avahi-daemon`, `<CA_HOSTNAME>-enroll` (CA host only).

If the script exits non-zero, **stop and read `/tmp/iss-bootstrap.log`** to find the failure line.

## Step 4: Verify

```bash
# step-ca health
curl -kfs https://127.0.0.1:8443/health

# Traefik dashboard (informational)
curl -s http://127.0.0.1:8082/api/overview | head -5

# Enroll page serves
curl -sf http://127.0.0.1:${ENROLL_PORT}/api/health

# mTLS handshake (expect HTTP 502 — backend not running, but TLS layer accepts)
curl --cacert /etc/${ISS_CONFIG_DIR##*/}/dynamic/root_ca.crt \
     --cert /tmp/mtls-cert.pem --key /tmp/mtls-key.pem \
     --resolve ${CA_HOSTNAME}.local:443:127.0.0.1 \
     https://${CA_HOSTNAME}.local/ -o /dev/null -w "HTTP %{http_code}\n"
```

The first three must return 200. The fourth returns 502 because no dashboard backend exists on the test host. mTLS handshake succeeded if you reach the backend layer at all.

## Step 5: First user

Before any device can connect, the operator needs to add an ACL entry:

```bash
# Edit ${ISS_CONFIG_DIR}/acl.json (operator's choice — defaults to /etc/iss/acl.json)
cat > "${ISS_CONFIG_DIR}/acl.json" <<EOF
{
  "anthony": ["<CA_HOSTNAME>.local"]
}
EOF
```

Then distribute the root cert to the user's device:

```bash
# Transfer root cert to the user's machine first, then:
# Mac: double-click ${ISS_CONFIG_DIR}/dynamic/root_ca.crt, add to System keychain
# Linux: sudo cp /root/iss-config/dynamic/root_ca.crt /usr/local/share/ca-certificates/iss-root.crt && sudo update-ca-certificates
# Windows: import to Trusted Root Certification Authorities
```

The user opens `http://<ENROLL_HOSTNAME>` (default: enroll app on the CA
host's port — operators can set `ENROLL_HOSTNAME=enroll.local` in `.env`
to get a dedicated hostname). They type their name + the household
password from `.env:ENROLL_HOUSEHOLD_PASSWORD`, get a `.p12`. They
import the `.p12` to their OS keychain (typing `.env:ENROLL_P12_PASSWORD`
on Mac). They browse to `https://<CA_HOSTNAME>.local`.

## Pitfalls

- **OpenSSL version:** bootstrap refuses on Ubuntu 24.04. Tell the operator upfront if they're on 24.04.
- **CA host vs join host:** `JOIN_AS_CA=true` runs `step ca init`, starts step-ca + enroll app. `JOIN_AS_CA=false` skips both and scps root + intermediate from `${CA_IP}`. SSH access to `root@${CA_IP}` required for join hosts.
- **mDNS scope:** `<CA_HOSTNAME>.local` only resolves on the same LAN/VLAN. Cross-VLAN needs real DNS or a reflector.
- **step-ca state:** `/root/.step/` is the source of truth. Back it up. Losing it makes issued certs unrevocable.
- **Bootstrap immutability:** changing `CA_HOSTNAME`, `CA_IP`, or `CA_NAME` after install is risky. Issued certs reference the old values.
- **`.env` is gitignored but contains real passwords.** Don't display it in chat. Don't commit it.

## What the operator wants to know

- The mTLS-gated dashboard is at `https://<CA_HOSTNAME>.local`.
- The enroll app listens on `127.0.0.1:<ENROLL_PORT>` but is not routed by the template's Traefik config. Operators add their own router in `iss.yml` (see "Adding a service") or expose it directly on a separate hostname.
- The user-visible enroll page says whatever `ISS_NAME` is in `.env`. Pick a short brand.
- The cert issuer's O is `CA_NAME`. Operator picks the legal name (e.g. their LLC).
- The mDNS hostname is `<CA_HOSTNAME>.local`. Operator picks a single label.

## Verification

Subagent audit checklist (12 items, all must be PASS). Slop strings intentionally not echoed here; the grep below uses quoted shell arguments so the audit grep returns no matches on `SKILL.md` itself.

```
[1]  No first brand string (lowercase or uppercase)
[2]  No second brand phrase
[3]  No live-system IP literal
[4]  No live-system ports outside .env.example defaults
[5]  No live-system path constants
[6]  Page <title> uses ${ISS_NAME}, not literal brand
[7]  All <CA_*> and <ISS_*> are bootstrap sed targets
[8]  .env not tracked in git
[9]  bash -n bootstrap.sh OK
[10] node --check scripts/iss-enroll.js OK
[11] yaml.safe_load OK on etc/traefik/dynamic/iss.yml
[12] bootstrap idempotent guards present
```

Grep commands (substitute the literal slop strings from the audit checklist):
