// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The relay settings on the Sharing screen (part-relay): the relays
/// this device knows in order of preference, each with the services it
/// offers, added by their id (`github:<owner>/<repo>`, `tsm:<url>`,
/// `wormhole:<url>`), moved, removed; the default relay for pairing; a
/// relay server's instance token, kept in the keychain through the service
/// (the approval link through the relay needs it in token mode). A shared
/// vault's mailbox relay is chosen in its row of Shared vaults.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/relay_settings.dart';
import '../state/service_connection.dart';
import '../widgets/style.dart';

/// The Relays section.
class TomSecretsRelaysSection extends StatefulWidget {
  /// The section.
  const TomSecretsRelaysSection({super.key});

  @override
  State<TomSecretsRelaysSection> createState() => _RelaysState();
}

class _RelaysState extends State<TomSecretsRelaysSection> {
  late final TomSecretsRelaySettings _settings;
  final _add = TextEditingController();
  String? _error;
  Map<TomSecretsRelayId, bool> _tokens = const {};

  @override
  void initState() {
    super.initState();
    _settings = TomSecretsRelaySettings(
      context.read<TomSecretsHost>().preferences,
    )..addListener(_changed);
    unawaited(_loadTokens());
  }

  void _changed() {
    if (mounted) setState(() {});
    unawaited(_loadTokens());
  }

  /// Which relay servers have an instance token kept.
  Future<void> _loadTokens() async {
    final servers = [
      for (final r in _settings.relays)
        if (r.kind == TomSecretsRelayKind.server) r,
    ];
    try {
      final kept = await tomSecretsRelayTokensKept(
        context.read<TomSecretsServiceConnection>(),
        servers,
      );
      if (mounted) setState(() => _tokens = kept);
    } on Object {
      // The service is not reachable now; the rows say nothing of tokens.
    }
  }

  Future<void> _editToken(TomSecretsRelayId relay) async {
    final kept = _tokens[relay] ?? false;
    final token = await showDialog<String>(
      context: context,
      builder: (context) => _TokenDialog(relay: relay, kept: kept),
    );
    if (token == null || !mounted) return;
    if (token.isEmpty && !kept) return;
    try {
      await tomSecretsKeepRelayToken(
        context.read<TomSecretsServiceConnection>(),
        relay,
        token,
      );
      setState(() => _error = null);
    } on TomSecretsAdminException catch (e) {
      setState(() => _error = 'The token was not kept: ${e.message}');
    }
    await _loadTokens();
  }

  @override
  void dispose() {
    _settings.removeListener(_changed);
    _add.dispose();
    super.dispose();
  }

  Future<void> _addRelay() async {
    setState(() => _error = null);
    try {
      await _settings.add(_add.text);
      _add.clear();
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on StateError catch (e) {
      setState(() => _error = e.message);
    }
  }

  static String _service(TomSecretsRelayService s) => switch (s) {
    TomSecretsRelayService.pairing => 'pairing',
    TomSecretsRelayService.mailbox => 'mailbox',
    TomSecretsRelayService.link => 'approval link',
  };

  static String _kind(TomSecretsRelayKind k) => switch (k) {
    TomSecretsRelayKind.github =>
      'a GitHub repository: pairing with a machine that reaches it with its '
          'own token; the mailbox of a shared vault in it',
    TomSecretsRelayKind.server =>
      'a relay server (tom_secrets_relay): pairing with any machine that '
          'reaches it, and the approval link when neither the network nor '
          'the VPN connects two paired machines',
    TomSecretsRelayKind.wormhole =>
      'a magic-wormhole server: not usable in this version',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final relays = _settings.relays;
    final pairing = _settings.pairingRelay;
    return TomSecretsSection(
      key: const Key('tsm-relays'),
      title: 'Relays',
      icon: Icons.hub_rounded,
      children: [
        Text(
          'A relay carries a pairing, or a share, where two machines do not '
          'reach each other over the network or the VPN. It sees only '
          'encrypted bytes and is not trusted: a tampered pairing fails. '
          'Pairing tries the network and the VPN first; when a relay fails '
          'the app says so and never switches to another by itself.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (relays.isEmpty)
          Text('No relays yet.', style: theme.textTheme.bodySmall),
        for (final (i, r) in relays.indexed)
          ListTile(
            key: Key('tsm-relay-${r.text}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              r.kind == TomSecretsRelayKind.github
                  ? Icons.cloud_outlined
                  : Icons.dns_outlined,
            ),
            title: Text(r.text),
            subtitle: Text(
              '${r.services.map(_service).join(', ')} · ${_kind(r.kind)}'
              '${r == pairing ? ' · the default for pairing' : ''}'
              '${r.kind != TomSecretsRelayKind.server
                  ? ''
                  : _tokens[r] == true
                  ? ' · instance token kept'
                  : ' · no instance token'}',
            ),
            trailing: Wrap(
              children: [
                if (r.kind == TomSecretsRelayKind.server)
                  IconButton(
                    key: Key('tsm-relay-token-${r.text}'),
                    tooltip: 'Instance token',
                    icon: Icon(
                      _tokens[r] == true
                          ? Icons.key_rounded
                          : Icons.key_off_rounded,
                    ),
                    onPressed: () => unawaited(_editToken(r)),
                  ),
                if (r.services.contains(TomSecretsRelayService.pairing) &&
                    r != pairing)
                  IconButton(
                    key: Key('tsm-relay-default-${r.text}'),
                    tooltip: 'The default for pairing',
                    icon: const Icon(Icons.star_border_rounded),
                    onPressed: () => unawaited(_settings.setPairingRelay(r)),
                  ),
                if (r == pairing)
                  IconButton(
                    key: Key('tsm-relay-undefault-${r.text}'),
                    tooltip: 'No default relay for pairing',
                    icon: const Icon(Icons.star_rounded),
                    onPressed: () => unawaited(_settings.setPairingRelay(null)),
                  ),
                IconButton(
                  tooltip: 'Up',
                  icon: const Icon(Icons.arrow_upward_rounded),
                  onPressed: i == 0
                      ? null
                      : () => unawaited(_settings.move(r, -1)),
                ),
                IconButton(
                  tooltip: 'Down',
                  icon: const Icon(Icons.arrow_downward_rounded),
                  onPressed: i == relays.length - 1
                      ? null
                      : () => unawaited(_settings.move(r, 1)),
                ),
                IconButton(
                  key: Key('tsm-relay-remove-${r.text}'),
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => unawaited(_settings.remove(r)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('tsm-relay-add-text'),
                controller: _add,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'A relay: github:owner/repo, tsm:https://…',
                ),
                onSubmitted: (_) => unawaited(_addRelay()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('tsm-relay-add'),
              onPressed: () => unawaited(_addRelay()),
              child: const Text('Add'),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _error!,
              key: const Key('tsm-relay-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

/// The instance token's dialog; it owns its text field's controller, so the
/// field outlives the dialog's closing animation. Answers the token, ''
/// to remove it, or null.
class _TokenDialog extends StatefulWidget {
  const _TokenDialog({required this.relay, required this.kept});

  final TomSecretsRelayId relay;
  final bool kept;

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Instance token of ${widget.relay.text}'),
    content: SizedBox(
      width: 420,
      child: TextField(
        key: const Key('tsm-relay-token-text'),
        controller: _text,
        obscureText: true,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'The token the relay\'s operator gave your team',
          helperText:
              'Kept in this machine\'s keychain; the approval link through '
              'this relay needs it when the relay runs in token mode.',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      if (widget.kept)
        TextButton(
          key: const Key('tsm-relay-token-remove'),
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Remove the token'),
        ),
      FilledButton(
        key: const Key('tsm-relay-token-keep'),
        onPressed: () => Navigator.pop(context, _text.text.trim()),
        child: const Text('Keep'),
      ),
    ],
  );
}
