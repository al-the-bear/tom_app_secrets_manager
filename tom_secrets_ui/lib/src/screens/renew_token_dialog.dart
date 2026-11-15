// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Renewing a vault repository's GitHub token from the Keys screen
/// (part-key-rotation §3): GitHub's new-token page opened filled in, the
/// pasted token checked and kept by the service (`token.set`), the result,
/// and the page where the old token is deleted.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../ports/desktop_ports.dart';
import '../state/service_connection.dart';
import '../state/token_renewal.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// Shows the renewal of [repository]'s token (`owner/name`); answers the
/// result, or null when cancelled.
Future<TomSecretsTokenRenewed?> tomSecretsShowRenewTokenDialog(
  BuildContext context,
  String repository, {
  String? device,
}) => showDialog<TomSecretsTokenRenewed>(
  context: context,
  barrierDismissible: false,
  builder: (_) => TomSecretsRenewTokenDialog(
    repository: repository,
    device: device ?? Platform.localHostname,
  ),
);

/// The renewal dialog of one repository's token.
class TomSecretsRenewTokenDialog extends StatefulWidget {
  /// The dialog for [repository] on [device].
  const TomSecretsRenewTokenDialog({
    required this.repository,
    required this.device,
    super.key,
  });

  /// The repository (`owner/name`).
  final String repository;

  /// This machine's name, in the token's name and description.
  final String device;

  @override
  State<TomSecretsRenewTokenDialog> createState() => _RenewState();
}

class _RenewState extends State<TomSecretsRenewTokenDialog> {
  final _token = TextEditingController();
  int _days = 90;
  bool _opened = false;
  bool _running = false;
  String? _error;
  TomSecretsTokenRenewed? _done;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Uri get _newTokenUrl => tomSecretsNewTokenUrl(
    repositories: [widget.repository],
    device: widget.device,
    expiresInDays: _days,
  );

  Future<void> _open(Uri url) async {
    final open = context.read<TomSecretsHost>().openUrl;
    if (open == null || !await open(url)) {
      await Clipboard.setData(ClipboardData(text: '$url'));
      if (mounted) {
        setState(
          () => _error =
              'The page could not be opened here; its address is on the '
              'clipboard.',
        );
      }
    }
    if (mounted) setState(() => _opened = true);
  }

  Future<void> _send() async {
    setState(() {
      _running = true;
      _error = null;
    });
    final c = context.read<TomSecretsServiceConnection>();
    try {
      final done = await tomSecretsRenewToken(
        c,
        repository: widget.repository,
        token: _token.text.trim(),
      );
      _token.clear();
      await c.refreshStatus();
      if (mounted) setState(() => _done = done);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _done;
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('tsm-renew'),
      title: Text('Renew the GitHub token for ${widget.repository}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: done == null ? _form(theme) : _result(theme, done),
        ),
      ),
      actions: done == null
          ? [
              TextButton(
                onPressed: _running ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('tsm-renew-send'),
                onPressed: _running || _token.text.trim().isEmpty
                    ? null
                    : () => unawaited(_send()),
                child: Text(_running ? 'Checking…' : 'Check and save'),
              ),
            ]
          : [
              FilledButton(
                key: const Key('tsm-renew-done'),
                onPressed: () => Navigator.pop(context, done),
                child: const Text('Done'),
              ),
            ],
    );
  }

  Widget _form(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text(
        '1. Make a new fine-grained token on GitHub. The page opens filled '
        'in: name, description, owner, expiry, and the permissions the vaults '
        'need (Contents: Read and write).',
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              key: const Key('tsm-renew-days'),
              initialValue: _days,
              decoration: const InputDecoration(labelText: 'Expires in'),
              items: [
                for (final d in tomSecretsTokenExpiryDays)
                  DropdownMenuItem(value: d, child: Text('$d days')),
              ],
              onChanged: (v) => setState(() => _days = v!),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            key: const Key('tsm-renew-open'),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open GitHub\'s new-token page'),
            onPressed: () => unawaited(_open(_newTokenUrl)),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        'GitHub cannot preselect the repository: under Repository access '
        'choose "Only select repositories" and select '
        '${widget.repository.split('/').last}.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 14),
      const Text(
        '2. Paste the new token. The service checks that it sees the '
        'repository and may write to it, then keeps it where the old one '
        'was.',
      ),
      const SizedBox(height: 8),
      TextField(
        key: const Key('tsm-renew-token'),
        controller: _token,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'The new token',
          helperText: _opened ? null : 'github_pat_…',
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(
          _error!,
          key: const Key('tsm-renew-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ],
    ],
  );

  Widget _result(ThemeData theme, TomSecretsTokenRenewed done) => Column(
    key: const Key('tsm-renew-result'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(done.description),
      const SizedBox(height: 12),
      const Text(
        '3. Delete the old token on GitHub, so it can no longer be used.',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('tsm-renew-delete-old'),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open GitHub\'s token list'),
          onPressed: () => unawaited(_open(Uri.parse(tomSecretsTokenListPage))),
        ),
      ),
    ],
  );
}
