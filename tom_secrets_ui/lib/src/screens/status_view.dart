// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Status screen (part-app): the service (running since, protocol
/// version, lock mode), the stores with their state, source and last fetch,
/// the hardening achieved and the attached admins.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../state/service_connection.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;
import 'rewritten_question.dart';
import 'vault_browser.dart' show tomSecretsAge;

/// The Status screen.
/// Asks, then gives the service a new identity key.
Future<void> _rotateIdentity(
  BuildContext context,
  TomSecretsServiceConnection c,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('tsm-identity-rotate-dialog'),
      title: const Text('A new identity key for this service'),
      content: const SizedBox(
        width: 520,
        child: Text(
          'The service makes a new identity key, and its old key signs the '
          'new one: this app and tsm on this machine follow by themselves '
          'at their next connection. The words your other devices show for '
          'this machine change once they have synced.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('tsm-identity-rotate-go'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Make a new key'),
        ),
      ],
    ),
  );
  if (go != true) return;
  String message;
  try {
    message = 'The service\'s identity is now ${await c.rotateIdentityKey()}.';
  } on TomSecretsAdminException catch (e) {
    message = tomSecretsDescribeAdminError(e);
  }
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}

class TomSecretsStatusView extends StatelessWidget {
  /// The screen.
  const TomSecretsStatusView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final report = c.report;
    final service = (report['service'] as Map?)?.cast<String, Object?>();
    final start = service?['start'];
    final hardening = (report['hardening'] as Map?)?.cast<String, Object?>();
    final links = [
      for (final l in (report['links'] as List? ?? const []))
        if (l is Map) l.cast<String, Object?>(),
    ];
    return ListView(
      key: const Key('tsm-status'),
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('Service', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Fetch every vault now'),
              onPressed: () => unawaited(c.reload().catchError((Object _) {})),
            ),
          ],
        ),
        ListTile(
          title: const Text('Running since'),
          subtitle: Text(
            start is int
                ? DateTime.fromMillisecondsSinceEpoch(
                    start,
                  ).toLocal().toString()
                : '—',
          ),
        ),
        ListTile(
          title: const Text('Version and protocol'),
          subtitle: Text(
            '${service?['version'] ?? '—'}, protocol ${report['protocol'] ?? '—'}',
          ),
        ),
        if (c.identityWords case final words?)
          ListTile(
            key: const Key('tsm-status-identity'),
            title: const Text('Identity'),
            subtitle: SelectableText(
              '$words\nThe words your other devices and `tsm status` show '
              'for this machine\'s service.',
            ),
            trailing: TextButton(
              key: const Key('tsm-identity-rotate'),
              onPressed: () => unawaited(_rotateIdentity(context, c)),
              child: const Text('New key…'),
            ),
          ),
        ListTile(
          title: const Text('Lock mode'),
          subtitle: Text(switch (c.lockMode) {
            'a' => 'stays unlocked until locked',
            'b' => 'locks after a time without use',
            'c' => 'locks after a time without use or with the screen',
            _ => '—',
          }),
        ),
        ListTile(
          title: const Text('Admins attached'),
          subtitle: Text('${report['admins'] ?? '—'}'),
        ),
        const SizedBox(height: 12),
        Text('Vaults', style: Theme.of(context).textTheme.titleLarge),
        for (final s in c.stores.values)
          ListTile(
            key: Key('tsm-status-store-${s.name}'),
            leading: Icon(s.isOffline ? Icons.cloud_off : Icons.cloud_done),
            trailing: s.rewrittenHead == null
                ? null
                : FilledButton.tonal(
                    key: Key('tsm-status-rewritten-${s.name}'),
                    onPressed: () =>
                        tomSecretsShowRewrittenQuestion(context, s.name),
                    child: const Text('Choose…'),
                  ),
            title: Text(s.name),
            subtitle: Text(
              [
                switch (s.state) {
                  'current' => 'synced',
                  'needs_unlock' => 'needs its own password',
                  'unavailable' => switch (s.reason) {
                    'offline' => 'waiting for GitHub',
                    'token_expired' => 'waiting: GitHub refused the token',
                    _ => 'unavailable',
                  },
                  _ => s.offlineReason ?? s.state,
                },
                if (s.source != null)
                  s.source == 'cache'
                      ? 'from the copy held'
                      : 'from ${s.source}',
                if (s.fetchedAt != null)
                  'fetched ${tomSecretsAge(s.fetchedAt!)}',
                if (s.isStaleAt(DateTime.now()))
                  'the copy held is over a week old and may be out of date',
                if (s.rewrittenHead != null)
                  'its branch on GitHub was rewritten: a choice is needed',
                if (s.notPushed > 0)
                  '${s.notPushed} change${s.notPushed == 1 ? '' : 's'} not yet '
                      'on GitHub: kept in memory and written when GitHub '
                      'answers; lost if the service stops or locks first',
              ].join(' · '),
            ),
          ),
        const SizedBox(height: 12),
        Text('Approval links', style: Theme.of(context).textTheme.titleLarge),
        if (links.isEmpty)
          const ListTile(
            key: Key('tsm-status-links-none'),
            title: Text('No paired device to approve for or from.'),
          ),
        for (final l in links)
          ListTile(
            key: Key('tsm-status-link-${l['role']}-${l['device']}'),
            leading: Icon(switch (l['state']) {
              'connected' => Icons.link,
              'waiting' || 'connecting' => Icons.hourglass_empty,
              _ => Icons.link_off,
            }),
            title: Text(
              l['role'] == 'host'
                  ? 'Approving for ${l['device']}'
                  : '${l['device']} approves for this machine',
            ),
            subtitle: Text(tomSecretsLinkStateText(l)),
          ),
        const SizedBox(height: 12),
        Text('Hardening', style: Theme.of(context).textTheme.titleLarge),
        if (hardening == null || hardening.isEmpty)
          const ListTile(title: Text('—')),
        for (final MapEntry(:key, :value) in (hardening ?? const {}).entries)
          ListTile(
            dense: true,
            leading: Icon(value == true ? Icons.check : Icons.close),
            title: Text(switch (key) {
              'noCoreDumps' => 'No core dumps',
              'notDumpable' => 'Not attachable by a debugger',
              'memoryAccessDenied' => 'Memory not readable by other processes',
              _ => key,
            }),
          ),
      ],
    );
  }
}

/// An approval link's state as the Status view says it (part-relay): a
/// link the relay refused (no instance token, too many links) reads as an
/// unreachable link, with the relay's reason.
String tomSecretsLinkStateText(Map<String, Object?> link) {
  final via = switch (link['via']) {
    'relay' => ' through the relay server',
    'address' => ' over the network or the VPN',
    _ => '',
  };
  final reason = link['reason'];
  return switch (link['state']) {
    'connected' => 'connected$via',
    'waiting' => 'waiting$via for the other device',
    'connecting' => 'connecting…',
    _ => 'unreachable$via${reason is String ? ': $reason' : ''}',
  };
}
