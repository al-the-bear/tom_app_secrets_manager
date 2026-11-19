// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The page side (part-browser): form detection (user name by autocomplete,
// type, name and position; a split login; one-time-code fields; open shadow
// roots; hidden and read-only fields left), the fill with the events
// frameworks listen to and the one retry, the content script's list and its
// fill only for its own token, and the list view. Demo data only.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { JSDOM } from 'jsdom';

import { ContentScript } from '../src/content';
import { loginFields } from '../src/detect';
import { fillLogin } from '../src/fill';
import type { Candidate } from '../src/messages';
import { matchesFilter, renderList } from '../src/view';
import { fakeApi } from './fakes';

function dom(body: string): Document {
  return new JSDOM(`<!doctype html><body>${body}</body>`, { pretendToBeVisual: true }).window
    .document;
}

test('a login form: the user name before the password', () => {
  const d = dom(`<form>
      <input name="q" type="text">
      <input id="u" name="login" type="text">
      <input id="p" type="password">
    </form>`);
  const f = loginFields(d);
  assert.equal(f.userName?.id, 'u');
  assert.equal(f.password?.id, 'p');
  assert.equal(f.otp, undefined);
});

test('autocomplete wins; a change form fills the current password', () => {
  const d = dom(`<input id="e" autocomplete="username" type="text">
    <input id="new" type="password" autocomplete="new-password">
    <input id="cur" type="password" autocomplete="current-password">`);
  const f = loginFields(d);
  assert.equal(f.userName?.id, 'e');
  assert.equal(f.password?.id, 'cur');
  const signUp = loginFields(
    dom(`<input id="e" autocomplete="username"><input id="n" type="password" autocomplete="new-password">`),
  );
  assert.equal(signUp.password, undefined);
});

test('a split login (user name first), a one-time-code field, hidden fields left', () => {
  const split = loginFields(dom(`<input id="mail" type="email"><input type="hidden" name="x">`));
  assert.equal(split.userName?.id, 'mail');
  assert.equal(split.password, undefined);
  const otp = loginFields(
    dom(`<input id="code" autocomplete="one-time-code">
      <input id="gone" type="password" style="display:none">
      <input id="ro" type="password" readonly>`),
  );
  assert.equal(otp.otp?.id, 'code');
  assert.equal(otp.password, undefined);
});

test('fields inside an open shadow root are found', () => {
  const d = dom('<login-box></login-box>');
  const root = d.querySelector('login-box')!.attachShadow({ mode: 'open' });
  root.innerHTML = '<input id="u" autocomplete="username"><input id="p" type="password">';
  const f = loginFields(d);
  assert.equal(f.userName?.id, 'u');
  assert.equal(f.password?.id, 'p');
});

test('the fill sets the values with input and change events, and types again once when the page cleared a field', async () => {
  const d = dom('<input id="u" autocomplete="username"><input id="p" type="password">');
  const f = loginFields(d);
  const events: string[] = [];
  f.userName!.addEventListener('input', () => events.push('u:input'));
  f.userName!.addEventListener('change', () => events.push('u:change'));
  // A framework that clears a value it did not set itself, once.
  let cleared = false;
  f.password!.addEventListener('change', () => {
    if (!cleared) {
      cleared = true;
      setTimeout(() => (f.password!.value = ''), 0);
    }
  });
  const outcome = await fillLogin(f, { userName: 'demo-user', password: 'demo-pw' }, 30);
  assert.deepEqual(outcome, { userName: true, password: true, totp: false });
  assert.equal(f.userName!.value, 'demo-user');
  assert.equal(f.password!.value, 'demo-pw');
  assert.deepEqual(events.slice(0, 2), ['u:input', 'u:change']);
});

test('the content script opens a list at its field and fills only for its own token', async () => {
  const window = new JSDOM(
    '<!doctype html><body><input id="u" autocomplete="username"><input id="p" type="password"><input id="c" autocomplete="one-time-code"></body>',
    { pretendToBeVisual: true },
  ).window;
  const d = window.document;
  const sent: unknown[] = [];
  const api = fakeApi({
    onSend: (m) => {
      sent.push(m);
      return { token: 'tok', listUrl: 'chrome-extension://x/list.html#tok' };
    },
  });
  const script = new ContentScript(d, api);
  script.install();
  assert.equal(await script.openList(), true);
  assert.deepEqual(sent, [{ op: 'tsm.openList', otpField: true }]);
  assert.equal(d.querySelectorAll('tom-secrets-list').length, 1);

  const listener = api.messageListeners[0];
  const ask = (message: unknown) =>
    new Promise((resolve) => listener(message, {}, resolve));
  // Another token fills nothing.
  assert.equal(
    await ask({ op: 'tsm.doFill', token: 'other', values: { userName: 'x', password: 'y' } }),
    null,
  );
  assert.equal((d.getElementById('p') as HTMLInputElement).value, '');
  const outcome = await ask({
    op: 'tsm.doFill',
    token: 'tok',
    values: { userName: 'demo-user', password: 'demo-pw', totp: '123456' },
  });
  assert.deepEqual(outcome, { userName: true, password: true, totp: true });
  assert.equal((d.getElementById('c') as HTMLInputElement).value, '123456');
  assert.equal(d.querySelectorAll('tom-secrets-list').length, 0, 'the list closes after the fill');
});

test('a frame without a login field opens no list', async () => {
  const d = dom('<p>no form</p>');
  const sent: unknown[] = [];
  const script = new ContentScript(d, fakeApi({ onSend: (m) => sent.push(m) }));
  assert.equal(await script.openList(), false);
  assert.deepEqual(sent, []);
});

const candidates: Candidate[] = [
  { entryId: 'a/~1', title: 'Mail', userName: 'demo', matchedUrl: 'https://mail.example.com', hasTotp: true },
  { entryId: 'a/~2', title: 'Mail (work)', userName: 'work', matchedUrl: 'https://mail.example.com', hasTotp: false },
];

test('the view: the logins with Fill and Copy code; the states with what to do', () => {
  const d = dom('<main id="root"></main>');
  const root = d.getElementById('root')!;
  const did: string[] = [];
  const actions = {
    fill: (id: string) => did.push(`fill ${id}`),
    copyCode: (id: string) => did.push(`code ${id}`),
    unlock: () => did.push('unlock'),
    openApp: () => did.push('open'),
    frameSite: () => did.push('frame'),
  };
  renderList(root, { state: 'running', candidates, site: 'mail.example.com' }, actions);
  assert.equal(root.querySelectorAll('li.candidate').length, 2);
  (root.querySelector('#tsm-fill-a\\/\\~1') as HTMLButtonElement).click();
  (root.querySelector('#tsm-totp-a\\/\\~1') as HTMLButtonElement).click();
  assert.equal(root.querySelector('#tsm-totp-a\\/\\~2'), null);
  assert.deepEqual(did, ['fill a/~1', 'code a/~1']);

  renderList(root, { state: 'locked', candidates: [], site: 's' }, actions);
  (root.querySelector('#tsm-unlock') as HTMLButtonElement).click();
  renderList(root, { state: 'not_running', candidates: [], site: 's' }, actions);
  (root.querySelector('#tsm-open-app') as HTMLButtonElement).click();
  renderList(root, { state: 'running', candidates: [], site: 'shop.example.org', crossSite: 'mail.example.com' }, actions);
  assert.match(root.textContent ?? '', /frame of mail\.example\.com, inside shop\.example\.org/);
  (root.querySelector('#tsm-frame-site') as HTMLButtonElement).click();
  assert.deepEqual(did.slice(2), ['unlock', 'open', 'frame']);
  renderList(root, { state: 'running', candidates: [], site: 's' }, actions);
  assert.match(root.querySelector('#tsm-none')!.textContent ?? '', /not approved yet/);
});

test('the filter matches title, user name and URL', () => {
  assert.equal(matchesFilter(candidates[1], 'work'), true);
  assert.equal(matchesFilter(candidates[0], 'MAIL'), true);
  assert.equal(matchesFilter(candidates[0], 'shop'), false);
  assert.equal(matchesFilter(candidates[0], ''), true);
});
