# Internal Service System (ISS) — plug-and-play mTLS template

A reusable system design for securing internal applications across an array
of ports and hostnames on a LAN. mTLS hard gate. mDNS discovery. Per-service
server certs. Per-user client certs. Per-user ACL. No click-throughs. No
public exposure.

This is a **template**, not a product. Operators clone, set `.env`, run
`bootstrap.sh`, and ship a working mesh.

## What's locked (the design)

The architecture is fixed:

- **step-ca** issues all certs. One CA per mesh.
- **Traefik** is the mTLS gate. Every `websecure` router demands a client
  cert signed by the CA.
- **avahi** broadcasts hostnames via mDNS.
- **The enroll app** runs the user-facing enrollment endpoint on plain HTTP.
  Hono (or any framework) is fine — see `scripts/iss-enroll.js`.
- **CA host** runs step-ca, Traefik, the enroll server, and operator-deployed
  backends.
- **Join host** runs Traefik only, with the CA's root + intermediate in
  its `caFiles`.
- **CRL** syncs via cron from the CA host to every join host.
- **Per-user cert** has an SAN list of allowed service hostnames. The
  operator maintains an ACL mapping users to hostnames.
- **Per-service server cert** is operator-issued at setup time.

## What's the operator's call (everything else)

These env vars in `.env` configure everything operator-specific:

| Variable | Example | What it is |
|---|---|---|
| `CA_HOSTNAME` | `ca` | mDNS name of the CA host. Becomes `<CA_HOSTNAME>.local` on the LAN. |
| `CA_NAME` | `MyCompanyLLC` | Cert subject O of the CA. Appears in every issued cert. |
| `CA_IP` | `10.0.0.10` | CA host's LAN IP. Used in cert SANs and Traefik config. |
| `JOIN_AS_CA` | `true` | Set `true` on the CA host itself; `false` on every join host. |
| `ISS_USER` | `dev` | Linux user the app runs as. |
| `ISS_HOME` | `/home/dev` | Linux user's home dir. |
| `ISS_CONFIG_DIR` | `/etc/iss` | Config dir. |
| `ISS_STATE_DIR` | `/var/lib/iss` | Runtime state dir. |
| `ISS_NAME` | `ISS` | Display name shown in the enroll page header. |
| `DASHBOARD_PORT` | `8080` | Port the operator's dashboard listens on. |
| `ENROLL_PORT` | `8081` | Port the enroll app listens on. |
| `ENROLL_HOUSEHOLD_PASSWORD` | (your secret) | Shared password users enter at the enroll page. |
| `ENROLL_P12_PASSWORD` | (your secret) | Password the `.p12` is encrypted with. Mac users type this on import. |

`CA_NAME` must contain only letters, digits, spaces, commas, and periods.
Avoid quote characters and other punctuation.

If you want a different framework for the enroll app, replace
`scripts/iss-enroll.js` with your own. The design's two contracts:
(a) the returned `.p12` bundles leaf + intermediate; (b) the cert is issued
with `--provisioner-password-file /root/.step-pw`.

## Quickstart

```bash
git clone https://github.com/good-shepherd-insights/internal-service-system.git
cd internal-service-system
cp .env.example .env
$EDITOR .env      # set CA_HOSTNAME, CA_NAME, CA_IP, JOIN_AS_CA,
                  # ENROLL_HOUSEHOLD_PASSWORD, ENROLL_P12_PASSWORD
sudo ./bootstrap.sh
```

Requires **Ubuntu 26.04+** (OpenSSL 3.5+). The bootstrap will refuse to run
on older hosts.

The bootstrap:
- Installs packages, downloads step-ca/step-cli/traefik from GitHub releases
- On the CA host: generates the CA, configures ACL+CRL, issues the
  dashboard's server cert
- On a join host: scp-copies the root + intermediate from the CA host by
  IP, sets up Traefik only
- Starts all services in dependency order
- Prints verification status at the end

## Adding a new service

After the mesh is up:

1. SSH to the host running the service.
2. Issue the server cert:
   ```
   step ca certificate <svc>.<host>.local cert.pem key.pem \
     --ca-url https://ca.<CA_HOSTNAME>.local:8443 \
     --san <svc>.<host>.local --san <host_ip> --not-after 2160h
   ```
3. Add a Traefik router with `Host(<svc>.<host>.local)` and
   `tls.options=mtls`.
4. Add an `avahi-publish-<svc>` service for the alias.
5. Add the new hostname to the user's entry in the ACL JSON on the CA host.

## Removing a service / revoking a user

1. `step ca revoke <serial-or-cert-path>` on the CA host.
2. Update the ACL to remove the user or hostname.
3. Cron picks up the new CRL on every host within 5 minutes.

## Repo layout

```
.
├── README.md                 — this file
├── bootstrap.sh              — one-shot install, idempotent
├── .env.example              — operator secrets template
├── .gitignore
├── etc/
│   ├── systemd/system/       — service units (renamed by bootstrap)
│   ├── traefik/              — Traefik static + dynamic configs
│   └── avahi/                — mDNS daemon config
├── scripts/
│   └── iss-enroll.js         — enroll app (example implementation)
├── templates/
│   └── acl.json              — user → service hostnames map (template)
└── docs/
    └── design.md             — full design specification (brand-agnostic)
```

## Caveats

- **OpenSSL ≥ 3.5 required.** step-cli 0.30.x's cert verification needs
  OpenSSL 3.5 or newer. Ubuntu 24.04 ships with 3.0; the bootstrap will
  refuse to run on older hosts. Tested on Ubuntu 26.04.
- mDNS scope is one LAN/VLAN. Cross-VLAN service discovery needs real DNS
  or a reflector.
- The dashboard at `DASHBOARD_PORT` is operator's responsibility. The
  bootstrap only configures the Traefik router for it.
- Re-enrolling an existing user requires deleting the issued-name tracker
  at `${ISS_STATE_DIR}/enroll/issued.json` on the CA host first.
