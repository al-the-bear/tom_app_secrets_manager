// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The candidate list in the page: the extension's own page in an iframe,
// opened for one field of one frame; its token (in the address's fragment)
// is all it knows, and the background answers it only for that token.

import { extensionApi } from './api';
import { suggestPassword } from './generator';
import type { ListAnswer } from './messages';
import { renderList, renderSuggestion } from './view';

const api = extensionApi();
const token = location.hash.slice(1);
const root = document.getElementById('tsm-root') as HTMLElement;

async function load(extra: { frameSite?: boolean; unlock?: boolean } = {}): Promise<void> {
  const answer = (await api.runtime.sendMessage({ op: 'tsm.list', token, ...extra })) as ListAnswer;
  if (answer.newPassword) {
    suggest(answer.site);
    return;
  }
  renderList(root, answer, {
    fill: (entryId) => void api.runtime.sendMessage({ op: 'tsm.fill', token, entryId }),
    copyCode: (entryId) => void copyCode(entryId),
    unlock: () => void load({ unlock: true }),
    openApp: (entryId) => void api.runtime.sendMessage({ op: 'tsm.openApp', entryId }),
    frameSite: () => void load({ frameSite: true }),
    close: () => void api.runtime.sendMessage({ op: 'tsm.close', token }),
  });
}

/** A new-password field: a suggestion, filled on "Use this password". */
function suggest(site: string): void {
  renderSuggestion(root, site, suggestPassword(), {
    use: (password) => void api.runtime.sendMessage({ op: 'tsm.fillNew', token, password }),
    another: () => suggest(site),
    close: () => void api.runtime.sendMessage({ op: 'tsm.close', token }),
  });
}

async function copyCode(entryId: string): Promise<void> {
  const a = (await api.runtime.sendMessage({ op: 'tsm.totp', token, entryId })) as {
    totp?: string | null;
  };
  if (a?.totp) await navigator.clipboard.writeText(a.totp);
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') void api.runtime.sendMessage({ op: 'tsm.close', token });
});
void load();
