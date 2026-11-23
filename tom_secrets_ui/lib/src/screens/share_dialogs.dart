// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** Single-entry exports in the app (part-sharing, BP-34): the
/// Share dialog, which writes chosen entries as one encrypted package (to
/// members' keys, under a passphrase, or to a classical key) and shows it as
/// armoured text, a QR code, a `.tsmshare` file or puts it into a shared
/// vault's inbox; and the Import a share dialog, which opens a pasted,
/// scanned or opened package (or one from the inbox), shows its entries and
/// imports them into a chosen group.
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
import '../state/shares.dart';
import '../widgets/qr_code.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;
import 'vault_browser.dart' show tomSecretsPickGroup, tomSecretsTypeName;

String _describe(Object e) => switch (e) {
  TomSecretsAdminException() => tomSecretsDescribeAdminError(e),
  TomSecretsAgeException(reason: TomSecretsAgeFailure.noMatch) =>
    'this share is not for your member key, or the passphrase is wrong',
  TomSecretsAgeException(:final message) => 'the share is damaged: $message',
  TomSecretsShareException(:final message) => message,
  StateError(:final message) => message,
  _ => '$e',
};

/// How a share is protected.
enum _Protection { members, passphrase, classical }

/// Shows the Share dialog for [refs] (desktop only, BP-32).
Future<void> tomSecretsShowShareDialog(
  BuildContext context,
  List<TomSecretsEntryRef> refs,
) => showDialog<void>(
  context: context,
  builder: (_) => _ShareDialog(refs: refs),
);

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({required this.refs});

  final List<TomSecretsEntryRef> refs;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  var _protection = _Protection.members;
  final Set<String> _chosen = {};
  String? _classical;
  final _passphrase = TextEditingController();
  bool _busy = false;
  String? _error;
  Uint8List? _file;
  List<TomSecretsAgeRecipient> _recipients = const [];
  List<String> _inboxVaults = const [];
  String? _sentTo;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  List<TomSecretsAgeRecipient> _selected(List<TomSecretsMember> members) =>
      switch (_protection) {
        _Protection.members => [
          for (final m in members)
            if (_chosen.contains(m.recipient.fingerprint)) m.recipient,
        ],
        _Protection.classical => [
          for (final m in members)
            if (m.recipient.fingerprint == _classical) m.recipient,
        ],
        _Protection.passphrase => const [],
      };

  Future<void> _make(List<TomSecretsMember> members) async {
    final session = context.read<TomSecretsSession>();
    final recipients = _selected(members);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await session.writeShare(
        widget.refs,
        recipients: _protection == _Protection.passphrase ? null : recipients,
        passphrase: _protection == _Protection.passphrase
            ? _passphrase.text
            : null,
      );
      final inbox = _protection == _Protection.members
          ? await session.inboxVaultsFor(recipients)
          : const <String>[];
      if (!mounted) return;
      setState(() {
        _file = file;
        _recipients = recipients;
        _inboxVaults = inbox;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: text));
    tomShowNotice(
      messenger,
      kind: 'share-copied',
      message: 'The share is on the clipboard: paste it into a message.',
    );
  }

  Future<void> _save(TomSecretsFiles files) async {
    final session = context.read<TomSecretsSession>();
    final title = session.view(widget.refs.first)?.title ?? 'share';
    final name = title.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    await files.save(
      '${name.isEmpty ? 'share' : name}$tomSecretsShareExtension',
      _file!,
    );
  }

  /// The relay server [store]'s shares go to, or null (its inbox folders).
  TomSecretsRelayId? _relayOf(String store) {
    final relay = context.read<TomSecretsSession>().mailboxRelayOf(store);
    return relay?.kind == TomSecretsRelayKind.server ? relay : null;
  }

  Future<void> _toInbox(String store) async {
    final session = context.read<TomSecretsSession>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.putIntoInbox(store, _recipients, _file!);
      if (mounted) setState(() => _sentTo = store);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _ready(List<TomSecretsMember> members) => switch (_protection) {
    _Protection.members => _chosen.isNotEmpty,
    _Protection.passphrase => _passphrase.text.length >= 8,
    _Protection.classical => _classical != null,
  };

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final host = context.read<TomSecretsHost>();
    final members = session.members;
    final hybrid = [
      for (final m in members)
        if (m.recipient.isHybrid) m,
    ];
    final classical = [
      for (final m in members)
        if (!m.recipient.isHybrid) m,
    ];
    final n = widget.refs.length;
    final file = _file;
    return AlertDialog(
      key: const Key('tsm-share-dialog'),
      title: Text(n == 1 ? 'Share an entry' : 'Share $n entries'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: file == null
              ? _choose(hybrid, classical)
              : _result(file, host),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('tsm-share-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(file == null ? 'Cancel' : 'Close'),
        ),
        if (file == null)
          FilledButton(
            key: const Key('tsm-share-make'),
            onPressed: _busy || !_ready(members)
                ? null
                : () => unawaited(_make(members)),
            child: const Text('Make the share'),
          ),
      ],
    );
  }

  Widget _choose(
    List<TomSecretsMember> hybrid,
    List<TomSecretsMember> classical,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'The entries are written as one encrypted package: their fields, '
          'attachments and tags, never the vault\'s history.',
        ),
        const SizedBox(height: 12),
        SegmentedButton<_Protection>(
          key: const Key('tsm-share-protection'),
          segments: const [
            ButtonSegment(
              value: _Protection.members,
              label: Text('Members'),
              icon: Icon(Icons.group_outlined),
            ),
            ButtonSegment(
              value: _Protection.passphrase,
              label: Text('A passphrase'),
              icon: Icon(Icons.password_rounded),
            ),
            ButtonSegment(
              value: _Protection.classical,
              label: Text('A classical key'),
              icon: Icon(Icons.key_outlined),
            ),
          ],
          selected: {_protection},
          onSelectionChanged: (s) => setState(() => _protection = s.single),
        ),
        const SizedBox(height: 12),
        switch (_protection) {
          _Protection.members =>
            hybrid.isEmpty
                ? const Text(
                    'No member with a hybrid key yet: add one under Members '
                    'on the Sharing screen.',
                  )
                : Column(
                    children: [
                      for (final m in hybrid)
                        CheckboxListTile(
                          key: Key(
                            'tsm-share-member-${m.recipient.fingerprint}',
                          ),
                          dense: true,
                          value: _chosen.contains(m.recipient.fingerprint),
                          title: Text(m.name),
                          subtitle: Text(m.recipient.shortFingerprint),
                          onChanged: (on) => setState(
                            () => on == true
                                ? _chosen.add(m.recipient.fingerprint)
                                : _chosen.remove(m.recipient.fingerprint),
                          ),
                        ),
                    ],
                  ),
          _Protection.passphrase => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('tsm-share-passphrase'),
                controller: _passphrase,
                obscureText: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Passphrase (at least 8 characters)',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Give the passphrase to the recipient another way than the '
                'share: by phone or in person. A passphrase is not weakened '
                'by a quantum computer.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          _Protection.classical => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Not protected against a future quantum computer: use it only '
                'for a person who has no hybrid key.',
                key: const Key('tsm-share-classical-warning'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
              if (classical.isEmpty)
                const Text('No member with a classical key.')
              else
                RadioGroup<String>(
                  groupValue: _classical,
                  onChanged: (v) => setState(() => _classical = v),
                  child: Column(
                    children: [
                      for (final m in classical)
                        RadioListTile<String>(
                          key: Key(
                            'tsm-share-classical-${m.recipient.fingerprint}',
                          ),
                          dense: true,
                          value: m.recipient.fingerprint,
                          title: Text(m.name),
                          subtitle: Text(m.recipient.shortFingerprint),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        },
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('tsm-share-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }

  Widget _result(Uint8List file, TomSecretsHost host) {
    final theme = Theme.of(context);
    final text = tomSecretsAgeArmor(file);
    final fits = tomSecretsShareFitsQr(file);
    final files = host.files;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _protection == _Protection.passphrase
              ? 'The share, under your passphrase:'
              : 'The share, for ${_recipients.length == 1 ? 'one key' : '${_recipients.length} keys'}:',
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 160),
          padding: const EdgeInsets.all(8),
          color: theme.colorScheme.surfaceContainerHighest,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              key: const Key('tsm-share-text'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('tsm-share-copy'),
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
              onPressed: () => unawaited(_copy(text)),
            ),
            if (files != null)
              OutlinedButton.icon(
                key: const Key('tsm-share-save'),
                icon: const Icon(Icons.save_alt),
                label: const Text('Save as file…'),
                onPressed: () => unawaited(_save(files)),
              ),
            for (final store in _inboxVaults)
              OutlinedButton.icon(
                key: Key('tsm-share-inbox-$store'),
                icon: const Icon(Icons.move_to_inbox_outlined),
                label: Text(
                  _relayOf(store) == null
                      ? 'Put into the inbox of $store'
                      : 'Put into the mailboxes of $store '
                            '(${_relayOf(store)!.text})',
                ),
                onPressed: _busy || _sentTo != null
                    ? null
                    : () => unawaited(_toInbox(store)),
              ),
          ],
        ),
        if (_sentTo != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'In the ${_relayOf(_sentTo!) == null ? 'inbox' : 'mailboxes'} of $_sentTo: the recipients\' apps find it at '
              'their next sync.',
              key: const Key('tsm-share-sent'),
            ),
          ),
        const SizedBox(height: 12),
        if (fits)
          Center(
            child: TomSecretsQrCode(
              key: const Key('tsm-share-qr'),
              data: text,
              size: 320,
              lowErrorCorrection: true,
            ),
          )
        else
          Text(
            'Too long for a QR code: send the text or the file.',
            key: const Key('tsm-share-no-qr'),
            style: theme.textTheme.bodySmall,
          ),
        if (_error != null)
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

/// Shows the Import a share dialog: for the inbox [package], or for a share
/// pasted, opened from a file or scanned. Answers how many entries it
/// imported (null: none).
Future<int?> tomSecretsShowImportShareDialog(
  BuildContext context, {
  TomSecretsInboxPackage? package,
}) => showDialog<int>(
  context: context,
  builder: (_) => _ImportShareDialog(package: package),
);

class _ImportShareDialog extends StatefulWidget {
  const _ImportShareDialog({this.package});

  final TomSecretsInboxPackage? package;

  @override
  State<_ImportShareDialog> createState() => _ImportShareDialogState();
}

class _ImportShareDialogState extends State<_ImportShareDialog> {
  final _text = TextEditingController();
  final _passphrase = TextEditingController();
  Uint8List? _bytes;
  TomSecretsShare? _share;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.package;
    if (p != null) {
      _bytes = p.bytes;
      _share = p.share;
      _error = p.problem;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  bool get _needsPassphrase =>
      _bytes != null && _share == null && tomSecretsAgeIsPassphrase(_bytes!);

  void _take(Uint8List bytes) {
    setState(() {
      _bytes = bytes;
      _share = null;
      _error = null;
    });
    if (!tomSecretsAgeIsPassphrase(bytes)) unawaited(_read());
  }

  void _takeText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!tomSecretsLooksLikeShare(trimmed)) {
      setState(
        () => _error =
            'that is not a share (it begins with '
            '-----BEGIN AGE ENCRYPTED FILE-----)',
      );
      return;
    }
    _take(Uint8List.fromList(utf8.encode(trimmed)));
  }

  Future<void> _open(TomSecretsFiles files) async {
    final picked = await files.pick();
    if (picked != null) _take(picked.bytes);
  }

  Future<void> _scan(TomSecretsCodeScanner scanner) async {
    final text = await scanner.scan(context, title: 'Scan the share');
    if (text != null) _takeText(text);
  }

  Future<void> _read() async {
    final session = context.read<TomSecretsSession>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final share = await session.readShare(
        _bytes!,
        passphrase: _needsPassphrase ? _passphrase.text : null,
      );
      if (mounted) setState(() => _share = share);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final session = context.read<TomSecretsSession>();
    final share = _share!;
    final target = await tomSecretsPickGroup(context, 'Import into');
    if (target == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = widget.package;
      final refs = p == null
          ? await session.importShare(share, target.store, target.group)
          : await session.acceptInboxPackage(p, target.store, target.group);
      if (mounted) Navigator.pop(context, refs.length);
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    final session = context.read<TomSecretsSession>();
    setState(() => _busy = true);
    try {
      await session.declineInboxPackage(widget.package!);
      if (mounted) Navigator.pop(context);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _describe(e);
        });
      }
    }
  }

  /// Who sent [share], in words: a member whose fingerprint matches, or
  /// only what the share says.
  String _sender(TomSecretsSession session, TomSecretsShare share) {
    final from = share.from;
    if (from == null) return 'It does not say who sent it.';
    final member = session.members
        .where((m) => m.recipient.fingerprint == from.fingerprint)
        .firstOrNull;
    return member != null
        ? 'From ${member.name}, a member whose key you have.'
        : 'It says it is from ${from.name}; that key is not among your '
              'members.';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final host = context.read<TomSecretsHost>();
    final theme = Theme.of(context);
    final share = _share;
    final inbox = widget.package;
    return AlertDialog(
      key: const Key('tsm-import-share-dialog'),
      title: Text(inbox == null ? 'Import a share' : inbox.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (inbox == null && _bytes == null) ...[
                const Text(
                  'Paste the share someone sent you, open its file, or scan '
                  'its QR code.',
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('tsm-import-share-text'),
                  controller: _text,
                  minLines: 4,
                  maxLines: 8,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  decoration: const InputDecoration(
                    hintText: '-----BEGIN AGE ENCRYPTED FILE-----',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonal(
                      key: const Key('tsm-import-share-paste'),
                      onPressed: () => _takeText(_text.text),
                      child: const Text('Read it'),
                    ),
                    if (host.files != null)
                      OutlinedButton.icon(
                        key: const Key('tsm-import-share-open'),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open file…'),
                        onPressed: () => unawaited(_open(host.files!)),
                      ),
                    if (host.scanner != null)
                      OutlinedButton.icon(
                        key: const Key('tsm-import-share-scan'),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Scan QR code'),
                        onPressed: () => unawaited(_scan(host.scanner!)),
                      ),
                  ],
                ),
              ],
              if (_needsPassphrase) ...[
                const Text('This share is under a passphrase: type it.'),
                TextField(
                  key: const Key('tsm-import-share-passphrase'),
                  controller: _passphrase,
                  obscureText: true,
                  autofocus: true,
                  onSubmitted: (_) => unawaited(_read()),
                ),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  key: const Key('tsm-import-share-unlock'),
                  onPressed: _busy ? null : () => unawaited(_read()),
                  child: const Text('Open'),
                ),
              ],
              if (share != null) ...[
                Text(
                  _sender(session, share),
                  key: const Key('tsm-import-share-from'),
                ),
                const SizedBox(height: 8),
                for (final e in share.entries)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.description_outlined),
                    title: Text(e.title.isEmpty ? '(no title)' : e.title),
                    subtitle: Text(
                      [
                        tomSecretsTypeName(e.type),
                        if (e.attachments.isNotEmpty)
                          '${e.attachments.length} attachment(s)',
                      ].join(' · '),
                    ),
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const Key('tsm-import-share-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        if (inbox != null)
          TextButton(
            key: const Key('tsm-import-share-decline'),
            onPressed: _busy ? null : () => unawaited(_decline()),
            child: const Text('Decline'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('tsm-import-share-go'),
          onPressed: share == null || _busy ? null : () => unawaited(_import()),
          child: const Text('Import into…'),
        ),
      ],
    );
  }
}

/// **[C]** The Shares section (part-sharing): "Import a share…" and the
/// packages in the user's inbox folders ("1 entry from Bob"), each opened
/// in the Import a share dialog. On the desktop's Sharing screen and the
/// phone's Shares page.
class TomSecretsSharesSection extends StatelessWidget {
  /// The section.
  const TomSecretsSharesSection({super.key});

  Future<void> _import(
    BuildContext context, [
    TomSecretsInboxPackage? package,
  ]) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final n = await tomSecretsShowImportShareDialog(context, package: package);
    if (n == null) return;
    tomShowNotice(
      messenger,
      kind: 'share-imported',
      message: n == 1 ? '1 entry imported.' : '$n entries imported.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final inbox = session.inbox;
    return TomSecretsSection(
      key: const Key('tsm-shares'),
      title: inbox.isEmpty
          ? 'Shares'
          : 'Shares — ${inbox.length} in your inbox',
      icon: Icons.move_to_inbox_outlined,
      trailing: TextButton.icon(
        key: const Key('tsm-import-share'),
        icon: const Icon(Icons.download_rounded),
        label: const Text('Import a share…'),
        onPressed: () => unawaited(_import(context)),
      ),
      children: [
        if (inbox.isEmpty)
          Text(
            context.read<TomSecretsHost>().sendsShares
                ? 'Entries someone shares with you arrive as text, a QR code '
                      'or a file, or in your inbox in a shared vault. To share '
                      'entries, mark them in the vault browser and choose '
                      'Share.'
                : 'Entries someone shares with you arrive as text, a QR code '
                      'or a file, or in your inbox in a shared vault. Shares '
                      'are sent from the desktop app.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          for (final p in inbox)
            ListTile(
              key: Key('tsm-inbox-${p.name}'),
              dense: true,
              leading: Icon(
                p.problem != null
                    ? Icons.error_outline
                    : p.passphrase
                    ? Icons.password_rounded
                    : Icons.mail_outline,
              ),
              title: Text(p.title),
              subtitle: Text(
                [
                  'in ${p.store}',
                  if (p.day != null)
                    'since ${p.day!.toIso8601String().substring(0, 10)}',
                  if (p.passphrase) 'under a passphrase',
                  ?p.problem,
                ].join(' · '),
              ),
              trailing: TextButton(
                key: Key('tsm-inbox-open-${p.name}'),
                onPressed: () => unawaited(_import(context, p)),
                child: const Text('Open…'),
              ),
            ),
      ],
    );
  }
}
