// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The page side of proposals and icons (part-browser): new-password fields
// and what a submit carries; the suggested password; the icons in the
// login fields, following the fields and opening the list; the capture at
// submit (once), the bar in the top frame and the suggestion filled into
// the new-password fields; the bar's and the suggestion's views; the build's
// icon and store packages. Demo data only.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { inflateRawSync } from 'node:zlib';
import { JSDOM } from 'jsdom';

import { ContentScript } from '../src/content';
import { newPasswordFields, submittedLogin } from '../src/detect';
import { suggestPassword } from '../src/generator';
import { FieldIcons } from '../src/icons';
import { manifest } from '../src/manifest';
import { renderBar, renderBarOutcome, renderSuggestion } from '../src/view';
import { iconPng, iconSizes } from '../tool/icon';
import { zip } from '../tool/zip';
import { fakeApi } from './fakes';

function windowOf(body: string) {
  return new JSDOM(`<!doctype html><body>${body}</body>`, { pretendToBeVisual: true }).window;
}

/** Gives [input] a box (jsdom lays nothing out). */
function boxed(input: Element, rect = { top: 100, left: 20, width: 240, height: 30 }) {
  (input as HTMLElement).getBoundingClientRect = () =>
    ({ ...rect, right: rect.left + rect.width, bottom: rect.top + rect.height, x: rect.left, y: rect.top, toJSON() {} }) as DOMRect;
}

test('new-password fields: marked ones, or the two after a current one', () => {
  const marked = windowOf(`<input type="email" id="e">
    <input type="password" id="n1" autocomplete="new-password">
    <input type="password" id="n2" autocomplete="new-password">`).document;
  assert.deepEqual(newPasswordFields(marked).map((f) => f.id), ['n1', 'n2']);
  const unmarked = windowOf(
    '<input type="password" id="c"><input type="password" id="n"><input type="password" id="r">',
  ).document;
  assert.deepEqual(newPasswordFields(unmarked).map((f) => f.id), ['n', 'r']);
  assert.deepEqual(newPasswordFields(windowOf('<input type="password">').document), []);
});

test('what a submit carries: the login typed, a new password, nothing '
  + 'without a password or with two that differ', () => {
  const d = windowOf('<input id="u" autocomplete="username"><input id="p" type="password">').document;
  assert.equal(submittedLogin(d), undefined);
  (d.getElementById('u') as HTMLInputElement).value = ' demo-user ';
  (d.getElementById('p') as HTMLInputElement).value = 'demo-pw';
  assert.deepEqual(submittedLogin(d), { userName: 'demo-user', password: 'demo-pw', change: false });

  const signUp = windowOf(`<input id="u" autocomplete="username">
    <input id="n1" type="password" autocomplete="new-password">
    <input id="n2" type="password" autocomplete="new-password">`).document;
  (signUp.getElementById('u') as HTMLInputElement).value = 'demo-user';
  (signUp.getElementById('n1') as HTMLInputElement).value = 'Fresh-1!';
  (signUp.getElementById('n2') as HTMLInputElement).value = 'Fresh-2!';
  assert.equal(submittedLogin(signUp), undefined, 'the page refuses differing ones');
  (signUp.getElementById('n2') as HTMLInputElement).value = 'Fresh-1!';
  assert.deepEqual(submittedLogin(signUp), { userName: 'demo-user', password: 'Fresh-1!', change: true });
});

test('the suggested password: 20 characters, every class, from the CSPRNG', () => {
  for (let i = 0; i < 20; i++) {
    const p = suggestPassword();
    assert.equal(p.length, 20);
    assert.match(p, /[a-z]/);
    assert.match(p, /[A-Z]/);
    assert.match(p, /[0-9]/);
    assert.match(p, /[^A-Za-z0-9]/);
  }
  assert.notEqual(suggestPassword(), suggestPassword());
  assert.equal(suggestPassword(32).length, 32);
  assert.throws(() => suggestPassword(3));
});

test('icons sit over the fields\' right edges, follow a moved field, hide '
  + 'for small fields, go with their field, and open the list', () => {
  const w = windowOf('<input id="u"><input id="p" type="password"><input id="tiny" style="width:20px">');
  const d = w.document;
  const [u, p, tiny] = ['u', 'p', 'tiny'].map((id) => d.getElementById(id) as HTMLInputElement);
  boxed(u);
  boxed(p, { top: 140, left: 20, width: 240, height: 30 });
  boxed(tiny, { top: 180, left: 20, width: 20, height: 30 });
  const clicked: string[] = [];
  const icons = new FieldIcons(d, (field, kind) => clicked.push(`${field.id}:${kind}`));
  icons.update([
    { field: u, kind: 'login' },
    { field: p, kind: 'login' },
    { field: tiny, kind: 'login' },
  ]);
  const hosts = Array.from(d.querySelectorAll('tom-secrets-icon')) as HTMLElement[];
  assert.equal(hosts.length, 3);
  assert.equal(hosts[0].style.top, '106px');
  assert.equal(hosts[0].style.left, '236px');
  assert.equal(hosts[2].style.display, 'none');
  // The same fields again: nothing rebuilt.
  icons.update([
    { field: u, kind: 'login' },
    { field: p, kind: 'login' },
  ]);
  assert.equal(d.querySelectorAll('tom-secrets-icon').length, 2);
  assert.equal(d.querySelectorAll('tom-secrets-icon')[0], hosts[0]);
  boxed(u, { top: 300, left: 20, width: 240, height: 30 });
  icons.place();
  assert.equal(hosts[0].style.top, '306px');
  icons.clear();
  assert.equal(d.querySelectorAll('tom-secrets-icon').length, 0);
  // The click (the shadow root is closed: through the host's listener).
  const again = new FieldIcons(d, (field, kind) => clicked.push(`${field.id}:${kind}`));
  again.update([{ field: p, kind: 'newPassword' }]);
  assert.equal(again.fields[0], p);
});

test('the content script: icons in the login fields; a submit captured '
  + 'once; the bar in the top frame; the suggestion into the new-password '
  + 'fields of its own list only', async () => {
  const w = windowOf(`<form id="f">
      <input id="u" autocomplete="username">
      <input id="p" type="password">
      <button id="go">Sign in</button>
    </form>`);
  const d = w.document;
  d.title = 'Mail sign-in';
  boxed(d.getElementById('u')!);
  boxed(d.getElementById('p')!);
  const sent: Array<Record<string, unknown>> = [];
  const api = fakeApi({
    onSend: (m) => {
      const message = m as Record<string, unknown>;
      sent.push(message);
      if (message.op === 'tsm.barPending') return null;
      if (message.op === 'tsm.openList') return { token: 'tok', listUrl: 'chrome-extension://x/list.html#tok' };
      return { bar: true };
    },
  });
  const script = new ContentScript(d, api);
  script.install();
  assert.equal(d.querySelectorAll('tom-secrets-icon').length, 2);
  assert.deepEqual(sent.shift(), { op: 'tsm.barPending' }, 'the top frame asks for a waiting bar');

  (d.getElementById('u') as HTMLInputElement).value = 'demo-user';
  (d.getElementById('p') as HTMLInputElement).value = 'demo-pw';
  d.getElementById('f')!.dispatchEvent(new w.Event('submit', { bubbles: true, cancelable: true }));
  d.getElementById('go')!.dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  await new Promise((r) => setTimeout(r, 10));
  const captured = sent.filter((m) => m.op === 'tsm.captured');
  assert.deepEqual(captured, [
    { op: 'tsm.captured', userName: 'demo-user', password: 'demo-pw', change: false, title: 'Mail sign-in' },
  ]);

  const listener = api.messageListeners[0];
  const ask = (message: unknown) => new Promise((resolve) => listener(message, {}, resolve));
  await ask({ op: 'tsm.showBar', token: 'bar-1', barUrl: 'chrome-extension://x/bar.html#bar-1' });
  assert.equal(d.querySelectorAll('tom-secrets-bar').length, 1);
  await ask({ op: 'tsm.closeBar', token: 'other' });
  assert.equal(d.querySelectorAll('tom-secrets-bar').length, 1);
  await ask({ op: 'tsm.closeBar', token: 'bar-1' });
  assert.equal(d.querySelectorAll('tom-secrets-bar').length, 0);

  // A change form: the icon at the new-password field, the suggestion filled.
  const change = windowOf(`<input id="c" type="password" autocomplete="current-password">
    <input id="n1" type="password" autocomplete="new-password">
    <input id="n2" type="password" autocomplete="new-password">`);
  const cd = change.document;
  for (const id of ['c', 'n1', 'n2']) boxed(cd.getElementById(id)!);
  const capi = fakeApi({
    onSend: (m) =>
      (m as { op: string }).op === 'tsm.openList'
        ? { token: 'new-1', listUrl: 'chrome-extension://x/list.html#new-1' }
        : null,
  });
  const changeScript = new ContentScript(cd, capi);
  changeScript.install();
  assert.equal(cd.querySelectorAll('tom-secrets-icon').length, 2, 'the current password and one new one');
  assert.equal(await changeScript.openList(cd.getElementById('n1') as HTMLInputElement, true), true);
  const cask = (message: unknown) =>
    new Promise((resolve) => capi.messageListeners[0](message, {}, resolve));
  assert.equal(await cask({ op: 'tsm.doFillNew', token: 'other', password: 'x' }), null);
  assert.deepEqual(await cask({ op: 'tsm.doFillNew', token: 'new-1', password: 'Suggested-1!' }), { filled: 2 });
  assert.equal((cd.getElementById('n1') as HTMLInputElement).value, 'Suggested-1!');
  assert.equal((cd.getElementById('n2') as HTMLInputElement).value, 'Suggested-1!');
  assert.equal((cd.getElementById('c') as HTMLInputElement).value, '');
});

test('the bar and the suggestion: what they say and what they do', () => {
  const d = windowOf('<main id="root"></main>').document;
  const root = d.getElementById('root')!;
  const did: string[] = [];
  renderBar(root, { site: 'mail.example.com', userName: 'demo-user', state: 'new' }, {
    save: () => did.push('save'),
    notNow: () => did.push('notNow'),
    never: () => did.push('never'),
  });
  assert.match(root.textContent ?? '', /Save the login demo-user for mail\.example\.com\?/);
  for (const id of ['tsm-bar-save', 'tsm-bar-not-now', 'tsm-bar-never']) {
    (root.querySelector(`#${id}`) as HTMLButtonElement).click();
  }
  assert.deepEqual(did, ['save', 'notNow', 'never']);
  renderBar(root, { site: 'mail.example.com', userName: 'demo-user', state: 'changed' }, {
    save() {},
    notNow() {},
    never() {},
  });
  assert.match(root.textContent ?? '', /Update the password of demo-user/);
  renderBarOutcome(root);
  assert.match(root.textContent ?? '', /under Proposals/);
  renderBarOutcome(root, { kind: 'denied', message: 'no', reason: 'not_allowed_op' });
  assert.match(root.textContent ?? '', /Always in this browser/);

  const used: string[] = [];
  renderSuggestion(root, 'mail.example.com', 'Suggested-1!', {
    use: (p) => used.push(p),
    another: () => used.push('another'),
  });
  assert.equal(root.querySelector('#tsm-suggestion')?.textContent, 'Suggested-1!');
  (root.querySelector('#tsm-use-suggestion') as HTMLButtonElement).click();
  (root.querySelector('#tsm-another') as HTMLButtonElement).click();
  assert.deepEqual(used, ['Suggested-1!', 'another']);
});

test('the build: the icon as PNG of each size; the store packages read '
  + 'back, their manifest without the development key', () => {
  for (const size of iconSizes) {
    const png = iconPng(size);
    assert.deepEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    assert.equal(png.readUInt32BE(16), size);
    assert.equal(png.readUInt32BE(20), size);
  }
  assert.equal(iconPng(16).equals(iconPng(16)), true, 'the same bytes each build');

  const files = new Map<string, Uint8Array>([
    ['manifest.json', Buffer.from(JSON.stringify(manifest('chromium', '1.0.0', { store: true })))],
    ['icons/icon-16.png', iconPng(16)],
  ]);
  const archive = zip(files);
  assert.equal(archive.equals(zip(files)), true, 'the same bytes each build');
  // Read the central directory back and inflate each entry.
  const end = archive.length - 22;
  assert.equal(archive.readUInt32LE(end), 0x06054b50);
  assert.equal(archive.readUInt16LE(end + 10), 2);
  let at = archive.readUInt32LE(end + 16);
  const read = new Map<string, Buffer>();
  for (let i = 0; i < 2; i++) {
    const nameLength = archive.readUInt16LE(at + 28);
    const name = archive.subarray(at + 46, at + 46 + nameLength).toString('utf8');
    const local = archive.readUInt32LE(at + 42);
    const packed = archive.readUInt32LE(local + 18);
    const localName = archive.readUInt16LE(local + 26);
    const start = local + 30 + localName;
    read.set(name, inflateRawSync(archive.subarray(start, start + packed)));
    at += 46 + nameLength;
  }
  assert.deepEqual([...read.keys()], ['icons/icon-16.png', 'manifest.json']);
  const m = JSON.parse(read.get('manifest.json')!.toString('utf8'));
  assert.equal(m.key, undefined);
  assert.equal(m.icons['128'], 'icons/icon-128.png');
  assert.ok(manifest('chromium', '1.0.0').key, 'the development build keeps its key');
});
