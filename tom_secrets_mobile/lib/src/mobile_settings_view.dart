// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's settings: the biometric unlock, the refresh interval,
/// the lock and clipboard timeouts, the Android Autofill service, this
/// device's setup.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import 'mobile_autofill.dart';
import 'mobile_documents.dart';
import 'mobile_engine.dart';

/// The settings view.
class TomSecretsMobileSettingsView extends StatefulWidget {
  /// The settings of [engine]; [onForget] forgets this device's setup.
  const TomSecretsMobileSettingsView({
    super.key,
    required this.engine,
    this.onForget,
    this.autofill,
  });

  /// The engine.
  final TomSecretsMobileEngine engine;

  /// The Android Autofill service's platform side, or null where there is
  /// none (iOS).
  final TomSecretsAutofillPlatform? autofill;

  /// Forgets the setup (back to the setup screen), or null.
  final Future<void> Function()? onForget;

  @override
  State<TomSecretsMobileSettingsView> createState() => _SettingsState();
}

class _SettingsState extends State<TomSecretsMobileSettingsView> {
  TomSecretsMobileSettings get _settings => widget.engine.settings;

  /// Whether the Autofill service is the device's, as last asked (null:
  /// the device has none).
  bool? _autofillOn;

  @override
  void initState() {
    super.initState();
    unawaited(_readAutofill());
  }

  Future<void> _readAutofill() async {
    final on = await widget.autofill?.serviceEnabled();
    if (mounted) setState(() => _autofillOn = on);
  }

  Future<void> _set(String key, int value) async {
    if (key == TomSecretsMobileKeys.refreshMinutes) {
      await widget.engine.request('settings.set', {
        'device': {'refreshMinutes': value},
      });
    } else {
      await _settings.set(key, value);
    }
    if (mounted) setState(() {});
  }

  /// A KDBX file picked, named and opened with its password, then listed in
  /// the primary (`TomSecretsMobileEngine.addDocumentVault`).
  Future<void> _addFileVault() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final session = context.read<TomSecretsSession>();
    final picked = await widget.engine.documents!.pickVault();
    if (picked == null || !mounted) return;
    final dot = picked.name.lastIndexOf('.');
    final answer = await showDialog<({String name, String password})>(
      context: context,
      builder: (_) => _AddFileVaultDialog(
        fileName: picked.name,
        suggestedName: (dot > 0 ? picked.name.substring(0, dot) : picked.name)
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-'),
      ),
    );
    if (answer == null || answer.name.isEmpty) return;
    final vaultName = answer.name;
    final secret = answer.password;
    try {
      await widget.engine.addDocumentVault(
        name: vaultName,
        document: picked,
        password: secret,
      );
      // The screens open the new vault with the others.
      await session.load();
      messenger?.showSnackBar(
        SnackBar(content: Text('${picked.name} is the vault $vaultName.')),
      );
    } on TomSecretsAdminException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    } on TomSecretsDocumentException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
    if (mounted) setState(() {});
  }

  Widget _choice(
    String title,
    String key,
    int value,
    List<int> options,
    String Function(int) label,
  ) => ListTile(
    title: Text(title),
    trailing: DropdownButton<int>(
      key: Key('tsm-mobile-setting-$key'),
      value: options.contains(value) ? value : null,
      hint: Text(label(value)),
      items: [
        for (final o in options)
          DropdownMenuItem(value: o, child: Text(label(o))),
      ],
      onChanged: (v) {
        if (v != null) unawaited(_set(key, v));
      },
    ),
  );

  static String _seconds(int s) => s == 0
      ? 'at once'
      : s < 60
      ? '$s s'
      : '${s ~/ 60} min';

  @override
  Widget build(BuildContext context) {
    final os = context.watch<TomSecretsOsUnlock>();
    return ListView(
      key: const Key('tsm-mobile-settings'),
      children: [
        SwitchListTile(
          key: const Key('tsm-mobile-setting-biometric'),
          title: Text('Unlock with ${os.label}'),
          subtitle: Text(
            !os.offered
                ? '${os.label} is not set up on this device.'
                : os.gateOnly
                ? 'The master password is kept in the keychain behind '
                      '${os.label}.'
                : 'The master password is kept under a key only '
                      '${os.label} releases.',
          ),
          value: os.offered && _settings.biometric,
          onChanged: !os.offered || os.busy
              ? null
              : (on) async {
                  await _settings.setBiometric(on);
                  await os.setSaved(on);
                  if (mounted) setState(() {});
                },
        ),
        if (os.message case final m?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(m),
          ),
        const Divider(),
        _choice(
          'Look for changes on GitHub every',
          TomSecretsMobileKeys.refreshMinutes,
          _settings.refreshMinutes,
          const [5, 15, 30, 60],
          (m) => '$m min',
        ),
        _choice(
          'Lock in the background after',
          TomSecretsMobileKeys.lockSeconds,
          _settings.lockSeconds,
          const [0, 30, 60, 300],
          _seconds,
        ),
        _choice(
          'Clear the clipboard after',
          TomSecretsMobileKeys.clipboardSeconds,
          _settings.clipboardSeconds,
          const [15, 30, 60, 120],
          _seconds,
        ),
        if (widget.autofill != null && _autofillOn != null) ...[
          const Divider(),
          ListTile(
            key: const Key('tsm-mobile-autofill'),
            leading: const Icon(Icons.password_rounded),
            title: const Text('Autofill service'),
            subtitle: Text(
              _autofillOn!
                  ? 'Apps and browsers fill logins from your personal and '
                        'shared vaults, after your fingerprint.'
                  : 'Turn Tom Secrets on as the autofill service to fill '
                        'logins in apps and browsers.',
            ),
            trailing: _autofillOn!
                ? const Icon(Icons.check_circle_outline_rounded)
                : TextButton(
                    key: const Key('tsm-mobile-autofill-on'),
                    onPressed: () async {
                      await widget.autofill!.openSettings();
                      await _readAutofill();
                    },
                    child: const Text('Turn on'),
                  ),
          ),
        ],
        const Divider(),
        ListTile(
          title: Text('Vaults', style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final MapEntry(key: name, value: locator)
            in widget.engine.locators.entries)
          ListTile(
            key: Key('tsm-mobile-vault-locator-$name'),
            dense: true,
            leading: Icon(
              locator.startsWith('file:')
                  ? Icons.description_outlined
                  : Icons.cloud_outlined,
            ),
            title: Text(name),
            subtitle: Text(
              '$locator'
              '${context.watch<TomSecretsServiceConnection>().stores[name]?.state == 'unavailable' ? ' · not reachable on this device' : ''}',
            ),
          ),
        if (widget.engine.documents != null)
          ListTile(
            key: const Key('tsm-mobile-add-file-vault'),
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Add a vault from a file'),
            subtitle: const Text(
              'A KDBX file in Files (e.g. iCloud Drive): read when you '
              'unlock, written back when you save; no copy is kept.',
            ),
            onTap: () => unawaited(_addFileVault()),
          ),
        const Divider(),
        ListTile(
          title: const Text('This device'),
          subtitle: Text(
            '${widget.engine.device} · the primary '
            '${widget.engine.primaryLocator}',
          ),
        ),
        const ListTile(
          title: Text('Kept on this device'),
          subtitle: Text(
            'The vaults are fetched into memory at every unlock and dropped '
            'at the lock; only the keys and the GitHub token stay, in the '
            'keychain. System vaults are read-only here.',
          ),
        ),
        if (widget.onForget case final forget?)
          ListTile(
            key: const Key('tsm-mobile-forget'),
            leading: const Icon(Icons.restart_alt_rounded),
            title: const Text('Set this device up again'),
            subtitle: const Text('Locks, then shows the pairing screen.'),
            onTap: () async {
              final sure = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Set this device up again?'),
                  content: const Text(
                    'The vaults stay on GitHub. Pair with a desktop again to '
                    'use them here.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Set up again'),
                    ),
                  ],
                ),
              );
              if (sure == true) await forget();
            },
          ),
      ],
    );
  }
}

/// The name and password of a file added as a vault.
class _AddFileVaultDialog extends StatefulWidget {
  const _AddFileVaultDialog({
    required this.fileName,
    required this.suggestedName,
  });

  final String fileName;
  final String suggestedName;

  @override
  State<_AddFileVaultDialog> createState() => _AddFileVaultDialogState();
}

class _AddFileVaultDialogState extends State<_AddFileVaultDialog> {
  late final _name = TextEditingController(text: widget.suggestedName);
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Add ${widget.fileName}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('tsm-mobile-file-vault-name'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Vault name'),
        ),
        TextField(
          key: const Key('tsm-mobile-file-vault-password'),
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Its password'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('tsm-mobile-file-vault-add'),
        onPressed: () => Navigator.of(
          context,
        ).pop((name: _name.text.trim(), password: _password.text)),
        child: const Text('Add'),
      ),
    ],
  );
}
