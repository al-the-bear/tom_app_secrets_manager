// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// CRC-32 (IEEE 802.3), as PNG chunks and ZIP entries carry it.

const table = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

/** The CRC-32 of [bytes]. */
export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (const b of bytes) c = table[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
