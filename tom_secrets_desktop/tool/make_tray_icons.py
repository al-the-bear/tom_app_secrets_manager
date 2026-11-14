#!/usr/bin/env python3
# Copyright (c) 2026 Peter Nicolai Alexis Kyaw
# SPDX-License-Identifier: BSD-3-Clause
"""Draws the tray icons into assets/tray/: a padlock locked, open, and locked
with an orange dot (attention), as 32x32 PNG (macOS template images, Linux)
and as ICO holding the PNG (Windows). Run from the package root:

    python3 tool/make_tray_icons.py
"""
import math
import os
import struct
import zlib


def png(size, pixels):
    rows = b''.join(
        b'\x00' + bytes(sum((pixels[y][x] for x in range(size)), ()))
        for y in range(size))

    def chunk(kind, data):
        crc = zlib.crc32(kind + data) % (1 << 32)
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', crc)

    header = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) +
            chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))


def draw(state, color, size=32):
    clear = (0, 0, 0, 0)
    px = [[clear] * size for _ in range(size)]

    def put(x, y):
        if 0 <= x < size and 0 <= y < size:
            px[y][x] = (*color, 255)

    for y in range(14, 29):
        for x in range(7, 25):
            put(x, y)
    for y in range(19, 25):
        for x in range(15, 18):
            px[y][x] = clear
    cx, cy = 16, (10 if state == 'unlocked' else 12)
    for y in range(size):
        for x in range(size):
            d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
            if 5 <= d <= 7.5 and y + 0.5 <= cy:
                put(x, y)
    for y in range(cy, 14):
        for x in (9, 10):
            put(x, y)
        if state != 'unlocked':
            for x in (22, 23):
                put(x, y)
    if state == 'attention':
        for y in range(size):
            for x in range(size):
                if math.hypot(x + 0.5 - 26, y + 0.5 - 6) <= 5.5:
                    px[y][x] = (0xE0, 0x60, 0x00, 255)
    return png(size, px)


def main():
    out = os.path.join(os.path.dirname(__file__), '..', 'assets', 'tray')
    os.makedirs(out, exist_ok=True)
    for state in ('locked', 'unlocked', 'attention'):
        with open(os.path.join(out, state + '.png'), 'wb') as f:
            f.write(draw(state, (0, 0, 0)))
        data = draw(state, (0x30, 0x30, 0x30))
        ico = (struct.pack('<HHH', 0, 1, 1) +
               struct.pack('<BBBBHHII', 32, 32, 0, 0, 1, 32, len(data), 22) +
               data)
        with open(os.path.join(out, state + '.ico'), 'wb') as f:
            f.write(ico)
    print(sorted(os.listdir(out)))


if __name__ == '__main__':
    main()
