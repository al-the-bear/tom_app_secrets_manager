// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The manifests per family (part-browser): Chromium's service worker and
// key, Firefox's background script and gecko id; the permissions DP-45
// names; the shortcut; the list page web-accessible; no remote code.

import { strict as assert } from 'node:assert';
import { createHash } from 'node:crypto';
import { test } from 'node:test';

import { chromiumDevelopmentKey, firefoxExtensionId, manifest } from '../src/manifest';

test('Chromium: a service worker and the key that fixes the development id', () => {
  const m = manifest('chromium', '0.1.0');
  assert.equal(m.manifest_version, 3);
  assert.deepEqual(m.background, { service_worker: 'background.js' });
  assert.equal(m.key, chromiumDevelopmentKey);
  const hex = createHash('sha256')
    .update(Buffer.from(chromiumDevelopmentKey, 'base64'))
    .digest('hex')
    .slice(0, 32);
  const id = [...hex].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
  assert.equal(id, 'lcejninmlbnhfnpedlgjjfeelhbgmach');
  assert.equal(m.browser_specific_settings, undefined);
});

test('Firefox: a background script and the gecko id, no key', () => {
  const m = manifest('firefox', '0.1.0');
  assert.deepEqual(m.background, { scripts: ['background.js'] });
  assert.equal(m.key, undefined);
  assert.deepEqual(m.browser_specific_settings, {
    gecko: { id: firefoxExtensionId, strict_min_version: '128.0' },
  });
});

test('the permissions, the content scripts in every frame, the shortcut, the list page', () => {
  const m = manifest('chromium', '1.2.3') as Record<string, any>;
  assert.equal(m.version, '1.2.3');
  assert.deepEqual(m.permissions, ['nativeMessaging', 'activeTab', 'scripting', 'storage', 'contextMenus']);
  assert.deepEqual(m.host_permissions, ['<all_urls>']);
  assert.equal(m.content_scripts[0].all_frames, true);
  assert.deepEqual(m.content_scripts[0].matches, ['http://*/*', 'https://*/*']);
  // Passkeys (DP-120): the page-world script in every frame from its start
  // (`world: "MAIN"`: Chrome 111, Firefox 128).
  assert.deepEqual(m.content_scripts[1], {
    matches: ['http://*/*', 'https://*/*'],
    js: ['webauthn.js'],
    all_frames: true,
    run_at: 'document_start',
    world: 'MAIN',
  });
  assert.equal(m.minimum_chrome_version, '111');
  assert.equal(m.commands['open-list'].suggested_key.mac, 'Command+Shift+L');
  assert.ok(m.web_accessible_resources[0].resources.includes('list.html'));
  // Manifest V3: no remote code, no content_security_policy loosening.
  assert.equal(m.content_security_policy, undefined);
});
