// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The browser extension's screenshots for its guide
// (`tom_secrets_browser/doc/images/<screen>-<state>-light.png`), made with
// demo data in headless Chromium (Playwright):
//
// - the screenshot build: the Chromium build (`dist/chromium`, from
//   `npm run build`), its background the tests' fake host answering demo
//   logins (tool/screenshot_background.ts);
// - a demo login page served on 127.0.0.1 (tool/demo_login.html);
// - the in-page list opened by the icon at the user-name field, the save
//   bar after signing in with a login the vaults do not hold, and the popup.
//
//   npm run build && npm run screenshots
//
// Needs Playwright's Chromium (`npx playwright install chromium`).

import { build } from 'esbuild';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdtempSync } from 'node:fs';
import { chromium } from 'playwright';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const images = join(root, '..', 'doc', 'images');
const dist = join(root, 'dist', 'chromium');
if (!existsSync(join(dist, 'manifest.json'))) {
  process.stderr.write('build the extension first: npm run build\n');
  process.exit(2);
}

// The demo site.
const page = readFileSync(join(root, 'tool', 'demo_login.html'), 'utf8');
const welcome = page
  .replace(/<main>[\s\S]*<\/main>/, '<main><h1>Welcome, demo user</h1><p>You are signed in.</p></main>')
  .replace('Sign in</title>', 'Inbox</title>');
const server = createServer((req, res) => {
  res.setHeader('content-type', 'text/html; charset=utf-8');
  res.end(req.url?.startsWith('/welcome') ? welcome : page);
});
await new Promise((ready) => server.listen(0, '127.0.0.1', ready));
const origin = `http://127.0.0.1:${server.address().port}`;

// The screenshot build.
const work = mkdtempSync(join(tmpdir(), 'tsmshots-'));
const ext = join(work, 'extension');
cpSync(dist, ext, { recursive: true });
await build({
  entryPoints: [join(root, 'tool', 'screenshot_background.ts')],
  bundle: true,
  format: 'iife',
  target: 'chrome111',
  outfile: join(ext, 'background.js'),
  define: { TSM_DEMO_ORIGIN: JSON.stringify(origin) },
  logLevel: 'warning',
});

const context = await chromium.launchPersistentContext(join(work, 'profile'), {
  channel: 'chromium',
  headless: true,
  viewport: { width: 1100, height: 680 },
  // At a scale above 1, headless Chromium lays the extension's own frames
  // (the list, the bar: frames of another process) out at a fraction of
  // their width; at 1 they are drawn as the browser shows them.
  deviceScaleFactor: 1,
  args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`],
});
const written = [];
try {
  let [worker] = context.serviceWorkers();
  worker ??= await context.waitForEvent('serviceworker');
  const id = new URL(worker.url()).host;
  mkdirSync(images, { recursive: true });
  const shot = async (p, name, options = {}) => {
    const file = join(images, `${name}-light.png`);
    await p.screenshot({ path: file, ...options });
    written.push(file);
  };

  // The list at the user-name field, opened by its icon.
  const login = await context.newPage();
  await login.goto(`${origin}/`);
  await login.focus('#user');
  await login.waitForTimeout(600);
  const field = await login.locator('#user').boundingBox();
  await login.mouse.click(field.x + field.width - 6 - 9, field.y + field.height / 2);
  await login.waitForTimeout(1200);
  await shot(login, 'list-logins');

  // The save bar after signing in with a login the vaults do not hold.
  const save = await context.newPage();
  await save.goto(`${origin}/`);
  await save.fill('#user', 'new-demo-user');
  await save.fill('#password', 'demo-new-password-1');
  await Promise.all([save.waitForURL('**/welcome'), save.click('button[type=submit]')]);
  await save.waitForTimeout(1500);
  await shot(save, 'bar-save');
  await save.close();

  // The popup, as a page of its own (its active tab: the demo page).
  await login.bringToFront();
  const popup = await context.newPage();
  await popup.setViewportSize({ width: 380, height: 420 });
  await popup.goto(`chrome-extension://${id}/popup.html`);
  await popup.waitForTimeout(1000);
  await shot(popup, 'popup-logins');
} finally {
  await context.close();
  server.close();
  rmSync(work, { recursive: true, force: true });
}
for (const file of written) process.stdout.write(`wrote ${file}\n`);
