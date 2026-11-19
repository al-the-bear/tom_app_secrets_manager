// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The bar "Save in Tom Secrets Manager?" (part-browser, Proposing a login):
// the extension's own page in an iframe at the top of the tab. It knows its
// token only; the background answers it the site, the user name and whether
// the login is new or a changed password, never the password itself.

import { extensionApi } from './api';
import type { BarAnswer, HostError } from './messages';
import { renderBar, renderBarOutcome } from './view';

const api = extensionApi();
const token = location.hash.slice(1);
const root = document.getElementById('tsm-root') as HTMLElement;

/** How long the outcome stays before the bar closes. */
const outcomeMs = 4000;

async function answer(choice: 'save' | 'notNow' | 'never'): Promise<void> {
  const a = (await api.runtime.sendMessage({ op: 'tsm.barAnswer', token, answer: choice })) as {
    error?: HostError;
  };
  if (choice !== 'save') return;
  renderBarOutcome(root, a?.error);
  setTimeout(
    () => void api.runtime.sendMessage({ op: 'tsm.barAnswer', token, answer: 'close' }),
    outcomeMs,
  );
}

async function load(): Promise<void> {
  const bar = (await api.runtime.sendMessage({ op: 'tsm.bar', token })) as
    | (BarAnswer & { error?: unknown })
    | undefined;
  if (!bar || bar.error) {
    void api.runtime.sendMessage({ op: 'tsm.barAnswer', token, answer: 'close' });
    return;
  }
  renderBar(root, bar, {
    save: () => void answer('save'),
    notNow: () => void answer('notNow'),
    never: () => void answer('never'),
  });
}

void load();
