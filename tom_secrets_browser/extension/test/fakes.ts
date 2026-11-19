// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// A fake browser API and a fake native host for the tests. Demo data only.

import type { ExtensionApi, NativePort, Sender } from '../src/api';

export const extensionId = 'lcejninmlbnhfnpedlgjjfeelhbgmach';
export const extensionBase = `chrome-extension://${extensionId}/`;

/** A host answering by [answer]; records every request. */
export class FakeHost {
  readonly requests: Array<Record<string, unknown>> = [];
  connects = 0;
  /** Throw on connect (the browser has no manifest for the host). */
  unreachable = false;

  constructor(public answer: (request: Record<string, unknown>) => Record<string, unknown>) {}

  connect = (): NativePort => {
    this.connects++;
    const messageListeners: Array<(m: unknown) => void> = [];
    const disconnectListeners: Array<() => void> = [];
    const self = this;
    if (this.unreachable) {
      queueMicrotask(() => disconnectListeners.forEach((l) => l()));
    }
    return {
      postMessage(message: unknown) {
        const request = message as Record<string, unknown>;
        self.requests.push(request);
        if (self.unreachable) return;
        const answer = self.answer(request);
        queueMicrotask(() => messageListeners.forEach((l) => l({ id: request.id, ...answer })));
      },
      disconnect() {},
      onMessage: { addListener: (l) => void messageListeners.push(l) },
      onDisconnect: { addListener: (l) => void disconnectListeners.push(l) },
    };
  };
}

/** A fake API: tabs.sendMessage recorded, runtime.sendMessage to [onSend]. */
export function fakeApi(
  options: {
    onSend?: (message: unknown) => unknown;
    activeTab?: { id?: number; url?: string };
  } = {},
): ExtensionApi & {
  sentToTabs: Array<{ tabId: number; message: unknown; frameId?: number }>;
  messageListeners: Array<(m: unknown, s: Sender, r: (x: unknown) => void) => boolean | void>;
} {
  const sentToTabs: Array<{ tabId: number; message: unknown; frameId?: number }> = [];
  const messageListeners: Array<(m: unknown, s: Sender, r: (x: unknown) => void) => boolean | void> =
    [];
  return {
    sentToTabs,
    messageListeners,
    runtime: {
      id: extensionId,
      getURL: (path: string) => `${extensionBase}${path}`,
      connectNative: () => {
        throw new Error('not in the tests');
      },
      sendMessage: async (message: unknown) => options.onSend?.(message),
      onMessage: { addListener: (l) => void messageListeners.push(l) },
    },
    tabs: {
      sendMessage: async (tabId: number, message: unknown, o?: { frameId?: number }) => {
        sentToTabs.push({ tabId, message, frameId: o?.frameId });
        return { filled: true };
      },
      query: async () => (options.activeTab ? [options.activeTab] : []),
    },
  };
}

/** The sender of a content script in [frameId] of tab 7 at [url]. */
export function contentSender(url: string, frameId = 0, pageUrl = url): Sender {
  return { tab: { id: 7, url: pageUrl }, frameId, url, id: extensionId };
}

/** The sender of the extension's own [page]. */
export function pageSender(page: string): Sender {
  return { tab: { id: 7 }, frameId: 3, url: `${extensionBase}${page}#x`, id: extensionId };
}
