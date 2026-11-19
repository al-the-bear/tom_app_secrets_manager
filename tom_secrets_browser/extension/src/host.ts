// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The native-messaging host `tsm-browser-host`: a port is opened for one
// operation (a list, a fill) and closed when it is done, since a Manifest V3
// background is suspended when idle and nothing may rely on a long-lived
// host. Requests carry an id; the host answers each with the same id.

import type { NativePort } from './api';
import type { HostError } from './messages';

/** A refusal of the host (its `error`), or the host not starting. */
export class HostFailure extends Error {
  constructor(readonly error: HostError) {
    super(error.message);
  }
}

/** The kind of a host that could not be started (no manifest, no host). */
export const unreachableKind = 'unreachable';

/** One port to the host. */
export class HostSession {
  private readonly pending = new Map<
    number,
    { resolve: (a: Record<string, unknown>) => void; reject: (e: Error) => void }
  >();
  private nextId = 1;
  private closed = false;

  constructor(private readonly port: NativePort) {
    port.onMessage.addListener((message) => this.onMessage(message));
    port.onDisconnect.addListener(() => this.onDisconnect());
  }

  private onMessage(message: unknown): void {
    if (typeof message !== 'object' || message === null) return;
    const m = message as Record<string, unknown>;
    if (typeof m.id !== 'number') {
      // The host's refusal of the caller comes without an id: every request
      // fails with it.
      const error = m.error as HostError | undefined;
      if (error) this.failAll(new HostFailure(error));
      return;
    }
    const waiting = this.pending.get(m.id);
    if (!waiting) return;
    this.pending.delete(m.id);
    if (m.error) {
      waiting.reject(new HostFailure(m.error as HostError));
    } else {
      waiting.resolve(m);
    }
  }

  private onDisconnect(): void {
    this.closed = true;
    this.failAll(
      new HostFailure({
        kind: unreachableKind,
        message:
          'the browser host is not installed for this browser: turn it on in ' +
          'Tom Secrets Manager › Settings › Integrations › Browsers',
      }),
    );
  }

  private failAll(error: Error): void {
    for (const w of this.pending.values()) w.reject(error);
    this.pending.clear();
  }

  /** Sends [op] with [args]; answers the host's answer. */
  request(op: string, args: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    if (this.closed) {
      return Promise.reject(
        new HostFailure({ kind: unreachableKind, message: 'the host has ended' }),
      );
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      try {
        this.port.postMessage({ id, op, ...args });
      } catch (e) {
        this.pending.delete(id);
        reject(e as Error);
      }
    });
  }

  /** Closes the port. */
  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.port.disconnect();
  }
}

/** Runs [work] on a session of a port from [connect], closed afterwards. */
export async function withHost<T>(
  connect: () => NativePort,
  work: (session: HostSession) => Promise<T>,
): Promise<T> {
  const session = new HostSession(connect());
  try {
    return await work(session);
  } finally {
    session.close();
  }
}
