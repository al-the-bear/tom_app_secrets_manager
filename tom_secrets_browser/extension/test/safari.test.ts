// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Safari (part-browser): its manifest (a service worker, Safari 17, no
// key, no page-world WebAuthn script) and its port to the host through the
// macOS app's handler, one session per port: the requests in order, the
// host's answers back, close ending the session, an unreachable app said.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import { HostFailure, HostSession } from '../src/host';
import { manifest } from '../src/manifest';
import { safariPort, safariUnreachableMessage } from '../src/safari';

test('Safari: a service worker, Safari 17, no key, no page-world script', () => {
  const m = manifest('safari', '0.1.0') as Record<string, any>;
  assert.deepEqual(m.background, { service_worker: 'background.js' });
  assert.equal(m.key, undefined);
  assert.deepEqual(m.browser_specific_settings, { safari: { strict_min_version: '17.0' } });
  assert.equal(m.minimum_chrome_version, undefined);
  assert.deepEqual(
    m.content_scripts.map((c: { js: string[] }) => c.js),
    [['content.js']],
  );
  assert.ok(m.permissions.includes('nativeMessaging'));
});

test('requests go to the handler as one session; the answers come back', async () => {
  const sent: unknown[] = [];
  const port = safariPort(async (message) => {
    sent.push(message);
    const m = message as { request?: { id: number; op: string } };
    if (m.request) return { answer: { id: m.request.id, status: 'unlocked' } };
    return { closed: true };
  }, 'demo-session');
  const session = new HostSession(port);
  const first = await session.request('status');
  const second = await session.request('status');
  assert.equal(first.status, 'unlocked');
  assert.equal(second.id, 2);
  session.close();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent, [
    { session: 'demo-session', request: { id: 1, op: 'status' } },
    { session: 'demo-session', request: { id: 2, op: 'status' } },
    { session: 'demo-session', close: true },
  ]);
});

test('the host\'s refusal comes through as the host\'s error', async () => {
  const port = safariPort(async (message) => {
    const m = message as { request: { id: number } };
    return { answer: { id: m.request.id, error: { kind: 'locked', message: 'locked' } } };
  });
  const session = new HostSession(port);
  await assert.rejects(session.request('match', { url: 'https://example.com/' }), (e: Error) => {
    assert.ok(e instanceof HostFailure);
    assert.equal((e as HostFailure).error.kind, 'locked');
    return true;
  });
});

test('an app that cannot be reached is said, and the port ends', async () => {
  let ended = false;
  const port = safariPort(async () => {
    throw new Error('no handler');
  });
  port.onDisconnect.addListener(() => {
    ended = true;
  });
  const session = new HostSession(port);
  await assert.rejects(session.request('status'), (e: Error) => {
    assert.ok(e instanceof HostFailure);
    assert.equal((e as HostFailure).error.message, safariUnreachableMessage);
    return true;
  });
  assert.ok(ended);
  assert.throws(() => port.postMessage({ id: 9 }));
});
