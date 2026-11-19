// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The background (part-browser): the only part that talks to the host. A
// content script asks for a list at one of its fields; the background takes
// the tab, the frame and the frame's address from the browser's sender
// information, keeps them under a token, and answers the list page only for
// that token. A fill goes to that one frame; values live here only for the
// one fill (part-browser, "The extension's own security").
//
// Proposing a login (part-browser, DP-43): a content script reports a
// submitted form's user name and password; the background asks the host
// whether the vaults hold it, and when the login is new or its password
// changed it shows the bar "Save in Tom Secrets Manager?" in the tab's top
// frame (also on the page the form led to). Save sends `propose`; the app
// shows it under Proposals. The password lives here only until the bar is
// answered or for [proposalLifetimeMs]; "Never for this site" keeps the
// site, never a secret, in the extension's storage.

import { type ExtensionApi, hostName, type NativePort, type Sender } from './api';
import { HostFailure, HostSession, unreachableKind } from './host';
import type {
  BarAnswer,
  Candidate,
  CapturedRequest,
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
  /** Opened at a new-password field: the list suggests a password. */
  newPassword?: boolean;
  /** When it is forgotten. */
  expires: number;
}

/** How long a list's token stays valid. */
export const listLifetimeMs = 10 * 60 * 1000;

/** How long a submitted login waits for the bar's answer. */
export const proposalLifetimeMs = 2 * 60 * 1000;

/** The storage key of the sites the user said "Never" for. */
export const neverSitesKey = 'neverSites';

/** A submitted login waiting for the bar (one per tab). */
interface PendingProposal {
  token: string;
  tabId: number;
  url: string;
  title?: string;
  userName?: string;
  password: string;
  state: BarAnswer['state'];
  expires: number;
}

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
  private readonly proposals = new Map<number, PendingProposal>();

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
    // A closed tab's submitted login is forgotten at once.
    this.api.tabs.onRemoved?.addListener((tabId) => this.proposals.delete(tabId));
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
        return this.openList(sender, message.otpField === true, message.newPassword === true);
      case 'tsm.fillNew':
        if (!this.isOwnPage(sender, 'list.html')) return refused();
        return this.fillNew(message.token, message.password);
      case 'tsm.captured':
        return this.captured(sender, message);
      case 'tsm.barPending':
        return this.barPending(sender);
      case 'tsm.bar':
        if (!this.isOwnPage(sender, 'bar.html')) return refused();
        return this.bar(message.token);
      case 'tsm.barAnswer':
        if (!this.isOwnPage(sender, 'bar.html')) return refused();
        return this.barAnswer(message.token, message.answer);
      case 'tsm.never':
        if (!this.isOwnPage(sender, 'popup.html')) return refused();
        return this.setNeverForActiveTab(message.never);
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
  private openList(sender: Sender, otpField: boolean, newPassword = false): unknown {
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
      newPassword,
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
    if (c.newPassword) {
      // The suggestion is made in the list; nothing to ask the host.
      return {
        state: 'running',
        candidates: [],
        site: hostOf(c.frameUrl),
        newPassword: true,
      } satisfies ListAnswer;
    }
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

  /** Fills [password] into the new-password fields of the list's frame. */
  private async fillNew(token: string, password: string): Promise<unknown> {
    const c = this.context(token);
    if (!c || !c.newPassword || !password) return refused();
    const result = await this.toContent(
      c.tabId,
      { op: 'tsm.doFillNew', token, password },
      c.frameId,
    );
    this.lists.delete(token);
    return { filled: true, frame: result ?? null };
  }

  // ── Proposing a login ────────────────────────────────────────────────

  private async neverSites(): Promise<string[]> {
    const stored = await this.api.storage?.local.get(neverSitesKey);
    const sites = stored?.[neverSitesKey];
    return Array.isArray(sites) ? sites.filter((s): s is string => typeof s === 'string') : [];
  }

  private async setNever(site: string, never: boolean): Promise<void> {
    const sites = new Set(await this.neverSites());
    if (never) sites.add(site);
    else sites.delete(site);
    await this.api.storage?.local.set({ [neverSitesKey]: [...sites].sort() });
  }

  private async setNeverForActiveTab(never: boolean): Promise<unknown> {
    const [tab] = await this.api.tabs.query({ active: true, currentWindow: true });
    const site = hostOf(tab?.url ?? '');
    if (!site) return refused();
    await this.setNever(site, never);
    return { site, never };
  }

  private proposal(token: string): PendingProposal | undefined {
    for (const p of this.proposals.values()) {
      if (p.token !== token) continue;
      if (p.expires < this.now()) {
        this.proposals.delete(p.tabId);
        return undefined;
      }
      return p;
    }
    return undefined;
  }

  /** A submitted form: the frame's address from the browser; the host tells
   *  whether the vaults hold the login; a new login or a changed password
   *  gets the bar. */
  private async captured(sender: Sender, m: CapturedRequest): Promise<unknown> {
    const tabId = sender.tab?.id;
    const url = sender.url;
    if (tabId === undefined || !url || !/^https?:/.test(url) || !m.password) return refused();
    const site = hostOf(url);
    if ((await this.neverSites()).includes(site)) return { ignored: 'never' };
    const checked = await this.withHost((h) =>
      h.request('check', { url, userName: m.userName, password: m.password }),
    );
    let state: BarAnswer['state'] = 'unknown';
    let userName = m.userName;
    if (!('error' in checked && checked.error)) {
      const a = checked as Record<string, unknown>;
      if (a.state === 'known') return { ignored: 'known' };
      if (a.state === 'new' || a.state === 'changed') state = a.state;
      if (!userName && typeof a.userName === 'string') userName = a.userName;
    }
    const token = this.newToken();
    this.proposals.set(tabId, {
      token,
      tabId,
      url,
      title: m.title,
      userName,
      password: m.password,
      state,
      expires: this.now() + proposalLifetimeMs,
    });
    await this.toContent(
      tabId,
      { op: 'tsm.showBar', token, barUrl: this.barUrl(token) },
      0,
    );
    return { bar: true };
  }

  private barUrl(token: string): string {
    return this.api.runtime.getURL(`bar.html#${token}`);
  }

  /** The tab's top frame after a navigation: the bar still waiting. */
  private barPending(sender: Sender): unknown {
    const tabId = sender.tab?.id;
    if (tabId === undefined || (sender.frameId ?? 0) !== 0) return null;
    const p = this.proposals.get(tabId);
    if (!p) return null;
    if (p.expires < this.now()) {
      this.proposals.delete(tabId);
      return null;
    }
    return { token: p.token, barUrl: this.barUrl(p.token) };
  }

  /** What the bar asks about: never the password. */
  private bar(token: string): unknown {
    const p = this.proposal(token);
    if (!p) return refused();
    return { site: hostOf(p.url), userName: p.userName, state: p.state } satisfies BarAnswer;
  }

  /** The bar's answer: Save proposes the login, Never keeps the site off,
   *  Not now drops it; each forgets the password. `close` only closes the
   *  bar (after it showed the outcome). */
  private async barAnswer(
    token: string,
    answer: 'save' | 'notNow' | 'never' | 'close',
  ): Promise<unknown> {
    const p = this.proposal(token);
    const tabId = p?.tabId ?? this.closingBars.get(token);
    if (tabId === undefined) return refused();
    if (answer === 'close' || !p) {
      this.closingBars.delete(token);
      await this.toContent(tabId, { op: 'tsm.closeBar', token }, 0);
      return { closed: true };
    }
    this.proposals.delete(tabId);
    if (answer === 'never') await this.setNever(hostOf(p.url), true);
    if (answer !== 'save') {
      await this.toContent(tabId, { op: 'tsm.closeBar', token }, 0);
      return { closed: true };
    }
    this.closingBars.set(token, tabId);
    const sent = await this.withHost((h) =>
      h.request('propose', {
        url: p.url,
        title: p.title,
        userName: p.userName ?? '',
        password: p.password,
      }),
    );
    if ('error' in sent && sent.error) return { error: sent.error };
    return { proposed: true };
  }

  private readonly closingBars = new Map<string, number>();

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
    // Whether the site's logins are offered for saving: shown in any state.
    const never = (await this.neverSites()).includes(hostOf(url));
    if ('error' in answer && answer.error) {
      return {
        state: answer.error.kind === unreachableKind ? 'unreachable' : 'running',
        candidates: [],
        site: hostOf(url),
        error: answer.error,
        token,
        never,
      };
    }
    return { ...(answer as object), site: hostOf(url), token, page: true, never };
  }
}

function refused(): { error: HostError } {
  return { error: { kind: 'denied', message: 'not for this sender' } };
}
