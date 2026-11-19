// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Keys screen (part-app, Screens › Keys; part-key-rotation): every key
/// with an expiry or a due date, soonest first — the GitHub tokens, the
/// vaults' key files and repository keys, the approver and approval-link key
/// pairs — with its use, its date, the time left and the reminders; an
/// expired, overdue or soon-due key is marked. A vault's keys get a due
/// date of their own (the entry's Expires in the primary). The rotation
/// ages and reminder starts (DP-85) are this machine's device settings. The
/// product only reminds: a rotation is always the user's click — every
/// vault's master password, key file and repository key are rotated here by
/// hand (part-key-rotation), and a rotation whose re-keyed save failed is
/// finished here.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_ui_support/tom_ui_support.dart' show tomShowNotice;

import '../state/clients.dart';
import '../state/rotation.dart';
import '../state/service_connection.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'github_sign_in.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;
import 'renew_token_dialog.dart';
import 'rotate_dialog.dart';
import 'vault_browser.dart' show tomSecretsGuarded;

/// The Keys screen.
class TomSecretsKeysView extends StatefulWidget {
  /// The screen.
  const TomSecretsKeysView({super.key});

  @override
  State<TomSecretsKeysView> createState() => _KeysState();
}

class _KeysState extends State<TomSecretsKeysView> {
  List<TomSecretsKeyInfo>? _keys;
  TomSecretsSettingsReport? _settings;
  Map<String, Object?> _draft = const {};
  String? _error;
  String? _agesMessage;
  List<TomSecretsPendingRotation> _pending = const [];
  String? _finishMessage;
  String? _pairsMessage;

  TomSecretsClientsApi get _api =>
      TomSecretsClientsApi(context.read<TomSecretsServiceConnection>());

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final session = context.read<TomSecretsSession>();
      final keys = await _api.keys();
      final settings = await _api.settings();
      final pending = await session.pendingRotations();
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _settings = settings;
        _pending = pending;
        _draft = settings.device.toJson();
        _error = null;
      });
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }

  Future<void> _setDue(TomSecretsKeyInfo key) async {
    final store = key.vault;
    if (store == null) return;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: key.expiresAt.isBefore(now) ? now : key.expiresAt.toLocal(),
      firstDate: now,
      lastDate: DateTime(now.year + 10),
      helpText: 'Due date of the keys of $store',
    );
    if (picked == null || !mounted) return;
    final session = context.read<TomSecretsSession>();
    final c = context.read<TomSecretsServiceConnection>();
    await tomSecretsGuarded(context, () async {
      await session.setVaultKeysDue(store, picked);
      // The service reads the primary's vault list again at a refresh.
      await c.reload();
      await c.refreshStatus();
    });
    await _load();
  }

  Future<void> _rotate(String store) async {
    final c = context.read<TomSecretsServiceConnection>();
    final session = context.read<TomSecretsSession>();
    if (session.kindOf(store) == TomSecretsVaultKind.shared) {
      // A shared vault's key travels in its recipients file: rotated there,
      // with its migration period (part-key-rotation).
      await _rotateShared(store);
      return;
    }
    // Read again whatever the outcome: a failed rotation leaves a pending
    // one to finish.
    await tomSecretsShowRotateDialog(context, store);
    await c.refreshStatus();
    await _load();
  }

  Future<void> _rotateShared(String store) async {
    final session = context.read<TomSecretsSession>();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Rotate the key of the shared vault $store?'),
        content: const Text(
          'The members take up the new key from the recipients file; a '
          'device that has not yet reads its copy under the old key, '
          'read-only, for 14 days. Finish it on the Sharing screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-key-rotate-shared-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await tomSecretsGuarded(
      context,
      () => session.rotateSharedVaultKeys(store),
    );
    await _load();
  }

  Future<void> _rotateMemberKey() async {
    final session = context.read<TomSecretsSession>();
    if (session.memberKeyRotation != null) {
      tomShowNotice(
        ScaffoldMessenger.maybeOf(context),
        kind: 'member-key-rotating',
        message: 'Your member key is rotating already: see Sharing.',
      );
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rotate your member key?'),
        content: const Text(
          'A new member key is made beside the old one, and your shared '
          'vaults are written for both until the rotation finishes (14 days, '
          'or Finish on the Sharing screen). Give the new key to your '
          'members.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-key-rotate-member-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      await session.startMemberKeyRotation();
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    await _load();
  }

  Future<void> _renew(String key) async {
    final c = context.read<TomSecretsServiceConnection>();
    await tomSecretsShowRenewTokenDialog(
      context,
      key.substring('github-token:'.length),
    );
    await c.refreshStatus();
    await _load();
  }

  Future<void> _rotatePairs() async {
    final c = context.read<TomSecretsServiceConnection>();
    final api = _api;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('tsm-pairs-rotate'),
        title: const Text('Rotate this device\'s key pairs'),
        content: const SizedBox(
          width: 520,
          child: Text(
            'This device gets a new approver key pair and a new approval-link '
            'key pair, together. What the old approver key signed (grants, '
            'revocations, pre-approvals) is signed again, and every paired '
            'host is told: over the approval link now, or from the vault at '
            'its next refresh. The old link key keeps working for 14 days '
            'for the hosts not reached yet.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-pairs-rotate-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    String message;
    try {
      message = (await api.rotateKeyPairs()).description;
    } on TomSecretsAdminException catch (e) {
      message = tomSecretsDescribeAdminError(e);
    }
    await c.refreshStatus();
    await _load();
    if (mounted) setState(() => _pairsMessage = message);
  }

  Future<void> _finish() async {
    final session = context.read<TomSecretsSession>();
    try {
      final done = await session.finishRotations();
      if (mounted) {
        setState(() => _finishMessage = 'Re-keyed: ${done.join(', ')}.');
      }
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() => _finishMessage = tomSecretsDescribeAdminError(e));
      }
    }
    await _load();
  }

  Future<void> _saveAges() async {
    final c = context.read<TomSecretsServiceConnection>();
    try {
      await _api.writeSettings(TomSecretsDeviceSettings.fromJson(_draft));
      await c.refreshStatus();
      if (mounted) setState(() => _agesMessage = 'Saved.');
      await _load();
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() => _agesMessage = tomSecretsDescribeAdminError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keys = _keys;
    if (_error != null) return Center(child: Text(_error!));
    if (keys == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      key: const Key('tsm-keys'),
      padding: const EdgeInsets.all(12),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_pending.isNotEmpty || _finishMessage != null)
                  _pendingBanner(context),
                if (_pairsMessage != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _pairsMessage!,
                        key: const Key('tsm-pairs-message'),
                      ),
                    ),
                  ),
                const TomSecretsGitHubSignInSection(),
                TomSecretsSection(
                  title: 'Keys and their dates',
                  icon: Icons.key_rounded,
                  trailing: IconButton(
                    tooltip: 'Read again',
                    iconSize: 18,
                    icon: const Icon(Icons.refresh),
                    onPressed: () => unawaited(_load()),
                  ),
                  children: [
                    Text(
                      'The product only reminds; a key is never rotated by '
                      'itself.',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (keys.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No key has a date yet.'),
                      ),
                    for (final k in keys) _keyRow(context, k),
                  ],
                ),
                _vaults(context),
                _ages(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _keyRow(BuildContext context, TomSecretsKeyInfo k) {
    final theme = Theme.of(context);
    final colour = k.expired
        ? theme.colorScheme.error
        : k.reminding
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final left = k.expired
        ? 'expired ${-k.daysLeft} days ago'
        : k.daysLeft == 0
        ? 'due today'
        : '${k.daysLeft} days left';
    final rotation = switch (k.kind) {
      'github_token' => 'Renew…',
      _ => 'Rotate…',
    };
    return ListTile(
      key: Key('tsm-key-${k.key}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(switch (k.kind) {
        'github_token' => Icons.vpn_key_outlined,
        'vault_keys' => Icons.lock_outline,
        'member_key' => Icons.badge_outlined,
        _ => Icons.devices_other_outlined,
      }, color: colour),
      title: Text(k.title, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        '${k.expiresAt.toLocal().toIso8601String().substring(0, 10)} · $left'
        '${k.reminding && !k.expired ? ' · reminding' : ''}',
        style: TextStyle(color: k.expired || k.reminding ? colour : null),
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (k.kind == 'vault_keys')
            TextButton(
              key: Key('tsm-key-due-${k.key}'),
              onPressed: () => unawaited(_setDue(k)),
              child: const Text('Due date…'),
            ),
          if (k.own && (k.kind == 'approver_key' || k.kind == 'link_key'))
            TextButton(
              key: Key('tsm-key-rotate-${k.key}'),
              onPressed: () => unawaited(_rotatePairs()),
              child: Text(rotation),
            )
          else if (k.kind == 'github_token')
            TextButton(
              key: Key('tsm-key-renew-${k.key}'),
              onPressed: () => unawaited(_renew(k.key)),
              child: Text(rotation),
            )
          else if (k.kind == 'member_key' && k.own)
            TextButton(
              key: Key('tsm-key-rotate-${k.key}'),
              onPressed: () => unawaited(_rotateMemberKey()),
              child: Text(rotation),
            )
          else if (k.kind == 'vault_keys' && k.vault != null)
            TextButton(
              key: Key('tsm-key-rotate-${k.key}'),
              onPressed: () => unawaited(_rotate(k.vault!)),
              child: Text(rotation),
            )
          else
            Tooltip(
              message: 'Not available in this version yet',
              child: TextButton(onPressed: null, child: Text(rotation)),
            ),
        ],
      ),
    );
  }

  Widget _pendingBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('tsm-rotate-pending'),
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.sync_problem_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _pending.isEmpty
                    ? _finishMessage!
                    : 'The rotation of ${_pending.map((p) => p.store).join(', ')} '
                          'is not finished: the primary holds the new keys, the '
                          'vault still has its old ones and is served with them.',
              ),
            ),
            if (_pending.isNotEmpty)
              FilledButton(
                key: const Key('tsm-rotate-finish'),
                onPressed: () => unawaited(_finish()),
                child: const Text('Finish the rotation'),
              ),
          ],
        ),
      ),
    );
  }

  /// Every vault the primary lists, the primary first, with its Rotate….
  Widget _vaults(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final primary = session.vaults.firstOrNull;
    if (primary == null) return const SizedBox.shrink();
    final listed = TomSecretsPrimaryVaults(primary.file).list();
    return TomSecretsSection(
      title: 'Rotate a vault\'s keys',
      icon: Icons.autorenew_rounded,
      children: [
        Text(
          'A new master password, key file or repository key, written into '
          'the primary and then into the vault.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        for (final (store, location) in [
          (primary.store, primary.location),
          for (final v in listed) (v.name, v.locator),
        ])
          ListTile(
            key: Key('tsm-vault-keys-$store'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              location.endsWith(tomSecretsOuterSuffix)
                  ? Icons.enhanced_encryption_outlined
                  : Icons.lock_outline,
            ),
            title: Text(
              store == primary.store ? '$store (primary)' : store,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(location, overflow: TextOverflow.ellipsis),
            trailing: TextButton(
              key: Key('tsm-rotate-$store'),
              onPressed: () => unawaited(_rotate(store)),
              child: const Text('Rotate…'),
            ),
          ),
      ],
    );
  }

  Widget _ages(BuildContext context) {
    if (_settings == null) return const SizedBox.shrink();
    int value(String key, int fallback) =>
        _draft[key] is int ? _draft[key]! as int : fallback;
    void set(String key, int v) => setState(() {
      _draft = {..._draft, key: v};
      _agesMessage = null;
    });
    Widget number(String key, String label, int fallback, int min, int max) {
      final v = value(key, fallback);
      return Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove),
            onPressed: v <= min ? null : () => set(key, v - 1),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$v',
              key: Key('tsm-ages-$key'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            key: Key('tsm-ages-$key-more'),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add),
            onPressed: v >= max ? null : () => set(key, v + 1),
          ),
        ],
      );
    }

    return TomSecretsSection(
      title: 'Rotation ages and reminders (this machine)',
      icon: Icons.schedule_rounded,
      children: [
        number(
          'keyExpiryWarningDays',
          'Days before a GitHub token expires that its reminders start',
          14,
          1,
          365,
        ),
        number(
          'otherKeyWarningDays',
          'Days before any other key is due that its reminders start',
          30,
          1,
          365,
        ),
        number(
          'keyPairAgeMonths',
          'Rotation age of the approver and approval-link key pairs, months',
          24,
          1,
          120,
        ),
        number(
          'memberKeyAgeMonths',
          'Rotation age of your member key (shared vaults), months',
          24,
          1,
          120,
        ),
        number(
          'primaryKeyAgeMonths',
          'Rotation age a new key of the primary vault gets, months',
          24,
          1,
          120,
        ),
        number(
          'vaultKeyAgeMonths',
          'Rotation age a new key of every other vault gets, months',
          12,
          1,
          120,
        ),
        Text(
          'Then 7 days and 1 day before, and once a day once a key is due. '
          'A vault\'s keys have their own due date above.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              key: const Key('tsm-ages-save'),
              onPressed: () => unawaited(_saveAges()),
              child: const Text('Save'),
            ),
            const SizedBox(width: 12),
            if (_agesMessage != null)
              Text(_agesMessage!, key: const Key('tsm-ages-message')),
          ],
        ),
      ],
    );
  }
}
