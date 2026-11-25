// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Reading a QR code from an image (a TOTP setup page's code): an image file,
/// a picture on the clipboard or a capture of the screen. The decoder is
/// `zxing2` (pure Dart, BSD-3); a PNG or JPEG is decoded by Flutter's own
/// codec. The image stays in memory and every buffer holding it is
/// overwritten once read.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:zxing2/qrcode.dart';

/// An image a QR code is read from: [TomSecretsQrImage.encoded] (a PNG,
/// JPEG, TIFF or BMP file's bytes) or [TomSecretsQrImage.rgba] (pixels).
sealed class TomSecretsQrImage {
  const TomSecretsQrImage();

  /// The bytes of an image file.
  const factory TomSecretsQrImage.encoded(Uint8List bytes) = _EncodedImage;

  /// [width] × [height] pixels, four bytes each in [order], rows top to
  /// bottom without padding.
  const factory TomSecretsQrImage.rgba(
    int width,
    int height,
    Uint8List pixels, {
    TomSecretsPixelOrder order,
  }) = _RgbaImage;

  /// Overwrites the image's bytes.
  void clear();
}

/// The byte order of a pixel.
enum TomSecretsPixelOrder {
  /// Red, green, blue, alpha (Flutter, macOS).
  rgba,

  /// Blue, green, red, alpha (Windows).
  bgra,
}

final class _EncodedImage extends TomSecretsQrImage {
  const _EncodedImage(this.bytes);
  final Uint8List bytes;

  @override
  void clear() => _overwrite(bytes);
}

/// Overwrites [bytes]; a view it may not change (a platform message's
/// buffer, which the engine frees itself) is left as it is.
void _overwrite(Uint8List bytes) {
  try {
    bytes.fillRange(0, bytes.length, 0);
  } on UnsupportedError {
    // Unmodifiable: nothing of ours to clear.
  }
}

final class _RgbaImage extends TomSecretsQrImage {
  const _RgbaImage(
    this.width,
    this.height,
    this.pixels, {
    this.order = TomSecretsPixelOrder.rgba,
  });
  final int width;
  final int height;
  final Uint8List pixels;
  final TomSecretsPixelOrder order;

  @override
  void clear() => _overwrite(pixels);
}

/// Why no QR code was read.
final class TomSecretsQrException implements Exception {
  /// Not read for [message].
  const TomSecretsQrException(this.message);

  /// What went wrong, for the user.
  final String message;

  @override
  String toString() => message;
}

/// The text of the QR code in [image], or null when it holds none. The
/// image's bytes are overwritten afterwards, read or not. Throws
/// [TomSecretsQrException] for an image file it cannot decode.
Future<String?> tomSecretsReadQr(TomSecretsQrImage image) async {
  try {
    switch (image) {
      case _EncodedImage(:final bytes):
        final decoded = await _decode(bytes);
        try {
          return tomSecretsReadQrPixels(
            decoded.width,
            decoded.height,
            decoded.pixels,
          );
        } finally {
          decoded.pixels.fillRange(0, decoded.pixels.length, 0);
        }
      case _RgbaImage(:final width, :final height, :final pixels, :final order):
        return tomSecretsReadQrPixels(width, height, pixels, order: order);
    }
  } finally {
    image.clear();
  }
}

Future<({int width, int height, Uint8List pixels})> _decode(
  Uint8List bytes,
) async {
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
  } on Exception {
    throw const TomSecretsQrException('the file is not an image it can read');
  }
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData();
      if (data == null) {
        throw const TomSecretsQrException('the image could not be read');
      }
      return (
        width: image.width,
        height: image.height,
        pixels: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// The text of the QR code in [width] × [height] [pixels] (four bytes
/// each), or null when it holds none. Light codes on a dark background
/// (dark mode) are read too.
String? tomSecretsReadQrPixels(
  int width,
  int height,
  Uint8List pixels, {
  TomSecretsPixelOrder order = TomSecretsPixelOrder.rgba,
}) {
  if (width <= 0 || height <= 0 || pixels.length < width * height * 4) {
    return null;
  }
  final source = _LumaSource(width, height, pixels, order);
  try {
    final hints = DecodeHints()..put(DecodeHintType.tryHarder);
    for (final luminance in [source, source.invert()]) {
      for (final binarizer in [
        HybridBinarizer(luminance),
        GlobalHistogramBinarizer(luminance),
      ]) {
        try {
          return QRCodeReader()
              .decode(BinaryBitmap(binarizer), hints: hints)
              .text;
        } on ReaderException {
          continue;
        }
      }
    }
    return null;
  } finally {
    source.clear();
  }
}

/// The luminance of every pixel (one byte each), computed once.
final class _LumaSource extends LuminanceSource {
  _LumaSource(
    super.width,
    super.height,
    Uint8List pixels,
    TomSecretsPixelOrder o,
  ) : _luma = Int8List(width * height) {
    final red = o == TomSecretsPixelOrder.rgba ? 0 : 2;
    final blue = 2 - red;
    for (var i = 0, p = 0; i < _luma.length; i++, p += 4) {
      final a = pixels[p + 3];
      // Why: a transparent pixel (a PNG's background) reads as white, the
      // way it is shown, not as black.
      final r = (pixels[p + red] * a + 255 * (255 - a)) ~/ 255;
      final g = (pixels[p + 1] * a + 255 * (255 - a)) ~/ 255;
      final b = (pixels[p + blue] * a + 255 * (255 - a)) ~/ 255;
      _luma[i] = (r * 77 + g * 150 + b * 29) >> 8;
    }
  }

  final Int8List _luma;

  void clear() => _luma.fillRange(0, _luma.length, 0);

  @override
  Int8List getRow(int y, Int8List? row) {
    final out = row != null && row.length >= width ? row : Int8List(width);
    out.setRange(0, width, _luma, y * width);
    return out;
  }

  @override
  Int8List getMatrix() => _luma;
}
