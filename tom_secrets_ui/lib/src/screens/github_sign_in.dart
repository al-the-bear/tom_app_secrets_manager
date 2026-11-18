// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// "Sign in with GitHub" (part-key-rotation §3, DP-83, DP-155), on the Keys
/// screen: where this device's GitHub App sign-in stands (`github.app`),
/// naming the App once (its client id, kept in the primary vault so every
/// device learns it), the device flow's code with the page to enter it on,
/// signing out, and the choice of a pasted token instead, with what each
/// means for cutting off a lost device. The service owns and renews the
/// tokens; the app never sees one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../ports/desktop_ports.dart';
import '../state/service_connection.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// GitHub's page for registering a new GitHub App.
final Uri tomSecretsNewGitHubAppUrl = Uri.parse(
  'https://github.com/settings/apps/new',
);

/// The section of the Keys screen.
class TomSecretsGitHubSignInSection extends StatefulWidget {
  /// The section.
  const TomSecretsGitHubSignInSection({super.key});

  @override
  State<TomSecretsGitHubSignInSection> createState() => _SignInState();
}

class _SignInState extends State<TomSecretsGitHubSignInSection> {
  Map<String, Object?>? _app;
  Map<String, Object?>? _code;
  String? _message;
  String? _error;
  bool _busy = false;
  final _clientId = TextEditingController();
  StreamSubscription<Map<String, Object?>>? _events;

  TomSecretsServiceConnection get _c =>
      context.read<TomSecretsServiceConnection>();

  @override
  void initState() {
    super.initState();
    _events = _c.events.listen((e) {
      if (e['op'] != 'github_sign_in') return;
      final outcome = e['outcome'];
      setState(() {
        _code = null;
        _message = switch (outcome) {
          'signed_in' =>
            e['login'] == null ? 'Signed in.' : 'Signed in as ${e['login']}.',
          'signed_out' => 'Signed out; the pasted tokens are used again.',
          'denied' => 'The code was refused on GitHub.',
          'expired' => 'The code ran out before it was entered.',
          'device_flow_disabled' =>
            'The App has the device flow switched off: switch on "Enable '
                'Device Flow" in its settings on GitHub.',
          'bad_client_id' => 'GitHub does not know this client id.',
          _ => 'The sign-in did not finish.',
        };
      });
      unawaited(_load());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    _clientId.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final app = await _c.request('github.app');
      if (mounted) setState(() => _app = app);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Uri url) async {
    final open = context.read<TomSecretsHost>().openUrl;
    if (open == null || !await open(url)) {
      await Clipboard.setData(ClipboardData(text: '$url'));
      if (mounted) {
        setState(() => _message = 'The page\'s address is on the clipboard.');
      }
    }
  }

  Future<void> _configure() => _run(() async {
    await _c.request('github.app.configure', {
      'clientId': _clientId.text.trim(),
    });
    _clientId.clear();
    await _load();
  });

  Future<void> _signIn() => _run(() async {
    final code = await _c.request('github.signIn');
    if (!mounted) return;
    setState(() {
      _code = code;
      _message = null;
    });
    await Clipboard.setData(ClipboardData(text: '${code['userCode']}'));
    await _open(Uri.parse('${code['verificationUri']}'));
  });

  Future<void> _signOut() => _run(() async {
    await _c.request('github.signOut');
    await _load();
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = _app;
    final state = app?['state'] as String?;
    final small = theme.textTheme.bodySmall;
    String? date(Object? iso) => iso is String ? iso.substring(0, 10) : null;
    return TomSecretsSection(
      key: const Key('tsm-github-sign-in'),
      title: 'GitHub sign-in (this machine)',
      icon: Icons.login_rounded,
      children: [
        if (app == null && _error == null)
          const LinearProgressIndicator()
        else if (state == 'not_configured') ...[
          Text(
            'Register the GitHub App for your vault repositories once: on '
            'GitHub, a new GitHub App with "Repository permissions › '
            'Contents: Read and write", "Enable Device Flow" switched on and '
            'no webhook, installed on the vault repositories only. Then '
            'enter its client id here; it is kept in the primary vault, so '
            'every device learns it.',
            style: small,
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('tsm-github-client-id'),
                  controller: _clientId,
                  decoration: const InputDecoration(
                    labelText: 'The App\'s client id (Iv23…)',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => unawaited(_open(tomSecretsNewGitHubAppUrl)),
                child: const Text('Register on GitHub…'),
              ),
              FilledButton(
                key: const Key('tsm-github-configure'),
                onPressed: _busy ? null : () => unawaited(_configure()),
                child: const Text('Save'),
              ),
            ],
          ),
        ] else ...[
          Text(switch (state) {
            'signed_in' =>
              'Signed in with the GitHub App'
                  '${app?['login'] == null ? '' : ' as ${app!['login']}'}. '
                  'The service renews the tokens itself; unused for six '
                  'months (until ${date(app?['refreshExpiresAt']) ?? '?'}) '
                  'the device signs in again.',
            'sign_in_again' =>
              'GitHub no longer accepts this device\'s sign-in (unused '
                  'for six months, or the App\'s authorization was '
                  'revoked): sign in again.',
            'pending' => 'Waiting for the code to be entered on GitHub…',
            _ =>
              'Not signed in: this machine reaches GitHub with the '
                  'tokens pasted for the vault repositories.',
          }, key: const Key('tsm-github-state')),
          if (_code case final code?)
            Card(
              key: const Key('tsm-github-code'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Enter this code on GitHub:', style: small),
                    SelectableText(
                      '${code['userCode']}',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      'at ${code['verificationUri']} (the code is on the '
                      'clipboard; the page opened, or open it on any '
                      'device).',
                      style: small,
                    ),
                  ],
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (state != 'signed_in')
                FilledButton.icon(
                  key: const Key('tsm-github-sign-in-button'),
                  icon: const Icon(Icons.login_rounded),
                  label: Text(
                    state == 'sign_in_again'
                        ? 'Sign in again'
                        : 'Sign in with GitHub',
                  ),
                  onPressed: _busy ? null : () => unawaited(_signIn()),
                ),
              if (state == 'signed_in' || state == 'sign_in_again')
                OutlinedButton(
                  key: const Key('tsm-github-sign-out'),
                  onPressed: _busy ? null : () => unawaited(_signOut()),
                  child: const Text('Use a personal access token instead'),
                ),
            ],
          ),
          Text(
            'A signed-in device is cut off by revoking the App\'s '
            'authorization on GitHub, which signs out every device. A '
            'pasted token is the way to cut off this one device alone: '
            'keep one where that matters (a headless machine).',
            style: small,
          ),
        ],
        if (_message != null)
          Text(_message!, key: const Key('tsm-github-message')),
        if (_error != null)
          Text(
            _error!,
            key: const Key('tsm-github-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }
}
