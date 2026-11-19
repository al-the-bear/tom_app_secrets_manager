// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Import screen (part-app, Screens › Import): pick the export
/// (1Password's 1PUX or CSV, Enpass's JSON or CSV, Bitwarden's JSON — a
/// password-protected one opened with its password —, a browser's CSV), or
/// another KDBX file (imported as a group or merged, opened with its own
/// password or key file). For an export: choose where each of the
/// source's vaults goes (a group of a vault, so several source vaults can go
/// to groups of one vault or to different vault files), preview the mapping
/// and what the format loses, run, read the report. Re-importing skips what
/// was imported already. Afterwards the app reminds the user that the export
/// holds every password in plaintext and offers to delete it. Exports are
/// made from a vault's or group's menu (`tomSecretsShowExportDialog`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_core_sync/tom_core_sync.dart' show TomMergeRefusedException;
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/import_model.dart';
import '../state/session_state.dart';
import 'new_vault_dialog.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// Opens the Import screen on its own route (the First run wizard's last
/// step offers it).
Future<void> tomSecretsShowImport(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Import')),
          body: const TomSecretsImportView(),
        ),
      ),
    );

/// The Import screen.
class TomSecretsImportView extends StatefulWidget {
  /// The screen.
  const TomSecretsImportView({super.key});

  @override
  State<TomSecretsImportView> createState() => _ImportState();
}

class _ImportState extends State<TomSecretsImportView> {
  String? _path;
  String? _fileName;
  List<TomSecretsImportFormat> _formats = const [];
  TomSecretsImportFormat? _format;
  final _vaultName = TextEditingController(text: 'Vault');
  TomSecretsImportSource? _source;
  String? _error;
  final Map<String, String> _stores = {};
  final Map<String, TextEditingController> _groups = {};
  bool _archived = false;
  TomSecretsImportReport? _report;
  bool _running = false;
  bool _exportGone = false;
  final _exportPassword = TextEditingController();
  bool _needsPassword = false;
  // The KeePass import.
  final _kdbxPassword = TextEditingController();
  final _kdbxName = TextEditingController();
  Uint8List? _kdbxKeyFile;
  String? _kdbxKeyFileName;
  bool _kdbxMerge = false;
  String? _kdbxStore;
  String? _kdbxResult;

  @override
  void dispose() {
    _vaultName.dispose();
    _exportPassword.dispose();
    _kdbxPassword.dispose();
    _kdbxName.dispose();
    for (final c in _groups.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    final files = context.read<TomSecretsHost>().files;
    if (files == null) {
      setState(() => _error = 'This app cannot open files.');
      return;
    }
    final path = await files.choosePath(save: false);
    if (path == null || !mounted) return;
    final name = path.split(RegExp(r'[/\\]')).last;
    final formats = tomSecretsImportFormatsOf(name);
    TomSecretsImportFormat? guess;
    if (formats.length == 1) {
      guess = formats.single;
    } else {
      // The content tells several formats apart (a JSON of Bitwarden's or
      // Enpass's, a CSV of a browser's); the chips stay for the user.
      final bytes = await files.read(path);
      guess = tomSecretsGuessImportFormat(formats, bytes);
      bytes.fillRange(0, bytes.length, 0);
    }
    if (!mounted) return;
    final dot = name.lastIndexOf('.');
    setState(() {
      _path = path;
      _fileName = name;
      _formats = formats;
      _format = guess;
      _source = null;
      _report = null;
      _exportGone = false;
      _error = null;
      _needsPassword = false;
      _exportPassword.clear();
      _kdbxResult = null;
      _kdbxName.text = dot > 0 ? name.substring(0, dot) : name;
    });
    if (_format != null) await _read();
  }

  Future<void> _read() async {
    final files = context.read<TomSecretsHost>().files;
    final session = context.read<TomSecretsSession>();
    final path = _path;
    final format = _format;
    if (files == null || path == null || format == null) return;
    if (format.isKdbx) {
      // Opened at the import, with its own key.
      setState(() {
        _source = null;
        _report = null;
        _error = null;
      });
      return;
    }
    try {
      final bytes = await files.read(path);
      if (format == TomSecretsImportFormat.bitwardenJson &&
          tomSecretsBitwardenNeedsPassword(
            utf8.decode(bytes, allowMalformed: true),
          ) &&
          _exportPassword.text.isEmpty) {
        bytes.fillRange(0, bytes.length, 0);
        if (mounted) {
          setState(() {
            _needsPassword = true;
            _source = null;
            _error = null;
          });
        }
        return;
      }
      final TomSecretsImportSource source;
      try {
        source = await tomSecretsReadExport(
          format,
          bytes,
          vaultName: _vaultName.text.trim().isEmpty
              ? 'Vault'
              : _vaultName.text.trim(),
          password: _exportPassword.text,
        );
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
      final writable = [
        for (final v in session.vaults)
          if (session.readOnlyReason(v.store) == null) v.store,
      ];
      if (!mounted) return;
      setState(() {
        _source = source;
        _report = null;
        _error = writable.isEmpty ? 'No vault can be written now.' : null;
        for (final c in _groups.values) {
          c.dispose();
        }
        _groups.clear();
        _stores.clear();
        for (final v in source.vaults) {
          if (writable.isNotEmpty) _stores[v.id] = writable.first;
          _groups[v.id] = TextEditingController(
            text: '${source.displayName}/${v.name}',
          );
        }
      });
    } on TomSecretsImportFormatException catch (e) {
      _notThe(format, e.message);
    } on FormatException catch (e) {
      _notThe(format, e.message);
    }
  }

  /// Opens the KDBX file with its key and imports it as chosen.
  Future<void> _importKdbx() async {
    final files = context.read<TomSecretsHost>().files;
    final session = context.read<TomSecretsSession>();
    final path = _path;
    final store = _kdbxStore;
    if (files == null || path == null || store == null) return;
    setState(() {
      _running = true;
      _error = null;
      _kdbxResult = null;
    });
    try {
      final bytes = await files.read(path);
      final KdbxFile source;
      try {
        source = await KdbxFormat().read(
          bytes,
          tomSecretsVaultCredentials(
            password: _kdbxPassword.text.isEmpty ? null : _kdbxPassword.text,
            keyFile: _kdbxKeyFile,
          ),
        );
      } on KdbxInvalidKeyException {
        if (mounted) {
          setState(() => _error = 'Wrong password or key file for $_fileName.');
        }
        return;
      } on Object catch (e) {
        if (mounted) setState(() => _error = 'Not a KDBX file: $e');
        return;
      }
      if (_kdbxMerge) {
        final r = await session.importKdbxMerged(source, store: store);
        _kdbxResult = r.isClean
            ? 'Merged into $store: nothing to settle.'
            : 'Merged into $store: ${r.conflicts.length} conflicts (under '
                  'Conflicts), ${r.editsAgainstDeletion.length} edits kept '
                  'against a deletion, ${r.keptGroups.length} groups kept.';
      } else {
        final r = await session.importKdbxAsGroup(
          source,
          store: store,
          name: _kdbxName.text.trim().isEmpty
              ? 'KeePass'
              : _kdbxName.text.trim(),
        );
        _kdbxResult =
            '${r.entries} entries in ${r.groups} groups copied into '
            '$store › ${r.group.join(' › ')}.';
      }
    } on TomMergeRefusedException {
      _error =
          '$_fileName is another vault, not a copy of $store: import it as '
          'a group.';
    } on TomSecretsAdminException catch (e) {
      _error = 'The import was not saved: ${tomSecretsDescribeAdminError(e)}';
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _pickKeyFile() async {
    final files = context.read<TomSecretsHost>().files;
    if (files == null) return;
    final path = await files.choosePath(save: false);
    if (path == null) return;
    final bytes = await files.read(path);
    if (!mounted) return;
    setState(() {
      _kdbxKeyFile = bytes;
      _kdbxKeyFileName = path.split(RegExp(r'[/\\]')).last;
    });
  }

  void _notThe(TomSecretsImportFormat format, String why) {
    if (!mounted) return;
    // A protected export read with a wrong password is still the export.
    setState(
      () => _error = _needsPassword
          ? 'The ${format.label} export cannot be opened: $why'
          : 'Not a ${format.label} export: $why',
    );
  }

  /// The mapping menu's "Into a new vault…".
  static const String _newVault = '\u0000new';

  /// Creates a vault for the source vault [id] ([name] proposes its store
  /// name) and maps it there; its group starts at the root.
  Future<void> _intoNewVault(String id, String name) async {
    final proposed = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^[-_]+|-+$'), '');
    final created = await tomSecretsShowNewVaultDialog(
      context,
      name: proposed.isEmpty ? null : proposed,
    );
    if (created == null || !mounted) return;
    setState(() {
      _stores[id] = created.store;
      _report = null;
      _error = null;
    });
  }

  Map<String, TomSecretsImportMapping> get _mappings => {
    for (final MapEntry(key: id, value: store) in _stores.entries)
      id: TomSecretsImportMapping(
        store,
        TomSecretsImportMapping.groupOf(_groups[id]!.text),
      ),
  };

  Future<void> _run({required bool dryRun}) async {
    final source = _source;
    if (source == null) return;
    final session = context.read<TomSecretsSession>();
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final report = await session.importExport(
        source,
        mappings: _mappings,
        includeArchived: _archived,
        dryRun: dryRun,
      );
      if (mounted) setState(() => _report = report);
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() {
          _report = null;
          _error =
              'The import was not saved: ${tomSecretsDescribeAdminError(e)}';
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _deleteExport() async {
    final files = context.read<TomSecretsHost>().files;
    final path = _path;
    if (files == null || path == null) return;
    final gone = await files.delete(path);
    if (mounted) setState(() => _exportGone = gone);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = context.watch<TomSecretsSession>();
    final source = _source;
    final report = _report;
    final writable = [
      for (final v in session.vaults)
        if (session.readOnlyReason(v.store) == null) v.store,
    ];
    return ListView(
      key: const Key('tsm-import'),
      padding: const EdgeInsets.all(12),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TomSecretsSection(
                  title: '1. The export',
                  icon: Icons.file_open_rounded,
                  children: [
                    const Text(
                      '1Password 8: File › Export, as 1PUX (recommended) or '
                      'CSV. Enpass: File › Export, as JSON (recommended) or '
                      'CSV, one vault per file. Bitwarden: Tools › Export '
                      'vault, as JSON or password-protected JSON. Chrome, '
                      'Edge, Firefox and Safari: the password manager\'s '
                      'Export passwords (CSV). KeePass and KeePassXC: the '
                      'KDBX file itself. Keep an export outside every '
                      'repository: it holds every password in plaintext. '
                      'To export a vault or a group, use its menu in the '
                      'vault browser › Export….',
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton.tonalIcon(
                          key: const Key('tsm-import-pick'),
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Choose the export…'),
                          onPressed: () => unawaited(_pick()),
                        ),
                        const SizedBox(width: 12),
                        if (_fileName != null)
                          Flexible(
                            child: Text(
                              _fileName!,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                          ),
                      ],
                    ),
                    if (_formats.length > 1)
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final f in _formats)
                            ChoiceChip(
                              key: Key('tsm-import-format-${f.name}'),
                              label: Text(f.label),
                              selected: _format == f,
                              onSelected: (_) {
                                setState(() => _format = f);
                                unawaited(_read());
                              },
                            ),
                        ],
                      ),
                    if (_format?.asksVaultName ?? false)
                      TextField(
                        key: const Key('tsm-import-vault-name'),
                        controller: _vaultName,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'The Enpass vault this file holds',
                        ),
                        onSubmitted: (_) => unawaited(_read()),
                      ),
                    if (_needsPassword &&
                        _format == TomSecretsImportFormat.bitwardenJson)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('tsm-import-export-password'),
                              controller: _exportPassword,
                              obscureText: true,
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText:
                                    'The password this export was protected '
                                    'with',
                              ),
                              onSubmitted: (_) => unawaited(_read()),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonal(
                            key: const Key('tsm-import-open'),
                            onPressed: () => unawaited(_read()),
                            child: const Text('Open'),
                          ),
                        ],
                      ),
                    if (_error != null)
                      Text(
                        _error!,
                        key: const Key('tsm-import-error'),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                  ],
                ),
                if (source != null)
                  TomSecretsSection(
                    title: '2. Where each vault goes',
                    icon: Icons.account_tree_rounded,
                    children: [
                      Text(
                        '${source.displayName}, ${_format?.label}: '
                        '${source.vaults.length} vaults, '
                        '${source.vaults.fold(0, (n, v) => n + v.items.length)} items.',
                      ),
                      for (final v in source.vaults)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 180,
                                child: Text(
                                  '${v.name} (${v.items.length})',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const Icon(Icons.arrow_forward, size: 16),
                              const SizedBox(width: 8),
                              DropdownButton<String>(
                                key: Key('tsm-import-store-${v.id}'),
                                value: _stores[v.id],
                                isDense: true,
                                items: [
                                  for (final s in writable)
                                    DropdownMenuItem(value: s, child: Text(s)),
                                  const DropdownMenuItem(
                                    key: Key('tsm-import-new-vault'),
                                    value: _newVault,
                                    child: Text('Into a new vault…'),
                                  ),
                                ],
                                onChanged: (s) {
                                  if (s == _newVault) {
                                    unawaited(_intoNewVault(v.id, v.name));
                                    return;
                                  }
                                  setState(() {
                                    if (s != null) _stores[v.id] = s;
                                    _report = null;
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  key: Key('tsm-import-group-${v.id}'),
                                  controller: _groups[v.id],
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'Group (a/b/c)',
                                  ),
                                  onChanged: (_) =>
                                      setState(() => _report = null),
                                ),
                              ),
                            ],
                          ),
                        ),
                      CheckboxListTile(
                        key: const Key('tsm-import-archived'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _archived,
                        onChanged: (v) => setState(() {
                          _archived = v == true;
                          _report = null;
                        }),
                        title: const Text(
                          'Import the archived items too (into an Archive group)',
                        ),
                      ),
                      Row(
                        children: [
                          OutlinedButton(
                            key: const Key('tsm-import-preview'),
                            onPressed: _running || _stores.isEmpty
                                ? null
                                : () => unawaited(_run(dryRun: true)),
                            child: const Text('Preview'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: const Key('tsm-import-run'),
                            onPressed:
                                _running ||
                                    report == null ||
                                    !report.dryRun ||
                                    _stores.isEmpty
                                ? null
                                : () => unawaited(_run(dryRun: false)),
                            child: const Text('Import'),
                          ),
                          const SizedBox(width: 12),
                          if (_running)
                            const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      if (source.notImported.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Not imported: ${source.notImported.map((n) => n.title == null ? n.what : '${n.title} (${n.what})').join('; ')}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                if (report != null) _reportCard(context, report),
                if (_format?.isKdbx ?? false) _keepassCard(context, writable),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _keepassCard(BuildContext context, List<String> writable) {
    final store = writable.contains(_kdbxStore)
        ? _kdbxStore
        : writable.firstOrNull;
    _kdbxStore = store;
    return TomSecretsSection(
      key: const Key('tsm-import-kdbx'),
      title: '2. The KeePass file',
      icon: Icons.key_rounded,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('tsm-import-kdbx-password'),
                controller: _kdbxPassword,
                obscureText: true,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Its master password',
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('tsm-import-kdbx-keyfile'),
              onPressed: () => unawaited(_pickKeyFile()),
              child: Text(_kdbxKeyFileName ?? 'Key file…'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ChoiceChip(
              key: const Key('tsm-import-kdbx-as-group'),
              label: const Text('As a group'),
              selected: !_kdbxMerge,
              onSelected: (_) => setState(() => _kdbxMerge = false),
            ),
            ChoiceChip(
              key: const Key('tsm-import-kdbx-merge'),
              label: const Text('Merged (a copy of this vault)'),
              selected: _kdbxMerge,
              onSelected: (_) => setState(() => _kdbxMerge = true),
            ),
            const SizedBox(width: 8),
            DropdownButton<String>(
              key: const Key('tsm-import-kdbx-store'),
              value: store,
              isDense: true,
              items: [
                for (final s in writable)
                  DropdownMenuItem(value: s, child: Text(s)),
              ],
              onChanged: (s) => setState(() => _kdbxStore = s),
            ),
          ],
        ),
        if (!_kdbxMerge)
          TextField(
            key: const Key('tsm-import-kdbx-name'),
            controller: _kdbxName,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'The new group',
            ),
          ),
        Text(
          _kdbxMerge
              ? 'Merged entry by entry like two machines\' edits: what only '
                    'one side holds is kept, an entry changed on both sides '
                    'keeps the newer state with the other in its history '
                    '(under Conflicts). Only a copy of the same vault merges.'
              : 'Its groups and entries are copied into a new group, each '
                    'entry with its history and attachments.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              key: const Key('tsm-import-kdbx-run'),
              onPressed: _running || store == null
                  ? null
                  : () => unawaited(_importKdbx()),
              child: const Text('Import'),
            ),
            const SizedBox(width: 12),
            if (_running)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        if (_kdbxResult != null)
          Text(_kdbxResult!, key: const Key('tsm-import-kdbx-result')),
      ],
    );
  }

  Widget _reportCard(BuildContext context, TomSecretsImportReport report) {
    final theme = Theme.of(context);
    return TomSecretsSection(
      key: const Key('tsm-import-report'),
      title: report.dryRun ? '3. Preview (nothing written yet)' : '3. Report',
      icon: report.dryRun ? Icons.visibility_rounded : Icons.fact_check_rounded,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final MapEntry(key: outcome, value: label)
                in tomSecretsImportOutcomeLabels.entries)
              if (report.count(outcome) > 0)
                TomSecretsChip(
                  '${report.count(outcome)} $label',
                  key: Key('tsm-import-count-${outcome.name}'),
                  colour: switch (outcome) {
                    TomSecretsImportOutcome.added ||
                    TomSecretsImportOutcome.updated =>
                      theme.colorScheme.primary,
                    TomSecretsImportOutcome.conflict ||
                    TomSecretsImportOutcome.notImported =>
                      theme.colorScheme.error,
                    _ => theme.colorScheme.outline,
                  },
                ),
          ],
        ),
        if (report.lost.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('What the format loses', style: theme.textTheme.labelLarge),
          for (final l in report.lost) Text('· $l'),
        ],
        if (report.largestAttachments.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Largest attachments', style: theme.textTheme.labelLarge),
          for (final a in report.largestAttachments.take(5))
            Text('· ${a.title}: ${a.name} (${(a.bytes / 1024).ceil()} KiB)'),
        ],
        const SizedBox(height: 6),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Every item (${report.lines.length})'),
          children: [
            for (final l in report.lines.take(500))
              ListTile(
                dense: true,
                title: Text(l.title.isEmpty ? '(untitled)' : l.title),
                subtitle: Text(
                  [
                    tomSecretsImportOutcomeLabels[l.outcome] ?? l.outcome.name,
                    ?l.group,
                    ?l.reason,
                  ].join(' · '),
                ),
              ),
          ],
        ),
        if (!report.dryRun) ...[
          const Divider(),
          Text(report.summary, key: const Key('tsm-import-summary')),
          const SizedBox(height: 6),
          if (_exportGone)
            const Text('The export is deleted.', key: Key('tsm-import-gone'))
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    'The export $_fileName holds every password in '
                    'plaintext. Delete it once you no longer need it.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
                FilledButton.tonal(
                  key: const Key('tsm-import-delete'),
                  onPressed: () => unawaited(_deleteExport()),
                  child: const Text('Delete the export'),
                ),
              ],
            ),
        ],
      ],
    );
  }
}
