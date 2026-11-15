// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The print path (`printing`): a PDF handed to the system print dialog on
/// macOS, Windows and Linux (the emergency sheet, BP-37).
library;

import 'dart:typed_data';

import 'package:printing/printing.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// [TomSecretsPrinter] over the system print dialog.
final class TomSecretsDesktopPrinter implements TomSecretsPrinter {
  /// The printer.
  const TomSecretsDesktopPrinter();

  @override
  Future<bool> printPdf(String name, Uint8List pdf) =>
      Printing.layoutPdf(onLayout: (_) async => pdf, name: name);
}
