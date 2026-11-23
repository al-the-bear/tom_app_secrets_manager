// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The candidate list as the in-page list and the popup show it: the site,
// the service's state with what to do about it, the logins (title and user
// name, never a value) with a filter, and per login Fill and, for one with a
// TOTP, Copy code.

import type { BarAnswer, Candidate, HostError, ListAnswer } from './messages';

/** What the view's buttons do. */
export interface ViewActions {
  fill(entryId: string): void;
  copyCode(entryId: string): void;
  unlock(): void;
  openApp(entryId?: string): void;
  frameSite(): void;
  close?(): void;
}

function el<K extends keyof HTMLElementTagNameMap>(
  doc: Document,
  tag: K,
  props: { text?: string; className?: string; id?: string } = {},
): HTMLElementTagNameMap[K] {
  const e = doc.createElement(tag);
  if (props.text !== undefined) e.textContent = props.text;
  if (props.className) e.className = props.className;
  if (props.id) e.id = props.id;
  return e;
}

function button(doc: Document, text: string, id: string, onClick: () => void): HTMLButtonElement {
  const b = el(doc, 'button', { text, id });
  b.type = 'button';
  b.addEventListener('click', onClick);
  return b;
}

/** A refusal in words. */
export function describeError(error: HostError): string {
  switch (error.kind) {
    case 'unreachable':
      return error.message;
    case 'denied':
      return error.reason === 'not_allowed_op'
        ? 'Tom Secrets Manager does not recognise this browser host: reinstall the browser integration.'
        : `Not allowed: ${error.message}`;
    case 'not_running':
      return 'Tom Secrets Manager is not running.';
    case 'locked':
      return 'Tom Secrets Manager is locked.';
    default:
      return error.message;
  }
}

/** Renders [answer] into [root] (emptied first). */
export function renderList(root: HTMLElement, answer: ListAnswer, actions: ViewActions): void {
  const doc = root.ownerDocument;
  root.replaceChildren();
  const header = el(doc, 'header');
  const heading = answer.passkey
    ? `Sign in to ${answer.site} with a passkey`
    : answer.site
      ? `Logins for ${answer.site}`
      : 'Tom Secrets Manager';
  header.append(el(doc, 'strong', { text: heading }));
  if (actions.close) header.append(button(doc, '×', 'tsm-close', actions.close));
  root.append(header);

  if (answer.error) {
    root.append(el(doc, 'p', { text: describeError(answer.error), className: 'error', id: 'tsm-error' }));
    return;
  }
  if (answer.state === 'not_running') {
    root.append(el(doc, 'p', { text: 'Tom Secrets Manager is not running.', id: 'tsm-state' }));
    root.append(button(doc, 'Open Tom Secrets Manager', 'tsm-open-app', () => actions.openApp()));
    return;
  }
  if (answer.state === 'locked') {
    root.append(el(doc, 'p', { text: 'Tom Secrets Manager is locked.', id: 'tsm-state' }));
    root.append(button(doc, 'Unlock in Tom Secrets Manager', 'tsm-unlock', () => actions.unlock()));
    return;
  }
  if (answer.crossSite) {
    root.append(
      el(doc, 'p', {
        text: `The login form is in a frame of ${answer.crossSite}, inside ${answer.site}.`,
        id: 'tsm-cross-site',
      }),
    );
    root.append(
      button(doc, `Show the logins of ${answer.crossSite}`, 'tsm-frame-site', () =>
        actions.frameSite(),
      ),
    );
    return;
  }
  if (answer.candidates.length === 0) {
    root.append(
      el(doc, 'p', {
        text:
          'No login of this site that this browser may use. Tom Secrets Manager asks ' +
          'you to approve the browser when the app is open; a refusal stays under ' +
          'Clients › Allow list.',
        id: 'tsm-none',
      }),
    );
    return;
  }
  const filter = el(doc, 'input', { id: 'tsm-filter' });
  filter.type = 'search';
  filter.placeholder = 'Filter';
  const list = el(doc, 'ul', { id: 'tsm-candidates' });
  const show = (query: string) => {
    list.replaceChildren(
      ...answer.candidates
        .filter((c) => matchesFilter(c, query))
        .map((c) => candidateItem(doc, c, actions)),
    );
  };
  filter.addEventListener('input', () => show(filter.value));
  if (answer.candidates.length > 5) root.append(filter);
  root.append(list);
  show('');
}

/** Whether [c] matches the filter [query] (title, user name, URL). */
export function matchesFilter(c: Candidate, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return [c.title, c.userName, c.matchedUrl].some((t) => t.toLowerCase().includes(q));
}

function candidateItem(doc: Document, c: Candidate, actions: ViewActions): HTMLLIElement {
  const item = el(doc, 'li', { className: 'candidate' });
  item.dataset.entry = c.entryId;
  const fill = button(doc, '', `tsm-fill-${c.entryId}`, () => actions.fill(c.entryId));
  fill.className = 'fill';
  fill.append(el(doc, 'span', { text: c.title || c.matchedUrl, className: 'title' }));
  fill.append(el(doc, 'span', { text: c.userName, className: 'user' }));
  item.append(fill);
  if (c.hasTotp) {
    item.append(button(doc, 'Copy code', `tsm-totp-${c.entryId}`, () => actions.copyCode(c.entryId)));
  }
  return item;
}

/** What the suggestion's buttons do. */
export interface SuggestionActions {
  use(password: string): void;
  another(): void;
  close?(): void;
}

/** A suggested password for a new-password field of [site]: shown, used
 *  (filled into the new-password fields) or replaced by another. */
export function renderSuggestion(
  root: HTMLElement,
  site: string,
  password: string,
  actions: SuggestionActions,
): void {
  const doc = root.ownerDocument;
  root.replaceChildren();
  const header = el(doc, 'header');
  header.append(el(doc, 'strong', { text: `A new password for ${site}` }));
  if (actions.close) header.append(button(doc, '×', 'tsm-close', actions.close));
  root.append(header);
  root.append(
    el(doc, 'p', {
      text: 'Suggested by Tom Secrets Manager. After you submit the form, the extension offers to save it.',
    }),
  );
  root.append(el(doc, 'code', { text: password, id: 'tsm-suggestion', className: 'suggestion' }));
  const row = el(doc, 'div', { className: 'actions' });
  row.append(button(doc, 'Use this password', 'tsm-use-suggestion', () => actions.use(password)));
  row.append(button(doc, 'Another', 'tsm-another', actions.another));
  root.append(row);
}

/** What the bar's buttons do. */
export interface BarActions {
  save(): void;
  notNow(): void;
  never(): void;
}

/** The bar "Save in Tom Secrets Manager?" for [answer]: never the password. */
export function renderBar(root: HTMLElement, answer: BarAnswer, actions: BarActions): void {
  const doc = root.ownerDocument;
  root.replaceChildren();
  const what =
    answer.state === 'changed'
      ? `Update the password of ${answer.userName ?? 'your login'} for ${answer.site}?`
      : `Save the login${answer.userName ? ` ${answer.userName}` : ''} for ${answer.site}?`;
  root.append(el(doc, 'strong', { text: 'Save in Tom Secrets Manager?', id: 'tsm-bar-title' }));
  root.append(el(doc, 'p', { text: what, id: 'tsm-bar-what' }));
  const row = el(doc, 'div', { className: 'actions' });
  row.append(button(doc, 'Save', 'tsm-bar-save', actions.save));
  row.append(button(doc, 'Not now', 'tsm-bar-not-now', actions.notNow));
  row.append(button(doc, 'Never for this site', 'tsm-bar-never', actions.never));
  root.append(row);
}

/** The bar after Save: where the login went, or why it did not. */
export function renderBarOutcome(root: HTMLElement, error?: HostError): void {
  const doc = root.ownerDocument;
  root.replaceChildren();
  root.append(el(doc, 'strong', { text: 'Tom Secrets Manager' }));
  root.append(
    el(doc, 'p', {
      id: 'tsm-bar-outcome',
      text: error
        ? error.kind === 'unavailable'
          ? 'Tom Secrets Manager is not open, so the login could not be handed to it.'
          : error.kind === 'denied'
            ? 'Tom Secrets Manager refused it: approve this browser ("Always in this browser") first.'
            : describeError(error)
        : 'Sent to the app: save it there under Proposals.',
    }),
  );
}
