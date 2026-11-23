// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Passkeys in the browser (DP-120, protocol.md 5.8): the page's WebAuthn
// options as the service takes them, the client data with the frame's
// origin from the browser (never the page's word), the credential the page
// gets back; the background's sign-in (the list of the page's passkeys, the
// signature for the one picked, sent to the one frame that asked) and
// creation (InvalidStateError for an excluded credential); the browser's
// own WebAuthn whenever Tom Secrets Manager has nothing (no passkey,
// locked, no host, the list closed, Not now); the page script taking over
// `navigator.credentials` but leaving conditional requests alone. Demo
// data only.

import { strict as assert } from 'node:assert';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { JSDOM } from 'jsdom';

import { Background } from '../src/background';
import type { ListAnswer } from '../src/messages';
import {
  clientDataJson,
  credentialFor,
  fromBase64Url,
  type PasskeyBridgeAnswer,
  type PasskeyBridgeRequest,
  serializeCreate,
  serializeGet,
  toBase64Url,
} from '../src/webauthn';
import { installPasskeys } from '../src/webauthn-page';
import { contentSender, FakeHost, fakeApi, pageSender } from './fakes';

const mailKey = {
  entryId: 'team/~0123456789abcdef0123456789abcdef',
  title: 'Mail',
  userName: 'demo-user',
  credentialId: 'ZGVtby1jcmVk',
};

const challenge = toBase64Url(new TextEncoder().encode('demo-challenge'));

function setUp({ state = 'running', excluded = false } = {}) {
  const host = new FakeHost((r) => {
    switch (r.op) {
      case 'status':
        return { state };
      case 'passkeys':
        return { candidates: r.rpId === 'mail.example.com' ? [mailKey] : [] };
      case 'passkeyGet':
        return {
          credentialId: mailKey.credentialId,
          authenticatorData: 'ZGF0YQ',
          signature: 'c2ln',
          userHandle: 'dXNlcg',
        };
      case 'passkeyCreate':
        return excluded
          ? { error: { kind: 'denied', message: 'held', reason: 'excluded' } }
          : {
              credentialId: 'bmV3',
              authenticatorData: 'ZGF0YQ',
              attestationObject: 'YXR0',
              publicKey: 'cGs',
              publicKeyAlgorithm: -7,
            };
      default:
        return { error: { kind: 'malformed', message: 'no' } };
    }
  });
  const api = fakeApi();
  let n = 0;
  const bg = new Background(api, host.connect, () => 1000, () => `token-${++n}`);
  return { host, api, bg };
}

test('the options as the service takes them; the client data in the '
  + 'specification\'s order; base64url both ways', () => {
  const get = serializeGet({
    challenge: new TextEncoder().encode('demo-challenge'),
    rpId: 'example.com',
    allowCredentials: [{ id: new Uint8Array([0xfb, 0xff]) }],
  });
  assert.deepEqual(get, { challenge, rpId: 'example.com', allowCredentials: ['-_8'] });
  const create = serializeCreate({
    challenge: new Uint8Array([1, 2, 3]),
    rp: { id: 'example.com', name: 'Example' },
    user: { id: new Uint8Array([4, 5]), name: 'demo', displayName: '' },
    pubKeyCredParams: [{ alg: -8 }, { alg: -7 }],
  });
  assert.deepEqual(create, {
    challenge: 'AQID',
    rpId: 'example.com',
    userId: 'BAU',
    userName: 'demo',
    displayName: undefined,
    algorithms: [-8, -7],
    excludeCredentials: [],
  });
  assert.equal(
    clientDataJson('webauthn.get', 'abc', 'https://example.com', false),
    '{"type":"webauthn.get","challenge":"abc","origin":"https://example.com","crossOrigin":false}',
  );
  assert.deepEqual([...fromBase64Url('-_8')], [0xfb, 0xff]);
});

test('a sign-in: the page\'s passkeys in the list; the pick signed by the service '
  + 'over the client data with the frame\'s origin; the credential to that frame only', async () => {
  const { host, api, bg } = setUp();
  const opened = (await bg.handle(
    { op: 'tsm.passkeyGet', options: { challenge, allowCredentials: [] } },
    contentSender('https://mail.example.com/login', 2, 'https://mail.example.com/'),
  )) as { token: string; listUrl: string };
  assert.equal(opened.token, 'token-1');
  const asked = host.requests.find((r) => r.op === 'passkeys');
  assert.equal(asked?.rpId, 'mail.example.com');
  assert.equal(asked?.url, 'https://mail.example.com/login');

  const list = (await bg.handle({ op: 'tsm.list', token: 'token-1' }, pageSender('list.html'))) as ListAnswer;
  assert.equal(list.passkey, true);
  assert.equal(list.site, 'mail.example.com');
  assert.equal(list.candidates[0].title, 'Mail');

  // Only the list page picks.
  const forged = (await bg.handle(
    { op: 'tsm.fill', token: 'token-1', entryId: mailKey.entryId },
    contentSender('https://mail.example.com/login'),
  )) as { error?: unknown };
  assert.ok(forged.error);
  await bg.handle({ op: 'tsm.fill', token: 'token-1', entryId: mailKey.entryId }, pageSender('list.html'));
  const signed = host.requests.find((r) => r.op === 'passkeyGet')!;
  const done = api.sentToTabs.at(-1)!;
  assert.equal(done.frameId, 2);
  const message = done.message as { op: string; answer: PasskeyBridgeAnswer };
  assert.equal(message.op, 'tsm.passkeyDone');
  const credential = message.answer.credential!;
  const clientData = new TextDecoder().decode(fromBase64Url(credential.clientDataJSON));
  assert.deepEqual(JSON.parse(clientData), {
    type: 'webauthn.get',
    challenge,
    origin: 'https://mail.example.com',
    crossOrigin: false,
  });
  assert.equal(
    signed.clientDataHash,
    createHash('sha256').update(clientData).digest('base64url'),
  );
  assert.equal(credential.signature, 'c2ln');
  assert.equal(credential.userHandle, 'dXNlcg');
});

test('the browser\'s own WebAuthn: no passkey of the site, locked, no host, '
  + 'a page that is not https; a list closed answers the frame so', async () => {
  const none = setUp();
  assert.deepEqual(
    await none.bg.handle(
      { op: 'tsm.passkeyGet', options: { challenge, rpId: 'shop.example.org', allowCredentials: [] } },
      contentSender('https://shop.example.org/'),
    ),
    { fallback: true },
  );
  const locked = setUp({ state: 'locked' });
  assert.deepEqual(
    await locked.bg.handle(
      { op: 'tsm.passkeyGet', options: { challenge, allowCredentials: [] } },
      contentSender('https://mail.example.com/'),
    ),
    { fallback: true },
  );
  assert.equal(locked.host.requests.some((r) => r.op === 'passkeys'), false);
  const unreachable = setUp();
  unreachable.host.unreachable = true;
  assert.deepEqual(
    await unreachable.bg.handle(
      { op: 'tsm.passkeyGet', options: { challenge, allowCredentials: [] } },
      contentSender('https://mail.example.com/'),
    ),
    { fallback: true },
  );
  const plain = setUp();
  assert.deepEqual(
    await plain.bg.handle(
      { op: 'tsm.passkeyGet', options: { challenge, allowCredentials: [] } },
      contentSender('http://mail.example.com/'),
    ),
    { fallback: true },
  );

  const { api, bg } = setUp();
  await bg.handle(
    { op: 'tsm.passkeyGet', options: { challenge, allowCredentials: [] } },
    contentSender('https://mail.example.com/', 0),
  );
  await bg.handle({ op: 'tsm.close', token: 'token-1' }, pageSender('list.html'));
  assert.deepEqual(api.sentToTabs.at(-1)?.message, {
    op: 'tsm.passkeyDone',
    token: 'token-1',
    answer: { fallback: true },
  });
});

test('a creation: the service asked with the user and the algorithms, the client '
  + 'data of webauthn.create; an excluded credential is InvalidStateError', async () => {
  const { host, bg } = setUp();
  const options = {
    challenge,
    rpId: 'mail.example.com',
    userId: 'dXNlcg',
    userName: 'demo-user',
    algorithms: [-7, -257],
    excludeCredentials: [],
  };
  const made = (await bg.handle(
    { op: 'tsm.passkeyCreate', options },
    contentSender('https://login.mail.example.com/signup', 0),
  )) as PasskeyBridgeAnswer;
  const asked = host.requests.find((r) => r.op === 'passkeyCreate')!;
  assert.equal(asked.url, 'https://login.mail.example.com/signup');
  assert.deepEqual(asked.algorithms, [-7, -257]);
  assert.equal(made.credential?.attestationObject, 'YXR0');
  assert.equal(made.credential?.publicKeyAlgorithm, -7);
  const clientData = JSON.parse(
    new TextDecoder().decode(fromBase64Url(made.credential!.clientDataJSON)),
  ) as Record<string, unknown>;
  assert.equal(clientData.type, 'webauthn.create');
  assert.equal(clientData.origin, 'https://login.mail.example.com');

  const excluded = setUp({ excluded: true });
  assert.deepEqual(
    await excluded.bg.handle(
      { op: 'tsm.passkeyCreate', options },
      contentSender('https://mail.example.com/signup'),
    ),
    { error: { name: 'InvalidStateError', message: 'this account has a passkey already' } },
  );
  const locked = setUp({ state: 'not_running' });
  assert.deepEqual(
    await locked.bg.handle({ op: 'tsm.passkeyCreate', options }, contentSender('https://mail.example.com/')),
    { fallback: true },
  );
});

test('the page script: a passkey request goes over the bridge and the credential '
  + 'comes back shaped as WebAuthn\'s; conditional requests, refusals and the '
  + 'fallback', async () => {
  const window = new JSDOM('<!doctype html><body></body>', { url: 'https://mail.example.com/' })
    .window as unknown as Window & typeof globalThis;
  const native: string[] = [];
  Object.defineProperty(window.navigator, 'credentials', {
    value: {
      get: async () => {
        native.push('get');
        return null;
      },
      create: async () => {
        native.push('create');
        return null;
      },
    },
    configurable: true,
  });
  installPasskeys(window);
  // The content script's side: answer each request by [reply].
  let reply: (r: PasskeyBridgeRequest) => Omit<PasskeyBridgeAnswer, '__tsm' | 'id'> = () => ({
    fallback: true,
  });
  const seen: PasskeyBridgeRequest[] = [];
  window.addEventListener('message', (event: MessageEvent) => {
    const data = event.data as PasskeyBridgeRequest;
    if (data?.__tsm !== 'webauthn-request') return;
    seen.push(data);
    window.dispatchEvent(
      new window.MessageEvent('message', {
        data: { __tsm: 'webauthn-answer', id: data.id, ...reply(data) },
        source: window,
      }),
    );
  });
  const credentials = window.navigator.credentials;
  const publicKey = { challenge: new Uint8Array([1, 2, 3]), rpId: 'mail.example.com' };

  // No credential for the page: the browser's own.
  assert.equal(await credentials.get({ publicKey }), null);
  assert.deepEqual(native, ['get']);
  assert.equal(seen[0].kind, 'get');
  assert.equal((seen[0].options as { challenge: string }).challenge, 'AQID');

  // A conditional request is left to the browser, never sent.
  await credentials.get({ publicKey, mediation: 'conditional' });
  assert.equal(seen.length, 1);
  assert.deepEqual(native, ['get', 'get']);

  reply = () => ({
    credential: {
      credentialId: 'ZGVtby1jcmVk',
      clientDataJSON: 'e30',
      authenticatorData: 'ZGF0YQ',
      signature: 'c2ln',
      userHandle: 'dXNlcg',
    },
  });
  const got = (await credentials.get({ publicKey })) as unknown as {
    id: string;
    type: string;
    rawId: ArrayBuffer;
    response: { signature: ArrayBuffer; userHandle: ArrayBuffer };
    toJSON(): Record<string, unknown>;
  };
  assert.equal(got.id, 'ZGVtby1jcmVk');
  assert.equal(got.type, 'public-key');
  assert.equal(toBase64Url(got.rawId), 'ZGVtby1jcmVk');
  assert.equal(toBase64Url(got.response.signature), 'c2ln');
  assert.equal(toBase64Url(got.response.userHandle), 'dXNlcg');
  assert.equal((got.toJSON().response as Record<string, unknown>).signature, 'c2ln');

  reply = () => ({ error: { name: 'InvalidStateError', message: 'held' } });
  await assert.rejects(
    credentials.create({
      publicKey: {
        challenge: new Uint8Array([1]),
        rp: { id: 'mail.example.com', name: 'Mail' },
        user: { id: new Uint8Array([2]), name: 'demo', displayName: 'Demo' },
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      },
    }),
    (e: Error) => e.name === 'InvalidStateError',
  );
});

test('a creation\'s credential has getPublicKey, its algorithm and transports', () => {
  const window = new JSDOM('<!doctype html>', { url: 'https://mail.example.com/' }).window as unknown as Window &
    typeof globalThis;
  const made = credentialFor(window, 'create', {
    credentialId: 'bmV3',
    clientDataJSON: 'e30',
    authenticatorData: 'ZGF0YQ',
    attestationObject: 'YXR0',
    publicKey: 'cGs',
    publicKeyAlgorithm: -8,
  }) as {
    response: {
      attestationObject: ArrayBuffer;
      getPublicKey(): ArrayBuffer;
      getPublicKeyAlgorithm(): number;
      getTransports(): string[];
      getAuthenticatorData(): ArrayBuffer;
    };
  };
  assert.equal(toBase64Url(made.response.attestationObject), 'YXR0');
  assert.equal(toBase64Url(made.response.getPublicKey()), 'cGs');
  assert.equal(made.response.getPublicKeyAlgorithm(), -8);
  assert.deepEqual(made.response.getTransports(), ['internal', 'hybrid']);
  assert.equal(toBase64Url(made.response.getAuthenticatorData()), 'ZGF0YQ');
});
