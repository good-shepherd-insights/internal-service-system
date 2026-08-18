#!/usr/bin/env node
// Hermes enroll — Hono, dark MercuryLogin-style, decoupled.
// Single file. No build step. Subprocess to `step` for cert issuance.
//
// THIS IS AN EXAMPLE IMPLEMENTATION. The Internal Service System design
// (see README.md) does not require Hono. To use a different framework, replace
// this file with your own implementation of these routes:
//   GET  /         — serve your enroll page
//   POST /api/enroll — accept {name, password}, call `step ca certificate ...` (see code below)
// The design's two contracts:
//   1. The .p12 returned MUST bundle cert + intermediate so the chain validates
//      against Traefik's caFiles.
//   2. The cert MUST have `--provisioner-password-file /root/.step-pw` so step-ca
//      can decrypt the admin JWK.

import { Hono } from 'hono';
import { serve } from '@hono/node-server';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const execFileP = promisify(execFile);
const PORT = 9120;
const HOUSEHOLD_PASSWORD = process.env.HERMES_HOUSEHOLD_PASSWORD;
const STEP = '/usr/bin/step';

if (!HOUSEHOLD_PASSWORD) {
  console.error('HERMES_HOUSEHOLD_PASSWORD env var is required');
  process.exit(1);
}

const app = new Hono();

const HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Hermes — Get Your Access</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;800&family=Space+Mono&display=swap');
:root {
  --bg: #050505;
  --mercury: #e0e0e0;
  --accent: #ffffff;
  --text-dim: rgba(255, 255, 255, 0.5);
  --error: #ff6b6b;
  --filter-goo: url('#gooey');
}
* { box-sizing: border-box; -webkit-font-smoothing: antialiased; }
html, body { margin: 0; padding: 0; height: 100%; }
.mercury-wrapper {
  background-color: var(--bg);
  color: var(--accent);
  font-family: 'Inter', sans-serif;
  height: 100vh;
  width: 100vw;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
  position: relative;
}
.stage {
  position: absolute;
  width: 100%;
  height: 100%;
  z-index: 0;
  filter: var(--filter-goo);
  opacity: 0.6;
}
.blob {
  position: absolute;
  background: linear-gradient(135deg, var(--mercury), #888);
  border-radius: 50%;
  filter: blur(20px);
  animation: float 20s infinite alternate ease-in-out;
  box-shadow: inset -10px -10px 20px rgba(0,0,0,0.5), 10px 10px 30px rgba(255,255,255,0.2);
  transition: margin 0.1s ease-out;
}
@keyframes float {
  0% { transform: translate(0, 0) scale(1); }
  33% { transform: translate(10vw, 20vh) scale(1.2); }
  66% { transform: translate(-5vw, 10vh) scale(0.8); }
  100% { transform: translate(5vw, -10vh) scale(1.1); }
}
.auth-container {
  position: relative;
  z-index: 10;
  width: 100%;
  max-width: 440px;
  padding: 40px;
}
.header { margin-bottom: 60px; text-align: left; }
.brand-id {
  font-family: 'Space Mono', monospace;
  font-size: 10px;
  letter-spacing: 4px;
  text-transform: uppercase;
  color: var(--text-dim);
  margin-bottom: 8px;
  display: block;
}
.header h1 {
  font-weight: 800;
  font-size: 3rem;
  line-height: 0.9;
  letter-spacing: -2px;
  margin: 0 0 0 -4px;
}
.subtitle {
  margin-top: 16px;
  font-family: 'Space Mono', monospace;
  font-size: 11px;
  color: var(--text-dim);
  line-height: 1.6;
}
.form-group {
  position: relative;
  margin-bottom: 30px;
  transition: transform 0.4s cubic-bezier(0.2, 1, 0.3, 1);
}
.form-group:focus-within { transform: translateX(10px); }
.form-group label {
  display: block;
  font-family: 'Space Mono', monospace;
  font-size: 11px;
  color: var(--text-dim);
  margin-bottom: 12px;
  text-transform: uppercase;
}
.form-group input {
  width: 100%;
  background: transparent;
  border: none;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
  color: var(--accent);
  padding: 12px 0;
  font-size: 18px;
  outline: none;
  transition: border-color 0.4s;
  font-family: 'Inter', sans-serif;
}
.input-glow {
  position: absolute;
  bottom: 0; left: 0;
  width: 0%;
  height: 2px;
  background: var(--mercury);
  transition: width 0.6s cubic-bezier(0.2, 1, 0.3, 1);
  box-shadow: 0 0 15px var(--mercury);
}
.form-group input:focus + .input-glow { width: 100%; }
.submit-wrap {
  margin-top: 50px;
  position: relative;
  filter: var(--filter-goo);
}
.btn-base {
  background: var(--accent);
  color: #000;
  border: none;
  padding: 20px 40px;
  font-size: 14px;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 2px;
  cursor: pointer;
  width: 100%;
  position: relative;
  z-index: 2;
  transition: letter-spacing 0.3s;
  font-family: 'Inter', sans-serif;
}
.btn-base:hover { letter-spacing: 4px; }
.btn-base:disabled { opacity: 0.5; cursor: not-allowed; }
.mercury-drop {
  position: absolute;
  top: 50%;
  left: 50%;
  width: 100%;
  height: 100%;
  background: var(--mercury);
  transform: translate(-50%, -50%);
  z-index: 1;
  border-radius: 50px;
  transition: all 0.5s cubic-bezier(0.175, 0.885, 0.32, 1.275);
}
.submit-wrap:hover .mercury-drop {
  transform: translate(-50%, -50%) scale(1.05, 1.2);
  filter: brightness(1.2);
}
.footer-nav {
  margin-top: 40px;
  display: flex;
  justify-content: space-between;
  font-family: 'Space Mono', monospace;
  font-size: 10px;
}
.footer-nav span {
  color: var(--text-dim);
}
.error {
  color: var(--error);
  font-family: 'Space Mono', monospace;
  font-size: 12px;
  margin-top: 20px;
  min-height: 16px;
}
.success {
  color: var(--mercury);
  font-family: 'Space Mono', monospace;
  font-size: 12px;
  margin-top: 20px;
  min-height: 16px;
}
.svg-filter-hidden { position: absolute; width: 0; height: 0; }
</style>
</head>
<body>
<svg class="svg-filter-hidden">
  <defs>
    <filter id="gooey">
      <feGaussianBlur in="SourceGraphic" stdDeviation="12" result="blur" />
      <feColorMatrix in="blur" mode="matrix" values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 19 -9" result="goo" />
      <feComposite in="SourceGraphic" in2="goo" operator="atop"/>
    </filter>
  </defs>
</svg>
<div class="mercury-wrapper">
  <div class="stage" id="stage"></div>
  <main class="auth-container">
    <header class="header">
      <span class="brand-id">Get connected</span>
    </header>
    <form id="enroll-form" autocomplete="off">
      <div class="form-group">
        <label for="name">Name</label>
        <input type="text" id="name" name="name" required maxlength="40" pattern="[a-zA-Z0-9_-]+" />
        <div class="input-glow"></div>
      </div>
      <div class="form-group">
        <label for="password">Password</label>
        <input type="password" id="password" name="password" required />
        <div class="input-glow"></div>
      </div>
      <div class="submit-wrap">
        <div class="mercury-drop"></div>
        <button type="submit" class="btn-base" id="submit">Get Access</button>
      </div>
      <div class="error" id="error"></div>
      <div class="success" id="success"></div>
    </form>
      <div class="footer-nav">
        <span>AF Resolutions, LLC</span>
      </div>
    </main>
  </div>
</body>
<script>
const blobs = Array.from({length: 6}).map(() => ({
  size: Math.random() * 200 + 150,
  left: Math.random() * 80 + 10,
  top: Math.random() * 80 + 10,
  delay: Math.random() * -20,
  duration: Math.random() * 15 + 15,
}));
const stage = document.getElementById('stage');
const blobEls = blobs.map(b => {
  const el = document.createElement('div');
  el.className = 'blob';
  el.style.width = b.size + 'px';
  el.style.height = b.size + 'px';
  el.style.left = b.left + '%';
  el.style.top = b.top + '%';
  el.style.animationDelay = b.delay + 's';
  el.style.animationDuration = b.duration + 's';
  stage.appendChild(el);
  return el;
});
document.addEventListener('mousemove', e => {
  const x = e.clientX / window.innerWidth;
  const y = e.clientY / window.innerHeight;
  blobEls.forEach((b, i) => {
    const speed = (i + 1) * 20;
    b.style.marginLeft = (x * speed) + 'px';
    b.style.marginTop = (y * speed) + 'px';
  });
});
const form = document.getElementById('enroll-form');
const submit = document.getElementById('submit');
const errorEl = document.getElementById('error');
const successEl = document.getElementById('success');
form.addEventListener('submit', async (e) => {
  e.preventDefault();
  errorEl.textContent = '';
  successEl.textContent = '';
  submit.disabled = true;
  submit.textContent = 'Issuing...';
  const name = document.getElementById('name').value.trim();
  const password = document.getElementById('password').value;
  try {
    const resp = await fetch('/api/enroll', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name, password}),
    });
    if (!resp.ok) {
      const j = await resp.json().catch(() => ({error: ''}));
      if (j.error === 'Wrong password') errorEl.textContent = "That password didn't work.";
      else if (j.error === 'Invalid name') errorEl.textContent = 'Use letters and numbers only.';
      else if (j.error && j.error.toLowerCase().includes('already')) errorEl.textContent = 'That name is already used. Try another.';
      else errorEl.textContent = 'Something went wrong. Try again.';
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
    successEl.textContent = 'All set. Click the file that downloaded to install.';
    submit.disabled = false;
    submit.textContent = 'Get Access';
  } catch (err) {
    errorEl.textContent = 'Something went wrong. Try again.';
    submit.disabled = false;
    submit.textContent = 'Get Access';
  }
});
</script>
</body>
</html>`;

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

  // Track issued names so we can warn on re-use.
  const issued = await readFile('/var/lib/hermes-enroll/issued.json', 'utf8').catch(() => '{}');
  let issuedMap = {};
  try { issuedMap = JSON.parse(issued); } catch {}
  if (issuedMap[name]) {
    return c.json({error: 'Name already used'}, 409);
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
      '--san', `${name}.local`,
      '--san', '192.168.1.152',
      '--not-after', '2160h',
      '--provisioner-password-file', '/root/.step-pw',
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

    // mark issued
    issuedMap[name] = Date.now();
    await mkdir('/var/lib/hermes-enroll', {recursive: true});
    await writeFile('/var/lib/hermes-enroll/issued.json', JSON.stringify(issuedMap, null, 2));

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

app.notFound((c) => c.html('<h1 style="color:white;background:black;padding:40px;font-family:monospace">404 — Not here.</h1>', 404));

serve({fetch: app.fetch, port: PORT, hostname: '127.0.0.1'}, (info) => {
  console.log(`hermes-enroll listening on http://127.0.0.1:${info.port}`);
});
