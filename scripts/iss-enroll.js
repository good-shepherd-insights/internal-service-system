#!/usr/bin/env node
// ISS enroll app — Hono, dark MercuryLogin-style, decoupled.
// Single file. No build step. Subprocess to `step` for cert issuance.
//
// THIS IS AN EXAMPLE IMPLEMENTATION. Replace this file with your own
// implementation of these routes:
//   GET  /         — serve your enroll page
//   POST /api/enroll — accept {name, password}, call `step ca certificate ...`
//
// Design contracts the implementation MUST honor:
//   1. The .p12 returned MUST bundle cert + intermediate so the chain
//      validates against Traefik's caFiles.
//   2. The cert MUST be issued with --provisioner-password-file
//      /root/.step-pw so step-ca can decrypt the admin JWK.

import { Hono } from 'hono';
import { serve } from '@hono/node-server';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const execFileP = promisify(execFile);
const STEP = '/usr/bin/step';

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`${name} env var is required`);
    process.exit(1);
  }
  return v;
}

const ISS_CONFIG_DIR = requireEnv('ISS_CONFIG_DIR');
const ISS_STATE_DIR = requireEnv('ISS_STATE_DIR');
const ISS_NAME = requireEnv('ISS_NAME');
const CA_NAME = requireEnv('CA_NAME');
const CA_HOSTNAME = requireEnv('CA_HOSTNAME');
const CA_IP = requireEnv('CA_IP');
const PORT = parseInt(requireEnv('ENROLL_PORT'), 10);
const HOUSEHOLD_PASSWORD = requireEnv('ENROLL_HOUSEHOLD_PASSWORD');
const P12_PASSWORD = requireEnv('ENROLL_P12_PASSWORD');
const STEPPATH = requireEnv('STEPPATH');
const STEPPATH_FILE = process.env.STEPPATH_FILE || `${STEPPATH}-pw`;

const ACL_PATH = `${ISS_CONFIG_DIR}/acl.json`;
const ISSUED_PATH = `${ISS_STATE_DIR}/enroll/issued.json`;

const app = new Hono();

app.get('/api/health', (c) => c.text('ok'));

app.get('/', (c) => {
  return c.html(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${ISS_NAME} — Get Your Access</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;800&family=Space+Mono&display=swap');
:root { --bg: #050505; --mercury: #e0e0e0; --mercury-dark: #666666; --accent: #ffffff; --text-dim: rgba(255,255,255,0.5); --filter-goo: url('#gooey'); }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--mercury); font-family: 'Inter', sans-serif; min-height: 100vh; overflow: hidden; }
.bg-field { position: fixed; inset: 0; filter: var(--filter-goo); z-index: 0; pointer-events: none; }
.blob { position: absolute; border-radius: 50%; background: var(--mercury); opacity: 0.18; mix-blend-mode: screen; transition: transform 1.2s cubic-bezier(0.2,1,0.3,1); will-change: transform; }
.container { position: relative; z-index: 1; display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
main { width: 100%; max-width: 380px; }
.header { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 60px; }
.brand-id { font-family: 'Space Mono', monospace; font-size: 11px; color: var(--text-dim); letter-spacing: 0.2em; text-transform: uppercase; }
h1 { font-family: 'Inter', sans-serif; font-weight: 800; font-size: 32px; letter-spacing: -0.04em; margin: 0 0 50px 0; color: var(--accent); line-height: 1; }
.subtitle { color: var(--text-dim); font-size: 13px; line-height: 1.6; margin-bottom: 40px; }
.form-group { position: relative; margin-bottom: 30px; transition: transform 0.4s cubic-bezier(0.2, 1, 0.3, 1); }
.form-group:focus-within { transform: translateX(10px); }
.form-group label { display: block; font-family: 'Space Mono', monospace; font-size: 11px; color: var(--text-dim); margin-bottom: 12px; text-transform: uppercase; }
.form-group input { width: 100%; background: transparent; border: none; border-bottom: 1px solid rgba(255,255,255,0.1); color: var(--accent); font-family: 'Inter', sans-serif; font-size: 18px; padding: 10px 0; outline: none; transition: border-color 0.4s; }
.form-group input:focus { border-bottom-color: var(--accent); }
.btn-base { width: 100%; padding: 18px; background: var(--accent); color: var(--bg); border: none; font-family: 'Inter', sans-serif; font-weight: 800; font-size: 14px; letter-spacing: 0.1em; text-transform: uppercase; cursor: pointer; transition: transform 0.2s, opacity 0.2s; }
.btn-base:hover { transform: translateY(-2px); }
.btn-base:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }
.error { color: #ff6b6b; font-family: 'Space Mono', monospace; font-size: 12px; margin-top: 12px; min-height: 18px; }
.success { color: var(--accent); font-family: 'Space Mono', monospace; font-size: 12px; margin-top: 12px; min-height: 18px; }
.footer-nav { margin-top: 40px; display: flex; justify-content: center; }
.footer-nav span { font-family: 'Space Mono', monospace; font-size: 10px; color: var(--text-dim); letter-spacing: 0.15em; text-transform: uppercase; }
@keyframes drift { from { transform: translate(0, 0); } to { transform: translate(var(--dx, 40px), var(--dy, -30px)); } }
.blob { animation: drift var(--dur, 25s) ease-in-out infinite alternate; }
</style>
</head>
<body>
<svg width="0" height="0" style="position:absolute"><defs>
<filter id="gooey"><feGaussianBlur in="SourceGraphic" stdDeviation="40" result="blur" /><feColorMatrix in="blur" mode="matrix" values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 22 -10" result="cm" /></filter>
</defs></svg>
<div class="bg-field" id="bg"></div>
<div class="container">
<main>
  <header class="header"><span class="brand-id">Get connected</span></header>
  <h1 style="opacity:0.0001">Network key</h1>
  <p class="subtitle">Generates a key file for this device.</p>
  <form id="enroll-form" autocomplete="off">
    <div class="form-group">
      <label for="name">Name</label>
      <input type="text" id="name" name="name" required autocomplete="off" />
    </div>
    <div class="form-group">
      <label for="password">Password</label>
      <input type="password" id="password" name="password" required autocomplete="off" />
    </div>
    <button type="submit" class="btn-base" id="submit">Get Access</button>
    <div class="error" id="error"></div>
    <div class="success" id="success"></div>
  </form>
  <div class="footer-nav">
    <span>${CA_NAME}</span>
  </div>
</main>
</div>
<script>
const blobsData = Array.from({length: 6}, () => ({
  size: Math.random() * 200 + 150,
  left: Math.random() * 80 + 10,
  top: Math.random() * 80 + 10,
  animDelay: Math.random() * -20,
  duration: Math.random() * 15 + 15,
  dx: (Math.random() * 80 - 40) + 'px',
  dy: (Math.random() * 80 - 40) + 'px',
}));
const bg = document.getElementById('bg');
blobsData.forEach((d, i) => {
  const el = document.createElement('div');
  el.className = 'blob';
  el.style.width = d.size + 'px';
  el.style.height = d.size + 'px';
  el.style.left = d.left + '%';
  el.style.top = d.top + '%';
  el.style.animationDelay = d.animDelay + 's';
  el.style.animationDuration = d.duration + 's';
  el.style.setProperty('--dx', d.dx);
  el.style.setProperty('--dy', d.dy);
  bg.appendChild(el);
});
document.addEventListener('mousemove', (e) => {
  const x = (e.clientX / window.innerWidth - 0.5) * 80;
  const y = (e.clientY / window.innerHeight - 0.5) * 80;
  document.querySelectorAll('.blob').forEach((el, i) => {
    const speed = (i + 1) * 20;
    el.style.transform = 'translate(' + (x * speed) + 'px, ' + (y * speed) + 'px)';
  });
});
const form = document.getElementById('enroll-form');
form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('error');
  const successEl = document.getElementById('success');
  errorEl.textContent = '';
  successEl.textContent = '';
  const submit = document.getElementById('submit');
  submit.disabled = true;
  const name = document.getElementById('name').value.trim();
  const password = document.getElementById('password').value;
  try {
    const resp = await fetch('/api/enroll', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name, password}),
    });
    if (!resp.ok) {
      const j = await resp.json().catch(() => ({error: 'Request failed'}));
      if (j.error === 'Wrong password') errorEl.textContent = "That password didn't work.";
      else if (j.error === 'Invalid name') errorEl.textContent = 'Use letters and numbers only.';
      else errorEl.textContent = 'We could not get you a key.';
      submit.disabled = false;
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
    successEl.textContent = 'Saved. Open the .p12 file to install.';
  } catch (err) {
    errorEl.textContent = 'We could not get you a key.';
  } finally {
    submit.disabled = false;
  }
});
</script>
</body>
</html>`);
});

app.post('/api/enroll', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({error: 'Invalid request'}, 400); }
  const name = (body.name || '').trim();
  const password = body.password || '';

  if (!name) return c.json({error: 'Invalid name'}, 400);
  if (!/^[a-zA-Z0-9_-]{1,40}$/.test(name)) return c.json({error: 'Invalid name'}, 400);
  if (password !== HOUSEHOLD_PASSWORD) return c.json({error: 'Wrong password'}, 401);

  let acl = {};
  try { acl = JSON.parse(await readFile(ACL_PATH, 'utf8')); } catch { return c.json({error: 'ACL missing'}, 500); }
  const allowed = acl[name];
  if (!Array.isArray(allowed) || allowed.length === 0) return c.json({error: 'Not approved'}, 403);

  let issuedMap = {};
  try { issuedMap = JSON.parse(await readFile(ISSUED_PATH, 'utf8').catch(() => '{}')); } catch {}

  const tmp = await mkdtemp(join(tmpdir(), 'iss-enroll-'));
  const certPath = join(tmp, 'cert.pem');
  const keyPath = join(tmp, 'key.pem');
  const p12Path = join(tmp, 'bundle.p12');

  try {
    await execFileP(STEP, [
      'ca', 'certificate', name,
      certPath, keyPath,
      '--provisioner', 'admin',
      '--provisioner-password-file', STEPPATH_FILE,
      '--san', ...allowed,
      '--san', CA_IP,
      '--not-after', '2160h',
    ], { env: { ...process.env, STEPPATH } });

    const certPEM = await readFile(certPath, 'utf8');
    const intermediatePEM = await readFile(`${ISS_CONFIG_DIR}/dynamic/intermediate_ca.crt`, 'utf8');
    const chainPath = join(tmp, 'chain.pem');
    await writeFile(chainPath, certPEM + '\n' + intermediatePEM);

    await execFileP('openssl', [
      'pkcs12', '-export',
      '-out', p12Path,
      '-inkey', keyPath,
      '-in', certPath,
      '-certfile', chainPath,
      '-password', `pass:${P12_PASSWORD}`,
      '-name', name,
    ]);

    const p12 = await readFile(p12Path);

    // Mark issued.
    issuedMap[name] = Date.now();
    try {
      await mkdir(join(ISSUED_PATH, '..'), {recursive: true});
      await writeFile(ISSUED_PATH, JSON.stringify(issuedMap, null, 2));
    } catch {}

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
    return c.json({error: err.stderr ? err.stderr.toString() : 'Server error'}, 500);
  } finally {
    await rm(tmp, {recursive: true, force: true}).catch(() => {});
  }
});

app.notFound((c) => c.html('<h1 style="color:white;background:black;padding:40px;font-family:monospace">404 — Not here.</h1>', 404));

serve({fetch: app.fetch, port: PORT, hostname: '127.0.0.1'}, (info) => {
  console.log(`${CA_HOSTNAME}-enroll listening on http://127.0.0.1:${info.port}`);
});
