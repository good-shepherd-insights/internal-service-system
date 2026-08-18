---
name: lan-service-mesh
description: Set up and operate the AF Resolutions, LLC LAN service mesh (mTLS + step-ca + Hono enroll). Use when adding services/hosts, enrolling users, or troubleshooting.
---

# LAN Service Mesh — AF Resolutions, LLC

One CA host runs step-ca. Other hosts run Traefik with mTLS hard gate, trusting the AF Resolutions root. Users enroll at `http://enroll.local` and get a cert whose SAN list is the services they're approved for. Discovery via mDNS. No public exposure.

## CA host setup (one-time)

### Install step-ca + step CLI

```bash
wget -P /tmp https://github.com/smallstep/cli/releases/download/v0.30.6/step-cli_0.30.6_amd64.deb
wget -P /tmp https://github.com/smallstep/certificates/releases/download/v0.30.2/step-ca_0.30.2_amd64.deb
sudo apt-get install -y /tmp/step-cli_0.30.6_amd64.deb /tmp/step-ca_0.30.2_amd64.deb
```

### Init step-ca

```bash
sudo mkdir -p /root/.step
echo "GENERATE-A-STRONG-PASSWORD" | sudo tee /root/.step-pw > /dev/null
sudo chmod 600 /root/.step-pw
sudo step ca init \
  --name="AF Resolutions, LLC" \
  --dns="ca.local,localhost,127.0.0.1" \
  --address="127.0.0.1:8443" \
  --provisioner="admin" \
  --password-file=/root/.step-pw
```

### Bump cert durations to 2160h (90d)

```bash
sudo python3 -c "
import json
p = '/root/.step/config/ca.json'
d = json.load(open(p))
d['authority']['claims']['defaultTLSCertDuration'] = '2160h'
d['authority']['claims']['maxTLSCertDuration'] = '2160h'
json.dump(d, open(p, 'w'), indent=2)
"
```

### Enable CRL export

Add to the top level of `/root/.step/config/ca.json` (sibling of `authority`, `db`, etc.):

```json
{
  "crl": {
    "enabled": true,
    "path": "/root/.step/crl.pem"
  }
}
```

Restart step-ca after editing.

### Ensure `/etc/hosts` has `ca.local`

```bash
grep -q "ca.local" /etc/hosts || echo "127.0.0.1 ca.local" | sudo tee -a /etc/hosts
```

### step-ca systemd unit

`/etc/systemd/system/step-ca.service`:

```ini
[Unit]
Description=step-ca Certificate Authority
After=network.target

[Service]
Type=simple
User=root
Environment=STEPPATH=/root/.step
ExecStart=/usr/bin/step-ca /root/.step/config/ca.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now step-ca
```

### Install Traefik 3.6.25

```bash
curl -fL -o /tmp/traefik.tgz https://github.com/traefik/traefik/releases/download/v3.6.25/traefik_v3.6.25_linux_amd64.tar.gz
tar -xzf /tmp/traefik.tgz -C /tmp/ traefik
sudo cp /tmp/traefik /usr/local/bin/traefik
sudo chmod +x /usr/local/bin/traefik
```

### Traefik systemd unit

`/etc/systemd/system/traefik.service`:

```ini
[Unit]
Description=Traefik reverse proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### Traefik static config

`/etc/traefik/traefik.yml`:

```yaml
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
log:
  level: INFO
  filePath: /var/log/traefik/traefik.log
  format: common
accessLog:
  filePath: /var/log/traefik/access.log
  format: common
```

### Traefik dynamic config (mTLS + dashboard + enroll routers)

`/etc/traefik/dynamic/hermes.yml`:

```yaml
tls:
  certificates:
    - certFile: /home/dev/certs/hermes.local.pem
      keyFile: /home/dev/certs/hermes.local-key.pem
  options:
    mtls:
      clientAuth:
        caFiles:
          - /etc/traefik/dynamic/root_ca.crt
          - /etc/traefik/dynamic/intermediate_ca.crt
        clientAuthType: RequireAndVerifyClientCert
http:
  routers:
    dashboard:
      rule: "Host(`hermes.local`)"
      entryPoints: [websecure]
      service: dashboard-svc
      tls:
        options: mtls
    dashboard-redirect:
      rule: "Host(`hermes.local`)"
      entryPoints: [web]
      middlewares: [redirect-https]
      service: dummy
    enroll:
      rule: "Host(`enroll.local`)"
      entryPoints: [web]
      service: enroll-svc
  middlewares:
    redirect-https:
      redirectScheme:
        scheme: https
        permanent: true
  services:
    dashboard-svc:
      loadBalancer:
        passHostHeader: false
        servers:
          - url: "http://127.0.0.1:9119"
    enroll-svc:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:9120"
    dummy:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9119"
```

Every router on `websecure` MUST have a `tls:` block (can be `tls: {}` empty) or Traefik filters it out.

```bash
sudo cp /root/.step/certs/root_ca.crt /etc/traefik/dynamic/root_ca.crt
sudo cp /root/.step/certs/intermediate_ca.crt /etc/traefik/dynamic/intermediate_ca.crt
```

### Issue the dashboard server cert

```bash
sudo step ca certificate hermes.local /home/dev/certs/hermes.local.pem /home/dev/certs/hermes.local-key.pem \
  --ca-url https://ca.local:8443 \
  --san hermes.local \
  --san 192.168.1.152 \
  --not-after 2160h \
  --password-file /root/.step-pw
```

### Dashboard

Runs on `127.0.0.1:9119` via `hermes-dashboard.service`. With `passHostHeader: false`, Host header is rewritten to `127.0.0.1:9119`; the dashboard strips the port.

### Hono enroll app

```bash
cd /home/dev/.hermes/scripts
npm init -y
npm install hono @hono/node-server
# Ensure package.json has "type": "module"
```

`/home/dev/.hermes/scripts/hermes-enroll.js`:

```javascript
#!/usr/bin/env node
import { Hono } from 'hono';
import { serve } from '@hono/node-server';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const execFileP = promisify(execFile);
const STEP = '/usr/bin/step';
const PORT = 9120;
const HOUSEHOLD_PASSWORD = process.env.HERMES_HOUSEHOLD_PASSWORD;
if (!HOUSEHOLD_PASSWORD) {
  console.error('HERMES_HOUSEHOLD_PASSWORD not set');
  process.exit(1);
}
const ACL_PATH = '/etc/hermes/acl.json';

const HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Network key</title>
<style>
* { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
html, body { margin: 0; padding: 0; height: 100%; background: #050505; }
body {
  color: #fff;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 40px 20px;
}
main { width: 100%; max-width: 360px; }
h1 { font-weight: 700; font-size: 1.5rem; letter-spacing: -0.5px; margin: 0 0 32px; }
.field { margin-bottom: 24px; }
label { display: block; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: rgba(255,255,255,0.5); margin-bottom: 8px; }
input { width: 100%; background: transparent; border: none; border-bottom: 1px solid rgba(255,255,255,0.2); color: #fff; padding: 10px 0; font-size: 16px; outline: none; }
input:focus { border-bottom-color: #fff; }
button { width: 100%; background: #fff; color: #000; border: none; padding: 14px; font-size: 14px; font-weight: 700; text-transform: uppercase; letter-spacing: 1px; cursor: pointer; margin-top: 16px; }
button:disabled { opacity: 0.5; cursor: not-allowed; }
.msg { margin-top: 16px; font-size: 13px; min-height: 1.2em; }
.error { color: #ff6b6b; }
.success { color: #d0d0d0; }
footer { margin-top: 48px; font-size: 10px; letter-spacing: 1px; color: rgba(255,255,255,0.4); }
</style>
</head>
<body>
<main>
  <h1>Get connected</h1>
  <form id="enroll-form" autocomplete="off">
    <div class="field">
      <label for="name">Name</label>
      <input type="text" id="name" name="name" required maxlength="40" pattern="[a-zA-Z0-9_-]+" />
    </div>
    <div class="field">
      <label for="password">Password</label>
      <input type="password" id="password" name="password" required />
    </div>
    <button type="submit" id="submit">Get Access</button>
    <div class="msg error" id="msg"></div>
  </form>
  <footer>AF Resolutions, LLC</footer>
</main>
<script>
const form = document.getElementById('enroll-form');
const submit = document.getElementById('submit');
const msg = document.getElementById('msg');
form.addEventListener('submit', async (e) => {
  e.preventDefault();
  msg.textContent = '';
  msg.className = 'msg error';
  submit.disabled = true;
  submit.textContent = 'Working...';
  const name = document.getElementById('name').value.trim();
  const password = document.getElementById('password').value;
  try {
    const resp = await fetch('/api/enroll', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name, password}),
    });
    if (!resp.ok) {
      msg.textContent = 'We could not get you a key.';
      submit.disabled = false;
      submit.textContent = 'Get Access';
      return;
    }
    const blob = await resp.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name + '.p12';
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    msg.textContent = 'Open ' + name + '.p12 to install. Then go to the service.';
    msg.className = 'msg success';
    submit.disabled = false;
    submit.textContent = 'Get Access';
  } catch (err) {
    msg.textContent = 'We could not get you a key.';
    submit.disabled = false;
    submit.textContent = 'Get Access';
  }
});
</script>
</body>
</html>`;

const app = new Hono();
app.get('/', (c) => c.html(HTML));
app.get('/api/health', (c) => c.json({status: 'ok'}));

app.post('/api/enroll', async (c) => {
  let body;
  try { body = await c.req.json(); }
  catch { return c.json({error: 'Invalid JSON'}, 400); }

  const name = (body.name || '').trim();
  const password = body.password || '';

  if (!/^[a-zA-Z0-9_-]{1,40}$/.test(name)) {
    return c.json({error: 'Invalid name'}, 400);
  }
  if (password !== HOUSEHOLD_PASSWORD) {
    return c.json({error: 'Wrong password'}, 401);
  }

  let acl = {};
  try { acl = JSON.parse(await readFile(ACL_PATH, 'utf8')); } catch {}
  const allowed = acl[name];
  if (!Array.isArray(allowed) || allowed.length === 0) {
    return c.json({error: 'Not approved'}, 403);
  }

  const tmp = await mkdtemp(join(tmpdir(), 'hermes-enroll-'));
  const certPath = join(tmp, 'cert.pem');
  const keyPath = join(tmp, 'key.pem');
  const p12Path = join(tmp, 'bundle.p12');

  try {
    await execFileP(STEP, [
      'ca', 'certificate', name,
      certPath, keyPath,
      '--provisioner', 'admin',
      '--provisioner-password-file', '/root/.step-pw',
      '--san', ...allowed,
      '--not-after', '2160h',
    ], {
      env: { ...process.env, STEPPATH: '/root/.step' },
    });

    const certPEM = await readFile(certPath, 'utf8');
    const intermediatePEM = await readFile('/root/.step/certs/intermediate_ca.crt', 'utf8');
    const chainPath = join(tmp, 'chain.pem');
    await writeFile(chainPath, certPEM + '\n' + intermediatePEM);

    await execFileP('openssl', [
      'pkcs12', '-export',
      '-out', p12Path,
      '-inkey', keyPath,
      '-in', certPath,
      '-certfile', chainPath,
      '-password', `pass:${process.env.HERMES_P12_PASSWORD || 'hermes'}`,
      '-name', name,
    ]);

    const p12 = await readFile(p12Path);

    return new Response(p12, {
      status: 200,
      headers: {
        'Content-Type': 'application/x-pkcs12',
        'Content-Disposition': `attachment; filename="${name}.p12"`,
        'Content-Length': String(p12.length),
      },
    });
  } catch (err) {
    console.error('enroll error:', err);
    return c.json({error: err.stderr ? err.stderr.toString() : err.message}, 500);
  } finally {
    await rm(tmp, {recursive: true, force: true}).catch(() => {});
  }
});

app.notFound((c) => c.text('Not here.', 404));

serve({fetch: app.fetch, port: PORT, hostname: '127.0.0.1'}, (info) => {
  console.log(`hermes-enroll listening on http://127.0.0.1:${info.port}`);
});
```

`/etc/systemd/system/hermes-enroll.service`:

```ini
[Unit]
Description=Hermes Client Cert Enrollment (Hono)
After=step-ca.service

[Service]
Type=simple
User=root
WorkingDirectory=/home/dev/.hermes/scripts
Environment=STEPPATH=/root/.step
ExecStart=/home/dev/.local/bin/node /home/dev/.hermes/scripts/hermes-enroll.js
Environment=HERMES_HOUSEHOLD_PASSWORD=REPLACE_ME
Environment=HERMES_P12_PASSWORD=hermes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo mkdir -p /etc/hermes
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-enroll
```

### mDNS (avahi)

```bash
sudo apt-get install -y avahi-daemon avahi-utils
```

`/etc/avahi/avahi-daemon.conf` — add to `[server]` section:

```
host-name=hermes
```

```bash
sudo systemctl enable --now avahi-daemon
```


## Adding a new service

Substitute: `SVC=grafana`, `HOST=server2`, `PORT=3000`.

```bash
SVC=grafana
HOST=server2
PORT=3000

# 1. Issue server cert
sudo step ca certificate ${SVC}.${HOST}.local /home/dev/certs/${SVC}.${HOST}.local.pem /home/dev/certs/${SVC}.${HOST}.local-key.pem \
  --ca-url https://ca.local:8443 \
  --san ${SVC}.${HOST}.local \
  --not-after 2160h \
  --password-file /root/.step-pw

# 2. Append router + service to /etc/traefik/dynamic/hermes.yml
sudo cat >> /etc/traefik/dynamic/hermes.yml <<EOF
  routers:
    ${SVC}:
      rule: "Host(\`${SVC}.${HOST}.local\`)"
      entryPoints: [websecure]
      service: ${SVC}-svc
      tls:
        options: mtls
  services:
    ${SVC}-svc:
      loadBalancer:
        passHostHeader: false
        servers:
          - url: "http://127.0.0.1:${PORT}"
EOF

# 3. Add cert to tls.certificates list
sudo sed -i "/certFile: \/home\/dev\/certs\/hermes.local.pem/i\    - certFile: /home/dev/certs/${SVC}.${HOST}.local.pem\n      keyFile: /home/dev/certs/${SVC}.${HOST}.local-key.pem" /etc/traefik/dynamic/hermes.yml

# 4. Broadcast via mDNS
sudo tee /etc/systemd/system/avahi-publish-${SVC}.service <<EOF
[Unit]
Description=mDNS broadcast of ${SVC}.${HOST}.local
After=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/bin/avahi-publish -a -R ${SVC}.${HOST}.local \$(hostname -I | awk '{print \$1}')
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now avahi-publish-${SVC}

# 5. Add hostname to user's ACL entry
USER=jane   # replace with the actual username
sudo python3 -c "
import json
p = '/etc/hermes/acl.json'
d = json.load(open(p))
d.setdefault('$USER', []).append('${SVC}.${HOST}.local')
json.dump(d, open(p, 'w'), indent=2)
"

# 6. Reload Traefik (watch:true picks up automatically)
sudo systemctl reload traefik
```

## Adding a new host

```bash
NEW_HOST=192.168.2.50

# 1. Install Traefik 3.6.25 on the new host (same binary, same traefik.yml + traefik.service).

# 2. Copy root + intermediate
scp /root/.step/certs/root_ca.crt        dev@$NEW_HOST:/etc/traefik/dynamic/root_ca.crt
scp /root/.step/certs/intermediate_ca.crt dev@$NEW_HOST:/etc/traefik/dynamic/intermediate_ca.crt

# 3. CRL sync via cron
ssh dev@$NEW_HOST "echo '*/5 * * * * root rsync ca-host:/root/.step/crl.pem /etc/traefik/dynamic/crl.pem >/dev/null 2>&1' | sudo tee /etc/cron.d/hermes-crl-sync"

# 4. Deploy Traefik dynamic config with the new host's services, then per-service avahi-publish units.

# 5. Add the new host's services to relevant users' ACL entries on the CA host.
```

## Onboarding a user

1. Add to `/etc/hermes/acl.json`:
   ```json
   {"<username>": ["<svc>.<host>.local", ...]}
   ```
2. User opens `http://enroll.local`.
3. User types name + household password.
4. User clicks **Get Access**.
5. A `.p12` downloads. Double-click to install in Mac Keychain (empty p12 password).
6. User opens the service URL → Safari prompts for the cert → access granted.

## Revocation

```bash
sudo step ca revoke <cert-serial> /path/to/cert.pem
```

CRL refreshes at `/root/.step/crl.pem`. Other hosts pull it within 5 min via cron.

## Verification

```bash
curl -k https://127.0.0.1:8443/health                        # step-ca up
curl -s http://127.0.0.1:9120/ | grep -E "Get connected|Get Access"   # enroll page reachable
curl -k --cacert /etc/traefik/dynamic/root_ca.crt --cert /tmp/test-client.pem --key /tmp/test-client-key.pem https://hermes.local/api/status   # mTLS works
curl -k https://hermes.local/api/status                      # without cert: TLS rejected
avahi-resolve --name <svc>.<host>.local                      # mDNS broadcast working
```

## Rules

- Root cert is copied ONCE per host. CRL syncs every 5 min via cron.
- Every Traefik router on `websecure` must have a `tls:` block.
- Service hostnames: `<svc>.<host>.local`. User cert SANs = approved service hostnames.
- User certs: issued by central enroll. Server certs: issued by step-ca at setup.
- mDNS: use `avahi-publish -a -R`. Never `/etc/avahi/hosts` (collision bug).
- `HERMES_HOUSEHOLD_PASSWORD` is one shared secret. Rotate via the systemd unit.
- `HERMES_P12_PASSWORD` is the .p12 install password (default `hermes`). Mac users enter this when importing the .p12.
- `.p12` packages leaf + intermediate. Traefik's `caFiles` must include both root AND intermediate.

## User cert re-issuance

To allow the same identifier to obtain a new cert: `sudo rm /var/lib/hermes-enroll/issued.json` then `sudo systemctl restart hermes-enroll`.

## Mac install flow

1. Open `http://enroll.local` → form → Name + Password + Get Access → `.p12` downloads
2. Double-click the `.p12` → Keychain Access prompts for the install password (the value of `HERMES_P12_PASSWORD`, default `hermes`)
3. Open Keychain Access → find the cert → Get Info → Trust → "When using this certificate" → "Always Trust"
4. Open `https://hermes.local` → browser prompts for cert → select the cert → basic auth → dashboard
- `/etc/hermes/acl.json` is the source of truth for what services each user can access. Re-enroll after editing.
