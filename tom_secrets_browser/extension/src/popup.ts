// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The toolbar popup: the active tab's logins (its top frame) with a filter,
// the service's state and what to do about it, and whether the extension
// offers to save logins on this site ("Never for this site" undone here).

import { extensionApi } from './api';
import type { ListAnswer } from './messages';
import { renderList } from './view';

const api = extensionApi();
const root = document.getElementById('tsm-root') as HTMLElement;

async function load(unlock = false): Promise<void> {
  const answer = (await api.runtime.sendMessage({ op: 'tsm.popup', unlock })) as ListAnswer & {
    token?: string;
  };
  const token = answer.token;
  renderList(root, answer, {
    fill: (entryId) => void fill(token, entryId),
    copyCode: (entryId) => void copyCode(token, entryId),
    unlock: () => void load(true),
    openApp: (entryId) => void api.runtime.sendMessage({ op: 'tsm.openApp', entryId }),
    frameSite: () => undefined,
  });
  if (answer.site) root.append(neverToggle(answer.never === true));
}

/** "Offer to save logins on this site": off after "Never for this site". */
function neverToggle(never: boolean): HTMLElement {
  const label = document.createElement('label');
  label.id = 'tsm-never-toggle';
  const box = document.createElement('input');
  box.type = 'checkbox';
  box.checked = !never;
  box.addEventListener('change', () => {
    void api.runtime.sendMessage({ op: 'tsm.never', never: !box.checked });
  });
  label.append(box, ' Offer to save logins on this site');
  return label;
}

async function fill(token: string | undefined, entryId: string): Promise<void> {
  if (!token) return;
  await api.runtime.sendMessage({ op: 'tsm.fill', token, entryId });
  window.close();
}

async function copyCode(token: string | undefined, entryId: string): Promise<void> {
  if (!token) return;
  const a = (await api.runtime.sendMessage({ op: 'tsm.totp', token, entryId })) as {
    totp?: string | null;
  };
  if (a?.totp) await navigator.clipboard.writeText(a.totp);
}

void load();
