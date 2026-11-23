// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Passkeys in the browser (part-browser, part-password-manager, DP-120,
// protocol.md 5.8): what the page's WebAuthn options become on their way to
// the service, the client data the extension makes as the page's client,
// and the credential objects the page gets back. The passkey's key never
// reaches the extension: the service lists passkeys by name and answers a
// signature.

/** The page script's message to the content script (`window.postMessage`). */
export interface PasskeyBridgeRequest {
  __tsm: 'webauthn-request';
  id: string;
  kind: 'get' | 'create';
  options: PasskeyGetOptions | PasskeyCreateOptions;
}

/** The content script's answer to the page script. */
export interface PasskeyBridgeAnswer {
  __tsm: 'webauthn-answer';
  id: string;
  /** The browser's own WebAuthn answers instead (none here, locked, no host,
   *  the list closed, the app said Not now). */
  fallback?: boolean;
  /** A refusal the page sees as a DOMException of this name. */
  error?: { name: string; message: string };
  /** The credential, every byte value base64url. */
  credential?: PasskeyCredentialAnswer;
}

/** A sign-in's options as the service takes them. */
export interface PasskeyGetOptions {
  challenge: string;
  rpId?: string;
  allowCredentials: string[];
}

/** A creation's options as the service takes them. */
export interface PasskeyCreateOptions {
  challenge: string;
  rpId?: string;
  userId: string;
  userName: string;
  displayName?: string;
  algorithms: number[];
  excludeCredentials: string[];
}

/** A credential for the page: a sign-in's or a creation's fields. */
export interface PasskeyCredentialAnswer {
  credentialId: string;
  clientDataJSON: string;
  authenticatorData: string;
  // A sign-in:
  signature?: string;
  userHandle?: string;
  // A creation:
  attestationObject?: string;
  publicKey?: string;
  publicKeyAlgorithm?: number;
}

/** [bytes] as base64url without padding. */
export function toBase64Url(bytes: ArrayBuffer | ArrayBufferView): string {
  const view =
    bytes instanceof ArrayBuffer
      ? new Uint8Array(bytes)
      : new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let text = '';
  for (const b of view) text += String.fromCharCode(b);
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** The bytes of base64url (or base64) [text]. */
export function fromBase64Url(text: string): Uint8Array {
  let t = text.replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4 !== 0) t += '=';
  const raw = atob(t);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

type Source = ArrayBuffer | ArrayBufferView;

/** A sign-in's options, from the page's `publicKey` request options. */
export function serializeGet(o: {
  challenge: Source;
  rpId?: string;
  allowCredentials?: ReadonlyArray<{ id: Source }>;
}): PasskeyGetOptions {
  return {
    challenge: toBase64Url(o.challenge),
    rpId: o.rpId,
    allowCredentials: (o.allowCredentials ?? []).map((c) => toBase64Url(c.id)),
  };
}

/** A creation's options, from the page's `publicKey` creation options. */
export function serializeCreate(o: {
  challenge: Source;
  rp: { id?: string; name?: string };
  user: { id: Source; name: string; displayName?: string };
  pubKeyCredParams: ReadonlyArray<{ alg: number }>;
  excludeCredentials?: ReadonlyArray<{ id: Source }>;
}): PasskeyCreateOptions {
  return {
    challenge: toBase64Url(o.challenge),
    rpId: o.rp.id,
    userId: toBase64Url(o.user.id),
    userName: o.user.name,
    displayName: o.user.displayName || undefined,
    algorithms: o.pubKeyCredParams.map((p) => p.alg),
    excludeCredentials: (o.excludeCredentials ?? []).map((c) => toBase64Url(c.id)),
  };
}

/** The client data the extension makes as the page's client (WebAuthn's
 *  `CollectedClientData`, its members in the order the specification
 *  serialises them). */
export function clientDataJson(
  type: 'webauthn.get' | 'webauthn.create',
  challenge: string,
  origin: string,
  crossOrigin: boolean,
): string {
  return JSON.stringify({ type, challenge, origin, crossOrigin });
}

/** SHA-256 of [text]'s UTF-8. */
export async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
}

/** The relying party a request names, else the frame's host: the service
 *  checks it may be used by the page. */
export function rpIdOf(options: { rpId?: string }, frameUrl: string): string {
  if (options.rpId) return options.rpId;
  try {
    return new URL(frameUrl).hostname;
  } catch {
    return '';
  }
}

/** An object of the page's realm whose prototype is [proto] (when the
 *  browser has it), with [members] as its own properties: the page's
 *  `instanceof` checks hold and its getters are shadowed. */
function shaped(proto: object | undefined, members: Record<string, unknown>): object {
  const o = Object.create(proto ?? Object.prototype) as object;
  for (const [key, value] of Object.entries(members)) {
    Object.defineProperty(o, key, { value, enumerable: true });
  }
  return o;
}

function buffer(text: string): ArrayBuffer {
  const bytes = fromBase64Url(text);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

/** The `PublicKeyCredential` the page gets for [kind] from [a], in the
 *  realm of [win]. */
export function credentialFor(
  win: Window & typeof globalThis,
  kind: 'get' | 'create',
  a: PasskeyCredentialAnswer,
): object {
  const w = win as unknown as Record<string, { prototype?: object } | undefined>;
  const json: Record<string, unknown> = {
    id: a.credentialId,
    rawId: a.credentialId,
    type: 'public-key',
    authenticatorAttachment: 'platform',
    clientExtensionResults: {},
  };
  let response: object;
  if (kind === 'get') {
    response = shaped(w.AuthenticatorAssertionResponse?.prototype, {
      clientDataJSON: buffer(a.clientDataJSON),
      authenticatorData: buffer(a.authenticatorData),
      signature: buffer(a.signature ?? ''),
      userHandle: a.userHandle ? buffer(a.userHandle) : null,
    });
    json.response = {
      clientDataJSON: a.clientDataJSON,
      authenticatorData: a.authenticatorData,
      signature: a.signature,
      ...(a.userHandle ? { userHandle: a.userHandle } : {}),
    };
  } else {
    response = shaped(w.AuthenticatorAttestationResponse?.prototype, {
      clientDataJSON: buffer(a.clientDataJSON),
      attestationObject: buffer(a.attestationObject ?? ''),
      getTransports: () => ['internal', 'hybrid'],
      getAuthenticatorData: () => buffer(a.authenticatorData),
      getPublicKey: () => (a.publicKey ? buffer(a.publicKey) : null),
      getPublicKeyAlgorithm: () => a.publicKeyAlgorithm ?? -7,
    });
    json.response = {
      clientDataJSON: a.clientDataJSON,
      attestationObject: a.attestationObject,
      authenticatorData: a.authenticatorData,
      publicKey: a.publicKey,
      publicKeyAlgorithm: a.publicKeyAlgorithm,
      transports: ['internal', 'hybrid'],
    };
  }
  return shaped(w.PublicKeyCredential?.prototype, {
    id: a.credentialId,
    rawId: buffer(a.credentialId),
    type: 'public-key',
    authenticatorAttachment: 'platform',
    response,
    getClientExtensionResults: () => ({}),
    toJSON: () => json,
  });
}
