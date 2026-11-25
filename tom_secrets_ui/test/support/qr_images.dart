// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// QR codes drawn for the tests: a demo text encoded with zxing2's encoder
/// and painted into pixels or a PNG, with a quiet zone, as a setup page
/// shows it.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:zxing2/qrcode.dart';

/// [text]'s QR code as RGBA pixels: [scale] pixels per module, a white
/// quiet zone of four modules, [inverted] light on dark; placed at
/// ([left], [top]) in a [canvasWidth] × [canvasHeight] grey canvas when
/// given (a code somewhere on a screen).
({int width, int height, Uint8List pixels}) qrPixels(
  String text, {
  int scale = 6,
  bool inverted = false,
  int? canvasWidth,
  int? canvasHeight,
  int left = 0,
  int top = 0,
}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  final size = (matrix.width + 8) * scale;
  final width = canvasWidth ?? size;
  final height = canvasHeight ?? size;
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels
      ..[i] = 0x80
      ..[i + 1] = 0x80
      ..[i + 2] = 0x80
      ..[i + 3] = 0xff;
  }
  final dark = inverted ? 0xff : 0x00;
  final light = inverted ? 0x10 : 0xff;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final mx = x ~/ scale - 4;
      final my = y ~/ scale - 4;
      final on =
          mx >= 0 &&
          my >= 0 &&
          mx < matrix.width &&
          my < matrix.height &&
          matrix.get(mx, my) == 1;
      final p = ((top + y) * width + left + x) * 4;
      final v = on ? dark : light;
      pixels
        ..[p] = v
        ..[p + 1] = v
        ..[p + 2] = v
        ..[p + 3] = 0xff;
    }
  }
  return (width: width, height: height, pixels: pixels);
}

/// [text]'s QR code as a PNG file's bytes (run inside `runAsync`).
Future<Uint8List> qrPng(String text, {int scale = 6}) async {
  final image = qrPixels(text, scale: scale);
  final buffer = await ui.ImmutableBuffer.fromUint8List(image.pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: image.width,
    height: image.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return png!.buffer.asUint8List();
}
