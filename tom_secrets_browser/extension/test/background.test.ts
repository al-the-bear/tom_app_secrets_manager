// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The background (part-browser): a list opened for the sender's own frame
// (its address from the browser, never from the page), answered only to the
// extension's list page for its token; the fill sent to that one frame; the
// service's states; a login form in a frame of another site; the popup.
// Demo data only.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import { Background } from '../src/background';
import type { ListAnswer } from '../src/messages';
import { contentSender, FakeHost, fakeApi, pageSender } from './fakes';

const mail = {
  entryId: 'team/~0123456789abcdef0123456789abcdef',
  title: 'Mail',
  userName: 'demo-user',
  matchedUrl: 'https://mail.example.com',
  hasTotp: true,
};

function hostFor(state = 'running') {
  return new FakeHost((r) => {
    switch (r.op) {
      case 'status':
        return { state };
      case 'match':
        return {
          candidates:
            new URL(String(r.url)).hostname === 'mail.example.com' ? [mail] : [],
        };
      case 'fill':
        return { userName: 'demo-user', password: 'demo-mail-pw', totp: r.totp ? '123456' : undefined };
      case 'openApp':
        return { opened: true };
      default:
        return { error: { kind: 'malformed', message: 'no' } };
    }
  });
}

function setUp(state = 'running') {
  const host = hostFor(state);
  const api = fakeApi({ activeTab: { id: 7, url: 'https://mail.example.com/login' } });
  let n = 0;
  const bg = new Background(api, host.connect, () => 1000, () => `token-${++n}`);
  return { host, api, bg };
}

test('a list for the sender\'s frame; the list page gets its logins, never a value', async () => {
  const { host, bg } = setUp();
  const opened = (await bg.handle(
    { op: 'tsm.openList', otpField: false },
    contentSender('https://mail.example.com/login'),
  )) as { token: string; listUrl: string };
  assert.equal(opened.token, 'token-1');
  assert.equal(opened.listUrl, 'chrome-extension://lcejninmlbnhfnpedlgjjfeelhbgmach/list.html#token-1');
  const list = (await bg.handle({ op: 'tsm.list', token: 'token-1' }, pageSender('list.html'))) as ListAnswer;
  assert.deepEqual(list.candidates, [mail]);
  assert.equal(list.state, 'running');
  assert.equal(list.site, 'mail.example.com');
  assert.deepEqual(
    host.requests.map((r) => r.op),
    ['status', 'match'],
  );
  assert.equal(host.requests[1].url, 'https://mail.example.com/login');
  assert.equal(JSON.stringify(list).includes('demo-mail-pw'), false);
});

test('a page or another sender cannot read a list or fill', async () => {
  const { bg, host } = setUp();
  await bg.handle({ op: 'tsm.openList' }, contentSender('https://mail.example.com/'));
  // A content script claiming to be the list.
  const asPage = (await bg.handle(
    { op: 'tsm.list', token: 'token-1' },
    contentSender('https://evil.example.net/'),
  )) as { error?: { kind: string } };
  assert.equal(asPage.error?.kind, 'denied');
  const fill = (await bg.handle(
    { op: 'tsm.fill', token: 'token-1', entryId: mail.entryId },
    contentSender('https://mail.example.com/'),
  )) as { error?: { kind: string } };
  assert.equal(fill.error?.kind, 'denied');
  // An unknown token.
  const unknown = (await bg.handle({ op: 'tsm.list', token: 'nope' }, pageSender('list.html'))) as {
    error?: { kind: string };
  };
  assert.equal(unknown.error?.kind, 'denied');
  assert.equal(host.requests.length, 0);
  // A non-web frame gets no list.
  const file = (await bg.handle({ op: 'tsm.openList' }, contentSender('file:///x.html'))) as {
    error?: unknown;
  };
  assert.ok(file.error);
});

test('the fill goes to the one frame the list was opened for, with the TOTP when it has a field', async () => {
  const { bg, api, host } = setUp();
  await bg.handle(
    { op: 'tsm.openList', otpField: true },
    contentSender('https://mail.example.com/frame', 4, 'https://mail.example.com/'),
  );
  const answer = (await bg.handle(
    { op: 'tsm.fill', token: 'token-1', entryId: mail.entryId },
    pageSender('list.html'),
  )) as { filled?: boolean };
  assert.equal(answer.filled, true);
  const fill = host.requests.find((r) => r.op === 'fill')!;
  assert.equal(fill.url, 'https://mail.example.com/');
  assert.equal(fill.frameUrl, 'https://mail.example.com/frame');
  assert.equal(fill.totp, true);
  assert.deepEqual(api.sentToTabs, [
    {
      tabId: 7,
      frameId: 4,
      message: {
        op: 'tsm.doFill',
        token: 'token-1',
        values: { userName: 'demo-user', password: 'demo-mail-pw', totp: '123456' },
      },
    },
  ]);
  // The token is spent.
  const again = (await bg.handle(
    { op: 'tsm.fill', token: 'token-1', entryId: mail.entryId },
    pageSender('list.html'),
  )) as { error?: unknown };
  assert.ok(again.error);
});

test('locked and not running say so; unlock waits for the service', async () => {
  for (const state of ['locked', 'not_running']) {
    const { bg } = setUp(state);
    await bg.handle({ op: 'tsm.openList' }, contentSender('https://mail.example.com/'));
    const list = (await bg.handle({ op: 'tsm.list', token: 'token-1' }, pageSender('list.html'))) as ListAnswer;
    assert.equal(list.state, state);
    assert.deepEqual(list.candidates, []);
  }
  const { bg, host } = setUp('locked');
  await bg.handle({ op: 'tsm.openList' }, contentSender('https://mail.example.com/'));
  await bg.handle({ op: 'tsm.list', token: 'token-1', unlock: true }, pageSender('list.html'));
  const waiting = host.requests.find((r) => r.op === 'match');
  assert.equal(waiting?.wait, true);
});

test('no host installed: the list says how to install it', async () => {
  const { bg, host } = setUp();
  host.unreachable = true;
  await bg.handle({ op: 'tsm.openList' }, contentSender('https://mail.example.com/'));
  const list = (await bg.handle({ op: 'tsm.list', token: 'token-1' }, pageSender('list.html'))) as ListAnswer;
  assert.equal(list.state, 'unreachable');
  assert.match(list.error!.message, /Settings › Integrations › Browsers/);
});

test('a form in a frame of another site: offered, then the frame\'s own logins', async () => {
  const { bg, host } = setUp();
  await bg.handle(
    { op: 'tsm.openList' },
    contentSender('https://mail.example.com/embedded', 2, 'https://shop.example.org/'),
  );
  const first = (await bg.handle({ op: 'tsm.list', token: 'token-1' }, pageSender('list.html'))) as ListAnswer;
  // The service matched the frame as part of the page: nothing (another site).
  assert.equal(host.requests[1].url, 'https://shop.example.org/');
  assert.equal(host.requests[1].frameUrl, 'https://mail.example.com/embedded');
  assert.equal(first.crossSite, 'mail.example.com');
  assert.deepEqual(first.candidates, []);
  const second = (await bg.handle(
    { op: 'tsm.list', token: 'token-1', frameSite: true },
    pageSender('list.html'),
  )) as ListAnswer;
  assert.deepEqual(second.candidates, [mail]);
  assert.equal(second.site, 'mail.example.com');
  await bg.handle({ op: 'tsm.fill', token: 'token-1', entryId: mail.entryId }, pageSender('list.html'));
  const fill = host.requests.find((r) => r.op === 'fill')!;
  assert.equal(fill.url, 'https://mail.example.com/embedded');
  assert.equal(fill.frameUrl, undefined);
});

test('the list closes from the list or from its own frame only', async () => {
  const { bg, api } = setUp();
  await bg.handle({ op: 'tsm.openList' }, contentSender('https://mail.example.com/', 0));
  const other = (await bg.handle(
    { op: 'tsm.close', token: 'token-1' },
    contentSender('https://mail.example.com/', 5),
  )) as { error?: unknown };
  assert.ok(other.error);
  const own = (await bg.handle(
    { op: 'tsm.close', token: 'token-1' },
    contentSender('https://mail.example.com/', 0),
  )) as { closed?: boolean };
  assert.equal(own.closed, true);
  assert.deepEqual(api.sentToTabs.at(-1)?.message, { op: 'tsm.closeList', token: 'token-1' });
});

test('the popup: the active tab\'s logins, a fill into its top frame', async () => {
  const { bg, api } = setUp();
  const popup = (await bg.handle({ op: 'tsm.popup' }, pageSender('popup.html'))) as ListAnswer & {
    token: string;
  };
  assert.deepEqual(popup.candidates, [mail]);
  await bg.handle({ op: 'tsm.fill', token: popup.token, entryId: mail.entryId }, pageSender('popup.html'));
  assert.equal(api.sentToTabs.at(-1)?.frameId, 0);
  const refused = (await bg.handle({ op: 'tsm.popup' }, pageSender('list.html'))) as {
    error?: unknown;
  };
  assert.ok(refused.error);
});

test('the copy of a code reads only the TOTP for the list', async () => {
  const { bg } = setUp();
  await bg.handle({ op: 'tsm.openList', otpField: false }, contentSender('https://mail.example.com/'));
  const a = (await bg.handle(
    { op: 'tsm.totp', token: 'token-1', entryId: mail.entryId },
    pageSender('list.html'),
  )) as Record<string, unknown>;
  assert.deepEqual(a, { totp: '123456' });
});
