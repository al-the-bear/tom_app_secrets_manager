// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Filling (part-browser): a field's value is set through the input
// element's own setter (so frameworks that track the value see it), then
// the `input` and `change` events they listen to are sent. A page that
// clears what it did not set itself gets one more try with simulated key
// events.

import type { FillValues } from './messages';
import type { LoginFields } from './detect';

/** Sets [input]'s value as typing would show it to the page's scripts. */
export function setFieldValue(input: HTMLInputElement, value: string): void {
  const view = input.ownerDocument.defaultView;
  const proto = view?.HTMLInputElement.prototype ?? HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
  input.focus();
  if (setter) {
    setter.call(input, value);
  } else {
    input.value = value;
  }
  const Ev = view?.Event ?? Event;
  input.dispatchEvent(new Ev('input', { bubbles: true }));
  input.dispatchEvent(new Ev('change', { bubbles: true }));
}

/** Types [value] into [input] key by key (the retry). */
export function typeFieldValue(input: HTMLInputElement, value: string): void {
  const view = input.ownerDocument.defaultView;
  const Key = view?.KeyboardEvent ?? KeyboardEvent;
  const Input = view?.InputEvent ?? view?.Event ?? Event;
  input.focus();
  setFieldValue(input, '');
  let typed = '';
  for (const ch of value) {
    input.dispatchEvent(new Key('keydown', { key: ch, bubbles: true }));
    typed += ch;
    const setter = Object.getOwnPropertyDescriptor(
      view?.HTMLInputElement.prototype ?? HTMLInputElement.prototype,
      'value',
    )?.set;
    if (setter) setter.call(input, typed);
    else input.value = typed;
    input.dispatchEvent(new Input('input', { bubbles: true }));
    input.dispatchEvent(new Key('keyup', { key: ch, bubbles: true }));
  }
  input.dispatchEvent(new (view?.Event ?? Event)('change', { bubbles: true }));
}

/** What a fill did. */
export interface FillOutcome {
  userName: boolean;
  password: boolean;
  totp: boolean;
}

/** Fills [fields] with [values]; after [retryAfterMs] a field the page
 *  cleared is typed once more. */
export async function fillLogin(
  fields: LoginFields,
  values: FillValues,
  retryAfterMs = 300,
): Promise<FillOutcome> {
  const pairs: Array<[HTMLInputElement | undefined, string | undefined]> = [
    [fields.userName, values.userName],
    [fields.password, values.password],
    [fields.otp, values.totp],
  ];
  for (const [field, value] of pairs) {
    if (field && value) setFieldValue(field, value);
  }
  if (retryAfterMs > 0) {
    await new Promise((r) => setTimeout(r, retryAfterMs));
    for (const [field, value] of pairs) {
      if (field && value && field.value !== value) typeFieldValue(field, value);
    }
  }
  return {
    userName: Boolean(fields.userName && values.userName),
    password: Boolean(fields.password && values.password),
    totp: Boolean(fields.otp && values.totp),
  };
}
