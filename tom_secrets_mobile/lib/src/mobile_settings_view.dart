// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's settings: the biometric unlock, the refresh interval,
/// the lock and clipboard timeouts, this device's setup.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'mobile_engine.dart';

/// The settings view.
class TomSecretsMobileSettingsView extends StatefulWidget {
  /// The settings of [engine]; [onForget] forgets this device's setup.
  const TomSecretsMobileSettingsView({
    super.key,
    required this.engine,
    this.onForget,
  });

  /// The engine.
  final TomSecretsMobileEngine engine;

  /// Forgets the setup (back to the setup screen), or null.
  final Future<void> Function()? onForget;

  @override
  State<TomSecretsMobileSettingsView> createState() => _SettingsState();
}

class _SettingsState extends State<TomSecretsMobileSettingsView> {
  TomSecretsMobileSettings get _settings => widget.engine.settings;

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
