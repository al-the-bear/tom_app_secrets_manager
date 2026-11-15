// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Keys screen (part-app, Screens › Keys; part-key-rotation): every key
/// with an expiry or a due date, soonest first — the GitHub tokens, the
/// vaults' key files and repository keys, the approver and approval-link key
/// pairs — with its use, its date, the time left and the reminders; an
/// expired, overdue or soon-due key is marked. A vault's keys get a due
/// date of their own (the entry's Expires in the primary). The rotation
/// ages and reminder starts (DP-85) are this machine's device settings. The
/// product only reminds: a rotation is always the user's click.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../state/clients.dart';
import '../state/service_connection.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;
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

  TomSecretsClientsApi get _api =>
      TomSecretsClientsApi(context.read<TomSecretsServiceConnection>());

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final keys = await _api.keys();
      final settings = await _api.settings();
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _settings = settings;
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
          Tooltip(
            message: 'Not available in this version yet',
            child: TextButton(onPressed: null, child: Text(rotation)),
          ),
        ],
      ),
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
