// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The background of the screenshot build (tool/screenshots.mjs): the
// extension's own background, its host the tests' fake host answering demo
// data, and the popup's active tab the demo page opened last (a screenshot
// shows the popup as a page of its own). Never part of a release build. Demo
// data only.
//
// The host's state follows the demo page the request comes for, by the
// first segment of its path: `/locked` (the service locked), `/notrunning`
// (not running), `/nohost` (no host installed: the port ends at once),
// `/asking` (the first lookup waits for the app's approval: `match` is never
// answered); every other page has the service running. The demo site is
// served on two origins (TSM_DEMO_ORIGIN on 127.0.0.1, TSM_FRAME_ORIGIN on
// localhost): the first holds the demo mail logins, the second the demo
// single sign-on's logins and passkey, and a login form of the second in a
// frame of the first matches nothing as part of the page.

import { extensionApi, type ExtensionApi, type NativePort, type Sender } from '../src/api';
import { Background } from '../src/background';
import { FakeHost } from '../test/fakes';

/** The demo site's origins, set by the screenshot build. */
declare const TSM_DEMO_ORIGIN: string;
declare const TSM_FRAME_ORIGIN: string;

type Mode = 'running' | 'locked' | 'notrunning' | 'nohost' | 'asking';

/** The host's state for a request made for the page at [url]. */
function modeOf(url: string | undefined): Mode {
  if (!url || !(url.startsWith(TSM_DEMO_ORIGIN) || url.startsWith(TSM_FRAME_ORIGIN))) {
    return 'running';
  }
  const segment = new URL(url).pathname.split('/')[1];
  return segment === 'locked' ||
    segment === 'notrunning' ||
    segment === 'nohost' ||
    segment === 'asking'
    ? segment
    : 'running';
}

const mailLogins = [
  {
    entryId: 'personal/~0a1b2c3d4e5f60718293a4b5c6d7e8f9',
    title: 'Demo mail',
    userName: 'demo-user',
    matchedUrl: TSM_DEMO_ORIGIN,
    hasTotp: true,
  },
  {
    entryId: 'team/~1b2c3d4e5f60718293a4b5c6d7e8f90a',
    title: 'Demo mail (team admin)',
    userName: 'demo-admin',
    matchedUrl: TSM_DEMO_ORIGIN,
    hasTotp: false,
  },
];

const ssoLogins = [
  {
    entryId: 'personal/~2c3d4e5f60718293a4b5c6d7e8f90a1b',
    title: 'Demo single sign-on',
    userName: 'demo-user@example.org',
    matchedUrl: TSM_FRAME_ORIGIN,
    hasTotp: false,
  },
];

const ssoPasskeys = [
  {
    entryId: 'personal/~3d4e5f60718293a4b5c6d7e8f90a1b2c',
    title: 'Demo single sign-on',
    userName: 'demo-user@example.org',
    credentialId: 'ZGVtby1jcmVkZW50aWFs',
  },
  {
    entryId: 'team/~4e5f60718293a4b5c6d7e8f90a1b2c3d',
    title: 'Demo single sign-on (team admin)',
    userName: 'demo-admin@example.org',
    credentialId: 'ZGVtby1hZG1pbi1jcmVk',
  },
];

function answer(mode: Mode, r: Record<string, unknown>): Record<string, unknown> {
  switch (r.op) {
    case 'status':
      return {
        state: mode === 'locked' ? 'locked' : mode === 'notrunning' ? 'not_running' : 'running',
      };
    case 'match': {
      // A frame of another site matches nothing as part of the page.
      if (typeof r.frameUrl === 'string') return { candidates: [] };
      const url = String(r.url);
      return {
        candidates: url.startsWith(TSM_DEMO_ORIGIN)
          ? mailLogins
          : url.startsWith(TSM_FRAME_ORIGIN)
            ? ssoLogins
            : [],
      };
    }
    case 'passkeys':
      return { candidates: String(r.url).startsWith(TSM_FRAME_ORIGIN) ? ssoPasskeys : [] };
    case 'passkeyGet':
      return {
        credentialId: ssoPasskeys[0].credentialId,
        authenticatorData: 'ZGVtby1kYXRh',
        signature: 'ZGVtby1zaWduYXR1cmU',
        userHandle: 'ZGVtby11c2Vy',
      };
    case 'fill':
      return { userName: 'demo-user', password: 'demo-mail-pw', totp: r.totp ? '123456' : undefined };
    case 'check':
      // The vaults hold demo-user (with another password): any other user
      // name is a new login.
      return r.userName === 'demo-user' ? { state: 'changed' } : { state: 'new' };
    case 'propose':
      return { accepted: true, known: false };
    case 'openApp':
      return { opened: true };
    default:
      return { error: { kind: 'malformed', message: 'not answered in the screenshot build' } };
  }
}

/** The mode of the request being handled: set from the sender (a page, the
 *  list in it) or from the popup's active tab, read when the background
 *  opens its port (synchronously after either). */
let current: Mode = 'running';

function connect(): NativePort {
  const mode = current;
  const host = new FakeHost((r) => answer(mode, r));
  host.unreachable = mode === 'nohost';
  const port = host.connect();
  if (mode !== 'asking') return port;
  // Asking the app to approve the browser: the lookup waits.
  return {
    ...port,
    postMessage(message: unknown) {
      if ((message as Record<string, unknown>).op !== 'match') port.postMessage(message);
    },
  };
}

const api = extensionApi();
const tabs = new Proxy(api.tabs, {
  get(target, key) {
    if (key === 'query') {
      // The popup's active tab: the demo page opened last.
      return async () => {
        const all = await (target as ExtensionApi['tabs'] & {
          query(q: object): Promise<Array<{ id?: number; url?: string }>>;
        }).query({});
        const demo = all
          .filter((t) => t.url?.startsWith(TSM_DEMO_ORIGIN) || t.url?.startsWith(TSM_FRAME_ORIGIN))
          .sort((a, b) => (b.id ?? 0) - (a.id ?? 0))
          .slice(0, 1);
        current = modeOf(demo[0]?.url);
        return demo;
      };
    }
    const value = (target as unknown as Record<PropertyKey, unknown>)[key];
    return typeof value === 'function' ? value.bind(target) : value;
  },
});
const runtime = new Proxy(api.runtime, {
  get(target, key) {
    if (key === 'onMessage') {
      return {
        addListener(
          listener: (m: unknown, s: Sender, r: (x: unknown) => void) => boolean | void,
        ) {
          target.onMessage.addListener((message, sender, sendResponse) => {
            current = modeOf(sender.tab?.url);
            return listener(message, sender, sendResponse);
          });
        },
      };
    }
    const value = (target as unknown as Record<PropertyKey, unknown>)[key];
    return typeof value === 'function' ? value.bind(target) : value;
  },
});
const shown = new Proxy(api, {
  get(target, key) {
    if (key === 'tabs') return tabs;
    if (key === 'runtime') return runtime;
    return (target as unknown as Record<PropertyKey, unknown>)[key];
  },
}) as ExtensionApi;

new Background(shown, connect).install();
