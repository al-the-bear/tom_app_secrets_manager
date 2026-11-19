// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// A ZIP archive of a few files (the store packages of the extension):
// deflated entries, names sorted and a fixed date, so the same files make
// the same bytes. Node only.

import { deflateRawSync } from 'node:zlib';

import { crc32 } from './crc32';

/** 1980-01-01 00:00, the earliest DOS date: the bytes do not depend on when. */
const dosTime = 0;
const dosDate = (1 << 5) | 1;

/** The ZIP of [files] (path with `/` → bytes). */
export function zip(files: Map<string, Uint8Array>): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const name of [...files.keys()].sort()) {
    const data = files.get(name)!;
    const packed = deflateRawSync(data);
    const nameBytes = Buffer.from(name, 'utf8');
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0x0800, 6); // UTF-8 names
    local.writeUInt16LE(8, 8); // deflate
    local.writeUInt16LE(dosTime, 10);
    local.writeUInt16LE(dosDate, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(packed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    locals.push(local, nameBytes, packed);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4); // made by
    central.writeUInt16LE(20, 6); // version needed
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt16LE(dosTime, 12);
    central.writeUInt16LE(dosDate, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(packed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, nameBytes);
    offset += 30 + nameBytes.length + packed.length;
  }
  const directory = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.size, 8);
  end.writeUInt16LE(files.size, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}
