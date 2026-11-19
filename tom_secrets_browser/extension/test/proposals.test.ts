// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Proposing a login (part-browser, DP-43): a submitted login the vaults hold
// brings no bar; a new one or a changed password brings "Save in Tom
// Secrets Manager?" in the tab's top frame, also on the page the form led
// to; the bar learns the site and user, never the password; Save proposes
// it, Not now drops it, Never for this site keeps the site off (and the
// popup turns it on again); a closed tab or the lifetime forgets the
// password. The suggested password of a new-password field goes to the
// list's frame only. Demo data only.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import { Background, neverSitesKey, proposalLifetimeMs } from '../src/background';
import type { BarAnswer, ListAnswer } from '../src/messages';
import { contentSender, FakeHost, fakeApi, pageSender } from './fakes';

const page = 'https://mail.example.com/login';

function setUp(check: Record<string, unknown> = { state: 'new' }, propose: Record<string, unknown> = { accepted: true, known: false }) {
  const host = new FakeHost((r) => {
    if (r.op === 'check') return check;
    if (r.op === 'propose') return propose;
    return { error: { kind: 'malformed', message: 'no' } };
  });
  const api = fakeApi({ activeTab: { id: 7, url: page } });
  let n = 0;
  let now = 1000;
  const bg = new Background(api, host.connect, () => now, () => `token-${++n}`);
  bg.install();
  return { host, api, bg, advance: (ms: number) => (now += ms) };
}

const captured = {
  op: 'tsm.captured' as const,
  userName: 'demo-user',
  password: 'demo-new-pw',
  change: false,
  title: 'Mail sign-in',
};

test('a new login: the host is asked, the bar shown in the top frame, '
  + 'the bar learns no password; Save proposes it', async () => {
  const { bg, host, api } = setUp();
  const answer = (await bg.handle(captured, contentSender(page, 4, page))) as { bar?: boolean };
  assert.equal(answer.bar, true);
  assert.deepEqual(
    { ...host.requests[0], id: undefined },
    { id: undefined, op: 'check', url: page, userName: 'demo-user', password: 'demo-new-pw' },
  );
  const shown = api.sentToTabs.at(-1)!;
  assert.equal(shown.frameId, 0, 'the bar is the top frame\'s');
  assert.deepEqual(shown.message, {
    op: 'tsm.showBar',
    token: 'token-1',
    barUrl: 'chrome-extension://lcejninmlbnhfnpedlgjjfeelhbgmach/bar.html#token-1',
  });
  const bar = (await bg.handle({ op: 'tsm.bar', token: 'token-1' }, pageSender('bar.html'))) as BarAnswer;
  assert.deepEqual(bar, { site: 'mail.example.com', userName: 'demo-user', state: 'new' });
  assert.equal(JSON.stringify(bar).includes('demo-new-pw'), false);
  // Only the bar page may ask.
  const page2 = (await bg.handle({ op: 'tsm.bar', token: 'token-1' }, contentSender(page))) as {
    error?: unknown;
  };
  assert.ok(page2.error);
  const saved = (await bg.handle(
    { op: 'tsm.barAnswer', token: 'token-1', answer: 'save' },
    pageSender('bar.html'),
  )) as { proposed?: boolean };
  assert.equal(saved.proposed, true);
  const proposed = host.requests.find((r) => r.op === 'propose')!;
  assert.equal(proposed.url, page);
  assert.equal(proposed.userName, 'demo-user');
  assert.equal(proposed.password, 'demo-new-pw');
  assert.equal(proposed.title, 'Mail sign-in');
  // The password is gone: the bar's token answers nothing but its close.
  const gone = (await bg.handle({ op: 'tsm.bar', token: 'token-1' }, pageSender('bar.html'))) as {
    error?: unknown;
  };
  assert.ok(gone.error);
  await bg.handle({ op: 'tsm.barAnswer', token: 'token-1', answer: 'close' }, pageSender('bar.html'));
  assert.deepEqual(api.sentToTabs.at(-1)?.message, { op: 'tsm.closeBar', token: 'token-1' });
});

test('a login the vaults hold brings no bar; a changed password is said '
  + 'so, with the user name the host found for a change form', async () => {
  const known = setUp({ state: 'known', entryId: 'team/~01' });
  assert.deepEqual(await known.bg.handle(captured, contentSender(page)), { ignored: 'known' });
  assert.equal(known.api.sentToTabs.length, 0);

  const changed = setUp({ state: 'changed', entryId: 'team/~01', userName: 'demo-user' });
  await changed.bg.handle({ ...captured, userName: undefined, change: true }, contentSender(page));
  const bar = (await changed.bg.handle(
    { op: 'tsm.bar', token: 'token-1' },
    pageSender('bar.html'),
  )) as BarAnswer;
  assert.deepEqual(bar, { site: 'mail.example.com', userName: 'demo-user', state: 'changed' });
});

test('the page the form led to shows the waiting bar; a closed tab and the '
  + 'lifetime forget the password', async () => {
  const { bg, api, advance } = setUp();
  await bg.handle(captured, contentSender(page));
  // The next page's top frame asks; a subframe gets nothing.
  assert.deepEqual(
    await bg.handle({ op: 'tsm.barPending' }, contentSender('https://mail.example.com/inbox')),
    {
      token: 'token-1',
      barUrl: 'chrome-extension://lcejninmlbnhfnpedlgjjfeelhbgmach/bar.html#token-1',
    },
  );
  assert.equal(
    await bg.handle({ op: 'tsm.barPending' }, contentSender('https://ads.example.net/', 2)),
    null,
  );
  advance(proposalLifetimeMs + 1);
  assert.equal(await bg.handle({ op: 'tsm.barPending' }, contentSender(page)), null);

  await bg.handle(captured, contentSender(page));
  api.closeTab(7);
  assert.equal(await bg.handle({ op: 'tsm.barPending' }, contentSender(page)), null);
});

test('Not now drops it; Never for this site keeps the site off until the '
  + 'popup turns it on again', async () => {
  const { bg, api, host } = setUp();
  await bg.handle(captured, contentSender(page));
  await bg.handle({ op: 'tsm.barAnswer', token: 'token-1', answer: 'notNow' }, pageSender('bar.html'));
  assert.deepEqual(api.sentToTabs.at(-1)?.message, { op: 'tsm.closeBar', token: 'token-1' });
  assert.equal(host.requests.some((r) => r.op === 'propose'), false);

  await bg.handle(captured, contentSender(page));
  await bg.handle({ op: 'tsm.barAnswer', token: 'token-2', answer: 'never' }, pageSender('bar.html'));
  assert.deepEqual(api.stored[neverSitesKey], ['mail.example.com']);
  const checks = host.requests.filter((r) => r.op === 'check').length;
  assert.deepEqual(await bg.handle(captured, contentSender(page)), { ignored: 'never' });
  assert.equal(host.requests.filter((r) => r.op === 'check').length, checks, 'nothing asked');

  const popup = (await bg.handle({ op: 'tsm.popup' }, pageSender('popup.html'))) as ListAnswer;
  assert.equal(popup.never, true);
  await bg.handle({ op: 'tsm.never', never: false }, pageSender('popup.html'));
  assert.deepEqual(api.stored[neverSitesKey], []);
  const refused = (await bg.handle({ op: 'tsm.never', never: true }, contentSender(page))) as {
    error?: unknown;
  };
  assert.ok(refused.error, 'only the popup turns it');
});

test('Save refused by the service: the bar says why', async () => {
  const { bg } = setUp(
    { state: 'new' },
    { error: { kind: 'denied', message: 'propose is not for this client', reason: 'not_allowed_op' } },
  );
  await bg.handle(captured, contentSender(page));
  const answer = (await bg.handle(
    { op: 'tsm.barAnswer', token: 'token-1', answer: 'save' },
    pageSender('bar.html'),
  )) as { error?: { kind: string } };
  assert.equal(answer.error?.kind, 'denied');
});

test('a new-password field: the list suggests, the password goes to that '
  + 'frame only', async () => {
  const { bg, api, host } = setUp();
  await bg.handle(
    { op: 'tsm.openList', newPassword: true },
    contentSender('https://mail.example.com/settings', 5, 'https://mail.example.com/'),
  );
  const list = (await bg.handle({ op: 'tsm.list', token: 'token-1' }, pageSender('list.html'))) as ListAnswer;
  assert.equal(list.newPassword, true);
  assert.equal(host.requests.length, 0, 'nothing asked of the host');
  await bg.handle({ op: 'tsm.fillNew', token: 'token-1', password: 'Suggested-1!' }, pageSender('list.html'));
  assert.deepEqual(api.sentToTabs.at(-1), {
    tabId: 7,
    frameId: 5,
    message: { op: 'tsm.doFillNew', token: 'token-1', password: 'Suggested-1!' },
  });
  const again = (await bg.handle(
    { op: 'tsm.fillNew', token: 'token-1', password: 'x' },
    pageSender('list.html'),
  )) as { error?: unknown };
  assert.ok(again.error, 'the token is spent');
});
