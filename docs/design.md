# Internal Service System — Design Specification

This document describes the design that the repo implements. Operators follow
it; agents and AI assistants read it as the spec.

## What this is

A reusable system design for securing internal applications across an array of
ports and hostnames on a LAN.

- mTLS hard gate (no click-throughs, no public exposure).
- mDNS discovery (works on one LAN/VLAN).
- Per-service server certs. Per-user client certs. Per-user ACL.
- One CA host per mesh. Other hosts join as Traefik-mTLS-only.

The repo's `bootstrap.sh` and `etc/` configs implement this design verbatim.
The skill used by AI agents is the lock-in to the live system — separate from
this repo.

## Trust hierarchy

```
AF Resolutions, LLC Root CA         ← step-ca init --name=...
├── Intermediate CA                 ← signs every user + server cert
│   ├── server certs                ← step ca certificate for each <svc>.<host>.local
│   ├── user certs                  ← step ca certificate, SAN list = ACL
│   └── CRL /root/.step/crl.pem     ← step-ca exports; join hosts pull via cron
└── Provisioners
    ├── admin (JWK)                 ← used by this repo's enroll app
    └── acme (ACME)                 ← optional, for automation
```

Every host's Traefik has `clientAuth.caFiles` pointing to BOTH root and
intermediate. Required to validate chains where the client only sends the leaf
cert.

## Component layout

```
CA host (any host in the mesh; runs step-ca)
├── step-ca           — issues + revokes certs. Port 8443.
├── Traefik           — terminates TLS, demands client certs, routes by Host
├── avahi-daemon      — mDNS broadcast of <CA_HOSTNAME>.local
├── <name>-enroll     — single-user cert issuance endpoint
│                       GET  /              → enroll form
│                       POST /api/enroll    → {name, password} → cert + .p12
└── (operator's)      — any dashboard on <DASHBOARD_PORT>, mTLS-protected

Join host (any other host with internal services to expose)
├── Traefik only      — same mTLS caFiles, no step-ca, no enroll, no dashboard
├── avahi-daemon      — broadcasts <host>.local
└── services          — each gets its own server cert issued by step-ca over LAN
```

## Cert issuance

### User cert (from the enroll app)

```
step ca certificate <user>
  --provisioner admin
  --provisioner-password-file /root/.step-pw
  --san <approved_hostname_1> --san <approved_hostname_2> ...
  --not-after 2160h
```

Output: PEM cert + PEM key, bundled into a `.p12` via OpenSSL.

The `.p12` MUST contain `leaf + intermediate`. Without the intermediate in the
bundle, Mac browsers send only the leaf and Traefik can't validate the chain.

The `.p12` install password is `ENROLL_P12_PASSWORD`. Mac users enter it on
import. Default is `hermes`.

The Intermediate is needed because Traefik needs both root + intermediate in
`caFiles` to bridge from a leaf-only client cert.

### Server cert (operator-issued at setup)

```
step ca certificate <svc>.<host>.local
  --provisioner admin
  --provisioner-password-file /root/.step-pw
  --san <svc>.<host>.local --san <host-ip>
  --not-after 2160h
```

Configured into each host's Traefik dynamic config as `tls.certificates`.

## ACL model

`/etc/hermes/acl.json` on the CA host. Maps user identifiers to allowed service
hostnames. Read by the enroll app at request time.

```json
{
  "anthony": ["hermes.local", "grafana.server2.local"],
  "grandma": ["photos.local"]
}
```

When the enroll app issues a cert, it puts each approved hostname as a SAN on
the cert. Traefik validates the cert's signature AND (because the user is
connecting to a specific Host header) implicitly only allows that Host.

The cert subject's `O` is set by step-ca to `CA_NAME` (e.g. `AF Resolutions, LLC`).

## The mTLS handshake

1. User visits `https://<svc>.<host>.local`.
2. Traefik demands a client cert.
3. Browser sends the user's cert.
4. Traefik's `clientAuth.clientAuthType: RequireAndVerifyClientCert` checks:
   - cert chain against `caFiles` (root + intermediate).
   - revocation status against `crlFiles` if configured.
5. If valid, forward to the backend on the local port.
6. If invalid, TLS handshake fails, browser shows generic connection error.

## mDNS scope

mDNS works on one LAN/VLAN. Cross-VLAN service discovery needs real DNS or a
mDNS reflector. avahi hosts within one subnet broadcast and resolve each other.

`avahi-publish -a -R <alias> <ip>` for static aliases. Use systemd units to
make them persistent.

`/etc/avahi/hosts` is broken for some hostname collisions (avahi issue #40).

## Discovery

Three pieces of state that operators maintain:

1. The CA host's `/etc/hermes/acl.json` — who can reach what.
2. Each host's Traefik dynamic config — what services run where.
3. Each service's mDNS broadcast (or static `/etc/avahi/hosts` minus the bug).

## Adding a service

1. Run the service on a port.
2. SSH to the service's host. `step ca certificate <svc>.<host>.local ...`.
3. Add a Traefik router entry: `Host(<svc>.<host>.local)` → backend port,
   `tls.options: mtls`.
4. Add an avahi `avahi-publish` unit for `<svc>.<host>.local`.
5. Add the user's hostname entry to `/etc/hermes/acl.json`.

## Revocation

`step ca revoke <serial-or-cert-path>` on the CA host. step-ca writes a new
CRL to `/root/.step/crl.pem`. Join hosts pull via cron every 5 minutes.

## Files the design owns

| Path | Owner | Purpose |
|---|---|---|
| `/root/.step/` | root:root 700 | step-ca state |
| `/root/.step-pw` | root:root 0600 | CA password (operator secret) |
| `/etc/traefik/dynamic/` | root:root 0755 | Traefik dynamic config |
| `/etc/traefik/certs/` | root:root 0755 | issued server certs |
| `/etc/avahi/avahi-daemon.conf` | root:root | mDNS daemon config |
| `/etc/hermes/acl.json` | root:root 0644 | user → hostname ACL |
| `/var/lib/hermes-enroll/` | root:root | issued name tracker |

## Files the design does NOT own

- `/home/dev/.hermes/` — Hermes's own state (gateway, dashboard). Anything
  here is the operator's responsibility and outside this design.

## Verification

```bash
curl -ksf https://ca.local:8443/health             # step-ca alive
curl -sf  http://127.0.0.1:9120/api/health         # enroll alive
curl -k  --cacert /etc/traefik/dynamic/root_ca.crt \
      --cert /etc/traefik/dynamic/test-client.pem \
      --key  /etc/traefik/dynamic/test-client-key.pem \
      https://hermes.local/                          # mTLS succeeds
avahi-resolve --name <svc>.<host>.local             # mDNS resolves
```

## Rules

1. Root cert is copied ONCE per host. CRL syncs every 5 min via cron.
2. Every `websecure` Traefik router needs a `tls: {}` block (Traefik 3.6.25+).
3. Service hostnames: `<svc>.<host>.local`. User cert SANs = approved
   hostnames.
4. User certs: issued by central enroll. Server certs: issued by step-ca at
   setup.
5. mDNS: use `avahi-publish -a -R`. Never `/etc/avahi/hosts` (collision bug).
6. `ENROLL_HOUSEHOLD_PASSWORD`: shared secret. Rotate via systemd drop-in.
7. `ENROLL_P12_PASSWORD`: install password. Mac users type this on import.
8. `.p12` MUST bundle cert + intermediate. Traefik MUST include both in
   `caFiles`.
9. `step ca certificate` MUST include `--provisioner-password-file` so step-ca
   can decrypt the admin JWK.
