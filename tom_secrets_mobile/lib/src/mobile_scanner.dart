// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The camera's QR reader (part-mobile): `mobile_scanner` (BSD-3) over
/// Apple's AVFoundation on iOS and Google's ML Kit barcode model on Android,
/// bundled into the APK so no Play services are needed (tsm_b_mobile1,
/// decision (a); ML Kit is closed source, named in THIRD_PARTY.md). It reads
/// the desktop's pairing code and a TOTP secret's code; the camera
/// permission is asked the first time it opens.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart' show TomSecretsCodeScanner;

/// [TomSecretsCodeScanner] over `mobile_scanner`: a full-screen camera page
/// that closes on the first QR code it reads.
final class TomSecretsMobileCodeScanner implements TomSecretsCodeScanner {
  /// The scanner.
  const TomSecretsMobileCodeScanner();

  @override
  Future<String?> scan(BuildContext context, {required String title}) =>
      Navigator.of(context).push<String>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => _ScanPage(title: title),
        ),
      );
}

class _ScanPage extends StatefulWidget {
  const _ScanPage({required this.title});

  final String title;

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final value = b.rawValue;
      if (value != null && value.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: MobileScanner(
      key: const Key('tsm-mobile-camera'),
      controller: _controller,
      onDetect: _detected,
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error.errorCode == MobileScannerErrorCode.permissionDenied
                ? 'The camera is not allowed. Allow it in the system '
                      'settings for Tom Secrets, or type the code instead.'
                : 'The camera cannot be used: '
                      '${error.errorDetails?.message ?? error.errorCode.name}. '
                      'Type the code instead.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
}
