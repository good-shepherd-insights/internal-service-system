# Internal Service System (ISS) — plug-and-play mTLS template

A reusable system design for securing internal applications across an array of
ports and hostnames on a LAN. mTLS hard gate. mDNS discovery. step-ca as the
cert authority. Traefik as the reverse proxy / TLS terminator. A single
Hono-based enroll app issues user certs via a shared password.

The repo is a **template**: every operator-specific value comes from `.env`,
and every committed file is brand-agnostic. Fork it, brand it, deploy.

---

## Table of contents

1. [System design](#system-design)
2. [Architecture Decision Record](#architecture-decision-record-adr-003)
3. [Quickstart](#quickstart)
4. [Adding a new service](#adding-a-new-service)
5. [Adding a new user](#adding-a-new-user)
6. [Joining a second host](#joining-a-second-host)
7. [Re-enrolling a user](#re-enrolling-a-user)
8. [Revoking a user](#revoking-a-user)
9. [Backing up](#backing-up)
10. [Troubleshooting](#troubleshooting)
11. [Repo layout](#repo-layout)
12. [Caveats](#caveats)

---

## System design

The ISS treats every internal service on the LAN as a **TLS-only resource behind mTLS**. The cert authority is step-ca. The reverse proxy is Traefik. User certs are issued via a small Hono enroll app. Service certs are issued via step-ca's CLI from the operator's workstation.

**Components on the CA host:**

```
                ┌──────────────────────────────────────────────────┐
                │ CA host (e.g. `iss-fresh`)                      │
                │                                                  │
   mDNS ────►   │ avahi-daemon ─► broadcasts "iss-fresh.local"     │
                │                                                  │
                │ step-ca ─────► issues user certs and server certs │
                │               ACME for automation                │
                │               JWK (admin) for Hono enroll         │
                │                                                  │
                │ Traefik :443 ─► mTLS gate (RequireAndVerify...)   │
                │      │      ─► http://127.0.0.1:8080  (dashboard) │
                │      │      ─► http://127.0.0.1:8081  (enroll)    │
                │      │      ─► http://127.0.0.1:8082+ (more svcs) │
                │      │                                            │
                │ Hono 8081 ─► enroll app, /api/enroll issues .p12  │
                │                                                  │
                │ /etc/iss/certs/  ─► dashboard server cert          │
                │ /etc/iss/dynamic/──► Traefik caFiles (root+inter) │
                │ /etc/iss/acl.json ─► user → hostname whitelist     │
                │ /var/lib/iss/enroll/ ─► issued-name tracker        │
                └──────────────────────────────────────────────────┘
                                  │
                          mDNS / mTLS
                                  ▼
        ┌─────────────────────────────────────────────────────┐
        │  User device                                         │
        │  - browses to http://iss-fresh.local                 │
        │  - downloads .p12 from /api/enroll                   │
        │  - imports to OS keychain (empty .p12 password)      │
        │  - opens https://iss-fresh.local (or any other svc)  │
        │  - Traefik asks for client cert, OS presents .p12    │
        │  - cert SAN matches acl.json entry → access granted  │
        └─────────────────────────────────────────────────────┘
```

**Trust chain:**

```
step-ca root (self-signed)
   └─► step-ca intermediate (operator's CA_NAME)
         └─► server certs (one per host: dashboard, etc.)
         └─► user certs (one per device, SAN: <name>.local)
         └─► all bundled into .p12 files for user import
```

**The `.p12` bundle contains:**

- The leaf user cert
- The step-ca intermediate cert (so OSes that don't trust the intermediate directly can still build the chain)
- The user's private key, encrypted with `ENROLL_P12_PASSWORD` (operator-configured; Mac users type this on import)
- **No root cert in the .p12** — the root is distributed separately per host (one-time `scp` of `/etc/iss/dynamic/root_ca.crt`)

**mTLS handshake sequence:**

1. Client opens `https://iss-fresh.local`
2. Traefik presents server cert (signed by step-ca intermediate)
3. Client validates server cert against its trust store. Trust store must contain step-ca root. **First-time setup: import root CA into OS trust store.**
4. Traefik asks client for a cert (mTLS)
5. Client presents user cert from `.p12`
6. Traefik validates user cert chain against its `caFiles` (root + intermediate)
7. Traefik reads cert SAN. If `<SAN>` matches the `Host()` rule on the router, Traefik checks `acl.json` — if the user has the host in their `allowed` array, request goes to backend. Otherwise 403.

**Service discovery:**

- Same LAN: mDNS via avahi. `<CA_HOSTNAME>.local` resolves.
- Cross-VLAN: needs real DNS or a reflector. The template does not provide DNS.
- The CA host's hostname is the operator's choice (`CA_HOSTNAME=iss-fresh` etc.). Each new service gets a hostname (`grafana.iss-fresh.local`).

**Operator's call (locked at install, then immutable):**

- `CA_HOSTNAME` — the mDNS name. Pick a short, single-label name.
- `CA_NAME` — the cert subject O. Pick your real organization name.
- `CA_IP` — the CA host's LAN IP. Stable.
- `ISS_USER`, `ISS_HOME` — the operator's Linux account. Defaults to `dev`/`/home/dev`.
- `ISS_CONFIG_DIR`, `ISS_STATE_DIR` — operator-configurable paths.
- `ISS_NAME` — the brand shown in the enroll page `<title>`. Pick your short brand.
- `DASHBOARD_PORT`, `ENROLL_PORT` — operator's app ports.
- `ENROLL_HOUSEHOLD_PASSWORD` — the shared password users type at the enroll page. **Must be set.**
- `ENROLL_P12_PASSWORD` — the `.p12` install password. Mac users type this on import. **Must be set.**

**Operator's call (per-service, after install):**

- ACL entries in `/etc/iss/acl.json`
- Service cert issuance via `step ca certificate` from any box with the JWK provisioner
- Router rules in `/etc/iss/dynamic/iss.yml` (Traefik watches the dir)

**System invariants:**

- step-ca on the CA host only. Join hosts have NO step-ca.
- step-ca state at `/root/.step/` is the source of truth for revocation. **Backup it.**
- Traefik dynamic config in `/etc/iss/dynamic/` is watched live. Edit the YAML; reload is automatic.
- mTLS is a hard gate. No click-through, no opt-out, no anonymous access.
- Revocation: step-ca auto-generates CRL every 60s. Traefik picks it up. To revoke a user, delete their entry from `/etc/iss/acl.json`. (CRL alone is not enough; without an ACL entry Traefik will still 403 them but the cert is technically valid. ACL removal is the operational revoke.)
- ACL enforcement happens in the operator's backend service, not in Traefik. Traefik enforces mTLS (cert + chain); the operator's service reads `acl.json` and 403s on SAN mismatch. If you want Traefik-level ACL enforcement, deploy an ACL forward-auth middleware (separate design).

**Why this design (vs alternatives):**

| Alternative | Why we don't use it |
|------------|---------------------|
| mkcert | Local CA only. No CRL, no automation, no multi-host. |
| certbot + Let's Encrypt | Public CA. Doesn't sign internal hostnames. Doesn't issue user certs. |
| OpenVPN / WireGuard | Different threat model. Operates below TLS. Requires a client. |
| Cloud HSM (e.g. HashiCorp Vault PKI) | Heavier to operate. Needs a Vault cluster. step-ca is single-binary and works. |
| Self-signed per-service | No chain validation. Browser warnings. No CRL. |

See [ADR-003](#architecture-decision-record-adr-003) below for the full design rationale.

---

## Architecture Decision Record (ADR-003)

**Title:** Internal Service System — LAN mTLS via step-ca + Traefik + Hono enroll

**Status:** Accepted, 2026-08-18

**Context:** Internal services on the LAN (dashboard, monitoring, deploy hooks) need authenticated access. LAN is trusted. mDNS is the discovery layer. Threat model: an attacker on the LAN with a packet sniffer, OR a compromised host, OR a curious contractor with a laptop plugged into a wall port.

**Options considered:**

1. **mTLS with a private CA (step-ca).** Hard gate. Cert-based identity. Per-user, per-service certs.
2. **Basic auth + TLS.** Soft gate. Shared password. No per-user identity.
3. **WireGuard mesh.** Strong crypto, but requires a client on every device; doesn't help browsers.
4. **Authelia / oauth2-proxy in front of every service.** Heavier: requires a Redis, a session store, an IdP. Overkill for a trusted LAN.

**Decision:** Option 1 — step-ca + Traefik + Hono enroll.

**Rationale:**

- mTLS is the only auth method that gives per-user identity AND works in browsers AND has a hard gate (no click-through).
- step-ca is a single binary. No DB, no JVM, no Python interpreter. Easy to operate.
- Traefik 3.x native mTLS support via `clientAuth.caFiles`. No custom plugins.
- Hono is single-file, no build step, runs as a plain systemd unit.
- Per-user ACL in `acl.json` lets us revoke a user by editing one line, without touching step-ca or rotating CRLs.
- The cert chain validates against operator-distributed root + intermediate. No public CA involved.

**Consequences:**

- Operator must distribute root cert to every device (one-time).
- step-ca's state (`/root/.step/`) is the source of truth — back it up.
- mDNS only works on the same LAN/VLAN. Cross-VLAN needs real DNS.
- Ubuntu 26.04+ required (step-cli 0.30.x needs OpenSSL ≥ 3.5).
- Per-host bootstrap is idempotent but operator-specific paths in `.env` are locked at first install.

**Rejected consequences (acceptable losses):**

- No auto-revocation of CRL when user leaves — operator must edit acl.json. (CRL alone is not enough anyway; certs are long-lived.)
- No user-facing UI for managing ACL — operator edits a JSON file.
- No HSM protection of CA key — operator's threat model is "trusted LAN", not "nation-state attacker with root."

---

## Quickstart

```bash
git clone https://github.com/good-shepherd-insights/internal-service-system.git
cd internal-service-system
cp .env.example .env   # edit EVERY field. Required: CA_HOSTNAME, CA_NAME, CA_IP,
                       # ISS_USER, ISS_HOME, ISS_CONFIG_DIR, ISS_STATE_DIR,
                       # ISS_NAME, ENROLL_HOUSEHOLD_PASSWORD, ENROLL_P12_PASSWORD.
                       # JOIN_AS_CA=true on the CA host, false on join hosts.
                       # DASHBOARD_PORT, ENROLL_PORT have safe defaults.
bash -n bootstrap.sh   # syntax check (optional)
./bootstrap.sh         # one-shot install
```

After bootstrap:

- step-ca is running, listening on `127.0.0.1:8443`, advertising as `ca.local`
- Traefik is running on :80 and :443, mTLS-enabled
- The Hono enroll app is running on `127.0.0.1:<ENROLL_PORT>`, accessible at `http://<CA_HOSTNAME>.local`
- mDNS advertises the CA host's hostname

Verify:

```bash
curl -sf http://127.0.0.1:<ENROLL_PORT>/api/health
curl -k https://ca.local:8443/health
```

Then browse to `http://<CA_HOSTNAME>.local` from a laptop on the LAN, enter the household password, download the `.p12`, import to OS keychain, browse to `https://<CA_HOSTNAME>.local`.

**Bootstrap is idempotent.** Re-running on a configured host is safe. New variables in `.env` are picked up on the next run; existing values are not overwritten.

---

## Adding a new service

Three steps:

1. **Issue a server cert** from any host that has the `step` CLI:

   ```bash
   STEPPATH=/root/.step step ca certificate <svc>.iss-fresh.local \
     /etc/iss/certs/<svc>.iss-fresh.local.pem \
     /etc/iss/certs/<svc>.iss-fresh.local-key.pem \
     --provisioner admin \
     --san <svc>.iss-fresh.local \
     --not-after 8760h \
     --provisioner-password-file /root/.step-pw
   chmod 0644 /etc/iss/certs/<svc>*
   ```

2. **Add a Traefik router** in `/etc/iss/dynamic/<svc>.yml`:

   ```yaml
   http:
     routers:
       <svc>:
         rule: "Host(`<svc>.iss-fresh.local`)"
         service: <svc>-svc
         tls:
           options: mtls
     services:
       <svc>-svc:
         loadBalancer:
           servers:
             - url: "http://127.0.0.1:<svc_port>"
   ```

   Traefik auto-reloads when the file appears.

3. **Add the hostname to the user's ACL** in `/etc/iss/acl.json`:

   ```json
   {
     "anthony": ["iss-fresh.local", "<svc>.iss-fresh.local"]
   }
   ```

The new service is live and mTLS-gated.

---

## Adding a new user

1. Distribute the step-ca root cert (`/etc/iss/dynamic/root_ca.crt`) to the user's device. One-time. Import to OS trust store.
2. Add an entry to `/etc/iss/acl.json`:

   ```json
   {
     "anthony": ["iss-fresh.local", "grafana.iss-fresh.local"]
   }
   ```

3. Tell the user the household password. They open `http://iss-fresh.local`, type their name + the password, get a `.p12`. They import it to the OS keychain (typing `ENROLL_P12_PASSWORD` on Mac). They browse to `https://iss-fresh.local`.

---

## Joining a second host

A second host joins the mesh by trusting the CA host's cert authority and serving its own services through mTLS.

```bash
# On the second host:
git clone https://github.com/good-shepherd-insights/internal-service-system.git
cd internal-service-system
cp .env.example .env
# Edit .env: JOIN_AS_CA=false, CA_HOSTNAME=iss-fresh (the CA), CA_IP=<ca-ip>,
# ISS_* values appropriate to this host. DASHBOARD_PORT/ENROLL_PORT
# can match the CA host or differ.
./bootstrap.sh
```

What happens on a join host:

- step-ca is NOT installed (it's a CA-host-only service)
- The enroll app is NOT installed (it's a CA-host-only service)
- Traefik IS installed, with `caFiles` pointing at the root + intermediate scp'd from `${CA_IP}`
- The second host's own services can be added as in [Adding a new service](#adding-a-new-service)
- The CRL is scp'd from `${CA_IP}` (5-min cron sync) so the second host's Traefik can revoke

**SSH requirement:** join host must be able to ssh to `root@${CA_IP}` for the root cert copy and CRL sync. Set up ssh keys ahead of time.

---

## Re-enrolling a user

The user forgot their .p12 password, lost their device, or wants a fresh cert.

1. Delete the user's entry from `<ISS_STATE_DIR>/enroll/issued.json` (the
   "issued tracker"). This unblocks re-enrollment.
2. User goes to `http://<ENROLL_HOSTNAME>` (default: enroll app on the
   CA host's port — see "Adding a service" if no separate hostname is set).
3. New `.p12` is issued with the same name and a fresh keypair.

The old cert remains valid (CRL aside). To fully invalidate the old
cert, also remove the user's entry from `<ISS_CONFIG_DIR>/acl.json` and
follow "Revoking a user" below.

## Revoking a user

1. Delete or comment out the user's entry in `/etc/iss/acl.json`.

That's it. Traefik reads `acl.json` on every request. The next request from that user cert gets a 403.

**Note:** the cert itself is still valid (CRL aside). ACL removal is the operational revoke. The cert is useless without an ACL entry.

To force a CRL revoke too:

```bash
# On the CA host:
step ca revoke <cert-serial-or-subject> --ca-url https://ca.local:8443 \
  --root /root/.step/certs/root_ca.crt
```

step-ca auto-regenerates the CRL every 60s. Traefik picks it up.

---

## Backing up

**Critical state on the CA host:**

- `/root/.step/` — step-ca state, including the CA private key, the DB of issued certs, and the intermediate cert. **This is the source of truth for the entire trust chain.** Back it up. If you lose it, all issued certs become unrevocable and you must reissue every user cert.
- `/etc/iss/acl.json` — the ACL. Without it, even valid certs get 403. Back it up.
- `/etc/iss/certs/` — server certs. Recoverable by reissuing from step-ca, but easier to back up.
- `/etc/iss/dynamic/root_ca.crt`, `intermediate_ca.crt` — public, can be regenerated from step-ca, but worth backing up.
- `.env` — the operator's config. **Back this up separately; it's not in the repo.**

Recommended: nightly tarball of `/root/.step/`, `/etc/iss/`, and `.env` to an off-host location.

---

## Troubleshooting

**Bootstrap refuses to run with "OpenSSL < 3.5".**

Ubuntu 24.04 ships OpenSSL 3.0; step-cli 0.30.x needs 3.5+. The template requires Ubuntu 26.04+.

**Enroll POST returns 403 "Not approved".**

The user is not in `/etc/iss/acl.json`. Add an entry.

**Enroll POST returns 401 "Wrong password".**

`ENROLL_HOUSEHOLD_PASSWORD` in `.env` doesn't match what the user typed. Verify the env file.

**Enroll POST returns 400 "Invalid name".**

Names must match `/^[a-zA-Z0-9_-]{1,40}$/`. Tell the user to pick a different name.

**mTLS handshake fails on the user's browser.**

The OS trust store doesn't have the step-ca root cert. Import `/etc/iss/dynamic/root_ca.crt` into the OS trust store.

**Traefik returns 502.**

The backend service on `<DASHBOARD_PORT>` or `<ENROLL_PORT>` is not running. Start it.

**step-ca restart loops.**

Check `journalctl -u step-ca`. Common cause: a permissions issue on `/root/.step/`. Fix perms, restart.

**Service rename fails on second bootstrap.**

Bootstrap is idempotent. If you change `CA_HOSTNAME`, the new service file is created but the old one remains. Manually remove `/etc/systemd/system/<old-hostname>-enroll.service` if desired.

**The `.env` was committed.**

Restore from git history (`git rm --cached .env && git commit`). Rotate any passwords that were committed. Add `.env` to `.gitignore` (it should already be there).

---

## Repo layout

```text
internal-service-system/
├── bootstrap.sh                          — one-shot installer. Idempotent.
├── README.md                             — this file.
├── docs/
│   └── design.md                         — design specification (full version)
├── .env.example                          — operator config template
├── .gitignore                            — excludes .env
├── templates/
│   └── acl.json                          — user → hostname whitelist
├── scripts/
│   └── iss-enroll.js                     — Hono enroll app (example impl)
├── etc/
│   ├── avahi/
│   │   └── avahi-daemon.conf             — mDNS config; host-name appended
│   ├── systemd/system/
│   │   ├── step-ca.service               — CA daemon (CA host only)
│   │   ├── traefik.service               — Traefik systemd unit
│   │   └── iss-enroll.service            — enroll app systemd unit (CA host only)
│   └── traefik/
│       ├── traefik.yml                   — Traefik static config
│       └── dynamic/
│           └── iss.yml                   — Traefik mTLS dynamic config
```

---

## Caveats

- **Ubuntu 26.04+ required.** step-cli 0.30.x's cert verification needs OpenSSL 3.5+. Ubuntu 24.04 ships with 3.0; the bootstrap will refuse to run on older hosts. Tested on Ubuntu 26.04.
- **mDNS scope is one LAN/VLAN.** Cross-VLAN service discovery needs real DNS or a reflector.
- **The CA host's `/root/.step/` is the source of truth.** Back it up or lose revocation.
- **Bootstrap is one-shot for `.env` variables.** Changing `CA_HOSTNAME`, `CA_IP`, `CA_NAME` after install is risky — issued certs reference the old values. The script does not migrate.
- **The Hono enroll app is an example.** Operators replace `scripts/iss-enroll.js` with their own auth flow if needed. The contract: `POST /api/enroll` with `{name, password}` returns a `.p12` file.
- **Per-user cert SANs use `<name>.local`.** Two users with names like `john` and `john-2` both get distinct SANs. Sanitization strips characters that conflict with mDNS.
- **step-ca's JWK provisioner requires `STEPPATH=/root/.step` in the env.** Bootstrap sets this in the drop-in.
