// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The shared vaults of the Sharing screen (part-sharing, part-app, phase C;
/// desktop only): a new shared vault for chosen members, an existing one
/// opened by its location, and per vault its members from the recipients
/// file — a member added, a member removed (the vault re-keyed) with the
/// offer to rotate its entries.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/new_vault.dart';
import '../state/relay_settings.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

String _describe(Object e) => switch (e) {
  TomSecretsAdminException(details: final d)
      when d['reason'] == 'no_recipients' =>
    'there is no shared vault there (no recipients file beside it)',
  TomSecretsAdminException() => tomSecretsDescribeAdminError(e),
  TomSecretsSharedVaultException(:final message) => message,
  TomSecretsMemberKeyException(:final message) => message,
  TomSecretsAgeException(:final message) => message,
  TomSecretsRotationException(:final message) => message,
  ArgumentError(:final message) => '$message',
  StateError(:final message) => message,
  _ => '$e',
};

/// The shared vaults section.
class TomSecretsSharedVaultsSection extends StatefulWidget {
  /// The section.
  const TomSecretsSharedVaultsSection({super.key});

  @override
  State<TomSecretsSharedVaultsSection> createState() => _SharedVaultsState();
}

class _SharedVaultsState extends State<TomSecretsSharedVaultsSection> {
  /// Each vault's recipients file as read, by store (read when expanded).
  final Map<String, TomSecretsSharedVaultRead> _read = {};
  final Map<String, String> _problems = {};
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final r in _read.values) {
      r.keys.dispose();
    }
    super.dispose();
  }

  Future<void> _load(String store) async {
    try {
      final read = await context.read<TomSecretsSession>().readSharedVault(
        store: store,
      );
      if (!mounted) {
        read.keys.dispose();
        return;
      }
      setState(() {
        _read.remove(store)?.keys.dispose();
        _read[store] = read;
        _problems.remove(store);
      });
    } on Object catch (e) {
      if (mounted) setState(() => _problems[store] = _describe(e));
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final session = context.read<TomSecretsSession>();
    final made = await showDialog<_NewShared>(
      context: context,
      builder: (_) => _NewSharedVaultDialog(
        members: [
          for (final m in session.members)
            if (m.canJoinSharedVaults) m,
        ],
      ),
    );
    if (made == null || !mounted) return;
    await _run(() => session.createSharedVault(made.spec, made.members));
  }

  Future<void> _join() async {
    final session = context.read<TomSecretsSession>();
    final join = await showDialog<_Join>(
      context: context,
      builder: (_) => const _JoinDialog(),
    );
    if (join == null || !mounted) return;
    await _run(
      () => session.joinSharedVault(
        location: join.location,
        name: join.name,
        githubToken: join.token,
      ),
    );
  }

  Future<void> _addMember(String store) async {
    final session = context.read<TomSecretsSession>();
    final read = _read[store];
    if (read == null) return;
    final candidates = [
      for (final m in session.members)
        if (m.canJoinSharedVaults && !read.keys.hasMember(m.recipient)) m,
    ];
    final chosen = await showDialog<TomSecretsMember>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Add a member to $store'),
        children: [
          if (candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text(
                'Every member with a hybrid key is in the vault already. Add '
                'the person\'s public key under Members first.',
              ),
            ),
          for (final m in candidates)
            SimpleDialogOption(
              key: Key('tsm-shared-add-${m.recipient.fingerprint}'),
              onPressed: () => Navigator.pop(context, m),
              child: Text('${m.name}  ·  ${m.recipient.shortFingerprint}'),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await _run(() async {
      await session.addSharedVaultMember(store, chosen);
      await _load(store);
    });
  }

  Future<void> _removeMember(
    String store,
    TomSecretsSharedVaultMember member,
  ) async {
    final session = context.read<TomSecretsSession>();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${member.name} from $store?'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'The vault gets a new key, which the members left receive '
            'through its recipients file. The removed member keeps every '
            'value they have seen, and the older versions of the vault in '
            'its history stay readable to them, never the new ones. Take '
            'their access to the repository away on GitHub yourself.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-shared-remove-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove and re-key'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    List<TomSecretsEntryRef>? entries;
    await _run(() async {
      entries = await session.removeSharedVaultMember(store, member.recipient);
      await _load(store);
    });
    if (entries == null || entries!.isEmpty || !mounted) return;
    final chosen = await showDialog<List<TomSecretsEntryRef>>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: session,
        child: _RotationOffer(store: store, entries: entries!),
      ),
    );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    await _run(() => session.markForRotation(chosen));
  }

  Future<void> _rotate(String store) async {
    final session = context.read<TomSecretsSession>();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Rotate the key of $store?'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'The vault gets a new key; its members take it up from the '
            'recipients file at their next start. A device that has not yet '
            'keeps reading its copy under the old key, read-only, during the '
            '14-day migration period. The finish compacts the vault\'s '
            'history, so no older version under the old key stays.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-shared-rotate-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _run(() async {
      await session.rotateSharedVaultKeys(store);
      await _load(store);
    });
  }

  Future<void> _finishRotation(String store, {required bool early}) async {
    final session = context.read<TomSecretsSession>();
    await _run(() async {
      final failed = await session.finishSharedVaultRotation(
        store,
        early: early,
      );
      if (failed != null && mounted) {
        setState(
          () => _error =
              'The rotation is finished; the history could not be compacted '
              'now ($failed): compact it on the Keys screen later.',
        );
      }
    });
  }

  Widget _rotationOf(
    BuildContext context,
    String store,
    TomSecretsRotation r,
    bool writable,
  ) {
    final due = r.isDueAt(DateTime.now());
    String day(DateTime d) => d.toLocal().toIso8601String().substring(0, 10);
    return Padding(
      key: Key('tsm-shared-rotation-$store'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Its key was rotated on ${day(r.started)} by ${r.by}; the '
            'migration period '
            '${due ? 'is over' : 'ends on ${day(r.endsAt)}'}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                key: Key('tsm-shared-finish-$store'),
                onPressed: writable && due
                    ? () => _finishRotation(store, early: false)
                    : null,
                child: const Text('Finish'),
              ),
              TextButton(
                key: Key('tsm-shared-finish-now-$store'),
                onPressed: writable && !due
                    ? () => _finishRotation(store, early: true)
                    : null,
                child: const Text('Finish now'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final theme = Theme.of(context);
    final ready =
        !_busy &&
        session.memberKeyRecipient != null &&
        session.sharingReadOnlyReason == null;
    return TomSecretsSection(
      title: 'Shared vaults',
      icon: Icons.folder_shared_rounded,
      children: [
        Text(
          'A shared vault is opened by a key file alone. Its keys sit beside '
          'it in a recipients file encrypted to every member\'s hybrid key, '
          'so each member\'s app opens it with their member key. Members '
          'also need write access to its repository, which you grant on '
          'GitHub.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('tsm-shared-new'),
              icon: const Icon(Icons.create_new_folder_rounded),
              label: const Text('New shared vault…'),
              onPressed: ready ? _create : null,
            ),
            OutlinedButton.icon(
              key: const Key('tsm-shared-join'),
              icon: const Icon(Icons.login_rounded),
              label: const Text('Open a shared vault…'),
              onPressed: ready ? _join : null,
            ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              key: const Key('tsm-shared-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        if (session.sharedKeysTakenUp.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'New keys taken up from the recipients file: '
              '${session.sharedKeysTakenUp.join(', ')}.',
              key: const Key('tsm-shared-taken-up'),
            ),
          ),
        if (session.sharedVaults.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'No shared vaults yet.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final store in session.sharedVaults) _vault(context, store),
      ],
    );
  }

  Widget _vault(BuildContext context, String store) {
    final theme = Theme.of(context);
    final session = context.read<TomSecretsSession>();
    final read = _read[store];
    final own = session.memberKeyRecipient;
    final writable = session.readOnlyReason(store) == null && !_busy;
    return ExpansionTile(
      key: Key('tsm-shared-$store'),
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_shared_outlined),
      title: Text(store),
      subtitle: read == null ? null : Text(read.location),
      onExpansionChanged: (open) {
        if (open && read == null) _load(store);
      },
      children: [
        if (_problems[store] case final p?)
          Text(p, style: TextStyle(color: theme.colorScheme.error)),
        if (read == null && _problems[store] == null)
          const LinearProgressIndicator(),
        if (read != null) ...[
          for (final m in read.keys.members)
            ListTile(
              key: Key('tsm-shared-$store-${m.recipient.fingerprint}'),
              dense: true,
              leading: Icon(
                m.recipient == own
                    ? Icons.person_rounded
                    : Icons.person_outline_rounded,
              ),
              title: Text(m.recipient == own ? '${m.name} (you)' : m.name),
              subtitle: Text(m.recipient.shortFingerprint),
              trailing: m.recipient == own || !writable
                  ? null
                  : IconButton(
                      key: Key(
                        'tsm-shared-remove-$store-${m.recipient.fingerprint}',
                      ),
                      tooltip: 'Remove from the vault',
                      icon: const Icon(Icons.person_remove_outlined),
                      onPressed: () => _removeMember(store, m),
                    ),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: Key('tsm-shared-add-member-$store'),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Add a member…'),
                onPressed: writable ? () => _addMember(store) : null,
              ),
              if (session.sharedVaultRotation(store) == null)
                TextButton.icon(
                  key: Key('tsm-shared-rotate-$store'),
                  icon: const Icon(Icons.autorenew_rounded),
                  label: const Text('Rotate the vault\'s key…'),
                  onPressed: writable ? () => _rotate(store) : null,
                ),
            ],
          ),
          if (session.sharedVaultRotation(store) case final r?)
            _rotationOf(context, store, r, writable),
          _mailboxRelay(context, store, writable),
        ],
      ],
    );
  }

  /// The vault's mailbox relay (part-relay): its own repository's inbox
  /// folders, or a relay of the settings that offers a mailbox; kept in the
  /// vault's metadata, so every member's app reads the same one.
  Widget _mailboxRelay(BuildContext context, String store, bool writable) {
    final session = context.read<TomSecretsSession>();
    final theme = Theme.of(context);
    final current = session.mailboxRelayOf(store);
    final relays = TomSecretsRelaySettings(
      context.read<TomSecretsHost>().preferences,
    ).offering(TomSecretsRelayService.mailbox);
    // GitHub's mailbox is the vault's own repository: other repositories
    // are not offered, only relays with a mailbox of their own.
    final options = {
      for (final r in relays)
        if (r.kind != TomSecretsRelayKind.github) r.text,
      ?current?.text,
    }.toList();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              const Text('Mailbox: '),
              DropdownButton<String>(
                key: Key('tsm-shared-mailbox-$store'),
                value: current?.text ?? '',
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('This vault\'s repository'),
                  ),
                  for (final o in options)
                    DropdownMenuItem(value: o, child: Text(o)),
                ],
                onChanged: !writable
                    ? null
                    : (v) => unawaited(
                        _run(
                          () => session.setVaultMailboxRelay(
                            store,
                            v == null || v.isEmpty
                                ? null
                                : TomSecretsRelayId.parse(v),
                          ),
                        ),
                      ),
              ),
            ],
          ),
          Text(
            current == null
                ? 'Shares to its members wait in the inbox folders beside '
                      'the vault.'
                : 'Recorded for every member. This version reads the inbox '
                      'folders beside the vault; ${current.text} is read once '
                      'the relay server is supported.',
            key: Key('tsm-shared-mailbox-note-$store'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

typedef _NewShared = ({
  TomSecretsNewVaultSpec spec,
  List<TomSecretsMember> members,
});

class _NewSharedVaultDialog extends StatefulWidget {
  const _NewSharedVaultDialog({required this.members});

  final List<TomSecretsMember> members;

  @override
  State<_NewSharedVaultDialog> createState() => _NewSharedState();
}

class _NewSharedState extends State<_NewSharedVaultDialog> {
  final _name = TextEditingController();
  final _repository = TextEditingController();
  final _folder = TextEditingController();
  final _token = TextEditingController();
  TomSecretsNewVaultPlace _place = TomSecretsNewVaultPlace.github;
  bool _outer = false;
  final Set<TomSecretsMember> _chosen = {};

  @override
  void dispose() {
    for (final c in [_name, _repository, _folder, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _ok =>
      tomSecretsStoreNamePattern.hasMatch(_name.text.trim()) &&
      (_place != TomSecretsNewVaultPlace.github ||
          _repository.text.trim().isNotEmpty) &&
      (_place != TomSecretsNewVaultPlace.file ||
          _folder.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New shared vault'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('tsm-shared-new-name'),
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name (lower-case letters, digits, - and _)',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<TomSecretsNewVaultPlace>(
              key: const Key('tsm-shared-new-place'),
              initialValue: _place,
              decoration: const InputDecoration(labelText: 'Where it lives'),
              items: const [
                DropdownMenuItem(
                  value: TomSecretsNewVaultPlace.github,
                  child: Text('A shared GitHub repository'),
                ),
                DropdownMenuItem(
                  value: TomSecretsNewVaultPlace.besidePrimary,
                  child: Text('Beside my primary vault'),
                ),
                DropdownMenuItem(
                  value: TomSecretsNewVaultPlace.file,
                  child: Text('A folder on this machine'),
                ),
              ],
              onChanged: (v) => setState(() => _place = v ?? _place),
            ),
            if (_place == TomSecretsNewVaultPlace.github) ...[
              TextField(
                key: const Key('tsm-shared-new-repository'),
                controller: _repository,
                decoration: const InputDecoration(
                  labelText: 'Repository (owner/name)',
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const Key('tsm-shared-new-token'),
                controller: _token,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'GitHub token for that repository (optional)',
                ),
              ),
            ],
            if (_place != TomSecretsNewVaultPlace.besidePrimary)
              TextField(
                key: const Key('tsm-shared-new-folder'),
                controller: _folder,
                decoration: InputDecoration(
                  labelText: _place == TomSecretsNewVaultPlace.file
                      ? 'Folder'
                      : 'Folder in the repository (optional)',
                ),
                onChanged: (_) => setState(() {}),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _outer,
              onChanged: (v) => setState(() => _outer = v ?? false),
              title: const Text('Outer encryption (a repository key)'),
            ),
            const SizedBox(height: 8),
            Text(
              'Members (you are always one):',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (widget.members.isEmpty)
              const Text(
                'No member with a hybrid key yet: add them later, once their '
                'public keys are under Members.',
              ),
            for (final m in widget.members)
              CheckboxListTile(
                key: Key('tsm-shared-new-member-${m.recipient.fingerprint}'),
                contentPadding: EdgeInsets.zero,
                value: _chosen.contains(m),
                onChanged: (v) => setState(
                  () => v == true ? _chosen.add(m) : _chosen.remove(m),
                ),
                title: Text(m.name),
                subtitle: Text(m.recipient.shortFingerprint),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('tsm-shared-new-go'),
        onPressed: !_ok
            ? null
            : () => Navigator.pop(context, (
                spec: TomSecretsNewVaultSpec(
                  name: _name.text.trim(),
                  kind: TomSecretsVaultKind.shared,
                  place: _place,
                  repository: _repository.text.trim(),
                  folder: _folder.text.trim(),
                  outer: _outer,
                  githubToken: _token.text.trim(),
                ),
                members: [
                  for (final m in widget.members)
                    if (_chosen.contains(m)) m,
                ],
              )),
        child: const Text('Create'),
      ),
    ],
  );
}

typedef _Join = ({String location, String? name, String? token});

class _JoinDialog extends StatefulWidget {
  const _JoinDialog();

  @override
  State<_JoinDialog> createState() => _JoinState();
}

class _JoinState extends State<_JoinDialog> {
  final _location = TextEditingController();
  final _name = TextEditingController();
  final _token = TextEditingController();

  @override
  void dispose() {
    for (final c in [_location, _name, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Open a shared vault'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'The vault someone shared with your member key: its location, '
            'as they give it to you.',
          ),
          TextField(
            key: const Key('tsm-shared-join-location'),
            controller: _location,
            decoration: const InputDecoration(
              labelText: 'Location (github:owner/repository/team.kdbx)',
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const Key('tsm-shared-join-token'),
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'GitHub token for that repository (optional)',
            ),
          ),
          TextField(
            key: const Key('tsm-shared-join-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name here (optional: the vault\'s own)',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('tsm-shared-join-go'),
        onPressed: _location.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (
                location: _location.text.trim(),
                name: _name.text.trim().isEmpty ? null : _name.text.trim(),
                token: _token.text.trim().isEmpty ? null : _token.text.trim(),
              )),
        child: const Text('Open'),
      ),
    ],
  );
}

/// After a member was removed: the vault's entries, the important ones to
/// mark for rotation.
class _RotationOffer extends StatefulWidget {
  const _RotationOffer({required this.store, required this.entries});

  final String store;
  final List<TomSecretsEntryRef> entries;

  @override
  State<_RotationOffer> createState() => _RotationOfferState();
}

class _RotationOfferState extends State<_RotationOffer> {
  final Set<TomSecretsEntryRef> _chosen = {};

  @override
  Widget build(BuildContext context) {
    final session = context.read<TomSecretsSession>();
    return AlertDialog(
      title: Text('Rotate the secrets of ${widget.store}?'),
      content: SizedBox(
        width: 480,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The removed member may have seen these values. Mark the '
              'important ones: they get the tag "rotate" and expire today, '
              'so Health lists them until you change them, at their '
              'service too.',
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final ref in widget.entries)
                    CheckboxListTile(
                      key: Key('tsm-rotate-${tomSecretsUuidHex(ref.uuid)}'),
                      dense: true,
                      value: _chosen.contains(ref),
                      onChanged: (v) => setState(
                        () =>
                            v == true ? _chosen.add(ref) : _chosen.remove(ref),
                      ),
                      title: Text(session.entryOf(ref)?.label ?? ''),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const <TomSecretsEntryRef>[]),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const Key('tsm-rotate-go'),
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, _chosen.toList()),
          child: const Text('Mark for rotation'),
        ),
      ],
    );
  }
}
