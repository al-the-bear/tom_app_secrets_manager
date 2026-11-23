// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The page's side of passkeys (part-browser, DP-120): a script in the
// page's own world (the manifest's `world: "MAIN"`) that takes over
// `navigator.credentials.get` and `create` for passkey requests and asks
// the content script, which asks the background. The browser's own WebAuthn
// answers whatever Tom Secrets Manager does not: conditional requests (the
// browser's own autofill of passkeys), a request with nothing of Tom
// Secrets Manager's, a locked or closed app, a list closed, a creation the
// user does not save there.
//
// The page sees these messages and may send them itself; that gains it
// nothing it could not ask WebAuthn for: the background takes the origin
// from the browser, the user picks a passkey in the extension's own list,
// and a new passkey is confirmed in the app.

import {
  credentialFor,
  type PasskeyBridgeAnswer,
  type PasskeyBridgeRequest,
  serializeCreate,
  serializeGet,
} from './webauthn';

/** Installs the take-over in [win] (the page's window). */
export function installPasskeys(win: Window & typeof globalThis): void {
  const credentials = win.navigator?.credentials;
  if (!credentials || typeof credentials.get !== 'function') return;
  const nativeGet = credentials.get.bind(credentials);
  const nativeCreate = credentials.create.bind(credentials);
  const waiting = new Map<string, (a: PasskeyBridgeAnswer) => void>();

  win.addEventListener('message', (event: MessageEvent) => {
    const data = event.data as PasskeyBridgeAnswer | undefined;
    if (event.source !== win || data?.__tsm !== 'webauthn-answer') return;
    const resolve = waiting.get(data.id);
    if (resolve) {
      waiting.delete(data.id);
      resolve(data);
    }
  });

  const ask = (kind: 'get' | 'create', options: PasskeyBridgeRequest['options']) =>
    new Promise<PasskeyBridgeAnswer>((resolve) => {
      const id = win.crypto.randomUUID();
      waiting.set(id, resolve);
      win.postMessage(
        { __tsm: 'webauthn-request', id, kind, options } satisfies PasskeyBridgeRequest,
        win.location.origin,
      );
    });

  const answer = (
    kind: 'get' | 'create',
    a: PasskeyBridgeAnswer,
    fallback: () => Promise<Credential | null>,
  ): Promise<Credential | null> => {
    if (a.error) return Promise.reject(new win.DOMException(a.error.message, a.error.name));
    if (a.credential) return Promise.resolve(credentialFor(win, kind, a.credential) as Credential);
    return fallback();
  };

  credentials.get = async function get(options?: CredentialRequestOptions) {
    const publicKey = options?.publicKey;
    if (!publicKey || options?.mediation === 'conditional' || options?.signal?.aborted) {
      return nativeGet(options);
    }
    const a = await ask('get', serializeGet(publicKey));
    return answer('get', a, () => nativeGet(options));
  };

  credentials.create = async function create(options?: CredentialCreationOptions) {
    const publicKey = options?.publicKey;
    if (!publicKey || options?.signal?.aborted) return nativeCreate(options);
    const a = await ask('create', serializeCreate(publicKey));
    return answer('create', a, () => nativeCreate(options));
  };
}
