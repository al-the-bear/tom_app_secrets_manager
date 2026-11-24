// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The background of the screenshot build (tool/screenshots.mjs): the
// extension's own background, its host the tests' fake host answering demo
// data, and the popup's active tab the demo login page (a screenshot shows
// the popup as a page of its own). Never part of a release build. Demo data
// only.

import { extensionApi, type ExtensionApi } from '../src/api';
import { Background } from '../src/background';
import { FakeHost } from '../test/fakes';

/** The demo site's origin, set by the screenshot build. */
declare const TSM_DEMO_ORIGIN: string;

const host = new FakeHost((r) => {
  switch (r.op) {
    case 'status':
      return { state: 'running' };
    case 'match':
      return {
        candidates: String(r.url).startsWith(TSM_DEMO_ORIGIN)
          ? [
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
            ]
          : [],
      };
    case 'fill':
      return { userName: 'demo-user', password: 'demo-mail-pw', totp: r.totp ? '123456' : undefined };
    case 'check':
      return { state: 'new' };
    case 'propose':
      return { accepted: true, known: false };
    case 'openApp':
      return { opened: true };
    default:
      return { error: { kind: 'malformed', message: 'not answered in the screenshot build' } };
  }
});

const api = extensionApi();
const tabs = new Proxy(api.tabs, {
  get(target, key) {
    if (key === 'query') {
      return async () => {
        const all = await (target as ExtensionApi['tabs'] & {
          query(q: object): Promise<Array<{ id?: number; url?: string }>>;
        }).query({});
        return all.filter((t) => t.url?.startsWith(TSM_DEMO_ORIGIN)).slice(0, 1);
      };
    }
    const value = (target as unknown as Record<PropertyKey, unknown>)[key];
    return typeof value === 'function' ? value.bind(target) : value;
  },
});
const shown = new Proxy(api, {
  get(target, key) {
    return key === 'tabs' ? tabs : (target as unknown as Record<PropertyKey, unknown>)[key];
  },
}) as ExtensionApi;

new Background(shown, host.connect).install();
