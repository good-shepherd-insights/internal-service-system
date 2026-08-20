# Internal Service System — Design Specification

This document describes the design that the repo implements. Operators
follow it; agents and AI assistants read it as the spec.

## What this is

A reusable system design for securing internal applications across an array
of ports and hostnames on a LAN:

- mTLS hard gate (no click-throughs, no public exposure)
- mDNS discovery via avahi
- One small step-ca authority issues both server certs (per service) and
  user certs (per person)
- Per-user cert carries the SAN list of services that user is approved for
- A central enroll endpoint issues user certs after a single shared
  password check
- An operator-maintained ACL JSON controls who can reach what

This is a **template**, not a product. Operators clone, configure `.env`,
run `bootstrap.sh`, and ship a working mesh.

## Trust hierarchy

```
<CA_NAME> Root CA           ← step-ca init --name=... (from .env: CA_NAME)
├── Intermediate CA         ← signs every user + server cert
│   ├── <service>.<host>.local (server cert, issued at service setup)
│   └── <user> (user cert, SANs from the ACL)
```

- The root cert is public. Every host in the mesh gets a copy.
- The intermediate private key lives only on the CA host.
- The `admin` JWK provisioner is what the central enroll uses to issue
  certs.

## Component layout

| Host kind | Runs |
|---|---|
| CA host (one) | step-ca, Traefik, the dashboard's mTLS target, the enroll server |
| Join host (any) | Traefik only, with the CA's root + intermediate in its caFiles |

On every host: avahi mDNS broadcasting the CA hostname.

## What runs as part of the design

- **step-ca** — issues and revokes certs. One instance per mesh, on the CA
  host.
- **Traefik** — every websecure router demands a client cert signed by the
  CA root. caFiles list both the root AND the intermediate.
- **avahi** — broadcasts service hostnames (e.g. `mysvc.host2.local`) over
  multicast on port 5353.
- **enroll server** — single, on the CA host. Plain HTTP, single shared
  password in a form, returns a `.p12` on success.

## Cert issuance — the two contracts

The enroll server handles user certs. To issue one:

```
step ca certificate <name> <cert.pem> <key.pem> \
  --provisioner admin \
  --provisioner-password-file /root/.step-pw \
  --san <approved_hostname_1> \
  ...
```

The `--provisioner-password-file` is required: the admin JWK is encrypted
with the CA's password file (`/root/.step-pw`). Without it, step-ca
prompts on a tty and fails.

The `.p12` returned to the user MUST contain the leaf + the intermediate.
Traefik only has the root in its `caFiles`. If the user's `.p12` doesn't
include the intermediate, the TLS handshake can't build the chain and
fails with `unknown CA`. The Hono enroll app bundles the two certs via:

```
cat <cert.pem> <intermediate_ca.pem> > chain.pem
openssl pkcs12 -export -inkey <key.pem> -in <cert.pem> \
  -certfile chain.pem -password pass:<ENROLL_P12_PASSWORD> ...
```

The `.p12` password is `ENROLL_P12_PASSWORD` (from `.env`). Mac users
enter this when importing the cert.

The cert subject's `O` is set by step-ca to `CA_NAME` (from `.env`). The
cert subject's `CN` is the user's chosen identifier.

## Per-user ACL

The ACL JSON on the CA host. Maps user identifiers to allowed service
hostnames:

```json
{
  "anthony": ["<CA_HOSTNAME>.local", "grafana.server2.local"],
  "grandma": ["photos.local"]
}
```

The user cert issued by the enroll server has those hostnames as its SANs.
Traefik validates the cert's signature chain. The service's router rule
(`Host(<svc>.<host>.local)`) further matches the SAN to the connection.
Result: an attacker with a valid CA-signed cert but no matching SAN gets
rejected.

## Per-service server cert

Each service running on a service host has its own cert, issued at setup:

```
step ca certificate <svc>.<host>.local cert.pem key.pem \
  --ca-url https://<CA_HOSTNAME>.local:8443 \
  --san <svc>.<host>.local --san <host_ip> --not-after 2160h
```

That cert + key go into Traefik's `tls.certificates` for the service's
`websecure` router. The service itself knows nothing about TLS.

## Operational facts

A host running one of these designs has, at minimum:

1. Traefik with mTLS hard gate, caFiles listing the CA root + intermediate.
2. Its own service's server cert at
   `<ISS_CONFIG_DIR>/certs/<svc>.<host>.local.pem`.
3. mDNS broadcast of `<svc>.<host>.local` → its own IP.
4. CRL sync from the CA host (cron `rsync ca-host:/root/.step/crl.pem ...`,
   every 5 min by default).

## Files on disk (paths come from .env)

| Path | Owner | Purpose |
|---|---|---|
| `/root/.step/` | root:root 700 | step-ca state |
| `/root/.step/certs/root_ca.crt` | root:root 600 | Root CA cert (public, copied to other hosts) |
| `/root/.step/certs/intermediate_ca.crt` | root:root 600 | Intermediate CA cert |
| `/root/.step/secrets/intermediate_ca_key` | root:root 600 | Intermediate private key |
| `<ISS_CONFIG_DIR>/dynamic/root_ca.crt` | root:root 644 | Root, copied to Traefik's caFiles |
| `<ISS_CONFIG_DIR>/dynamic/intermediate_ca.crt` | root:root 644 | Intermediate, copied to Traefik's caFiles |
| `<ISS_CONFIG_DIR>/dynamic/iss.yml` | root:root 644 | Traefik dynamic config (placeholders substituted) |
| `<ISS_CONFIG_DIR>/acl.json` | root:root 0644 | user → hostname ACL |
| `<ISS_CONFIG_DIR>/certs/<svc>.<host>.local.pem` | root:root 0644 | service server cert |
| `/etc/systemd/system/step-ca.service` | root:root 644 | step-ca systemd unit |
| `/etc/systemd/system/traefik.service` | root:root 644 | Traefik systemd unit |
| `/etc/systemd/system/<CA_HOSTNAME>-enroll.service` | root:root 644 | Enroll app unit |
| `/etc/systemd/system/<CA_HOSTNAME>-enroll.service.d/env.conf` | root:root 644 | Drop-in with secrets |
| `/etc/avahi/avahi-daemon.conf` | root:root 644 | avahi config (host-name= substituted) |
| `<ISS_HOME>/.local/share/iss/scripts/<CA_HOSTNAME>-enroll.js` | root:root 0755 | enroll app source |
| `<ISS_STATE_DIR>/enroll/issued.json` | root:root 0644 | issued-name tracker |
| `avahi-publish-<svc>.service` | root:root | per-service mDNS publisher |

## Verification checklist

```bash
curl -ksf https://127.0.0.1:8443/health                                     # step-ca up
curl -s "http://127.0.0.1:${ENROLL_PORT}/" | grep -E "Get connected|Get Access"  # enroll page reachable
curl -k --cacert <ISS_CONFIG_DIR>/dynamic/root_ca.crt \
     --cert /tmp/test-client.pem --key /tmp/test-client-key.pem \
     https://<CA_HOSTNAME>.local/api/status                                # mTLS works
curl -k https://<CA_HOSTNAME>.local/api/status                             # without cert: TLS rejected
avahi-resolve --name <svc>.<host>.local                                    # mDNS broadcast working
```

## Rules

- Root cert is copied ONCE per host. CRL syncs every 5 min via cron.
- Every Traefik router on `websecure` must have a `tls:` block.
- Service hostnames: `<svc>.<host>.local`. User cert SANs = approved
  hostnames from the ACL.
- User certs: issued by central enroll. Server certs: issued by step-ca at
  setup.
- mDNS: use `avahi-publish -a -R`. Never `/etc/avahi/hosts` (collision
  bug).
- `ENROLL_HOUSEHOLD_PASSWORD` is one shared secret.
- `ENROLL_P12_PASSWORD` is the `.p12` install password.
- `.p12` packages leaf + intermediate. Traefik's `caFiles` must include
  both.

## User cert re-issuance

To allow the same identifier to obtain a new cert: delete the issued-name
tracker and restart the enroll service:

```bash
sudo rm <ISS_STATE_DIR>/enroll/issued.json
sudo systemctl restart <CA_HOSTNAME>-enroll
```

## Mac install flow

1. Open the enroll endpoint in any browser → form → Name + Password + Get
   Access → `.p12` downloads
2. Double-click the `.p12` → Keychain Access prompts for the install
   password (the value of `ENROLL_P12_PASSWORD`)
3. Open Keychain Access → find the cert → Get Info → Trust → "When using
   this certificate" → "Always Trust"
4. Open `https://<CA_HOSTNAME>.local` → browser prompts for cert → select
   the cert → basic auth → dashboard

The ACL is the source of truth for what services each user can access.
Re-enroll after editing.
