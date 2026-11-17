// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Creating a further vault beside the primary (part-app; protocol.md 6.4
/// `vault.create`), from the vault browser, the Environments screen and the
/// Import screen: its name, its kind (and for a system vault the environment
/// it serves in, or every environment), where it lives (beside the primary by default, another
/// GitHub repository or a file), its keys (a master password given or
/// generated and kept in the primary, a key file: none, the primary's or a
/// new one) and its outer encryption (a key the repository already uses, or
/// a new one). The dialog then offers copies of the new key material and the
/// new emergency sheet (BP-37).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/new_vault.dart';
import '../state/rotation.dart';
import '../state/session_state.dart';
import '../widgets/emergency_sheet_offer.dart';
import '../widgets/generator_dialog.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// Shows the New vault dialog, prefilled with [name], [kind] and
/// [environment]; answers what it created, or null when cancelled.
Future<TomSecretsVaultCreated?> tomSecretsShowNewVaultDialog(
  BuildContext context, {
  String? name,
  TomSecretsVaultKind kind = TomSecretsVaultKind.personal,
  String? environment,
}) => showDialog<TomSecretsVaultCreated>(
  context: context,
  barrierDismissible: false,
  builder: (_) => TomSecretsNewVaultDialog(
    name: name,
    kind: kind,
    environment: environment,
  ),
);

/// The New vault dialog.
class TomSecretsNewVaultDialog extends StatefulWidget {
  /// The dialog, prefilled with [name], [kind] and [environment].
  const TomSecretsNewVaultDialog({
    this.name,
    this.kind = TomSecretsVaultKind.personal,
    this.environment,
    super.key,
  });

  /// The name proposed, or null.
  final String? name;

  /// The kind proposed.
  final TomSecretsVaultKind kind;

  /// The environment proposed for a system vault, or null.
  final String? environment;

  @override
  State<TomSecretsNewVaultDialog> createState() => _NewVaultState();
}

class _NewVaultState extends State<TomSecretsNewVaultDialog> {
  late final _name = TextEditingController(text: widget.name ?? '');
  late final _environment = TextEditingController(
    text: widget.environment ?? '',
  );
  final _purpose = TextEditingController();
  final _repository = TextEditingController();
  final _folder = TextEditingController();
  final _token = TextEditingController();
  final _password = TextEditingController();
  late TomSecretsVaultKind _kind = widget.kind;
  TomSecretsNewVaultPlace _place = TomSecretsNewVaultPlace.besidePrimary;
  bool _generate = true;
  bool _showPassword = false;
  TomSecretsNewKeyFile _keyFile = TomSecretsNewKeyFile.none;
  bool _outer = false;
  String? _repositoryKey;
  TomSecretsOuterCipher _cipher = TomSecretsOuterCipher.xchacha20Poly1305;
  // The keys the repository's vaults use, for the repository they were
  // read for.
  String? _knownFor;
  List<TomSecretsKnownRepositoryKey> _known = const [];
  bool _running = false;
  String? _error;
  TomSecretsVaultCreated? _done;
  final Set<String> _saved = {};

  @override
  void dispose() {
    for (final c in [
      _name,
      _environment,
      _purpose,
      _repository,
      _folder,
      _token,
      _password,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  TomSecretsSession get _session => context.read<TomSecretsSession>();

  TomSecretsNewVaultSpec get _spec => TomSecretsNewVaultSpec(
    name: _name.text.trim(),
    kind: _kind,
    environment: _kind == TomSecretsVaultKind.system
        ? _environment.text.trim()
        : null,
    purpose: _purpose.text,
    place: _place,
    repository: _repository.text,
    folder: _folder.text,
    outer: _outer,
    repositoryKey: _outer ? _repositoryKey : null,
    cipher: _cipher,
    password: _generate ? null : _password.text,
    keyFile: _keyFile,
    githubToken: _place == TomSecretsNewVaultPlace.github ? _token.text : null,
  );

  /// The new vault's locator, or why it cannot be named yet.
  ({String? location, String? problem}) get _where {
    final primary = _session.vaults.firstOrNull;
    if (primary == null) return (location: null, problem: 'No primary open.');
    if (_name.text.trim().isEmpty) {
      return (location: null, problem: 'Name the vault.');
    }
    try {
      return (
        location: tomSecretsNewVaultLocation(_spec, primary.location),
        problem: null,
      );
    } on ArgumentError catch (e) {
      return (location: null, problem: '${e.message}');
    }
  }

  bool get _ready =>
      _where.location != null && (_generate || _password.text.isNotEmpty);

  /// Reads the keys the repository of [location] uses, once per repository.
  void _loadKnown(String location) {
    final repository = tomSecretsRepositoryOf(location);
    if (_knownFor == repository) return;
    _knownFor = repository;
    unawaited(
      _session.repositoryKeysAt(location).then((known) {
        if (!mounted || _knownFor != repository) return;
        setState(() {
          _known = known;
          if (!known.any((k) => k.key == _repositoryKey)) _repositoryKey = null;
        });
      }),
    );
  }

  Future<void> _create() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final done = await _session.createVault(_spec);
      if (mounted) setState(() => _done = done);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = '${e.message}');
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _saveCopy(String what, String name, Uint8List bytes) async {
    final files = context.read<TomSecretsHost>().files;
    if (files == null) return;
    if (await files.save(name, bytes) && mounted) {
      setState(() => _saved.add(what));
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _done;
    return AlertDialog(
      key: const Key('tsm-newvault'),
      title: Text(done == null ? 'New vault' : '${done.store} created'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: done == null ? _form(context) : _result(context, done),
        ),
      ),
      actions: done == null
          ? [
              TextButton(
                onPressed: _running ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('tsm-newvault-create'),
                onPressed: _running || !_ready
                    ? null
                    : () => unawaited(_create()),
                child: Text(_running ? 'Creating…' : 'Create'),
              ),
            ]
          : [
              FilledButton(
                key: const Key('tsm-newvault-done'),
                onPressed: () => Navigator.pop(context, done),
                child: const Text('Done'),
              ),
            ],
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final where = _where;
    final location = where.location;
    if (_outer && location != null) _loadKnown(location);
    final environments = _session.resolution.config.stores.keys.toList()
      ..sort();
    void changed(String _) => setState(() => _error = null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('tsm-newvault-name'),
          controller: _name,
          enabled: !_running,
          decoration: const InputDecoration(
            labelText: 'Name (the store name: a-z, 0-9, - and _)',
          ),
          onChanged: changed,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<TomSecretsVaultKind>(
          key: const Key('tsm-newvault-kind'),
          initialValue: _kind,
          decoration: const InputDecoration(labelText: 'Kind'),
          items: const [
            DropdownMenuItem(
              value: TomSecretsVaultKind.personal,
              child: Text('Personal: your own passwords'),
            ),
            DropdownMenuItem(
              value: TomSecretsVaultKind.system,
              child: Text('System: secrets for the processes'),
            ),
            DropdownMenuItem(
              value: TomSecretsVaultKind.shared,
              enabled: false,
              child: Text('Shared between people (phase C)'),
            ),
          ],
          onChanged: _running
              ? null
              : (k) => setState(() => _kind = k ?? _kind),
        ),
        if (_kind == TomSecretsVaultKind.system) ...[
          const SizedBox(height: 8),
          TextField(
            key: const Key('tsm-newvault-env'),
            controller: _environment,
            enabled: !_running,
            decoration: InputDecoration(
              labelText: 'The environment it serves in (env)',
              helperText:
                  'Every entry of the vault is bound in it; empty: every '
                  'environment.'
                  '${environments.isEmpty ? '' : ' Known: ${environments.join(', ')}'}',
            ),
            onChanged: changed,
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: const Key('tsm-newvault-purpose'),
          controller: _purpose,
          enabled: !_running,
          decoration: const InputDecoration(
            labelText: 'Purpose (optional, shown in the app)',
          ),
        ),
        const SizedBox(height: 16),
        Text('Where it lives', style: theme.textTheme.titleSmall),
        RadioGroup<TomSecretsNewVaultPlace>(
          groupValue: _place,
          onChanged: (p) {
            if (!_running && p != null) setState(() => _place = p);
          },
          child: const Column(
            children: [
              RadioListTile(
                key: Key('tsm-newvault-place-beside'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsNewVaultPlace.besidePrimary,
                title: Text('Beside the primary (its repository or folder)'),
              ),
              RadioListTile(
                key: Key('tsm-newvault-place-github'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsNewVaultPlace.github,
                title: Text('Another GitHub repository'),
              ),
              RadioListTile(
                key: Key('tsm-newvault-place-file'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsNewVaultPlace.file,
                title: Text('A file on this machine'),
              ),
            ],
          ),
        ),
        if (_place == TomSecretsNewVaultPlace.github) ...[
          TextField(
            key: const Key('tsm-newvault-repo'),
            controller: _repository,
            enabled: !_running,
            decoration: const InputDecoration(
              labelText: 'Repository (owner/name)',
            ),
            onChanged: changed,
          ),
          TextField(
            key: const Key('tsm-newvault-token'),
            controller: _token,
            enabled: !_running,
            obscureText: true,
            decoration: const InputDecoration(
              labelText:
                  'Its GitHub token (when this machine\'s keychain has none)',
              helperText: 'Kept with the vault\'s entry in the primary.',
            ),
          ),
        ],
        if (_place != TomSecretsNewVaultPlace.besidePrimary)
          TextField(
            key: const Key('tsm-newvault-folder'),
            controller: _folder,
            enabled: !_running,
            decoration: InputDecoration(
              labelText: _place == TomSecretsNewVaultPlace.file
                  ? 'Folder (absolute)'
                  : 'Folder in the repository (optional)',
            ),
            onChanged: changed,
          ),
        const SizedBox(height: 8),
        Text(
          location ?? where.problem ?? '',
          key: const Key('tsm-newvault-location'),
          style: location == null
              ? TextStyle(color: theme.colorScheme.error)
              : const TextStyle(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 16),
        Text('Keys', style: theme.textTheme.titleSmall),
        SwitchListTile(
          key: const Key('tsm-newvault-generate'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Generate the master password'),
          subtitle: const Text(
            'Kept in the primary only: the vault opens wherever the primary '
            'does.',
          ),
          value: _generate,
          onChanged: _running ? null : (v) => setState(() => _generate = v),
        ),
        if (!_generate)
          TextField(
            key: const Key('tsm-newvault-password'),
            controller: _password,
            obscureText: !_showPassword,
            enabled: !_running,
            onChanged: changed,
            decoration: InputDecoration(
              labelText: 'The master password',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: _showPassword ? 'Hide' : 'Show',
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                  IconButton(
                    tooltip: 'Generate a password',
                    icon: const Icon(Icons.casino_outlined),
                    onPressed: () async {
                      final generated = await tomSecretsShowGenerator(context);
                      if (generated != null) {
                        setState(() => _password.text = generated);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text('Key file', style: theme.textTheme.bodyMedium),
        RadioGroup<TomSecretsNewKeyFile>(
          groupValue: _keyFile,
          onChanged: (v) {
            if (!_running && v != null) setState(() => _keyFile = v);
          },
          child: const Column(
            children: [
              RadioListTile(
                key: Key('tsm-newvault-keyfile-none'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsNewKeyFile.none,
                title: Text('None'),
              ),
              RadioListTile(
                key: Key('tsm-newvault-keyfile-primary'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsNewKeyFile.primary,
                title: Text('The primary\'s key file'),
              ),
              RadioListTile(
                key: Key('tsm-newvault-keyfile-new'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsNewKeyFile.generate,
                title: Text('A new key file'),
              ),
            ],
          ),
        ),
        SwitchListTile(
          key: const Key('tsm-newvault-outer'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Outer encryption (.kdbx.tsmx)'),
          subtitle: const Text(
            'The file is encrypted again under the repository\'s key: who '
            'reads the repository sees neither its structure nor can try '
            'its password.',
          ),
          value: _outer,
          onChanged: _running ? null : (v) => setState(() => _outer = v),
        ),
        if (_outer) ...[
          RadioGroup<String?>(
            groupValue: _repositoryKey,
            onChanged: (v) {
              if (!_running) setState(() => _repositoryKey = v);
            },
            child: Column(
              children: [
                const RadioListTile<String?>(
                  key: Key('tsm-newvault-repokey-new'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: null,
                  title: Text('A new repository key'),
                ),
                for (final k in _known)
                  RadioListTile<String?>(
                    key: Key('tsm-newvault-repokey-${k.keyId}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: k.key,
                    title: Text(
                      'The key of ${k.vaults.join(', ')} (${k.keyId})',
                    ),
                  ),
              ],
            ),
          ),
          DropdownButtonFormField<TomSecretsOuterCipher>(
            key: const Key('tsm-newvault-cipher'),
            initialValue: _cipher,
            decoration: const InputDecoration(labelText: 'Outer cipher'),
            items: const [
              DropdownMenuItem(
                value: TomSecretsOuterCipher.xchacha20Poly1305,
                child: Text('XChaCha20-Poly1305'),
              ),
              DropdownMenuItem(
                value: TomSecretsOuterCipher.aes256Gcm,
                child: Text('AES-256-GCM'),
              ),
            ],
            onChanged: _running
                ? null
                : (v) => setState(() => _cipher = v ?? _cipher),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'The service writes the new file where it lives and lists the vault '
          'with its keys in the primary; every machine that opens the '
          'primary serves it from then on.',
          style: theme.textTheme.bodySmall,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('tsm-newvault-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _result(BuildContext context, TomSecretsVaultCreated done) {
    final theme = Theme.of(context);
    final files = context.read<TomSecretsHost>().files;
    final keyFile = done.keyFile;
    final repositoryKey = done.repositoryKey;
    return Column(
      key: const Key('tsm-newvault-result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${done.store} is at ${done.location}.'),
        if (done.passwordGenerated)
          const Text(
            'Its master password was generated and is kept in the primary.',
          ),
        if (keyFile != null || repositoryKey != null) ...[
          const SizedBox(height: 12),
          Text(
            'Keep a copy of the new key material with your recovery codes; '
            'without it the vault cannot be opened once the primary is gone.',
            style: theme.textTheme.bodySmall,
          ),
          if (files != null && keyFile != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('tsm-newvault-save-keyfile'),
                icon: Icon(
                  _saved.contains('keyFile') ? Icons.check : Icons.save_alt,
                ),
                label: const Text('Save a copy of the new key file…'),
                onPressed: () => unawaited(
                  _saveCopy('keyFile', '${done.store}.keyx', keyFile),
                ),
              ),
            ),
          if (files != null && repositoryKey != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('tsm-newvault-save-repokey'),
                icon: Icon(
                  _saved.contains('repositoryKey')
                      ? Icons.check
                      : Icons.save_alt,
                ),
                label: const Text('Save a copy of the new repository key…'),
                onPressed: () => unawaited(
                  _saveCopy(
                    'repositoryKey',
                    '${done.store}.repository-key.txt',
                    Uint8List.fromList(utf8.encode('$repositoryKey\n')),
                  ),
                ),
              ),
            ),
        ],
        const SizedBox(height: 12),
        // BP-37: the sheet lists every vault and its key material.
        Text(
          'Your emergency sheet does not name this vault yet: replace it.',
          style: theme.textTheme.bodySmall,
        ),
        TomSecretsEmergencySheetOffer(sheet: _session.emergencySheet),
      ],
    );
  }
}
