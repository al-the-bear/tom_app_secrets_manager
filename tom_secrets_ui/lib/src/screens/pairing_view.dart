// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Pairing screen (part-sharing, part-app): the giving side of a
/// pairing — the window with its code, addresses and countdown; the bundle
/// chosen once the other device proved the code; the result — and the
/// paired devices with Revoke. Leaving the screen, or the app locking (the
/// shell goes), closes the window and aborts a pairing in progress.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/pairing_model.dart';
import '../state/service_connection.dart';
import '../state/session_state.dart';
import '../widgets/qr_code.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// Opens the Pairing screen on its own page: the First run wizard's offer
/// to pair another desktop (`TomSecretsFirstRunActions.pair`).
Future<void> tomSecretsShowPairing(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Pairing')),
          body: const TomSecretsPairingView(),
        ),
      ),
    );

/// The Pairing screen.
class TomSecretsPairingView extends StatefulWidget {
  /// The screen.
  const TomSecretsPairingView({super.key});

  @override
  State<TomSecretsPairingView> createState() => _PairingState();
}

class _PairingState extends State<TomSecretsPairingView> {
  late final TomSecretsPairingModel _model;
  String? _error;

  @override
  void initState() {
    super.initState();
    final host = context.read<TomSecretsHost>();
    _model = TomSecretsPairingModel(
      context.read<TomSecretsServiceConnection>(),
      addresses: host.pairingAddresses,
      allowLoopback: host.pairingAllowsLoopback,
      discovery: host.pairingDiscovery,
    )..addListener(_changed);
    unawaited(_loadDevices());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDevices() async {
    try {
      await _model.loadDevices();
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }

  Future<void> _open() async {
    setState(() => _error = null);
    _model.configYaml = null;
    try {
      final config = context.read<TomSecretsSession>().sharedConfigYaml;
      await _model.open();
      _model.configYaml = config;
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = 'The pairing window cannot open: $e');
      }
    }
  }

  @override
  void dispose() {
    _model
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('tsm-pairing'),
    padding: const EdgeInsets.all(12),
    children: [
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 820,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_pairSection(context), _devicesSection(context)],
          ),
        ),
      ),
    ],
  );

  Widget _pairSection(BuildContext context) {
    final theme = Theme.of(context);
    final m = _model;
    return TomSecretsSection(
      title: 'Pair a device',
      icon: Icons.devices_other_rounded,
      children: [
        Text(
          'Brings another of your machines into your fleet: it gets the '
          'vaults you choose with their keys, and the two approve for each '
          'other. The other machine connects over the same network or the '
          'VPN and types the code; you then choose what it gets.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (m.stage == TomSecretsPairingStage.idle ||
            m.stage == TomSecretsPairingStage.paired ||
            m.stage == TomSecretsPairingStage.failed)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('tsm-pair-open'),
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Pair a device'),
              onPressed: () => unawaited(_open()),
            ),
          ),
        if (m.stage == TomSecretsPairingStage.waiting) _waiting(context),
        if (m.stage == TomSecretsPairingStage.choosing) _choosing(context),
        if (m.stage == TomSecretsPairingStage.sending)
          const Padding(padding: EdgeInsets.all(8), child: Text('Sending…')),
        if (m.message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              m.message!,
              key: const Key('tsm-pair-message'),
              style: TextStyle(
                color: m.stage == TomSecretsPairingStage.failed
                    ? theme.colorScheme.error
                    : null,
              ),
            ),
          ),
        if (_error != null)
          Text(
            _error!,
            key: const Key('tsm-pair-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }

  Widget _waiting(BuildContext context) {
    final theme = Theme.of(context);
    final m = _model;
    final left = m.remaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'On the other machine, type this code:',
          style: theme.textTheme.bodyMedium,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SelectableText(
            m.code!.text,
            key: const Key('tsm-pair-code'),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          'and connect to ${m.listening.join(' or ')}.',
          key: const Key('tsm-pair-addresses'),
        ),
        if (m.invitation case final invitation?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TomSecretsQrCode(
                  key: const Key('tsm-pair-qr'),
                  data: invitation.text,
                  size: 180,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'A phone or tablet scans this code instead: its setup '
                    'screen › "Scan the desktop\'s code". It holds the '
                    'addresses and the code.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        if (m.announced)
          Text(
            'Announced on this network: on the same network the other '
            'machine finds this one by the code alone. Over the VPN it '
            'needs the address.',
            key: const Key('tsm-pair-announced'),
            style: theme.textTheme.bodySmall,
          ),
        Text(
          'Open for ${left.inMinutes}:'
          '${(left.inSeconds % 60).toString().padLeft(2, '0')} more; the '
          'code works once.',
          key: const Key('tsm-pair-countdown'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          'macOS and Windows Defender Firewall ask once whether this app may '
          'accept connections: allow it, or the other machine cannot reach '
          'this one.',
          style: theme.textTheme.bodySmall,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('tsm-pair-cancel'),
            onPressed: () => unawaited(_model.close()),
            child: const Text('Close the pairing window'),
          ),
        ),
      ],
    );
  }

  Widget _choosing(BuildContext context) {
    final theme = Theme.of(context);
    final m = _model;
    return Column(
      key: const Key('tsm-pair-choosing'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${m.receiver} proved the code. Choose what it gets:',
          key: const Key('tsm-pair-receiver'),
          style: theme.textTheme.titleSmall,
        ),
        for (final c in m.choices)
          CheckboxListTile(
            key: Key('tsm-pair-vault-${c.vault.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: c.chosen,
            onChanged: (v) => m.toggle(c, v ?? false),
            title: Text(
              c.vault.primary ? '${c.vault.name} (primary)' : c.vault.name,
            ),
            subtitle: Text(
              [
                c.vault.locator,
                if (c.vault.keyFile != null) 'with its key file',
                if (c.vault.repositoryKey != null) 'with its repository key',
              ].join(' · '),
            ),
          ),
        if (m.configYaml != null)
          CheckboxListTile(
            key: const Key('tsm-pair-config'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: m.includeConfig,
            onChanged: (v) => setState(() => m.includeConfig = v ?? false),
            title: const Text('The shared configuration (dimensions)'),
          ),
        if (m.repositories.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'A GitHub token for this device (optional): paste a fine-grained '
            'token made for it. This machine\'s own token is never sent.',
            style: theme.textTheme.bodySmall,
          ),
          for (final r in m.repositories)
            TextField(
              key: Key('tsm-pair-token-$r'),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: 'Token for $r'),
              onChanged: (v) => m.tokens[r] = v,
            ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              key: const Key('tsm-pair-confirm'),
              onPressed: m.confirm,
              child: Text('Pair ${m.receiver}'),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('tsm-pair-decline'),
              onPressed: m.decline,
              child: const Text('Decline'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _devicesSection(BuildContext context) {
    final theme = Theme.of(context);
    final devices = _model.devices;
    String date(DateTime? at) =>
        at == null ? '—' : at.toLocal().toIso8601String().substring(0, 10);
    return TomSecretsSection(
      title: 'Paired devices',
      icon: Icons.devices_rounded,
      trailing: IconButton(
        tooltip: 'Read again',
        iconSize: 18,
        icon: const Icon(Icons.refresh),
        onPressed: () => unawaited(_loadDevices()),
      ),
      children: [
        if (devices.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No device is paired yet.'),
          ),
        for (final d in devices)
          ListTile(
            key: Key('tsm-paired-${d.device}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              d.isRevoked ? Icons.block : Icons.computer,
              color: d.isRevoked ? theme.colorScheme.error : null,
            ),
            title: Text(
              [d.device, ?d.platform].join(' · '),
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              [
                'paired ${date(d.paired)}'
                    '${d.pairedBy == null ? '' : ' by ${d.pairedBy}'}',
                'keys received: '
                    '${d.keyIds.isEmpty ? 'none' : d.keyIds.join(', ')}',
                if (d.approverKeyId != null)
                  'approver key since ${date(d.approverKeySince)}',
                if (d.linkKeySince != null)
                  'link key since ${date(d.linkKeySince)}',
                if (d.githubAuth == TomSecretsGitHubAuth.app)
                  'GitHub: signed in with the App'
                else if (d.githubAuth == TomSecretsGitHubAuth.token)
                  'GitHub: a pasted token'
                      '${d.githubTokenExpires == null ? '' : ' until ${date(d.githubTokenExpires)}'}',
                if (d.isRevoked) 'revoked ${date(d.revoked)}',
              ].join(' · '),
            ),
            trailing: d.isRevoked
                ? null
                : TextButton(
                    key: Key('tsm-paired-revoke-${d.device}'),
                    onPressed: () => unawaited(_revoke(d)),
                    child: const Text('Revoke'),
                  ),
          ),
      ],
    );
  }

  Future<void> _revoke(TomSecretsDeviceRecord d) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('tsm-paired-revoke'),
        title: Text('Revoke ${d.device}?'),
        content: SizedBox(
          width: 520,
          child: Text(
            'It no longer approves for this machine, and this machine no '
            'longer approves for it. It keeps the keys it received: rotate '
            '${d.keyIds.isEmpty ? 'nothing it was given' : 'the keys ${d.keyIds.join(', ')}'} '
            'on the Keys screen if it is lost or no longer trusted.'
            '${tomSecretsLostDeviceGitHubAdvice(d.githubAuth)}',
            key: const Key('tsm-paired-revoke-text'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-paired-revoke-go'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await _model.revoke(d.device);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }
}

/// What cuts a lost device off GitHub, by how it reaches it
/// (part-key-rotation §3, DP-83): a leading space and the advice, or empty.
String tomSecretsLostDeviceGitHubAdvice(TomSecretsGitHubAuth? auth) =>
    switch (auth) {
      TomSecretsGitHubAuth.token =>
        ' On GitHub, delete this device\'s token (Settings › Developer '
            'settings › Personal access tokens).',
      TomSecretsGitHubAuth.app =>
        ' It is signed in with the GitHub App: revoke the App\'s '
            'authorization on GitHub (Settings › Applications › Authorized '
            'GitHub Apps); every signed-in device must sign in again.',
      null => '',
    };
