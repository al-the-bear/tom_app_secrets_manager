// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A QR code on screen (the pairing invitation, DP-56), drawn from the `qr`
/// package's modules, dark on white with the quiet zone the standard asks,
/// whatever the theme: a scanner reads it from a dark-mode screen too.
library;

import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

/// [data] as a QR code, [size] logical pixels wide.
class TomSecretsQrCode extends StatelessWidget {
  /// The code of [data].
  const TomSecretsQrCode({super.key, required this.data, this.size = 200});

  /// The text it carries.
  final String data;

  /// Its width and height.
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'QR code',
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _QrPainter(
          QrImage(
            QrCode.fromData(
              data: data,
              errorCorrectLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
      ),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  /// The quiet zone, in modules (ISO/IEC 18004: four).
  static const int _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount + 2 * _quiet;
    final cell = size.shortestSide / n;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final dark = Paint()..color = const Color(0xFF000000);
    for (var r = 0; r < image.moduleCount; r++) {
      for (var c = 0; c < image.moduleCount; c++) {
        if (!image.isDark(r, c)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (c + _quiet) * cell,
            (r + _quiet) * cell,
            cell + 0.5,
            cell + 0.5,
          ),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
