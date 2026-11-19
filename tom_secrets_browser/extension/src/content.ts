// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The content script of every frame (part-browser): it finds the login
// fields (watching the page for forms that appear later), opens the
// candidate list at a field when the user asks (the shortcut, the context
// menu), and fills the values the background sends for that list. Nothing
// fills when a page loads: a fill needs the user's click in the list.
//
// The list runs in the extension's own page in an iframe, inside a closed
// shadow root, so the page can neither read nor restyle it. So do the icons
// in the login fields and the bar "Save in Tom Secrets Manager?" that a
// submitted login brings up in the top frame (part-browser, DP-43).

import type { ExtensionApi } from './api';
import {
  hasLogin,
  type LoginFields,
  loginFields,
  newPasswordFields,
  submittedLogin,
} from './detect';
import { fillLogin, setFieldValue } from './fill';
import { FieldIcons } from './icons';
import type { ToContent } from './messages';

/** The list's size in the page. */
const listWidth = 340;
const listHeight = 300;

/** The bar's size in the page. */
const barWidth = 380;
const barHeight = 104;

/** A button whose click submits a login where the page has no form submit
 *  (single-page apps). */
const submitWords =
  /sign\s?in|log\s?in|continue|next|submit|save|change|update|register|sign\s?up|create|anmelden|weiter|speichern/i;

/** The content script of [doc]. */
export class ContentScript {
  private fields: LoginFields = {};
  private newFields: HTMLInputElement[] = [];
  private token: string | undefined;
  private host: HTMLElement | undefined;
  private anchorField: HTMLInputElement | undefined;
  private barToken: string | undefined;
  private barHost: HTMLElement | undefined;
  private icons: FieldIcons | undefined;
  private observer: MutationObserver | undefined;
  private scheduled = false;
  private lastCaptured = { key: '', at: 0 };

  constructor(
    private readonly doc: Document,
    private readonly api: ExtensionApi,
  ) {}

  /** Starts watching [doc] and answering the background. */
  install(): void {
    this.icons = new FieldIcons(this.doc, (field, kind) =>
      void this.openList(field, kind === 'newPassword'),
    );
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
    // A login is captured when it is submitted: the form's submit, Enter in
    // a password field, or a submit-like button (single-page apps).
    this.doc.addEventListener('submit', () => void this.capture(), true);
    this.doc.addEventListener(
      'keydown',
      (e) => {
        const target = e.target as HTMLInputElement | null;
        if (e.key === 'Enter' && target?.type === 'password') void this.capture();
      },
      true,
    );
    this.doc.addEventListener(
      'click',
      (e) => {
        if (this.isSubmitButton(e.target)) void this.capture();
      },
      true,
    );
    // The page a form led to: the bar still waiting for this tab.
    if (this.isTop()) void this.showPendingBar();
  }

  private isTop(): boolean {
    const view = this.doc.defaultView;
    try {
      return !view || view.top === view;
    } catch {
      return false;
    }
  }

  private isSubmitButton(target: EventTarget | null): boolean {
    const View = this.doc.defaultView;
    if (!View || !(target instanceof View.Element)) return false;
    const button = (target as Element).closest('button, input[type=submit], [role=button]');
    if (!button) return false;
    if (button instanceof View.HTMLInputElement) return button.type === 'submit';
    if (button instanceof View.HTMLButtonElement && button.form) {
      return button.type === 'submit';
    }
    return submitWords.test(button.textContent ?? '');
  }

  /** Reports the submitted login (once per user name and password a few
   *  seconds apart) to the background, which decides about the bar. */
  async capture(): Promise<boolean> {
    const submitted = submittedLogin(this.doc);
    if (!submitted) return false;
    const key = `${submitted.userName ?? ''}\u0000${submitted.password}`;
    const now = Date.now();
    if (this.lastCaptured.key === key && now - this.lastCaptured.at < 5000) return false;
    this.lastCaptured = { key, at: now };
    await this.api.runtime
      .sendMessage({
        op: 'tsm.captured',
        userName: submitted.userName,
        password: submitted.password,
        change: submitted.change,
        title: this.doc.title || undefined,
      })
      .catch(() => undefined);
    return true;
  }

  private async showPendingBar(): Promise<void> {
    const pending = (await this.api.runtime
      .sendMessage({ op: 'tsm.barPending' })
      .catch(() => null)) as { token?: string; barUrl?: string } | null;
    if (pending?.token && pending.barUrl) this.showBar(pending.token, pending.barUrl);
  }

  private schedule(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    (this.doc.defaultView ?? globalThis).setTimeout(() => {
      this.scheduled = false;
      this.refresh();
    }, 200);
  }

  /** The login fields as they are now; the icons follow them. */
  refresh(): LoginFields {
    this.fields = loginFields(this.doc);
    this.newFields = newPasswordFields(this.doc);
    this.icons?.update([
      ...[this.fields.userName, this.fields.password]
        .filter((f): f is HTMLInputElement => f !== undefined)
        .map((field) => ({ field, kind: 'login' as const })),
      ...this.newFields.slice(0, 1).map((field) => ({ field, kind: 'newPassword' as const })),
    ]);
    return this.fields;
  }

  /** The field the list is placed at: the focused login field, else the
   *  user-name field, else the password or one-time-code field. */
  private anchor(): HTMLInputElement | undefined {
    if (this.anchorField?.isConnected) return this.anchorField;
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
      case 'tsm.doFillNew': {
        if (message.token !== this.token) return null;
        this.refresh();
        for (const field of this.newFields) setFieldValue(field, message.password);
        await this.closeList(false);
        return { filled: this.newFields.length };
      }
      case 'tsm.showBar':
        if (!this.isTop()) return null;
        this.showBar(message.token, message.barUrl);
        return { shown: true };
      case 'tsm.closeBar':
        if (message.token === this.barToken) this.removeBar();
        return { closed: true };
      default:
        return null;
    }
  }

  /** Asks the background for a list at this frame's login field ([at],
   *  else the focused one) and shows it; at a new-password field
   *  ([newPassword]) the list suggests a password. Answers whether one is
   *  shown. */
  async openList(at?: HTMLInputElement, newPassword = false): Promise<boolean> {
    this.refresh();
    if (newPassword ? this.newFields.length === 0 : !hasLogin(this.fields)) return false;
    const answer = (await this.api.runtime.sendMessage({
      op: 'tsm.openList',
      otpField: Boolean(this.fields.otp),
      newPassword,
    })) as { token?: string; listUrl?: string } | undefined;
    if (!answer?.token || !answer.listUrl) return false;
    this.removeList();
    this.token = answer.token;
    this.anchorField = at;
    this.showList(answer.listUrl);
    return true;
  }

  /** The bar "Save in Tom Secrets Manager?" at the top right of the page. */
  private showBar(token: string, barUrl: string): void {
    this.removeBar();
    const host = this.doc.createElement('tom-secrets-bar');
    const root = host.attachShadow({ mode: 'closed' });
    const frame = this.doc.createElement('iframe');
    frame.src = barUrl;
    frame.title = 'Tom Secrets Manager';
    frame.style.cssText =
      `width:${barWidth}px;height:${barHeight}px;border:0;` +
      'border-radius:8px;box-shadow:0 4px 18px rgba(0,0,0,.25);background:#fff;';
    root.appendChild(frame);
    host.style.cssText =
      'all:initial;position:fixed;z-index:2147483647;top:12px;right:12px;';
    (this.doc.body ?? this.doc.documentElement).appendChild(host);
    this.barToken = token;
    this.barHost = host;
  }

  private removeBar(): void {
    this.barHost?.remove();
    this.barHost = undefined;
    this.barToken = undefined;
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
    this.anchorField = undefined;
  }

  private async closeList(tell: boolean): Promise<void> {
    const token = this.token;
    this.removeList();
    if (tell && token) {
      await this.api.runtime.sendMessage({ op: 'tsm.close', token }).catch(() => undefined);
    }
  }
}
