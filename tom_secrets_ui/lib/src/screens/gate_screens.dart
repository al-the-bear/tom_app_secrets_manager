// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// What the app shows before the vaults: attaching to the service, starting
/// it, claiming it, and the Unlock screen (part-app, "How it works with the
/// service" and Screens › Unlock).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_reusable_ui/tom_reusable_ui.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../ports/desktop_ports.dart';
import '../state/service_connection.dart';
import '../widgets/style.dart';

/// A centred card with a title, text and actions.
class TomSecretsGateCard extends StatelessWidget {
  /// A card titled [title].
  const TomSecretsGateCard({
    super.key,
    required this.title,
    this.icon = Icons.lock_outline,
    required this.children,
  });

  /// The title.
  final String title;

  /// The icon above it.
  final IconData icon;

  /// The content.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: TomSecretsAvatar(
                      icon: icon,
                      colour: tomSecretsSeed,
                      size: 56,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Attaching, no service, starting, a start that failed, a dropped
/// connection.
class TomSecretsConnectionScreen extends StatelessWidget {
  /// The screen.
  const TomSecretsConnectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final (title, text, busy) = switch (c.phase) {
      TomSecretsConnectionPhase.connecting => (
        'Connecting',
        'Looking for the secrets service…',
        true,
      ),
      TomSecretsConnectionPhase.starting => (
        'Starting the service',
        'The secrets service is starting…',
        true,
      ),
      TomSecretsConnectionPhase.noService => (
        'The service is not running',
        'The secrets service holds the unlocked secrets and answers the '
            'programs on this machine. Start it to unlock.',
        false,
      ),
      TomSecretsConnectionPhase.dropped => (
        'Service stopped',
        'The connection to the secrets service ended: it was stopped or it '
            'died. Start it again to go on.',
        false,
      ),
      TomSecretsConnectionPhase.cannotStart => (
        'The service cannot be started',
        c.message ?? '',
        false,
      ),
      TomSecretsConnectionPhase.startFailed => (
        'The service did not start',
        c.message ?? '',
        false,
      ),
      _ => ('', '', false),
    };
    return TomSecretsGateCard(
      title: title,
      icon: Icons.dns_outlined,
      children: [
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        if (busy)
          const Center(child: CircularProgressIndicator())
        else ...[
          if (c.phase != TomSecretsConnectionPhase.cannotStart)
            FilledButton(
              key: const Key('tsm-start-service'),
              onPressed: () => unawaited(c.startService()),
              child: const Text('Start the service'),
            ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('tsm-retry'),
            onPressed: () => unawaited(c.connect()),
            child: const Text('Look again'),
          ),
        ],
      ],
    );
  }
}

/// Taking over a service this app holds no key for (DP-16).
class TomSecretsClaimScreen extends StatefulWidget {
  /// The screen; [keyFiles] picks a key file.
  const TomSecretsClaimScreen({super.key, this.keyFiles});

  /// The host's key-file picker.
  final TomKeyFilePicker? keyFiles;

  @override
  State<TomSecretsClaimScreen> createState() => _ClaimScreenState();
}

class _ClaimScreenState extends State<TomSecretsClaimScreen> {
  final TomKeyStepController _key = TomKeyStepController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _key.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  Future<void> _claim() async {
    final material = _key.material;
    final password = material.passphrase;
    if (password == null) return;
    setState(() => _busy = true);
    try {
      await context.read<TomSecretsServiceConnection>().claim(
        password,
        keyFile: material.keyFileBytes,
      );
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TomSecretsGateCard(
    title: 'Take over the service',
    icon: Icons.admin_panel_settings_outlined,
    children: [
      const Text(
        'A secrets service runs that this app holds no key for: it was '
        'started from the command line (tsm), or another admin took it over. '
        'Taking it over sends your master password to the process that '
        'answers as the service; the app cannot check beforehand that it is '
        'the real one. Take it over only on a machine you trust.',
        key: Key('tsm-claim-warning'),
      ),
      const SizedBox(height: 16),
      TomKeyFields(
        controller: _key,
        keyPrefix: 'tsm-claim',
        keyFiles: widget.keyFiles,
        pickerContext: context,
        offersRemember: false,
        autofocus: true,
        onSubmitted: _claim,
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(
          _error!,
          key: const Key('tsm-claim-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('tsm-claim'),
        onPressed: _busy || _key.material.passphrase == null ? null : _claim,
        child: const Text('Take over'),
      ),
    ],
  );
}

/// The Unlock screen: the master password and the key file (BP-8: each file
/// with a password of its own is opened afterwards, on the vault browser).
class TomSecretsUnlockScreen extends StatefulWidget {
  /// The screen; [keyFiles] picks a key file.
  const TomSecretsUnlockScreen({super.key, this.keyFiles});

  /// The host's key-file picker.
  final TomKeyFilePicker? keyFiles;

  @override
  State<TomSecretsUnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<TomSecretsUnlockScreen> {
  final TomKeyStepController _key = TomKeyStepController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _key.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  Future<void> _unlock() async {
    final material = _key.material;
    final password = material.passphrase;
    if (password == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<TomSecretsServiceConnection>().unlock(
        password,
        keyFile: material.keyFileBytes,
      );
      _key.passphrase.clear();
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    return TomSecretsGateCard(
      title: 'Unlock',
      children: [
        if (c.unlockNeeded)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'A program on this machine waits for the unlock.',
              key: Key('tsm-unlock-needed'),
              textAlign: TextAlign.center,
            ),
          ),
        TomKeyFields(
          controller: _key,
          keyPrefix: 'tsm-unlock',
          keyFiles: widget.keyFiles,
          pickerContext: context,
          offersRemember: false,
          autofocus: true,
          onSubmitted: _unlock,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const Key('tsm-unlock-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('tsm-unlock'),
          onPressed: _busy || _key.material.passphrase == null ? null : _unlock,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Unlock'),
        ),
      ],
    );
  }
}

/// Asks for the password (and key file) of [store], a file with a password
/// of its own (BP-8), and opens it.
Future<void> tomSecretsUnlockStoreDialog(
  BuildContext context,
  String store, {
  TomKeyFilePicker? keyFiles,
}) => showDialog<void>(
  context: context,
  builder: (_) => _UnlockStoreDialog(
    store: store,
    keyFiles: keyFiles,
    connection: context.read<TomSecretsServiceConnection>(),
    pickerContext: context,
  ),
);

class _UnlockStoreDialog extends StatefulWidget {
  const _UnlockStoreDialog({
    required this.store,
    required this.keyFiles,
    required this.connection,
    required this.pickerContext,
  });

  final String store;
  final TomKeyFilePicker? keyFiles;
  final TomSecretsServiceConnection connection;
  final BuildContext pickerContext;

  @override
  State<_UnlockStoreDialog> createState() => _UnlockStoreDialogState();
}

class _UnlockStoreDialogState extends State<_UnlockStoreDialog> {
  final TomKeyStepController _key = TomKeyStepController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _key.addListener(() => setState(() {}));
  }

  Future<void> _open() async {
    final material = _key.material;
    final password = material.passphrase;
    if (password == null) return;
    try {
      await widget.connection.unlockStore(
        widget.store,
        password,
        keyFile: material.keyFileBytes,
      );
      if (mounted) Navigator.of(context).pop();
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Open ${widget.store}'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${widget.store} has a password of its own.'),
          const SizedBox(height: 12),
          TomKeyFields(
            controller: _key,
            keyPrefix: 'tsm-store',
            keyFiles: widget.keyFiles,
            pickerContext: widget.pickerContext,
            offersRemember: false,
            autofocus: true,
            onSubmitted: _open,
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _key.material.passphrase == null ? null : _open,
        child: const Text('Open'),
      ),
    ],
  );
}

/// An admin error as the user reads it: never a value.
String tomSecretsDescribeAdminError(TomSecretsAdminException e) => switch ((
  e.kind,
  e.details['reason'],
)) {
  ('denied', 'bad_password') => 'Wrong master password or key file.',
  ('denied', 'wrong_executable') =>
    'The service accepts no admin from this app here: it must be '
        'installed beside the service, or named in its bootstrap.',
  ('denied', 'history_rewritten') =>
    'The vault\'s branch on GitHub was rewritten. Choose on the vault how to '
        'go on: take the file on GitHub, or merge this copy over it.',
  ('denied', 'stale_base') =>
    'The vault changed meanwhile; it was read again. Make the change once '
        'more.',
  ('offline', _) || ('token_expired', _) =>
    'The vault is served from its offline copy: '
        '${e.kind == 'offline' ? 'GitHub is not reachable' : 'the GitHub token expired'}. '
        'The change could not be written.',
  ('not_running', _) => 'The service is not running.',
  (final kind, final reason?) => '$kind ($reason): ${e.message}',
  (final kind, _) => '$kind: ${e.message}',
};

/// The host's preferences, for widgets below the root.
TomSecretsPreferences tomSecretsPreferencesOf(BuildContext context) =>
    context.read<TomSecretsHost>().preferences;
