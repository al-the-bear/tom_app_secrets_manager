// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Health screen (part-app, part-password-manager): weak, reused, old,
/// expiring and breached entries and short keys of the open vaults, each
/// one click from its entry; the breach check's state with Check now and
/// its switch (DP-39); the age after which a password counts as old.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../state/health.dart';
import '../state/session_state.dart';

/// The ages a password may count as old after.
const List<(Duration, String)> tomSecretsOldAfterChoices = [
  (Duration(days: 182), '6 months'),
  (Duration(days: 365), '1 year'),
  (Duration(days: 730), '2 years'),
  (Duration(days: 1095), '3 years'),
];

/// The Health screen; [onOpen] shows an entry (default: selects it).
class TomSecretsHealthView extends StatefulWidget {
  /// The screen.
  const TomSecretsHealthView({super.key, this.onOpen});

  /// Shows the entry [ref].
  final void Function(TomSecretsEntryRef ref)? onOpen;

  @override
  State<TomSecretsHealthView> createState() => _TomSecretsHealthViewState();
}

class _TomSecretsHealthViewState extends State<TomSecretsHealthView> {
  String? _store;

  @override
  Widget build(BuildContext context) {
    final health = context.watch<TomSecretsHealth>();
    final session = context.watch<TomSecretsSession>();
    final theme = Theme.of(context);
    final report = health.report;
    final stores = session.vaults.map((v) => v.store).toList()..sort();
    final store = stores.contains(_store) ? _store : null;
    final findings = [
      for (final f in report.findings)
        if (store == null || f.store == store) f,
    ];
    return ListView(
      key: const Key('tsm-health'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            Icon(
              Icons.health_and_safety_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text('Health', style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${report.checkedPasswords} '
                '${report.checkedPasswords == 1 ? 'password' : 'passwords'} '
                'checked',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _BreachCard(health: health),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (stores.length > 1)
              DropdownButton<String?>(
                key: const Key('tsm-health-store'),
                value: store,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All vaults'),
                  ),
                  for (final s in stores)
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (s) => setState(() => _store = s),
              ),
            const Text('Old after'),
            DropdownButton<int>(
              key: const Key('tsm-health-old-after'),
              value: health.oldAfter.inDays,
              items: [
                for (final (age, label) in tomSecretsOldAfterChoices)
                  DropdownMenuItem(value: age.inDays, child: Text(label)),
                if (!tomSecretsOldAfterChoices.any(
                  (c) => c.$1.inDays == health.oldAfter.inDays,
                ))
                  DropdownMenuItem(
                    value: health.oldAfter.inDays,
                    child: Text('${health.oldAfter.inDays} days'),
                  ),
              ],
              onChanged: (days) {
                if (days != null) {
                  unawaited(health.setOldAfter(Duration(days: days)));
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (session.vaults.isEmpty)
          const _Message('No vault is open.')
        else if (findings.isEmpty)
          const _Message(
            'Nothing to fix: no weak, reused, old or breached password, no '
            'entry about to expire and no short key.',
            key: Key('tsm-health-healthy'),
          )
        else
          for (final issue in TomSecretsHealthIssue.values)
            if (findings.where((f) => f.issue == issue).toList() case final list
                when list.isNotEmpty)
              _IssueSection(
                issue: issue,
                findings: list,
                onOpen: (ref) =>
                    (widget.onOpen ?? (r) => session.selectedEntry = r)(ref),
              ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Text(text, textAlign: TextAlign.center),
  );
}

/// The breach check's state, Check now and its switch.
class _BreachCard extends StatelessWidget {
  const _BreachCard({required this.health});

  final TomSecretsHealth health;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = health.lastFullRun;
    final run = health.lastRun;
    final lines = <String>[
      if (!health.breachEnabled)
        'Off: passwords are not checked against known breaches.'
      else ...[
        'Have I Been Pwned is asked with the first five characters of each '
            'password\'s SHA-1 hash; the password and its full hash never '
            'leave this device. New and changed passwords are checked at '
            'once, all of them once a week.',
        if (last != null)
          'All passwords checked on ${last.toLocal().toString().substring(0, 16)}.',
        if (run != null) run.body,
        if (health.lastError case final error?) 'The last check failed: $error',
      ],
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Breach check',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (health.running)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (health.breachEnabled)
                  TextButton(
                    key: const Key('tsm-health-check-now'),
                    onPressed: () => unawaited(health.runNow(full: true)),
                    child: const Text('Check now'),
                  ),
                Switch(
                  key: const Key('tsm-health-breach-switch'),
                  value: health.breachEnabled,
                  onChanged: (on) => unawaited(health.setBreachEnabled(on)),
                ),
              ],
            ),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(line, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class _IssueSection extends StatelessWidget {
  const _IssueSection({
    required this.issue,
    required this.findings,
    required this.onOpen,
  });

  final TomSecretsHealthIssue issue;
  final List<TomSecretsHealthFinding> findings;
  final void Function(TomSecretsEntryRef ref) onOpen;

  static String _explain(TomSecretsHealthIssue issue) => switch (issue) {
    TomSecretsHealthIssue.weak =>
      'Guessed quickly: dictionary words, patterns or keyboard walks.',
    TomSecretsHealthIssue.reused =>
      'One leak opens every account sharing the password.',
    TomSecretsHealthIssue.old => 'Not changed for a long time.',
    TomSecretsHealthIssue.expiring => 'Expires within 30 days, or has expired.',
    TomSecretsHealthIssue.shortKey =>
      'Below today\'s guidance (RSA 3072 bits, curves 256 bits); still '
          'served. Open the entry to generate an Ed25519 replacement.',
    TomSecretsHealthIssue.breached =>
      'Found in known data breaches: change it where it is used.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final health = context.read<TomSecretsHealth>();
    return Padding(
      key: Key('tsm-health-${issue.name}'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${issue.label} (${findings.length})',
            style: theme.textTheme.titleSmall,
          ),
          Text(_explain(issue), style: theme.textTheme.bodySmall),
          for (final f in findings)
            ListTile(
              key: Key(
                'tsm-health-${issue.name}-${f.store}-${tomSecretsUuidHex(f.entry.uuid)}',
              ),
              dense: true,
              leading: const Icon(Icons.key_outlined),
              title: Text(
                (f.entry.label ?? '').isEmpty ? '(untitled)' : f.entry.label!,
              ),
              subtitle: Text('${f.store} · ${f.detail}'),
              trailing: issue == TomSecretsHealthIssue.breached
                  ? TextButton(
                      key: Key(
                        'tsm-health-exclude-${tomSecretsUuidHex(f.entry.uuid)}',
                      ),
                      onPressed: () => unawaited(
                        health.setExcluded(
                          TomSecretsEntryRef(f.store, f.entry.uuid),
                          true,
                        ),
                      ),
                      child: const Text('Exclude'),
                    )
                  : null,
              onTap: () => onOpen(TomSecretsEntryRef(f.store, f.entry.uuid)),
            ),
        ],
      ),
    );
  }
}
