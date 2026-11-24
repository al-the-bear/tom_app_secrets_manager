// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The browser extension's screenshots for its guide
// (`tom_secrets_browser/doc/images/<screen>-<state>-light.png`), made with
// demo data in headless Chromium (Playwright):
//
// - the screenshot build: the Chromium build (`dist/chromium`, from
//   `npm run build`), its background the tests' fake host answering demo
//   logins and passkeys, in the state the demo page's path names
//   (tool/screenshot_background.ts);
// - demo pages served on 127.0.0.1 (the demo mail, from
//   tool/demo_login.html) and on localhost (the demo single sign-on);
// - the shots:
//   - shield-field: the login form with the icons in its fields;
//   - list-logins: the list opened by the icon at the user-name field;
//   - list-locked, list-notrunning, list-nohost: the list with the service
//     locked, not running, and no host installed;
//   - list-asking: the list while the app is asked to approve the browser;
//   - list-suggest: a sign-up form's new-password field, a suggested password;
//   - list-frame, list-frame-logins: a login form in a frame of another
//     site, the list offering the frame's own logins, then showing them;
//   - passkey-list: a page's passkey sign-in, the list of its passkeys;
//   - bar-save, bar-saved, bar-update: the save bar after signing in with a
//     new login, after Save, and for a changed password;
//   - popup-logins, popup-locked, popup-never: the popup with the logins,
//     with the service locked, and with saving turned off for the site.
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

// The demo site, on two origins: 127.0.0.1 (the demo mail, whose logins the
// fake host holds; its paths /locked, /notrunning, /nohost and /asking set
// the host's state, tool/screenshot_background.ts) and localhost (the demo
// single sign-on: a login form in a frame of the mail's portal page, and a
// passkey sign-in, which WebAuthn allows on http only for localhost).
const page = readFileSync(join(root, 'tool', 'demo_login.html'), 'utf8');
const withMain = (main, title, header) =>
  page
    .replace(/<main>[\s\S]*<\/main>/, `<main>${main}</main>`)
    .replace('Demo Mail — Sign in</title>', `${title}</title>`)
    .replace('<header>Demo Mail</header>', `<header>${header}</header>`);
const pages = {
  welcome: withMain(
    '<h1>Welcome, demo user</h1><p>You are signed in.</p>',
    'Demo Mail — Inbox',
    'Demo Mail',
  ),
  signup: withMain(
    `<h1>Create your account</h1>
  <form id="signup" method="post" action="/welcome">
    <label for="user">Email</label>
    <input id="user" name="user" type="email" autocomplete="username" value="new-demo-user@example.org">
    <label for="new-password">Password</label>
    <input id="new-password" name="password" type="password" autocomplete="new-password">
    <label for="confirm-password">Repeat the password</label>
    <input id="confirm-password" name="confirm" type="password" autocomplete="new-password">
    <button type="submit">Create account</button>
  </form>`,
    'Demo Mail — Create your account',
    'Demo Mail',
  ),
  // The portal page holds the single sign-on's form in a frame (its src
  // set below, once the port is known).
  portal: withMain(
    `<h1>Demo portal</h1>
  <p>Sign in with the demo single sign-on:</p>
  <iframe id="sso" title="Demo single sign-on" src="FRAME_ORIGIN/sso"
    style="width:100%;height:470px;border:1px solid #c4ccd5;border-radius:6px"></iframe>`,
    'Demo Portal',
    'Demo Portal',
  ).replace('max-width: 380px; margin: 56px auto', 'max-width: 420px; margin: 24px auto'),
  sso: page
    .replace('<header>Demo Mail</header>', '')
    .replace('<h1>Sign in</h1>', '<h1>Demo single sign-on</h1>')
    .replace('max-width: 380px; margin: 56px auto', 'max-width: 340px; margin: 0 auto')
    .replace('box-shadow: 0 1px 4px rgba(0,0,0,.12);', '')
    .replace('Demo Mail — Sign in</title>', 'Demo single sign-on</title>'),
  passkey: withMain(
    `<h1>Sign in</h1>
  <p>Sign in to the demo single sign-on without a password.</p>
  <button id="passkey" type="button">Sign in with a passkey</button>
  <p id="outcome"></p>
  <script>
    document.getElementById('passkey').addEventListener('click', async () => {
      const outcome = document.getElementById('outcome');
      try {
        const credential = await navigator.credentials.get({
          publicKey: { challenge: crypto.getRandomValues(new Uint8Array(32)), rpId: 'localhost' },
        });
        outcome.textContent = credential ? 'Signed in with a passkey.' : 'No passkey.';
      } catch (e) {
        outcome.textContent = String(e);
      }
    });
  </script>`,
    'Demo single sign-on — Sign in',
    'Demo single sign-on',
  ),
};
const server = createServer((req, res) => {
  res.setHeader('content-type', 'text/html; charset=utf-8');
  const segment = (req.url ?? '/').split(/[/?#]/)[1];
  const html = pages[segment] ?? page;
  res.end(html.replaceAll('FRAME_ORIGIN', frameOrigin));
});
await new Promise((ready) => server.listen(0, '127.0.0.1', ready));
const { port } = server.address();
const origin = `http://127.0.0.1:${port}`;
const frameOrigin = `http://localhost:${port}`;

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
  define: {
    TSM_DEMO_ORIGIN: JSON.stringify(origin),
    TSM_FRAME_ORIGIN: JSON.stringify(frameOrigin),
  },
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
  args: [
    `--disable-extensions-except=${ext}`,
    `--load-extension=${ext}`,
    // localhost is the server's 127.0.0.1 (not ::1, where nothing listens).
    `--host-resolver-rules=MAP localhost 127.0.0.1`,
  ],
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

  /** The frame of the extension's page [name] (list.html, bar.html) in [p]. */
  const extensionFrame = async (p, name) => {
    for (let i = 0; i < 50; i++) {
      const f = p.frames().find((x) => x.url().startsWith(`chrome-extension://${id}/${name}`));
      if (f) return f;
      await p.waitForTimeout(100);
    }
    throw new Error(`no ${name} in ${p.url()}`);
  };
  /** Clicks the shield icon at the right edge of [field] (a locator). */
  const clickIcon = async (p, field) => {
    const box = await field.boundingBox();
    await p.mouse.click(box.x + box.width - 6 - 9, box.y + box.height / 2);
  };
  /** A demo page at [path] with the list opened by the icon at [selector]. */
  const listAt = async (path, selector = '#user', base = origin) => {
    const p = await context.newPage();
    await p.goto(`${base}${path}`);
    await p.waitForTimeout(600);
    await clickIcon(p, p.locator(selector));
    await p.waitForTimeout(1200);
    return p;
  };

  // The login page before anything is opened: the icons in its fields.
  const fields = await context.newPage();
  await fields.goto(`${origin}/`);
  await fields.waitForTimeout(800);
  const form = await fields.locator('main').boundingBox();
  await shot(fields, 'shield-field', {
    clip: { x: form.x - 24, y: form.y - 24, width: form.width + 48, height: form.height + 48 },
  });
  await fields.close();

  // The list at the user-name field, opened by its icon.
  const login = await listAt('/');
  await shot(login, 'list-logins');

  // The list in the service's other states.
  for (const [path, state] of [
    ['/locked', 'list-locked'],
    ['/notrunning', 'list-notrunning'],
    ['/nohost', 'list-nohost'],
    ['/asking', 'list-asking'],
  ]) {
    const p = await listAt(path);
    await shot(p, state);
    await p.close();
  }

  // A suggested password at a sign-up form's new-password field.
  const signup = await listAt('/signup', '#new-password');
  await shot(signup, 'list-suggest');
  await signup.close();

  // A login form in a frame of another site: the list offers the frame's
  // own logins, then shows them.
  const portal = await context.newPage();
  await portal.goto(`${origin}/portal`);
  await portal.waitForTimeout(800);
  await clickIcon(portal, portal.frameLocator('#sso').locator('#user'));
  await portal.waitForTimeout(1200);
  await shot(portal, 'list-frame');
  await (await extensionFrame(portal, 'list.html')).click('#tsm-frame-site');
  await portal.waitForTimeout(1000);
  await shot(portal, 'list-frame-logins');
  await portal.close();

  // A passkey sign-in: the list of the page's passkeys at the top right.
  const passkey = await context.newPage();
  await passkey.goto(`${frameOrigin}/passkey`);
  await passkey.waitForTimeout(600);
  await passkey.click('#passkey');
  await passkey.waitForTimeout(1200);
  await shot(passkey, 'passkey-list');
  await passkey.close();

  // The save bar after signing in with a login the vaults do not hold, the
  // bar after Save, and the bar for a changed password.
  const signIn = async (user, password) => {
    const p = await context.newPage();
    await p.goto(`${origin}/`);
    await p.fill('#user', user);
    await p.fill('#password', password);
    await Promise.all([p.waitForURL('**/welcome'), p.click('button[type=submit]')]);
    await p.waitForTimeout(1500);
    return p;
  };
  const save = await signIn('new-demo-user', 'demo-new-password-1');
  await shot(save, 'bar-save');
  await (await extensionFrame(save, 'bar.html')).click('#tsm-bar-save');
  await save.waitForTimeout(600);
  await shot(save, 'bar-saved');
  await save.close();
  const changed = await signIn('demo-user', 'demo-changed-password-2');
  await shot(changed, 'bar-update');
  await changed.close();

  // The popup, as a page of its own; its active tab the demo page opened
  // last: the logins, the service locked, and after "Never for this site".
  const popupFor = async (path) => {
    const tab = await context.newPage();
    await tab.goto(`${origin}${path}`);
    await tab.waitForTimeout(400);
    const popup = await context.newPage();
    await popup.setViewportSize({ width: 380, height: 420 });
    await popup.goto(`chrome-extension://${id}/popup.html`);
    await popup.waitForTimeout(1000);
    return { tab, popup };
  };
  await login.close();
  const logins = await popupFor('/');
  await shot(logins.popup, 'popup-logins');
  await logins.popup.close();
  await logins.tab.close();
  const locked = await popupFor('/locked');
  await shot(locked.popup, 'popup-locked');
  await locked.popup.close();
  await locked.tab.close();
  const never = await popupFor('/');
  await never.popup.click('#tsm-never-toggle input');
  await never.popup.waitForTimeout(300);
  await never.popup.reload();
  await never.popup.waitForTimeout(1000);
  await shot(never.popup, 'popup-never');
} finally {
  await context.close();
  server.close();
  rmSync(work, { recursive: true, force: true });
}
for (const file of written) process.stdout.write(`wrote ${file}\n`);
