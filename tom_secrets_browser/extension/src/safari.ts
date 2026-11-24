// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Safari's way to the host (part-browser, Safari): Safari has no stdio
// native messaging. `browser.runtime.sendNativeMessage` reaches the Swift
// handler in the macOS app's extension (SafariWebExtensionHandler), which
// runs `tsm-browser-host` from the app's tools folder, one process per
// session. A port here is one session: each request goes as
// `{session, request}` and comes back as `{answer}`, the host's answer;
// `{session, close: true}` ends the host process.

import type { NativePort } from './api';

/** Sends one message to the app's handler and answers its reply. */
export type SafariSend = (message: unknown) => Promise<unknown>;

/** What the extension is told when the app's handler cannot be reached. */
export const safariUnreachableMessage =
  "the Tom Secrets Manager app could not be reached: open it once, and turn " +
  'the extension on in Safari › Settings › Extensions';

/** A random session id. */
function newSession(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** A port to the host through the app's handler, over [send]. */
export function safariPort(send: SafariSend, session: string = newSession()): NativePort {
  const messageListeners: Array<(message: unknown) => void> = [];
  const disconnectListeners: Array<() => void> = [];
  let open = true;

  const emit = (message: unknown): void => {
    for (const l of messageListeners) l(message);
  };
  const end = (): void => {
    if (!open) return;
    open = false;
    for (const l of disconnectListeners) l();
  };

  return {
    postMessage(message: unknown): void {
      if (!open) throw new Error('the port is closed');
      send({ session, request: message }).then(
        (reply) => {
          const answer =
            typeof reply === 'object' && reply !== null
              ? (reply as Record<string, unknown>).answer
              : undefined;
          if (answer === undefined) {
            emit({ error: { kind: 'unreachable', message: safariUnreachableMessage } });
            end();
            return;
          }
          emit(answer);
        },
        () => {
          emit({ error: { kind: 'unreachable', message: safariUnreachableMessage } });
          end();
        },
      );
    },
    disconnect(): void {
      if (!open) return;
      open = false;
      // The host process ends with its session; nothing waits for it.
      send({ session, close: true }).catch(() => undefined);
    },
    onMessage: {
      addListener(listener: (message: unknown) => void): void {
        messageListeners.push(listener);
      },
    },
    onDisconnect: {
      addListener(listener: () => void): void {
        disconnectListeners.push(listener);
      },
    },
  };
}
