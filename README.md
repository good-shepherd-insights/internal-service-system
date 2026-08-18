# Internal Service System (ISS) — plug-and-play mTLS template

A reusable system design for securing internal applications across an array of ports and hostnames on a LAN. mTLS hard gate. mDNS discovery. Per-service server certs. Per-user client certs. Per-user ACL. No click-throughs. No public exposure.

This is a **template**, not a product. The files in this repo implement one instance; you rename and rebrand to fit your environment.

## What's locked (the design)

The architecture is fixed. Don't deviate:

- **step-ca** issues all certs. One CA per mesh.
- **Traefik** is the mTLS gate. Every `websecure` router demands a client cert signed by the CA.
- **avahi** broadcasts hostnames via mDNS.
- **Hono (or any Node http server)** runs the user-facing enrollment endpoint on plain HTTP.
- **AC host** runs step-ca, the dashboard (Hermes/traefik/dashboard.py), the enroll server, and the Traefik reverse-proxy.
- **A join host** runs Traefik only, with the CA's root + intermediate in its `caFiles`.
- **CRL** sync via cron from the CA host to every join host.
- **Per-user cert** has an SAN list of allowed service hostnames. The operator maintains an ACL mapping users to hostnames.
- **Per-service server cert** is operator-issued at setup time.

## What's the operator's call (the brand)

Pick your own brand on install. Update `.env` and the script will pick up your values:

| Variable | Example | What it is |
|---|---|---|
| `CA_HOSTNAME` | `hermes` | mDNS name of the CA host (`hermes.local`). Default in this repo. |
| `CA_NAME` | `AF Resolutions, LLC` | The cert subject O of the CA. Appears in every issued cert. |
| `CA_IP` | `192.168.1.152` | The CA host's LAN IP. Used in cert SANs. |
| `DASHBOARD_PORT` | `9119` | Port the operator's dashboard listens on. The Traefik router renders this as the backend. |
| `ENROLL_PORT` | `9120` | Port the Hono enroll app listens on (this template). |
| `ENROLL_HOUSEHOLD_PASSWORD` | (your secret) | Shared password users enter at the enroll page. |
| `ENROLL_P12_PASSWORD` | `hermes` | Password the .p12 file is encrypted with. Mac users type this on import. |

If you fork this repo and want to rebrand entirely, also:
- Rename service unit filenames. Bootstrap does this automatically on install — the committed `hermes-enroll.service` becomes `${CA_HOSTNAME}-enroll.service` based on `.env`.
- Replace the Hono enroll app with your own implementation. The design doesn't require Hono; any Node/Go/Python server with the same `/api/enroll` shape works.
- Replace the dashboard module with your own. The template ships an empty `<DASHBOARD_PORT>` slot — operators fill it in.

## Quickstart

```bash
git clone https://github.com/good-shepherd-insights/internal-service-system.git
cd internal-service-system
cp .env.example .env   # edit CA_HOSTNAME, CA_NAME, CA_IP, JOIN_AS_CA, ENROLL_HOUSEHOLD_PASSWORD, ENROLL_P12_PASSWORD
sudo ./bootstrap.sh
```

Requires Ubuntu 26.04+ (OpenSSL 3.5+). The bootstrap will refuse to run on older hosts.

The bootstrap:
- Installs packages, downloads step-ca/step-cli/traefik from GitHub releases
- On the CA host: generates the CA, configures ACL+CRL, issues the dashboard's server cert
- On a join host: ssh-copies the root + intermediate from the CA host, sets up Traefik only
- Starts all services in dependency order
- Prints verification status at the end

## Adding a new service

After the mesh is up:

1. SSH to the host running the service.
2. `step ca certificate <svc>.<host>.local ... --provisioner admin --not-after 2160h` (issued via the CA host's step-ca over the LAN)
3. Add a Traefik router with `Host(<svc>.<host>.local)` and `tls.options=mtls`.
4. Add an avahi/publish service for the alias.
5. Add the new hostname to the user's entry in `/etc/hermes/acl.json` on the CA host.

## Removing a service / revoking a user

1. `step ca revoke <serial-or-cert-path>` on the CA host.
2. Update `/etc/hermes/acl.json` to remove the user or hostname.
3. Cron picks up the new CRL on every host within 5 minutes.

## Repo layout

```
.
├── README.md                 — this file
├── bootstrap.sh              — one-shot install, idempotent
├── .env.example              — operator secrets template
├── etc/
│   ├── systemd/system/       — service unit files (CA + dashboard + enroll)
│   ├── traefik/              — Traefik static + dynamic configs
│   └── avahi/                — mDNS daemon config
├── scripts/
│   └── hermes-enroll.js      — Hono enroll app. Example implementation. Renamed to <CA_HOSTNAME>-enroll.js by bootstrap.
├── templates/
│   └── acl.json              — user → service hostnames map (template)
└── docs/
    └── design.md             — full design specification (brand-agnostic)
```

## Caveats

- **OpenSSL ≥ 3.5 required.** step-cli 0.30.x's cert verification needs OpenSSL 3.5 or newer. Ubuntu 24.04 ships with 3.0; the bootstrap will refuse to run on older hosts. Tested on Ubuntu 26.04.
- mDNS scope is one LAN/VLAN. Cross-VLAN service discovery needs real DNS or a reflector.
- The dashboard at port 9119 is operator's responsibility. The bootstrap only configures the Traefik router for it.
- Re-enrolling an existing user requires deleting `/var/lib/hermes-enroll/issued.json` on the CA host first.
- Each unit file in `etc/systemd/system/` is keyed to example names (`hermes-*`). Bootstrap renames them based on `.env`.
