// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The extension's icon (the toolbar, the browsers' extension pages, the
// stores): the shield with a keyhole in the app's colour, drawn here and
// written as PNG at build time, so the repository holds no binary image and
// the build needs no image tool. Node only (`node:zlib`).

import { deflateSync } from 'node:zlib';

import { crc32 } from './crc32';

/** The sizes the manifest names. */
export const iconSizes = [16, 32, 48, 128] as const;

const shield = [0x2e, 0x6b, 0x5a];

/** How much of the pixel around (x, y) (0…1 each) the shield covers, and
 *  whether that is the keyhole. */
function shade(x: number, y: number): 'shield' | 'hole' | 'none' {
  const dx = Math.abs(x - 0.5);
  // The top: two slopes meeting at the middle.
  if (y < 0.08 + 0.1 * (dx / 0.4)) return 'none';
  // The sides, rounding into the point at the bottom.
  const halfWidth = y < 0.52 ? 0.4 : 0.4 * Math.sqrt(Math.max(0, 1 - ((y - 0.52) / 0.42) ** 2));
  if (dx > halfWidth || y > 0.94) return 'none';
  const inCircle = (x - 0.5) ** 2 + (y - 0.42) ** 2 < 0.11 ** 2;
  const inStem = dx < 0.055 && y >= 0.42 && y < 0.7;
  return inCircle || inStem ? 'hole' : 'shield';
}

function chunk(type: string, data: Uint8Array): Buffer {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

/** The icon at [size] × [size] pixels as PNG (RGBA, 4 × 4 samples a pixel). */
export function iconPng(size: number): Buffer {
  const rows: number[] = [];
  const samples = 4;
  for (let py = 0; py < size; py++) {
    rows.push(0); // filter: none
    for (let px = 0; px < size; px++) {
      let covered = 0;
      let hole = 0;
      for (let sy = 0; sy < samples; sy++) {
        for (let sx = 0; sx < samples; sx++) {
          const s = shade((px + (sx + 0.5) / samples) / size, (py + (sy + 0.5) / samples) / size);
          if (s !== 'none') covered++;
          if (s === 'hole') hole++;
        }
      }
      const n = samples * samples;
      // The keyhole is white on the shield.
      const white = covered === 0 ? 0 : hole / covered;
      for (const c of shield) rows.push(Math.round(c + (255 - c) * white));
      rows.push(Math.round((255 * covered) / n));
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(Buffer.from(rows))),
    chunk('IEND', new Uint8Array(0)),
  ]);
}
