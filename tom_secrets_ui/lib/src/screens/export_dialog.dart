// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Export dialog (part-password-manager, DP-40), from a vault's or a
/// group's menu in the vault browser: the vault or group written as
///
/// - **KDBX**, a copy under a new master password of its own (for KeePass
///   and every tool reading KDBX; encrypted);
/// - **CSV**, for other tools;
/// - **Bitwarden JSON**, so a move to Bitwarden keeps folders, item types
///   and custom fields.
///
/// CSV and Bitwarden JSON hold every password in plaintext: the dialog says
/// so before anything is written. The result names what the format does not
/// carry. The file is saved where the user chooses (the host's files).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/session_state.dart';

/// The export formats.
enum TomSecretsExportFormat {
  /// A KDBX copy under a new master password.
  kdbx('KDBX (KeePass)', 'kdbx'),

  /// CSV for other tools.
  csv('CSV', 'csv'),

  /// Bitwarden's JSON export.
  bitwardenJson('Bitwarden (JSON)', 'json');

  const TomSecretsExportFormat(this.label, this.extension);

  /// How the user reads it.
  final String label;

  /// The file name's extension.
  final String extension;

  /// Whether the file holds the passwords in plaintext.
  bool get plaintext => this != kdbx;
}

/// What an export wrote.
final class TomSecretsExportResult {
  /// [items] entries written, [lost] what the format does not carry.
  const TomSecretsExportResult(this.items, this.lost);

  /// How many entries the file holds.
  final int items;

  /// What it does not carry.
  final List<String> lost;
}

/// Writes [group] of [store] (default the whole vault) as [format] and
/// hands the bytes with [suggestedName] to [save]; KDBX under [password].
/// Answers what was written, or null when the user cancelled the save.
Future<TomSecretsExportResult?> tomSecretsExport(
  TomSecretsSession session, {
  required String store,
  KdbxUuid? group,
  required TomSecretsExportFormat format,
  String? password,
  required Future<bool> Function(String name, Uint8List bytes) save,
}) async {
  final vault = session.vaults.firstWhere((v) => v.store == store);
  final from = group == null ? null : session.groupOf(store, group);
  final base = from == null ? store : (from.name.get() ?? store);
  final Uint8List bytes;
  final TomSecretsExportResult result;
  switch (format) {
    case TomSecretsExportFormat.kdbx:
      bytes = await tomSecretsExportKdbx(
        vault.file,
        tomSecretsVaultCredentials(password: password),
        name: base,
        group: from,
      );
      result = TomSecretsExportResult(
        tomSecretsExportEntries(vault.file, group: from).length,
        const [],
      );
    case TomSecretsExportFormat.csv:
      final e = tomSecretsExportCsv(vault.file, group: from);
      bytes = Uint8List.fromList(utf8.encode(e.text));
      result = TomSecretsExportResult(e.items, e.lost);
    case TomSecretsExportFormat.bitwardenJson:
      final e = tomSecretsExportBitwardenJson(vault.file, group: from);
      bytes = Uint8List.fromList(utf8.encode(e.text));
      result = TomSecretsExportResult(e.items, e.lost);
  }
  final suffix = format == TomSecretsExportFormat.bitwardenJson
      ? '_bitwarden'
      : '';
  final saved = await save('$base$suffix.${format.extension}', bytes);
  bytes.fillRange(0, bytes.length, 0);
  return saved ? result : null;
}

/// Shows the Export dialog for [store] (or its [group]).
Future<void> tomSecretsShowExportDialog(
  BuildContext context, {
  required String store,
  KdbxUuid? group,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ExportDialog(store: store, group: group),
);

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.store, this.group});

  final String store;
  final KdbxUuid? group;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  TomSecretsExportFormat _format = TomSecretsExportFormat.kdbx;
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  String? _error;
  TomSecretsExportResult? _result;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final files = context.read<TomSecretsHost>().files;
    final session = context.read<TomSecretsSession>();
    if (files == null) {
      setState(() => _error = 'This app cannot save files.');
      return;
    }
    if (_format == TomSecretsExportFormat.kdbx) {
      if (_password.text.length < 8) {
        setState(
          () => _error =
              'Give the copy a password of 8 characters '
              'or more.',
        );
        return;
      }
      if (_password.text != _repeat.text) {
        setState(() => _error = 'The passwords differ.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await tomSecretsExport(
        session,
        store: widget.store,
        group: widget.group,
        format: _format,
        password: _password.text,
        save: files.save,
      );
      if (mounted) setState(() => _result = result);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'The export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = context.watch<TomSecretsSession>();
    final group = widget.group == null
        ? null
        : session.groupOf(widget.store, widget.group!);
    final what = group == null
        ? 'the vault ${widget.store}'
        : 'the group ${group.name.get()} of ${widget.store}';
    final result = _result;
    return AlertDialog(
      key: const Key('tsm-export'),
      title: Text('Export $what'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              children: [
                for (final f in TomSecretsExportFormat.values)
                  ChoiceChip(
                    key: Key('tsm-export-format-${f.name}'),
                    label: Text(f.label),
                    selected: _format == f,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                            _format = f;
                            _result = null;
                            _error = null;
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_format == TomSecretsExportFormat.kdbx) ...[
              const Text(
                'A copy as a KDBX file of its own, for KeePass and the tools '
                'that read KDBX, under a new master password (not this '
                'vault\'s).',
              ),
              TextField(
                key: const Key('tsm-export-password'),
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'The copy\'s master password',
                ),
              ),
              TextField(
                key: const Key('tsm-export-repeat'),
                controller: _repeat,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Again'),
              ),
            ] else
              Container(
                key: const Key('tsm-export-warning'),
                padding: const EdgeInsets.all(8),
                color: theme.colorScheme.errorContainer,
                child: Text(
                  'This file holds every password in plaintext: anyone who '
                  'reads it reads them all. Save it where nothing syncs or '
                  'backs it up, keep it out of every repository, and delete '
                  'it as soon as it has been imported.',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('tsm-export-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (result != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  [
                    '${result.items} entries written.',
                    if (result.lost.isNotEmpty)
                      'Not carried: ${result.lost.join('; ')}.',
                  ].join(' '),
                  key: const Key('tsm-export-result'),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(result == null ? 'Cancel' : 'Close'),
        ),
        if (result == null)
          FilledButton(
            key: const Key('tsm-export-run'),
            onPressed: _busy ? null : _export,
            child: const Text('Export…'),
          ),
      ],
    );
  }
}
