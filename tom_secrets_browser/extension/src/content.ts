// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The content script of every frame (part-browser): it finds the login
// fields (watching the page for forms that appear later), opens the
// candidate list at a field when the user asks (the shortcut, the context
// menu), and fills the values the background sends for that list. Nothing
// fills when a page loads: a fill needs the user's click in the list.
//
// The list runs in the extension's own page in an iframe, inside a closed
// shadow root, so the page can neither read nor restyle it.

import type { ExtensionApi } from './api';
import { hasLogin, type LoginFields, loginFields } from './detect';
import { fillLogin } from './fill';
import type { ToContent } from './messages';

/** The list's size in the page. */
const listWidth = 340;
const listHeight = 300;

/** The content script of [doc]. */
export class ContentScript {
  private fields: LoginFields = {};
  private token: string | undefined;
  private host: HTMLElement | undefined;
  private observer: MutationObserver | undefined;
  private scheduled = false;

  constructor(
    private readonly doc: Document,
    private readonly api: ExtensionApi,
  ) {}

  /** Starts watching [doc] and answering the background. */
  install(): void {
    this.refresh();
    const View = this.doc.defaultView;
    if (View?.MutationObserver) {
      this.observer = new View.MutationObserver(() => this.schedule());
      this.observer.observe(this.doc.documentElement, { childList: true, subtree: true });
    }
    this.api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      this.onMessage(message as ToContent).then(sendResponse, () => sendResponse(null));
      return true;
    });
    this.doc.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && this.token) void this.closeList(true);
    });
  }

  private schedule(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    (this.doc.defaultView ?? globalThis).setTimeout(() => {
      this.scheduled = false;
      this.refresh();
    }, 200);
  }

  /** The login fields as they are now. */
  refresh(): LoginFields {
    this.fields = loginFields(this.doc);
    return this.fields;
  }

  /** The field the list is placed at: the focused login field, else the
   *  user-name field, else the password or one-time-code field. */
  private anchor(): HTMLInputElement | undefined {
    const f = this.fields;
    const focused = this.doc.activeElement;
    for (const field of [f.userName, f.password, f.otp]) {
      if (field && (field === focused || field.getRootNode() === focused?.shadowRoot)) {
        return field;
      }
    }
    return f.userName ?? f.password ?? f.otp;
  }

  private async onMessage(message: ToContent): Promise<unknown> {
    switch (message.op) {
      case 'tsm.openListHere':
        // The shortcut reaches every frame: the one with the focus answers.
        if (!this.doc.hasFocus()) return null;
        return this.openList();
      case 'tsm.doFill': {
        if (message.token !== this.token) return null;
        this.refresh();
        const outcome = await fillLogin(this.fields, message.values);
        await this.closeList(false);
        return outcome;
      }
      case 'tsm.closeList':
        if (message.token === this.token) this.removeList();
        return { closed: true };
      default:
        return null;
    }
  }

  /** Asks the background for a list at this frame's login field and shows
   *  it; answers whether one is shown. */
  async openList(): Promise<boolean> {
    this.refresh();
    if (!hasLogin(this.fields)) return false;
    const answer = (await this.api.runtime.sendMessage({
      op: 'tsm.openList',
      otpField: Boolean(this.fields.otp),
    })) as { token?: string; listUrl?: string } | undefined;
    if (!answer?.token || !answer.listUrl) return false;
    this.removeList();
    this.token = answer.token;
    this.showList(answer.listUrl);
    return true;
  }

  private showList(listUrl: string): void {
    const anchor = this.anchor();
    const host = this.doc.createElement('tom-secrets-list');
    const root = host.attachShadow({ mode: 'closed' });
    const frame = this.doc.createElement('iframe');
    frame.src = listUrl;
    frame.title = 'Tom Secrets Manager';
    frame.setAttribute('allow', 'clipboard-write');
    frame.style.cssText =
      `width:${listWidth}px;height:${listHeight}px;border:0;` +
      'border-radius:8px;box-shadow:0 4px 18px rgba(0,0,0,.25);background:#fff;';
    root.appendChild(frame);
    const rect = anchor?.getBoundingClientRect();
    const view = this.doc.defaultView;
    const top = (rect ? rect.bottom : 16) + (view?.scrollY ?? 0) + 4;
    const left = Math.max(4, (rect ? rect.left : 16) + (view?.scrollX ?? 0));
    host.style.cssText =
      `all:initial;position:absolute;z-index:2147483647;top:${top}px;left:${left}px;`;
    (this.doc.body ?? this.doc.documentElement).appendChild(host);
    this.host = host;
  }

  private removeList(): void {
    this.host?.remove();
    this.host = undefined;
    this.token = undefined;
  }

  private async closeList(tell: boolean): Promise<void> {
    const token = this.token;
    this.removeList();
    if (tell && token) {
      await this.api.runtime.sendMessage({ op: 'tsm.close', token }).catch(() => undefined);
    }
  }
}
