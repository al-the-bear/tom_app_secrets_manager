// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Form detection (part-browser, "The fill UI in the page"): password fields,
// the user-name field before each (by `autocomplete` first, then by type and
// name, then by position), one-time-code fields; open shadow roots are
// searched too. A login split over two pages (the user name first) is a
// user-name field with no password field after it.

/** A login form's fields in one document. */
export interface LoginFields {
  userName?: HTMLInputElement;
  password?: HTMLInputElement;
  otp?: HTMLInputElement;
}

const userNameAutocomplete = new Set(['username', 'email']);
const userNameNames = /user|login|email|e-mail|account|identifier|ident|nutzer|benutzer/i;
const otpNames = /otp|totp|2fa|mfa|one.?time|token|verification|code/i;

/** Every input of [root] and the open shadow roots below it, in order. */
export function allInputs(root: Document | ShadowRoot | Element): HTMLInputElement[] {
  const found: HTMLInputElement[] = [];
  const walk = (node: Document | ShadowRoot | Element) => {
    for (const el of Array.from(node.querySelectorAll('*'))) {
      if (el instanceof (el.ownerDocument?.defaultView ?? globalThis).HTMLInputElement) {
        found.push(el as HTMLInputElement);
      }
      const shadow = (el as Element).shadowRoot;
      if (shadow) walk(shadow);
    }
  };
  walk(root);
  return found;
}

/** Whether [input] can be filled (shown, enabled, writable). */
export function fillable(input: HTMLInputElement): boolean {
  if (input.disabled || input.readOnly) return false;
  if (input.type === 'hidden') return false;
  const style = input.ownerDocument.defaultView?.getComputedStyle(input);
  return !(style && (style.display === 'none' || style.visibility === 'hidden'));
}

function autocompleteOf(input: HTMLInputElement): string[] {
  return (input.getAttribute('autocomplete') ?? '').toLowerCase().split(/\s+/);
}

/** Whether [input] is a one-time-code field. */
export function isOtpField(input: HTMLInputElement): boolean {
  if (autocompleteOf(input).includes('one-time-code')) return true;
  if (input.type === 'password' || input.type === 'email') return false;
  const named = `${input.name} ${input.id}`;
  return (
    otpNames.test(named) &&
    (input.inputMode === 'numeric' || input.maxLength === 6 || input.maxLength === 8)
  );
}

/** Whether [input] looks like a user-name field. */
export function isUserNameField(input: HTMLInputElement): boolean {
  const ac = autocompleteOf(input);
  if (ac.some((a) => userNameAutocomplete.has(a))) return true;
  if (ac.includes('current-password') || ac.includes('new-password')) return false;
  if (input.type === 'email') return true;
  if (input.type !== 'text' && input.type !== '') return false;
  if (isOtpField(input)) return false;
  return userNameNames.test(`${input.name} ${input.id} ${input.placeholder}`);
}

/** The login fields of [root]: the first fillable password field, the
 *  user-name field before it (or the one alone, a split login), the
 *  one-time-code field. */
export function loginFields(root: Document | ShadowRoot | Element): LoginFields {
  const inputs = allInputs(root).filter(fillable);
  const passwords = inputs.filter((i) => i.type === 'password');
  // A current password before any other; a new password is never filled (a
  // change form fills the current one, a sign-up form none).
  const password =
    passwords.find((p) => autocompleteOf(p).includes('current-password')) ??
    passwords.find((p) => !autocompleteOf(p).includes('new-password'));
  const otp = inputs.find(isOtpField);
  let userName: HTMLInputElement | undefined;
  if (password) {
    const before = inputs.slice(0, inputs.indexOf(password));
    userName =
      [...before].reverse().find(isUserNameField) ??
      [...before].reverse().find((i) => i.type === 'text' || i.type === 'email');
  } else {
    userName = inputs.find(isUserNameField);
  }
  return { userName, password, otp };
}

/** Whether [fields] hold anything to fill. */
export function hasLogin(fields: LoginFields): boolean {
  return Boolean(fields.password ?? fields.userName ?? fields.otp);
}
