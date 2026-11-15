// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Rotating a vault's keys by hand (part-key-rotation), from the Keys
/// screen: a new master password, a new, added or removed key file, and for
/// a `.tsmx` vault a new repository key and the outer cipher (DP-80). The
/// session writes the new keys into the primary, saves the vaults re-keyed
/// and cuts the repositories' history; the dialog then offers copies of the
/// new key file and repository key and the new emergency sheet (BP-37).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/rotation.dart';
import '../state/session_state.dart';
import '../widgets/emergency_sheet_offer.dart';
import '../widgets/generator_dialog.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// Shows the rotation of [store]'s keys; answers what it did, or null when
/// cancelled.
Future<TomSecretsRotated?> tomSecretsShowRotateDialog(
  BuildContext context,
  String store,
) => showDialog<TomSecretsRotated>(
  context: context,
  barrierDismissible: false,
  builder: (_) => TomSecretsRotateDialog(store: store),
);

/// The rotation dialog of one vault.
class TomSecretsRotateDialog extends StatefulWidget {
  /// The dialog for [store].
  const TomSecretsRotateDialog({required this.store, super.key});

  /// The vault whose keys are rotated.
  final String store;

  @override
  State<TomSecretsRotateDialog> createState() => _RotateState();
}

class _RotateState extends State<TomSecretsRotateDialog> {
  final _password = TextEditingController();
  bool _newPassword = false;
  bool _showPassword = false;
  TomSecretsKeyFileChange _keyFile = TomSecretsKeyFileChange.keep;
  bool _newRepositoryKey = false;
  TomSecretsOuterCipher? _cipher;
  bool _running = false;
  String? _error;
  TomSecretsRotated? _done;

  // Adding or removing the outer encryption (`vault.move`): the mode
  // (`add` / `remove`), the keys the repository's other vaults use, the one
  // chosen (null: a new key), the cipher, and what it did.
  String? _outerMode;
  List<TomSecretsKnownRepositoryKey> _known = const [];
  String? _outerKey;
  TomSecretsOuterCipher _outerCipher = TomSecretsOuterCipher.xchacha20Poly1305;
  TomSecretsOuterMoved? _moved;
  final Set<String> _saved = {};

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  TomSecretsSession get _session => context.read<TomSecretsSession>();

  String get _location {
    final session = _session;
    final open = [
      ...session.vaults,
      ...session.editOnly,
    ].where((v) => v.store == widget.store).firstOrNull;
    if (open != null) return open.location;
    return session.unserved
            .where((u) => u.store == widget.store)
            .firstOrNull
            ?.location ??
        '';
  }

  bool get _isPrimary => _session.vaults.firstOrNull?.store == widget.store;

  TomSecretsRotation get _rotation => TomSecretsRotation(
    password: _newPassword ? _password.text : null,
    keyFile: _keyFile,
    newRepositoryKey: _newRepositoryKey,
    cipher: _cipher,
  );

  bool get _ready =>
      !_rotation.isEmpty && (!_newPassword || _password.text.isNotEmpty);

  Future<void> _rotate() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final done = await _session.rotateKeys(widget.store, _rotation);
      if (mounted) setState(() => _done = done);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = '${e.message}');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _startOuter(String mode) async {
    final known = mode == 'add'
        ? await _session.repositoryKeysFor(widget.store)
        : const <TomSecretsKnownRepositoryKey>[];
    if (!mounted) return;
    setState(() {
      _outerMode = mode;
      _known = known;
      _outerKey = null;
      _error = null;
    });
  }

  Future<void> _moveOuter() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final moved = await _session.moveOuter(
        widget.store,
        add: _outerMode == 'add',
        outerKey: _outerKey,
        cipher: _outerCipher,
      );
      if (mounted) setState(() => _moved = moved);
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
    final moved = _moved;
    if (moved != null || _outerMode != null) {
      return AlertDialog(
        key: const Key('tsm-rotate'),
        title: Text(
          _outerMode == 'add'
              ? 'Add outer encryption to ${widget.store}'
              : 'Remove the outer encryption of ${widget.store}',
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: moved == null
                ? _outerForm(context)
                : _movedResult(context, moved),
          ),
        ),
        actions: moved == null
            ? [
                TextButton(
                  onPressed: _running
                      ? null
                      : () => setState(() => _outerMode = null),
                  child: const Text('Back'),
                ),
                FilledButton(
                  key: const Key('tsm-outer-go'),
                  onPressed: _running ? null : () => unawaited(_moveOuter()),
                  child: Text(
                    _running
                        ? 'Moving…'
                        : _outerMode == 'add'
                        ? 'Add outer encryption'
                        : 'Remove outer encryption',
                  ),
                ),
              ]
            : [
                FilledButton(
                  key: const Key('tsm-rotate-done'),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ],
      );
    }
    return AlertDialog(
      key: const Key('tsm-rotate'),
      title: Text('Rotate the keys of ${widget.store}'),
      content: SizedBox(
        width: 560,
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
                key: const Key('tsm-rotate-go'),
                onPressed: _running || !_ready
                    ? null
                    : () => unawaited(_rotate()),
                child: Text(_running ? 'Rotating…' : 'Rotate'),
              ),
            ]
          : [
              FilledButton(
                key: const Key('tsm-rotate-done'),
                onPressed: () => Navigator.pop(context, done),
                child: const Text('Done'),
              ),
            ],
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final outer = _location.endsWith(tomSecretsOuterSuffix);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_location, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('tsm-rotate-password-on'),
          contentPadding: EdgeInsets.zero,
          title: const Text('New master password'),
          value: _newPassword,
          onChanged: _running ? null : (v) => setState(() => _newPassword = v),
        ),
        if (_newPassword)
          TextField(
            key: const Key('tsm-rotate-password'),
            controller: _password,
            obscureText: !_showPassword,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'The new master password',
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
                    key: const Key('tsm-rotate-generate'),
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
        const SizedBox(height: 12),
        Text('Key file', style: theme.textTheme.titleSmall),
        RadioGroup<TomSecretsKeyFileChange>(
          groupValue: _keyFile,
          onChanged: (v) {
            if (!_running && v != null) setState(() => _keyFile = v);
          },
          child: const Column(
            children: [
              RadioListTile(
                key: Key('tsm-rotate-keyfile-keep'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsKeyFileChange.keep,
                title: Text('Keep it as it is'),
              ),
              RadioListTile(
                key: Key('tsm-rotate-keyfile-renew'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsKeyFileChange.renew,
                title: Text(
                  'A new key file (replaces the old one, or adds '
                  'one)',
                ),
              ),
              RadioListTile(
                key: Key('tsm-rotate-keyfile-remove'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: TomSecretsKeyFileChange.remove,
                title: Text('Remove the key file'),
              ),
            ],
          ),
        ),
        if (outer) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('tsm-rotate-repokey'),
            contentPadding: EdgeInsets.zero,
            title: const Text('New repository key'),
            subtitle: const Text(
              'Every vault of this repository under the same key is '
              're-encrypted under the new one.',
            ),
            value: _newRepositoryKey,
            onChanged: _running
                ? null
                : (v) => setState(() => _newRepositoryKey = v),
          ),
          DropdownButtonFormField<TomSecretsOuterCipher?>(
            key: const Key('tsm-rotate-cipher'),
            initialValue: _cipher,
            decoration: const InputDecoration(labelText: 'Outer cipher'),
            items: const [
              DropdownMenuItem(child: Text('Keep each file\'s')),
              DropdownMenuItem(
                value: TomSecretsOuterCipher.xchacha20Poly1305,
                child: Text('XChaCha20-Poly1305'),
              ),
              DropdownMenuItem(
                value: TomSecretsOuterCipher.aes256Gcm,
                child: Text('AES-256-GCM'),
              ),
            ],
            onChanged: _running ? null : (v) => setState(() => _cipher = v),
          ),
        ],
        const Divider(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                outer
                    ? 'Outer encryption is on (.kdbx.tsmx).'
                    : 'Outer encryption is off (.kdbx).',
              ),
            ),
            TextButton(
              key: Key(
                outer ? 'tsm-rotate-outer-remove' : 'tsm-rotate-outer-add',
              ),
              onPressed: _running || _session.vault(widget.store) == null
                  ? null
                  : () => unawaited(_startOuter(outer ? 'remove' : 'add')),
              child: Text(
                outer ? 'Remove outer encryption…' : 'Add outer encryption…',
              ),
            ),
          ],
        ),
        if (_session.vault(widget.store) == null)
          Text(
            'Only a machine that serves this vault adds or removes its outer '
            'encryption.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 12),
        Text(
          'The new keys are written into the primary first, then the vault is '
          'saved under them; a vault on GitHub then has its repository\'s '
          'history cut, so no commit keeps a file under the old keys.'
          '${_isPrimary ? ' The primary\'s new key file and repository key '
                    'reach your other devices by pairing or by hand; '
                    'until then they open their offline copy only.' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('tsm-rotate-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _outerForm(BuildContext context) {
    final theme = Theme.of(context);
    final add = _outerMode == 'add';
    final location = _location;
    final to = add
        ? '$location$tomSecretsOuterSuffix'
        : location.substring(0, location.length - tomSecretsOuterSuffix.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('The vault moves from $location to $to.'),
        const SizedBox(height: 8),
        if (add) ...[
          Text('Repository key', style: theme.textTheme.titleSmall),
          RadioGroup<String?>(
            groupValue: _outerKey,
            onChanged: (v) {
              if (!_running) setState(() => _outerKey = v);
            },
            child: Column(
              children: [
                const RadioListTile<String?>(
                  key: Key('tsm-outer-key-new'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: null,
                  title: Text('A new repository key'),
                ),
                for (final k in _known)
                  RadioListTile<String?>(
                    key: Key('tsm-outer-key-${k.keyId}'),
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
            key: const Key('tsm-outer-cipher'),
            initialValue: _outerCipher,
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
                : (v) => setState(() => _outerCipher = v!),
          ),
        ] else
          const Text(
            'Without the outer layer the file is a plain KDBX vault: anyone '
            'who can read the repository sees its structure and can try its '
            'master password.',
          ),
        const SizedBox(height: 12),
        Text(
          'The new file is written before the old one is removed (on GitHub '
          'in one commit); then the repository\'s history is cut, so no '
          'commit keeps the file ${add ? 'without' : 'with'} the outer layer.'
          '${_isPrimary ? ' Your other devices name the primary in their '
                    'own settings: tell them its new place by pairing or by '
                    'hand.' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('tsm-rotate-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _movedResult(BuildContext context, TomSecretsOuterMoved moved) {
    final theme = Theme.of(context);
    final files = context.read<TomSecretsHost>().files;
    final key = moved.repositoryKey;
    return Column(
      key: const Key('tsm-outer-result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${moved.store} is at ${moved.to} now.'),
        if (moved.reusedKeyId != null)
          Text('It uses the repository key ${moved.reusedKeyId}.'),
        if (moved.compacted.isNotEmpty)
          Text('History cut: ${moved.compacted.join(', ')}.'),
        for (final MapEntry(key: repo, :value) in moved.compactFailures.entries)
          Text(
            'The history of $repo was not cut ($value); run `tsm compact '
            '$repo` later.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        if (key != null && files != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('tsm-outer-save-repokey'),
              icon: Icon(
                _saved.contains('repositoryKey') ? Icons.check : Icons.save_alt,
              ),
              label: const Text('Save a copy of the new repository key…'),
              onPressed: () => unawaited(
                _saveCopy(
                  'repositoryKey',
                  '${moved.store}.repository-key.txt',
                  Uint8List.fromList(utf8.encode('$key\n')),
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          'Your emergency sheet names the old place and keys: replace it.',
          style: theme.textTheme.bodySmall,
        ),
        TomSecretsEmergencySheetOffer(sheet: _session.emergencySheet),
      ],
    );
  }

  Widget _result(BuildContext context, TomSecretsRotated done) {
    final theme = Theme.of(context);
    final files = context.read<TomSecretsHost>().files;
    final keyFile = done.keyFile;
    final repositoryKey = done.repositoryKey;
    return Column(
      key: const Key('tsm-rotate-result'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Written under the new keys: ${done.rekeyed.join(', ')}.'),
        if (done.compacted.isNotEmpty)
          Text('History cut: ${done.compacted.join(', ')}.'),
        for (final MapEntry(:key, :value) in done.compactFailures.entries)
          Text(
            'The history of $key was not cut ($value); run `tsm compact '
            '$key` later.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        if (keyFile != null || repositoryKey != null) ...[
          const SizedBox(height: 12),
          Text(
            'Keep a copy of the new key material with your recovery codes; '
            'without it the vault cannot be opened once this machine is gone.',
            style: theme.textTheme.bodySmall,
          ),
          if (files != null && keyFile != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('tsm-rotate-save-keyfile'),
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
                key: const Key('tsm-rotate-save-repokey'),
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
        if (done.primaryRekeyed && (keyFile != null || repositoryKey != null))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Your other devices need the primary\'s new key file or '
              'repository key: pair them again or copy it by hand.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 12),
        // BP-37: the sheet as the keys are now; the old one is outdated.
        Text(
          'Your emergency sheet names the old keys: replace it.',
          style: theme.textTheme.bodySmall,
        ),
        TomSecretsEmergencySheetOffer(sheet: _session.emergencySheet),
      ],
    );
  }
}
