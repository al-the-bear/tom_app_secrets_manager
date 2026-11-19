// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The password the extension suggests in a new-password field (part-browser,
// password-change forms): the product generator's default policy
// (tom_secrets_core's TomSecretsPasswordGenerator): 20 characters from lower
// and upper case letters, digits and the printable ASCII symbols, one of
// each class at least, drawn without bias from the browser's CSPRNG and
// shuffled.

const classes = [
  'abcdefghijklmnopqrstuvwxyz',
  'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
  '0123456789',
  '!"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~',
];

/** The default length. */
export const suggestedLength = 20;

/** A uniform integer below [bound] from [random] (rejection sampling). */
function below(bound: number, random: (into: Uint32Array) => void): number {
  const limit = Math.floor(0x100000000 / bound) * bound;
  const word = new Uint32Array(1);
  for (;;) {
    random(word);
    if (word[0] < limit) return word[0] % bound;
  }
}

/** A suggested password; [random] fills a word array (default: the
 *  browser's `crypto.getRandomValues`). */
export function suggestPassword(
  length = suggestedLength,
  random: (into: Uint32Array) => void = (into) => crypto.getRandomValues(into),
): string {
  if (length < classes.length) throw new RangeError('too short');
  const alphabet = classes.join('');
  const chars = classes.map((c) => c[below(c.length, random)]);
  while (chars.length < length) chars.push(alphabet[below(alphabet.length, random)]);
  for (let i = chars.length - 1; i > 0; i--) {
    const j = below(i + 1, random);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join('');
}
