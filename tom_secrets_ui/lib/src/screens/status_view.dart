// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Status screen (part-app): the service (running since, protocol
/// version, lock mode), the stores with their state, source and last fetch,
/// the hardening achieved and the attached admins.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/service_connection.dart';
import 'vault_browser.dart' show tomSecretsAge;

/// The Status screen.
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
            title: Text(s.name),
            subtitle: Text(
              [
                switch (s.state) {
                  'current' => 'synced',
                  'needs_unlock' => 'needs its own password',
                  'unavailable' => 'unavailable',
                  _ => s.offlineReason ?? s.state,
                },
                if (s.source != null) 'from ${s.source}',
                if (s.fetchedAt != null)
                  'fetched ${tomSecretsAge(s.fetchedAt!)}',
                if (s.notPushed > 0) '${s.notPushed} changes not yet on GitHub',
              ].join(' · '),
            ),
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
