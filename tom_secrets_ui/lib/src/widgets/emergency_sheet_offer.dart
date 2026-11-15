// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The offer of the emergency sheet (BP-37): print it through the host's
/// print path or save it as a PDF, where the First run wizard creates a
/// vault and where a rotation changed a key.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ports/desktop_ports.dart';
import '../state/emergency_sheet.dart';

/// "Print the emergency sheet…" and "Save it as a PDF…" for the sheet
/// [sheet] makes when asked (it reads the keys as they are then).
class TomSecretsEmergencySheetOffer extends StatefulWidget {
  /// The offer of [sheet].
  const TomSecretsEmergencySheetOffer({required this.sheet, super.key});

  /// Makes the sheet.
  final Future<TomSecretsEmergencySheet> Function() sheet;

  @override
  State<TomSecretsEmergencySheetOffer> createState() => _OfferState();
}

class _OfferState extends State<TomSecretsEmergencySheetOffer> {
  bool _busy = false;
  String? _done;
  String? _error;

  Future<void> _run(
    Future<bool> Function(String name, Uint8List pdf) out,
    String done,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sheet = await widget.sheet();
      final pdf = await sheet.toPdf();
      if (await out(sheet.fileName, pdf) && mounted) {
        setState(() => _done = done);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'The sheet could not be made: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = context.read<TomSecretsHost>();
    final printer = host.printer;
    final files = host.files;
    final theme = Theme.of(context);
    return Column(
      key: const Key('tsm-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'The emergency sheet lists the vaults, their repositories and '
          'formats, and every key file and repository key as a QR code; the '
          'master password is left blank for you to write in. Keep it '
          'offline.',
          style: theme.textTheme.bodySmall,
        ),
        Wrap(
          spacing: 8,
          children: [
            if (printer != null)
              OutlinedButton.icon(
                key: const Key('tsm-sheet-print'),
                icon: const Icon(Icons.print_outlined),
                label: const Text('Print the emergency sheet…'),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _run(
                          (name, pdf) => printer.printPdf(name, pdf),
                          'The emergency sheet was printed.',
                        ),
                      ),
              ),
            if (files != null)
              OutlinedButton.icon(
                key: const Key('tsm-sheet-save'),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Save it as a PDF…'),
                onPressed: _busy
                    ? null
                    : () => unawaited(
                        _run(
                          (name, pdf) => files.save(name, pdf),
                          'The emergency sheet was saved. Print it and '
                          'delete the file.',
                        ),
                      ),
              ),
          ],
        ),
        if (_done != null) Text(_done!, key: const Key('tsm-sheet-done')),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}
