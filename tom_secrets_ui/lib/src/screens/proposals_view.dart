// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Proposals screen (part-app, Screens › Proposals; BP-28, DP-43,
/// DP-52): the logins the browser extension saw submitted and git's
/// credential helper saw work, which the vaults do not hold yet (or hold
/// with another password). Per proposal: update the existing login of that
/// site and user (its old password goes to the history), save it as a new
/// login in a vault chosen here, or drop it. Proposals live in memory
/// only; the lock forgets them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../state/proposals.dart';
import '../state/service_connection.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// The Proposals screen.
class TomSecretsProposalsView extends StatelessWidget {
  /// The screen.
  const TomSecretsProposalsView({super.key});

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<TomSecretsServiceConnection>();
    final proposals = connection.proposals.reversed.toList();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Icon(Icons.add_task_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Proposals', style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              Text(
                proposals.isEmpty ? 'none' : '${proposals.length}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Logins the browser extension saw you sign in with, and '
            'credentials git saw work, that the vaults do not hold yet. '
            'Nothing is written until you save one; locking forgets them.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: proposals.isEmpty
              ? const Center(
                  key: Key('tsm-proposals-none'),
                  child: Text('No proposals.'),
                )
              : ListView(
                  key: const Key('tsm-proposal-list'),
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final p in proposals)
                      _ProposalCard(key: Key('tsm-proposal-${p.id}'), p),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ProposalCard extends StatefulWidget {
  const _ProposalCard(this.proposal, {super.key});

  final TomSecretsProposal proposal;

  @override
  State<_ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends State<_ProposalCard> {
  late final TextEditingController _title = TextEditingController(
    text: widget.proposal.suggestedTitle,
  );
  String? _vault;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final connection = context.read<TomSecretsServiceConnection>();
    final p = widget.proposal;
    final matches = session.proposalMatches(p);
    final vaults = session.proposalVaults;
    final preferred = matches.isNotEmpty ? matches.first.store : null;
    final vault = vaults.contains(_vault)
        ? _vault!
        : vaults.contains(preferred)
        ? preferred!
        : vaults.firstOrNull;
    final theme = Theme.of(context);
    final known = matches.where((m) => m.samePassword).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.language_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.site,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  TimeOfDay.fromDateTime(p.received).format(context),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText('User name: ${p.userName}'),
            SelectableText('Page: ${p.url}', style: theme.textTheme.bodySmall),
            Text(
              'Password: ${'•' * p.password.length.clamp(4, 16)}',
              style: theme.textTheme.bodySmall,
            ),
            if (known.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${known.first.title} (${known.first.store}) holds this '
                  'password already.',
                  key: const Key('tsm-proposal-known'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            for (final m in matches.where((m) => !m.samePassword))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    TomSecretsChip(
                      m.store,
                      colour: tomSecretsVaultColour(m.store),
                      icon: Icons.inventory_2_outlined,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${m.title} · ${m.matchedUrl}')),
                    FilledButton.tonalIcon(
                      key: Key('tsm-proposal-update-${m.store}-${m.title}'),
                      icon: const Icon(Icons.update_rounded),
                      label: const Text('Update the password'),
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _run(
                                () => session.applyProposal(
                                  p,
                                  TomSecretsEntryRef(m.store, m.uuid),
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('tsm-proposal-title'),
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (vaults.isEmpty)
                  const Text('No vault to save into')
                else
                  DropdownButton<String>(
                    key: const Key('tsm-proposal-vault'),
                    value: vault,
                    items: [
                      for (final v in vaults)
                        DropdownMenuItem(value: v, child: Text(v)),
                    ],
                    onChanged: (v) => setState(() => _vault = v),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('tsm-proposal-save'),
                  icon: const Icon(Icons.save_rounded),
                  label: const Text('Save as a new login'),
                  onPressed: _busy || vault == null
                      ? null
                      : () => unawaited(
                          _run(
                            () => session.saveProposalAsNew(
                              p,
                              vault,
                              title: _title.text,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const Key('tsm-proposal-drop'),
                  onPressed: _busy ? null : () => connection.dropProposal(p.id),
                  child: const Text('Drop'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
