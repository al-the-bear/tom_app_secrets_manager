// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The background (part-browser): the only part that talks to the host. A
// content script asks for a list at one of its fields; the background takes
// the tab, the frame and the frame's address from the browser's sender
// information, keeps them under a token, and answers the list page only for
// that token. A fill goes to that one frame; values live here only for the
// one fill (part-browser, "The extension's own security").

import { type ExtensionApi, hostName, type NativePort, type Sender } from './api';
import { HostFailure, HostSession, unreachableKind } from './host';
import type {
  Candidate,
  FillValues,
  HostError,
  ListAnswer,
  ServiceState,
  ToBackground,
  ToContent,
} from './messages';

/** A list opened for one field of one frame. */
interface ListContext {
  tabId: number;
  frameId: number;
  /** The tab's address (the page). */
  pageUrl: string;
  /** The frame's address (the page's own for the top frame). */
  frameUrl: string;
  /** Whether the frame has a one-time-code field to put a TOTP into. */
  otpField: boolean;
  /** The logins shown are the frame's own (a cross-site frame, confirmed). */
  frameSite: boolean;
  /** When it is forgotten. */
  expires: number;
}

/** How long a list's token stays valid. */
export const listLifetimeMs = 10 * 60 * 1000;

function hostOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
}

/** The extension's background, over [api]. */
export class Background {
  private readonly lists = new Map<string, ListContext>();

  constructor(
    private readonly api: ExtensionApi,
    private readonly connect: () => NativePort = () => api.runtime.connectNative(hostName),
    private readonly now: () => number = () => Date.now(),
    private readonly newToken: () => string = () => crypto.randomUUID(),
  ) {}

  /** Wires the browser's events (the extension's start). */
  install(): void {
    this.api.runtime.onMessage.addListener((message, sender, sendResponse) => {
      this.handle(message as ToBackground, sender).then(sendResponse, (e: Error) =>
        sendResponse({ error: { kind: 'internal', message: e.message } }),
      );
      return true;
    });
    this.api.commands?.onCommand.addListener((command, tab) => {
      if (command === 'open-list' && tab?.id !== undefined) {
        void this.toContent(tab.id, { op: 'tsm.openListHere' });
      }
    });
    const menus = this.api.contextMenus;
    if (menus) {
      void Promise.resolve(menus.removeAll()).then(() =>
        menus.create({
          id: 'tsm-fill',
          title: 'Fill from Tom Secrets Manager',
          contexts: ['editable'],
        }),
      );
      menus.onClicked.addListener((info, tab) => {
        if (info.menuItemId === 'tsm-fill' && tab?.id !== undefined) {
          void this.toContent(tab.id, { op: 'tsm.openListHere' }, info.frameId);
        }
      });
    }
  }

  private toContent(tabId: number, message: ToContent, frameId?: number): Promise<unknown> {
    return this.api.tabs
      .sendMessage(tabId, message, frameId === undefined ? undefined : { frameId })
      .catch(() => undefined);
  }

  /** Whether [sender] is one of the extension's own pages ([page]). */
  private isOwnPage(sender: Sender, page: string): boolean {
    return (
      sender.id === this.api.runtime.id &&
      typeof sender.url === 'string' &&
      sender.url.startsWith(this.api.runtime.getURL(page))
    );
  }

  private context(token: string): ListContext | undefined {
    const c = this.lists.get(token);
    if (!c) return undefined;
    if (c.expires < this.now()) {
      this.lists.delete(token);
      return undefined;
    }
    return c;
  }

  /** Answers [message] from [sender]. */
  async handle(message: ToBackground, sender: Sender): Promise<unknown> {
    switch (message.op) {
      case 'tsm.openList':
        return this.openList(sender, message.otpField === true);
      case 'tsm.list':
        if (!this.isOwnPage(sender, 'list.html')) return refused();
        return this.list(message.token, message.frameSite === true, message.unlock === true);
      case 'tsm.fill':
        if (!this.isOwnPage(sender, 'list.html') && !this.isOwnPage(sender, 'popup.html')) {
          return refused();
        }
        return this.fill(message.token, message.entryId);
      case 'tsm.totp':
        if (!this.isOwnPage(sender, 'list.html')) return refused();
        return this.totp(message.token, message.entryId);
      case 'tsm.close': {
        // The list closes itself; the frame it was opened for may close it
        // too (Escape in the page).
        const c = this.lists.get(message.token);
        const ownFrame =
          c !== undefined && sender.tab?.id === c.tabId && (sender.frameId ?? 0) === c.frameId;
        if (!this.isOwnPage(sender, 'list.html') && !ownFrame) return refused();
        return this.close(message.token);
      }
      case 'tsm.popup':
        if (!this.isOwnPage(sender, 'popup.html')) return refused();
        return this.popup(message.unlock === true);
      case 'tsm.openApp':
        if (!this.isOwnPage(sender, 'list.html') && !this.isOwnPage(sender, 'popup.html')) {
          return refused();
        }
        return this.withHost((h) => h.request('openApp', { entryId: message.entryId }));
      default:
        return refused();
    }
  }

  private async withHost<T>(work: (h: HostSession) => Promise<T>): Promise<T | { error: HostError }> {
    let session: HostSession;
    try {
      session = new HostSession(this.connect());
    } catch (e) {
      return { error: { kind: unreachableKind, message: (e as Error).message } };
    }
    try {
      return await work(session);
    } catch (e) {
      if (e instanceof HostFailure) return { error: e.error };
      return { error: { kind: 'internal', message: (e as Error).message } };
    } finally {
      session.close();
    }
  }

  /** A content script's list request: its frame, from the sender. */
  private openList(sender: Sender, otpField: boolean): unknown {
    const tabId = sender.tab?.id;
    const frameUrl = sender.url;
    const pageUrl = sender.tab?.url ?? sender.url;
    if (tabId === undefined || !frameUrl || !pageUrl || !/^https?:/.test(frameUrl)) {
      return refused();
    }
    const token = this.newToken();
    this.lists.set(token, {
      tabId,
      frameId: sender.frameId ?? 0,
      pageUrl,
      frameUrl,
      otpField,
      frameSite: false,
      expires: this.now() + listLifetimeMs,
    });
    return { token, listUrl: this.api.runtime.getURL(`list.html#${token}`) };
  }

  /** The address pair a match or fill of [c] names. */
  private target(c: ListContext): { url: string; frameUrl?: string } {
    if (c.frameSite) return { url: c.frameUrl };
    return c.frameUrl === c.pageUrl ? { url: c.pageUrl } : { url: c.pageUrl, frameUrl: c.frameUrl };
  }

  private async list(token: string, frameSite: boolean, unlock: boolean): Promise<unknown> {
    const c = this.context(token);
    if (!c) return refused();
    if (frameSite) c.frameSite = true;
    const answer = await this.withHost(async (h) => {
      let state = (await h.request('status')).state as ServiceState;
      if (state === 'locked' && unlock) {
        // A match that waits: the service asks the app for the unlock.
        await h.request('match', { ...this.target(c), wait: true });
        state = (await h.request('status')).state as ServiceState;
      }
      if (state !== 'running') {
        return { state, candidates: [] } as Partial<ListAnswer>;
      }
      const matched = await h.request('match', this.target(c));
      return { state, candidates: (matched.candidates ?? []) as Candidate[] };
    });
    const site = hostOf(c.pageUrl);
    const frameHost = hostOf(c.frameUrl);
    if ('error' in answer && answer.error) {
      return {
        state: answer.error.kind === unreachableKind ? 'unreachable' : 'running',
        candidates: [],
        site,
        error: answer.error,
      } satisfies ListAnswer;
    }
    const a = answer as Partial<ListAnswer>;
    // A form in a frame of another site: the service answers nothing for
    // it as part of the page; the list says so and offers the frame's own.
    const crossSite =
      !c.frameSite && frameHost !== site && (a.candidates?.length ?? 0) === 0
        ? frameHost
        : undefined;
    return {
      state: a.state ?? 'running',
      candidates: a.candidates ?? [],
      site: c.frameSite ? frameHost : site,
      crossSite,
    } satisfies ListAnswer;
  }

  private async fill(token: string, entryId: string): Promise<unknown> {
    const c = this.context(token);
    if (!c) return refused();
    const answer = await this.withHost((h) =>
      h.request('fill', { entryId, ...this.target(c), totp: c.otpField }),
    );
    if ('error' in answer && answer.error) return answer;
    const a = answer as Record<string, unknown>;
    const values: FillValues = {
      userName: String(a.userName ?? ''),
      password: String(a.password ?? ''),
      totp: typeof a.totp === 'string' ? a.totp : undefined,
    };
    // To the one frame the list was opened for, nowhere else.
    const result = await this.toContent(
      c.tabId,
      { op: 'tsm.doFill', token, values },
      c.frameId,
    );
    this.lists.delete(token);
    return { filled: true, frame: result ?? null };
  }

  private async totp(token: string, entryId: string): Promise<unknown> {
    const c = this.context(token);
    if (!c) return refused();
    const answer = await this.withHost((h) =>
      h.request('fill', { entryId, ...this.target(c), totp: true }),
    );
    if ('error' in answer && answer.error) return answer;
    const totp = (answer as Record<string, unknown>).totp;
    return { totp: typeof totp === 'string' ? totp : null };
  }

  private async close(token: string): Promise<unknown> {
    const c = this.lists.get(token);
    this.lists.delete(token);
    if (c) await this.toContent(c.tabId, { op: 'tsm.closeList', token }, c.frameId);
    return { closed: true };
  }

  /** The popup: the active tab's state and logins (its top frame). */
  private async popup(unlock: boolean): Promise<unknown> {
    const [tab] = await this.api.tabs.query({ active: true, currentWindow: true });
    const url = tab?.url;
    if (tab?.id === undefined || !url || !/^https?:/.test(url)) {
      return { state: 'running', candidates: [], site: '', page: false };
    }
    const token = this.newToken();
    this.lists.set(token, {
      tabId: tab.id,
      frameId: 0,
      pageUrl: url,
      frameUrl: url,
      otpField: true,
      frameSite: false,
      expires: this.now() + listLifetimeMs,
    });
    const answer = await this.withHost(async (h) => {
      let state = (await h.request('status')).state as ServiceState;
      if (state === 'locked' && unlock) {
        // A match that waits: the service asks the app for the unlock.
        await h.request('match', { url, wait: true });
        state = (await h.request('status')).state as ServiceState;
      }
      if (state !== 'running') return { state, candidates: [] as Candidate[] };
      const matched = await h.request('match', { url });
      return { state, candidates: (matched.candidates ?? []) as Candidate[] };
    });
    if ('error' in answer && answer.error) {
      return {
        state: answer.error.kind === unreachableKind ? 'unreachable' : 'running',
        candidates: [],
        site: hostOf(url),
        error: answer.error,
        token,
      };
    }
    return { ...(answer as object), site: hostOf(url), token, page: true };
  }
}

function refused(): { error: HostError } {
  return { error: { kind: 'denied', message: 'not for this sender' } };
}
