// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The small icon in the user-name, password and new-password fields
// (part-browser, Offering): a click opens the list at that field (a
// suggested password at a new-password field). Each icon is a button in a
// closed shadow root laid over the field's right edge, so the page can
// neither read nor restyle it; it follows the field when the page scrolls
// or resizes, and goes when the field goes.

/** What an icon is for. */
export type IconKind = 'login' | 'newPassword';

/** The icon's size, in CSS pixels. */
export const iconSize = 18;

/** Fields too small for an icon are left without one. */
const minFieldWidth = 60;
const minFieldHeight = 16;

/** The shield with a keyhole (the app's colour), built element by element:
 *  no markup parsing, so a page's Trusted Types policy has nothing to
 *  refuse. */
const shieldPath =
  'M12 1 3 5v6c0 5.6 3.8 10.7 9 12 5.2-1.3 9-6.4 9-12V5l-9-4zm0 6a3 3 0 0 1 ' +
  '1.5 5.6V17h-3v-4.4A3 3 0 0 1 12 7z';

function shield(doc: Document): SVGSVGElement {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = doc.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', String(iconSize));
  svg.setAttribute('height', String(iconSize));
  svg.setAttribute('aria-hidden', 'true');
  const path = doc.createElementNS(ns, 'path');
  path.setAttribute('fill', '#2E6B5A');
  path.setAttribute('d', shieldPath);
  svg.appendChild(path);
  return svg;
}

interface Icon {
  field: HTMLInputElement;
  kind: IconKind;
  host: HTMLElement;
}

/** The icons of one document. */
export class FieldIcons {
  private icons: Icon[] = [];
  private framePending = false;

  constructor(
    private readonly doc: Document,
    private readonly onClick: (field: HTMLInputElement, kind: IconKind) => void,
  ) {
    const view = doc.defaultView;
    const later = () => this.schedulePlace();
    view?.addEventListener('scroll', later, { capture: true, passive: true });
    view?.addEventListener('resize', later, { passive: true });
  }

  /** The fields that have an icon now. */
  get fields(): HTMLInputElement[] {
    return this.icons.map((i) => i.field);
  }

  /** Shows an icon at each of [targets], removing those of fields gone;
   *  icons of fields still there stay as they are. */
  update(targets: Array<{ field: HTMLInputElement; kind: IconKind }>): void {
    const keep: Icon[] = [];
    for (const icon of this.icons) {
      const still = targets.find((t) => t.field === icon.field && t.kind === icon.kind);
      if (still && icon.field.isConnected) keep.push(icon);
      else icon.host.remove();
    }
    for (const t of targets) {
      if (keep.some((i) => i.field === t.field)) continue;
      keep.push({ ...t, host: this.create(t.field, t.kind) });
    }
    this.icons = keep;
    this.place();
  }

  /** Removes every icon. */
  clear(): void {
    for (const icon of this.icons) icon.host.remove();
    this.icons = [];
  }

  private create(field: HTMLInputElement, kind: IconKind): HTMLElement {
    const host = this.doc.createElement('tom-secrets-icon');
    const root = host.attachShadow({ mode: 'closed' });
    const button = this.doc.createElement('button');
    button.type = 'button';
    button.title =
      kind === 'newPassword'
        ? 'Suggest a password (Tom Secrets Manager)'
        : 'Logins from Tom Secrets Manager';
    button.style.cssText =
      `all:initial;cursor:pointer;display:block;width:${iconSize}px;height:${iconSize}px;`;
    button.appendChild(shield(this.doc));
    // Keep the field's focus: the click alone opens the list.
    button.addEventListener('mousedown', (e) => e.preventDefault());
    button.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      this.onClick(field, kind);
    });
    root.appendChild(button);
    host.style.cssText = 'all:initial;position:absolute;z-index:2147483646;display:none;';
    (this.doc.body ?? this.doc.documentElement).appendChild(host);
    return host;
  }

  private schedulePlace(): void {
    if (this.framePending) return;
    this.framePending = true;
    const view = this.doc.defaultView;
    const run = () => {
      this.framePending = false;
      this.place();
    };
    if (view?.requestAnimationFrame) view.requestAnimationFrame(run);
    else run();
  }

  /** Puts each icon over its field's right edge; hides it while the field
   *  is not shown or too small. */
  place(): void {
    const view = this.doc.defaultView;
    for (const { field, host } of this.icons) {
      const rect = field.getBoundingClientRect();
      if (rect.width < minFieldWidth || rect.height < minFieldHeight) {
        host.style.display = 'none';
        continue;
      }
      const top = rect.top + (view?.scrollY ?? 0) + (rect.height - iconSize) / 2;
      const left = rect.right + (view?.scrollX ?? 0) - iconSize - 6;
      host.style.display = 'block';
      host.style.top = `${Math.round(top)}px`;
      host.style.left = `${Math.round(left)}px`;
    }
  }
}
