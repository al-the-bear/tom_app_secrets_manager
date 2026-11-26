// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// What the app shows before the vaults: attaching to the service, starting
/// it, claiming it, and the Unlock screen (part-app, "How it works with the
/// service" and Screens › Unlock).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_credentials_ui/tom_credentials_ui.dart';
import 'package:tom_secrets_client/admin.dart'
    show
        TomSecretsAdminException,
        tomSecretsKeyChangedAdvice,
        tomSecretsUntrustedAdvice;

import '../ports/desktop_ports.dart';
import '../state/os_unlock.dart';
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

/// [text] ending as a sentence, its first letter a capital.
String _sentence(String text) {
  if (text.isEmpty) return text;
  final t = '${text[0].toUpperCase()}${text.substring(1)}';
  return RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
}

/// Attaching, no service, starting, a start that failed, a dropped
/// connection, an endpoint that is not this user's service.
class TomSecretsConnectionScreen extends StatelessWidget {
  /// The screen.
  const TomSecretsConnectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final unpinned =
        c.phase == TomSecretsConnectionPhase.untrusted &&
        c.untrustedReason == 'unpinned' &&
        c.untrustedWords != null &&
        c.canTrustService;
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
      // A service this app has not met: its words, to compare.
      TomSecretsConnectionPhase.untrusted when unpinned => (
        'Is this your secrets service?',
        'A secrets service runs on this machine that this app did not '
            'start and has not met before. Its identity is:',
        false,
      ),
      // What is wrong, then what to do; never a password field.
      TomSecretsConnectionPhase.untrusted => (
        'This is not your secrets service',
        '${_sentence(c.message ?? '')}\n\n'
            '${tomSecretsUntrustedAdvice(c.untrustedReason)}\n\n'
            'Nothing was sent to it.',
        false,
      ),
      TomSecretsConnectionPhase.keyChanged => (
        'The service\'s identity changed',
        'This app pinned the identity '
            '${c.changedKey.pinned ?? '(unknown)'} for the secrets service '
            'on this machine; what answers now presents '
            '${c.changedKey.presented ?? 'another one'}.\n\n'
            '$tomSecretsKeyChangedAdvice',
        false,
      ),
      _ => ('', '', false),
    };
    final refused =
        c.phase == TomSecretsConnectionPhase.untrusted ||
        c.phase == TomSecretsConnectionPhase.keyChanged;
    final startable =
        c.phase != TomSecretsConnectionPhase.cannotStart && !refused;
    return TomSecretsGateCard(
      title: title,
      icon: unpinned
          ? Icons.fingerprint
          : refused
          ? Icons.gpp_bad_outlined
          : Icons.dns_outlined,
      children: [
        Text(
          text,
          key: const Key('tsm-service-gate-text'),
          textAlign: TextAlign.center,
        ),
        if (unpinned) ...[
          const SizedBox(height: 12),
          SelectableText(
            c.untrustedWords!,
            key: const Key('tsm-service-words'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          const Text(
            'Compare these words with the ones another of your devices '
            'shows for this machine (Pairing, the device list), or with '
            'what `tsm status` showed here. Trust it only when they are '
            'the same: from then on this app talks to this service alone. '
            'Nothing was sent to it yet.',
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 20),
        if (busy)
          const Center(child: CircularProgressIndicator())
        else ...[
          if (unpinned)
            FilledButton(
              key: const Key('tsm-trust-service'),
              onPressed: () => unawaited(c.trustService()),
              child: const Text('The words are the same: trust it'),
            ),
          if (c.phase == TomSecretsConnectionPhase.keyChanged &&
              c.canTrustService)
            OutlinedButton(
              key: const Key('tsm-forget-pin'),
              onPressed: () => unawaited(c.forgetServicePin()),
              child: const Text(
                'I set this service up anew: compare the new identity',
              ),
            ),
          if (startable)
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
  final TextEditingController _pin = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _remember = false;

  /// "Use the master password" while a PIN would unlock.
  bool _usePassword = false;

  /// "Use a PIN next time".
  bool _pinNext = false;

  @override
  void initState() {
    super.initState();
    _key.addListener(_rebuild);
    // A kept unlock (lock mode (c), a saved master password) is tried at
    // once: the OS prompt, then the vaults open (part-os-unlock).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final os = context.read<TomSecretsOsUnlock>();
      await os.refresh();
      if (mounted && os.offered && os.usable != null) await _osUnlock();
    });
  }

  void _rebuild() => setState(() {});

  Future<void> _osUnlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<TomSecretsOsUnlock>().unlock();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlock() async {
    final material = _key.material;
    final password = material.passphrase;
    if (password == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final os = context.read<TomSecretsOsUnlock>();
      final c = context.read<TomSecretsServiceConnection>();
      // Asked before the unlock: the gate shows the PIN step at once.
      if (_pinNext) c.askPin(TomSecretsPinStep.choose);
      try {
        await c.unlock(password, keyFile: material.keyFileBytes);
      } on Object {
        c.askPin(null);
        rethrow;
      }
      _key.passphrase.clear();
      // The biometric after a lock (the quick unlock's token) or
      // "remember" (the bundle) goes into the gated store.
      await os.keep(remember: _remember);
      // After a restart the PIN is typed once more: no PIN is kept.
      if (!_pinNext && c.quickUnlock.pinToRearm) {
        c.askPin(TomSecretsPinStep.rearm);
      }
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockWithPin() async {
    final pin = _pin.text;
    if (pin.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final c = context.read<TomSecretsServiceConnection>();
    try {
      await c.unlockWithPin(pin);
      _pin.clear();
    } on TomSecretsAdminException catch (e) {
      _pin.clear();
      if (mounted) {
        setState(() {
          _error = tomSecretsDescribeAdminError(e);
          // Nothing left for the PIN to open: the master password.
          if (e.details['reason'] != 'bad_pin') _usePassword = true;
        });
      }
      unawaited(c.refreshStatus().catchError((Object _) {}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final os = context.watch<TomSecretsOsUnlock>();
    final kept = os.offered && os.usable != null;
    final quick = c.quickUnlock;
    final withPin = quick.pinArmed && !_usePassword;
    if (withPin) return _pinCard(c, os, kept);
    return TomSecretsGateCard(
      title: 'Unlock',
      children: [
        if (kept) ...[
          FilledButton.icon(
            key: const Key('tsm-unlock-os'),
            onPressed: _busy ? null : _osUnlock,
            icon: const Icon(Icons.fingerprint_rounded),
            label: Text('Unlock with ${os.label}'),
          ),
          const SizedBox(height: 12),
          const Text(
            'or with the master password:',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
        ],
        if (os.message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              os.message!,
              key: const Key('tsm-unlock-os-message'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
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
          autofocus: !kept,
          onSubmitted: _unlock,
        ),
        if (!quick.pinOn)
          CheckboxListTile(
            key: const Key('tsm-unlock-pin-next'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _pinNext,
            onChanged: (v) => setState(() => _pinNext = v ?? false),
            title: const Text('Use a PIN next time'),
            subtitle: const Text(
              'After this unlock: a PIN undoes the next idle or screen lock.',
            ),
          ),
        if (os.offered && os.offersQuick)
          CheckboxListTile(
            key: const Key('tsm-unlock-biometric'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: os.quickOn,
            onChanged: (v) => unawaited(os.chooseQuick(v ?? false)),
            title: Text('Unlock with ${os.label} after a lock'),
            subtitle: const Text(
              'Until the service restarts; nothing of the master password is '
              'kept for it.',
            ),
          ),
        if (os.offered && !os.saved)
          CheckboxListTile(
            key: const Key('tsm-unlock-remember'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _remember,
            onChanged: (v) => setState(() => _remember = v ?? false),
            title: Text('Remember the master password with ${os.label}'),
            subtitle: Text(
              '${tomSecretsRememberWarning(os.label)}'
              '${os.gateOnly ? ' The weaker, gate-only form here (see Settings).' : ''}',
              key: const Key('tsm-unlock-remember-warning'),
            ),
          ),
        if (quick.pinArmed)
          TextButton(
            key: const Key('tsm-unlock-use-pin'),
            onPressed: _busy
                ? null
                : () => setState(() => _usePassword = false),
            child: const Text('Use the PIN'),
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
        ?context.read<TomSecretsHost>().unlockFooter?.call(context),
      ],
    );
  }

  /// The quick unlock: the biometric, the PIN, or "Use the master
  /// password".
  Widget _pinCard(
    TomSecretsServiceConnection c,
    TomSecretsOsUnlock os,
    bool kept,
  ) {
    final quick = c.quickUnlock;
    return TomSecretsGateCard(
      title: 'Unlock',
      children: [
        if (kept) ...[
          FilledButton.icon(
            key: const Key('tsm-unlock-os'),
            onPressed: _busy ? null : _osUnlock,
            icon: const Icon(Icons.fingerprint_rounded),
            label: Text('Unlock with ${os.label}'),
          ),
          const SizedBox(height: 12),
          const Text('or with the PIN:', textAlign: TextAlign.center),
          const SizedBox(height: 8),
        ],
        if (os.message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              os.message!,
              key: const Key('tsm-unlock-os-message'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (c.unlockNeeded)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'A program on this machine waits for the unlock.',
              key: Key('tsm-unlock-needed'),
              textAlign: TextAlign.center,
            ),
          ),
        TextField(
          key: const Key('tsm-unlock-pin'),
          controller: _pin,
          obscureText: true,
          autofocus: !kept,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'PIN'),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => unawaited(_unlockWithPin()),
        ),
        if (quick.attemptsLeft < 5)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${quick.attemptsLeft} attempts left before the master password '
              'is needed.',
              key: const Key('tsm-unlock-pin-attempts'),
            ),
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
          key: const Key('tsm-unlock-with-pin'),
          onPressed: _busy || _pin.text.isEmpty
              ? null
              : () => unawaited(_unlockWithPin()),
          child: const Text('Unlock'),
        ),
        TextButton(
          key: const Key('tsm-unlock-use-password'),
          onPressed: _busy
              ? null
              : () => setState(() {
                  _usePassword = true;
                  _error = null;
                }),
          child: const Text('Use the master password'),
        ),
        ?context.read<TomSecretsHost>().unlockFooter?.call(context),
      ],
    );
  }
}

/// What "Remember the master password" costs (BP-37), on its checkbox and
/// its switch in Settings.
String tomSecretsRememberWarning(String label) =>
    'It unlocks after a restart without the master password, which skips '
    'the one master-password unlock after a restart that keeps the password '
    'in your memory: you may forget it. On this machine only; $label also '
    'opens the vault when the password is forgotten.';

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
  ('denied', 'bad_pin') =>
    'Wrong PIN: ${e.details['attemptsLeft'] ?? 'few'} attempts left before '
        'the master password is needed.',
  ('denied', 'pin_wiped') =>
    'Too many wrong PINs: type the master password. The PIN works again '
        'after it.',
  ('denied', 'quick_expired') =>
    'The quick unlock ended (7 days after the master password): type the '
        'master password.',
  ('denied', 'no_quick_unlock') =>
    'The PIN does not unlock now (the service restarted, or you locked '
        'completely): type the master password.',
  ('denied', 'rekeyed') => 'The master password changed: type the new one.',
  ('malformed', 'pin') => e.message,
  ('denied', 'password_first') => 'Unlock with the master password first.',
  ('denied', 'wrong_executable') =>
    'The service accepts no admin from this app here: it must be '
        'installed beside the service, or named in its bootstrap.',
  ('denied', 'history_rewritten') =>
    'The vault\'s branch on GitHub was rewritten. Choose on the vault how to '
        'go on: take the file on GitHub, or merge this copy over it.',
  ('denied', 'stale_base') =>
    'The vault changed meanwhile; it was read again. Make the change once '
        'more.',
  // Where there is no copy to serve (the mobile app holds none): the
  // refusal says what to do itself.
  ('offline', 'no_copy') || ('token_expired', 'no_copy') => e.message,
  ('offline', _) || ('token_expired', _) =>
    'The vault is served from the copy held: '
        '${e.kind == 'offline' ? 'GitHub is not reachable' : 'the GitHub token expired'}. '
        'The change could not be written.',
  ('denied', 'token_refused') =>
    'GitHub refused the token: it may be mistyped, expired or revoked.',
  ('denied', 'token_no_access') =>
    'The token does not see the repository: under Repository access, '
        'select it.',
  ('denied', 'token_read_only') =>
    'The token may read the repository but not write to it: give it '
        'Contents: Read and write.',
  ('not_running', _) => 'The service is not running.',
  (final kind, final reason?) => '$kind ($reason): ${e.message}',
  (final kind, _) => '$kind: ${e.message}',
};

/// The host's preferences, for widgets below the root.
TomSecretsPreferences tomSecretsPreferencesOf(BuildContext context) =>
    context.read<TomSecretsHost>().preferences;
