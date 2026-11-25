// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop's QR reader: a demo otpauth:// URI's code read from pixels
/// (RGBA and Windows' BGRA, on a larger "screen", light on dark), from a
/// PNG, and nothing from an image without one; the bytes overwritten after.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/qr_images.dart';

const _uri =
    'otpauth://totp/Demo:demo-user?secret=JBSWY3DPEHPK3PXP&issuer=Demo';

void main() {
  test('pixels: the code is read, as RGBA and as BGRA', () {
    final image = qrPixels(_uri);
    expect(
      tomSecretsReadQrPixels(image.width, image.height, image.pixels),
      _uri,
    );
    expect(
      tomSecretsReadQrPixels(
        image.width,
        image.height,
        image.pixels,
        order: TomSecretsPixelOrder.bgra,
      ),
      _uri,
      reason: 'a grey code reads the same in either order',
    );
    expect(TomSecretsTotp.parse(_uri)!.issuer, 'Demo');
  });

  test('a code somewhere on a larger screen, and light on dark', () {
    final screen = qrPixels(
      _uri,
      scale: 4,
      canvasWidth: 1600,
      canvasHeight: 1000,
      left: 900,
      top: 300,
    );
    expect(
      tomSecretsReadQrPixels(screen.width, screen.height, screen.pixels),
      _uri,
    );
    final dark = qrPixels(_uri, inverted: true);
    expect(tomSecretsReadQrPixels(dark.width, dark.height, dark.pixels), _uri);
  });

  test('an image without a code: null; the image is overwritten', () async {
    final blank = Uint8List(200 * 200 * 4)..fillRange(0, 200 * 200 * 4, 0xff);
    final image = TomSecretsQrImage.rgba(200, 200, blank);
    expect(await tomSecretsReadQr(image), isNull);
    expect(blank.every((b) => b == 0), isTrue);

    final code = qrPixels(_uri);
    expect(
      await tomSecretsReadQr(
        TomSecretsQrImage.rgba(code.width, code.height, code.pixels),
      ),
      _uri,
    );
    expect(code.pixels.every((b) => b == 0), isTrue, reason: 'overwritten');

    // A platform message's bytes are an unmodifiable view: read all the
    // same, left for the engine to free.
    final view = qrPixels(_uri);
    expect(
      await tomSecretsReadQr(
        TomSecretsQrImage.rgba(
          view.width,
          view.height,
          view.pixels.asUnmodifiableView(),
        ),
      ),
      _uri,
    );
  });

  testWidgets('a PNG file is decoded and read; a file that is no image is '
      'refused', (tester) async {
    await tester.runAsync(() async {
      final png = await qrPng(_uri);
      expect(await tomSecretsReadQr(TomSecretsQrImage.encoded(png)), _uri);
      expect(png.every((b) => b == 0), isTrue, reason: 'overwritten');
      await expectLater(
        tomSecretsReadQr(
          TomSecretsQrImage.encoded(
            Uint8List.fromList('not an image'.codeUnits),
          ),
        ),
        throwsA(isA<TomSecretsQrException>()),
      );
    });
  });
}
