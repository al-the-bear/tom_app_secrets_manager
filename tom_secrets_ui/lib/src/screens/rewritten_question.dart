// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The force-push question (part-stores; protocol.md 6.4): a vault's branch
/// on GitHub was rewritten without a compaction, so the service refused a
/// save and waits for the user's choice — follow the rewritten branch, or
/// merge this copy over it.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../state/service_connection.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// Asks what to do with the rewritten branch of [store] and sends the
/// answer; the vault is read again when the service reports the change.
Future<void> tomSecretsShowRewrittenQuestion(
  BuildContext context,
  String store,
) {
  final connection = context.read<TomSecretsServiceConnection>();
  return showDialog<void>(
    context: context,
    builder: (_) => _RewrittenDialog(store: store, connection: connection),
  );
}

class _RewrittenDialog extends StatefulWidget {
  const _RewrittenDialog({required this.store, required this.connection});

  final String store;
  final TomSecretsServiceConnection connection;

  @override
  State<_RewrittenDialog> createState() => _RewrittenDialogState();
}

class _RewrittenDialogState extends State<_RewrittenDialog> {
  bool _sending = false;
  String? _error;

  Future<void> _answer({required bool takeRemote}) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final conflicts = await widget.connection.resolveRewritten(
        widget.store,
        takeRemote: takeRemote,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            takeRemote
                ? '${widget.store} follows the file on GitHub now.'
                : conflicts == 0
                ? 'This copy was merged over the file on GitHub.'
                : 'Merged; $conflicts fields changed on both sides wait '
                      'under Conflicts.',
          ),
        ),
      );
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = tomSecretsDescribeAdminError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = widget.connection.stores[widget.store]?.rewrittenHead;
    return AlertDialog(
      key: const Key('tsm-rewritten-question'),
      title: Text('${widget.store}: the branch on GitHub was rewritten'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Someone replaced the history of the vault\'s branch on GitHub '
              '(a force push${head == null ? '' : ' to ${head.substring(0, head.length < 12 ? head.length : 12)}'}), '
              'not by a compaction. Your last change was not written, and the '
              'vault is not read again until you choose.',
            ),
            const SizedBox(height: 12),
            Text('Take the file on GitHub', style: theme.textTheme.titleSmall),
            const Text(
              'Follow the rewritten branch as it is. Your change that was '
              'refused is dropped; make it again if it is still needed.',
            ),
            const SizedBox(height: 8),
            Text('Merge this copy over it', style: theme.textTheme.titleSmall),
            const Text(
              'Merge the copy this machine holds, your change included, '
              'into the file on GitHub, without taking anything as deleted, '
              'and commit it on top. Fields changed on both sides are kept '
              'as conflicts.',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        OutlinedButton(
          key: const Key('tsm-rewritten-remote'),
          onPressed: _sending ? null : () => _answer(takeRemote: true),
          child: const Text('Take the file on GitHub'),
        ),
        FilledButton(
          key: const Key('tsm-rewritten-merge'),
          onPressed: _sending ? null : () => _answer(takeRemote: false),
          child: const Text('Merge this copy over it'),
        ),
      ],
    );
  }
}
