// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Sharing screen (part-sharing, part-app, BP-32; desktop only): the
/// user's member key — a hybrid `age` key (X25519 + ML-KEM-768, DP-177),
/// made the first time the screen opens — shown as text, QR code and
/// fingerprint, copied or saved as a file; and the directory of members,
/// the public keys received from other people, added by pasting, opening a
/// file or scanning a QR code, with the date each fingerprint was compared.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_ui_support/tom_ui_support.dart' show tomShowNotice;

import '../ports/desktop_ports.dart';
import '../state/session_state.dart';
import '../widgets/qr_code.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// What a date is shown as on this screen.
String _day(DateTime d) => d.toLocal().toIso8601String().substring(0, 10);

/// Why an action failed, for people.
String _describe(Object e) => switch (e) {
  TomSecretsAdminException() => tomSecretsDescribeAdminError(e),
  TomSecretsMemberKeyException(:final message) => message,
  StateError(:final message) => message,
  _ => '$e',
};

/// The Sharing screen.
class TomSecretsSharingView extends StatefulWidget {
  /// The screen.
  const TomSecretsSharingView({super.key});

  @override
  State<TomSecretsSharingView> createState() => _SharingState();
}

class _SharingState extends State<TomSecretsSharingView> {
  final TextEditingController _name = TextEditingController();
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.text = context.read<TomSecretsSession>().memberName;
    // The member key is made the first time the user opens Sharing.
    WidgetsBinding.instance.addPostFrameCallback((_) => _createIfMissing());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _createIfMissing() async {
    final session = context.read<TomSecretsSession>();
    if (!mounted ||
        _creating ||
        session.memberKeyEntry != null ||
        session.sharingReadOnlyReason != null) {
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await session.createMemberKey(name: _name.text);
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error = 'Your member key could not be made: ${_describe(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _saveName() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await context.read<TomSecretsSession>().setMemberName(_name.text);
      tomShowNotice(messenger, kind: 'member-name', message: 'Name saved.');
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    }
  }

  Future<void> _copy(TomSecretsAgeRecipient key) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: key.encoded));
    tomShowNotice(
      messenger,
      kind: 'copied',
      message: 'Your public member key is on the clipboard.',
    );
  }

  Future<void> _saveFile(TomSecretsAgeRecipient key) async {
    final files = context.read<TomSecretsHost>().files;
    if (files == null) return;
    final name = context.read<TomSecretsSession>().memberName;
    final text = tomSecretsMemberKeyFile(
      key,
      name: name,
      created: context.read<TomSecretsSession>().memberKeyCreated,
    );
    await files.save(
      tomSecretsMemberKeyFileName(name),
      Uint8List.fromList(utf8.encode(text)),
    );
  }

  Future<void> _check(TomSecretsMember member) async {
    final same = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Compare with ${member.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Read this fingerprint to them by phone or in person, or let '
                'them read theirs to you. It must be the same, character for '
                'character, before you trust the key.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                member.recipient.shortFingerprint,
                key: const Key('tsm-check-fingerprint'),
                style: tomSecretsFingerprintStyle(context),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not the same'),
          ),
          FilledButton(
            key: const Key('tsm-check-same'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('The same'),
          ),
        ],
      ),
    );
    if (same == null || !mounted) return;
    if (!same) {
      setState(
        () => _error =
            'The fingerprints of ${member.name} differ: do not use this key. '
            'Ask them to send it again, another way.',
      );
      return;
    }
    await _run(
      () => context.read<TomSecretsSession>().markMemberChecked(member),
    );
  }

  Future<void> _remove(TomSecretsMember member) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${member.name}?'),
        content: const Text(
          'The key goes to the recycle bin of your primary vault. Shared '
          'vaults are not changed by this.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-remove-member-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _run(() => context.read<TomSecretsSession>().removeMember(member));
  }

  Future<void> _add() async {
    final added = await showDialog<int>(
      context: context,
      builder: (_) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(
            value: context.read<TomSecretsSession>(),
          ),
          Provider.value(value: context.read<TomSecretsHost>()),
        ],
        child: const _AddMemberDialog(),
      ),
    );
    if (added != null && added > 0 && mounted) {
      tomShowNotice(
        ScaffoldMessenger.maybeOf(context),
        kind: 'member-added',
        message: added == 1 ? 'Member added.' : '$added members added.',
      );
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _error = null);
    try {
      await f();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    return ListView(
      key: const Key('tsm-sharing'),
      padding: const EdgeInsets.all(12),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _error!,
                      key: const Key('tsm-sharing-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                _keySection(context, session),
                _membersSection(context, session),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _keySection(BuildContext context, TomSecretsSession session) {
    final theme = Theme.of(context);
    final key = session.memberKeyRecipient;
    final readOnly = session.sharingReadOnlyReason;
    final files = context.read<TomSecretsHost>().files;
    if (key == null) {
      return TomSecretsSection(
        title: 'Your member key',
        icon: Icons.badge_rounded,
        children: [
          if (_creating)
            const Row(
              key: Key('tsm-member-key-creating'),
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Making your member key…'),
              ],
            )
          else if (readOnly != null)
            Text(
              'Your member key is made in your primary vault, which is '
              '$readOnly.',
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('tsm-member-key-create'),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Make my member key'),
                onPressed: _createIfMissing,
              ),
            ),
        ],
      );
    }
    final created = session.memberKeyCreated;
    return TomSecretsSection(
      title: 'Your member key',
      icon: Icons.badge_rounded,
      children: [
        Text(
          'Give this public key to the people you share vaults or entries '
          'with: as a file, pasted into a message, or as the QR code. They '
          'compare its fingerprint with you before they trust it. It is a '
          'hybrid key (X25519 + ML-KEM-768), safe against a future quantum '
          'computer, and works with the age command line from v1.3.0 on. '
          'The private key stays in your primary vault and reaches your '
          'other devices by pairing.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TomSecretsQrCode(
              key: const Key('tsm-member-key-qr'),
              data: key.encoded,
              size: 300,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Fingerprint', style: theme.textTheme.labelMedium),
                  SelectableText(
                    key.shortFingerprint,
                    key: const Key('tsm-member-key-fingerprint'),
                    style: tomSecretsFingerprintStyle(context),
                  ),
                  if (created != null)
                    Text(
                      'Made ${_day(created)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('tsm-member-name'),
                    controller: _name,
                    readOnly: readOnly != null,
                    decoration: InputDecoration(
                      labelText: 'Your name, written into the key file',
                      suffixIcon: readOnly != null
                          ? null
                          : IconButton(
                              key: const Key('tsm-member-name-save'),
                              tooltip: 'Save the name',
                              icon: const Icon(Icons.check_rounded),
                              onPressed: _saveName,
                            ),
                    ),
                    onSubmitted: readOnly != null ? null : (_) => _saveName(),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        key: const Key('tsm-member-key-copy'),
                        icon: const Icon(Icons.copy_rounded),
                        label: const Text('Copy'),
                        onPressed: () => _copy(key),
                      ),
                      if (files != null)
                        FilledButton.tonalIcon(
                          key: const Key('tsm-member-key-save'),
                          icon: const Icon(Icons.save_alt_rounded),
                          label: const Text('Save as file…'),
                          onPressed: () => _saveFile(key),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(6),
          ),
          constraints: const BoxConstraints(maxHeight: 120),
          child: SingleChildScrollView(
            child: SelectableText(
              key.encoded,
              key: const Key('tsm-member-key-text'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }

  Widget _membersSection(BuildContext context, TomSecretsSession session) {
    final theme = Theme.of(context);
    final members = session.members;
    final readOnly = session.sharingReadOnlyReason;
    return TomSecretsSection(
      title: 'Members',
      icon: Icons.group_rounded,
      trailing: FilledButton.icon(
        key: const Key('tsm-member-add'),
        icon: const Icon(Icons.person_add_alt_rounded),
        label: const Text('Add a member…'),
        onPressed: readOnly == null ? _add : null,
      ),
      children: [
        if (members.isEmpty)
          Text(
            'No members yet. Add the public key someone gave you: pasted, '
            'from a file or by its QR code.',
            style: theme.textTheme.bodySmall,
          ),
        for (final m in members)
          ListTile(
            key: Key('tsm-member-${m.recipient.fingerprint}'),
            contentPadding: EdgeInsets.zero,
            leading: TomSecretsAvatar(
              colour: tomSecretsTypeColour(TomSecretsEntryType.member),
              icon: tomSecretsTypeIcon(TomSecretsEntryType.member),
            ),
            title: Text(m.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    m.recipient.shortFingerprint,
                    if (m.checked case final c?)
                      'checked ${_day(c)}'
                    else
                      'fingerprint not checked yet',
                  ].join(' · '),
                ),
                if (!m.canJoinSharedVaults)
                  Text(
                    'A classical key: for exports to them only, not '
                    'protected against a future quantum computer. They make '
                    'a hybrid key (age-keygen -pq) to join shared vaults.',
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
              ],
            ),
            trailing: Wrap(
              spacing: 4,
              children: [
                if (m.checked == null && readOnly == null)
                  TextButton(
                    key: Key('tsm-member-check-${m.recipient.fingerprint}'),
                    onPressed: () => _check(m),
                    child: const Text('Compare fingerprint'),
                  ),
                if (readOnly == null)
                  IconButton(
                    key: Key('tsm-member-remove-${m.recipient.fingerprint}'),
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _remove(m),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The text style of a fingerprint people compare.
TextStyle tomSecretsFingerprintStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleMedium!.copyWith(
      fontFamily: 'monospace',
      fontWeight: FontWeight.w600,
      letterSpacing: 1.2,
    );

/// Adds the public keys of a pasted text, a file or a QR code; answers how
/// many were added.
class _AddMemberDialog extends StatefulWidget {
  const _AddMemberDialog();

  @override
  State<_AddMemberDialog> createState() => _AddMemberState();
}

class _AddMemberState extends State<_AddMemberDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _text = TextEditingController();
  List<TomSecretsReceivedMemberKey> _keys = const [];
  String? _problem;
  bool _checked = false;
  bool _adding = false;

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  void _read() {
    final text = _text.text;
    if (text.trim().isEmpty) {
      setState(() {
        _keys = const [];
        _problem = null;
      });
      return;
    }
    try {
      final keys = tomSecretsReadMemberKeys(text);
      setState(() {
        _keys = keys;
        _problem = null;
        if (keys.length == 1 && _name.text.trim().isEmpty) {
          _name.text = keys.single.name ?? '';
        }
      });
    } on TomSecretsMemberKeyException catch (e) {
      setState(() {
        _keys = const [];
        _problem = e.message;
      });
    }
  }

  Future<void> _open(TomSecretsFiles files) async {
    final picked = await files.pick();
    if (picked == null) return;
    try {
      _text.text = utf8.decode(picked.bytes);
    } on FormatException {
      setState(() => _problem = '${picked.name} is not a text file');
      return;
    }
    _read();
  }

  Future<void> _scan(TomSecretsCodeScanner scanner) async {
    final text = await scanner.scan(context, title: 'Scan the member key');
    if (text == null) return;
    _text.text = text;
    _read();
  }

  Future<void> _add() async {
    final session = context.read<TomSecretsSession>();
    setState(() {
      _adding = true;
      _problem = null;
    });
    var added = 0;
    try {
      for (final (i, k) in _keys.indexed) {
        final typed = _name.text.trim();
        final name = _keys.length == 1
            ? typed
            : (k.name ??
                  (typed.isEmpty ? 'Member ${i + 1}' : '$typed ${i + 1}'));
        await session.addMember(
          name,
          k.recipient,
          checked: _checked ? DateTime.now() : null,
        );
        added++;
      }
      if (mounted) Navigator.pop(context, added);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _adding = false;
          _problem = added == 0
              ? _describe(e)
              : '$added added, then: ${_describe(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = context.read<TomSecretsHost>();
    final theme = Theme.of(context);
    final single = _keys.length == 1 ? _keys.single.recipient : null;
    final canAdd =
        !_adding &&
        _keys.isNotEmpty &&
        (_keys.length > 1 || _name.text.trim().isNotEmpty);
    return AlertDialog(
      title: const Text('Add a member'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('tsm-add-member-key'),
                controller: _text,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                decoration: const InputDecoration(
                  labelText: 'Their public key (age1pq1… or age1…)',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => _read(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  if (host.files != null)
                    OutlinedButton.icon(
                      key: const Key('tsm-add-member-open'),
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Open file…'),
                      onPressed: () => _open(host.files!),
                    ),
                  if (host.scanner != null)
                    OutlinedButton.icon(
                      key: const Key('tsm-add-member-scan'),
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text('Scan QR code'),
                      onPressed: () => _scan(host.scanner!),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (_keys.length > 1)
                Text(
                  '${_keys.length} keys: each is added under the name its '
                  'file gives it.',
                  key: const Key('tsm-add-member-several'),
                ),
              TextField(
                key: const Key('tsm-add-member-name'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: _keys.length > 1
                      ? 'Name for keys without one'
                      : 'Their name',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (single != null) ...[
                const SizedBox(height: 12),
                Text('Fingerprint', style: theme.textTheme.labelMedium),
                SelectableText(
                  single.shortFingerprint,
                  key: const Key('tsm-add-member-fingerprint'),
                  style: tomSecretsFingerprintStyle(context),
                ),
                if (!single.isHybrid)
                  Text(
                    'A classical key: it can receive exports only, not '
                    'protected against a future quantum computer, and '
                    'cannot join shared vaults.',
                    key: const Key('tsm-add-member-classical'),
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
              ],
              if (_keys.isNotEmpty)
                CheckboxListTile(
                  key: const Key('tsm-add-member-checked'),
                  contentPadding: EdgeInsets.zero,
                  value: _checked,
                  onChanged: (v) => setState(() => _checked = v ?? false),
                  title: const Text(
                    'I compared the fingerprint with them, by phone or in '
                    'person',
                  ),
                ),
              if (_problem != null)
                Text(
                  _problem!,
                  key: const Key('tsm-add-member-problem'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _adding ? null : () => Navigator.pop(context, 0),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('tsm-add-member-go'),
          onPressed: canAdd ? _add : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
