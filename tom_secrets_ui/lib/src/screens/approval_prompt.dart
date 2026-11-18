// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The approval prompt (part-app, Screens › Approval prompt; protocol.md
/// 7.2): which host asks, who is asking there (the executable or the
/// interpreter with its script, its folder and parent, as that host's
/// service measured them), which secrets (by reference and resolved entry),
/// and the choices once, always, always for this folder, or never, with the
/// scope (this reference, the store, everything) and the pin (DP-17).
///
/// An ssh-agent signature (protocol.md 7.6) shows the key, the destination
/// host and what the signature is for; a lasting answer may hold only for
/// that host. A confirmation (a forwarded agent, or a key or vault that asks
/// for it) is answered for this signature only.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../state/service_connection.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// Shows the prompt [approvalId] as a dialog on top; it closes itself when
/// the prompt is answered elsewhere or ends.
Future<void> tomSecretsShowApprovalPrompt(
  BuildContext context,
  String approvalId,
) {
  final connection = context.read<TomSecretsServiceConnection>();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangeNotifierProvider.value(
      value: connection,
      child: TomSecretsApprovalPromptDialog(approvalId: approvalId),
    ),
  );
}

/// The dialog of one prompt.
class TomSecretsApprovalPromptDialog extends StatefulWidget {
  /// The dialog of [approvalId].
  const TomSecretsApprovalPromptDialog({super.key, required this.approvalId});

  /// The prompt.
  final String approvalId;

  @override
  State<TomSecretsApprovalPromptDialog> createState() => _PromptState();
}

class _PromptState extends State<TomSecretsApprovalPromptDialog> {
  String _decision = 'once';
  String _secret = 'ref';
  String _pin = 'hash';
  TextEditingController? _folder;
  bool _sshHost = true;
  bool _withParent = false;
  bool _sending = false;
  String? _error;
  bool _closing = false;

  @override
  void dispose() {
    _folder?.dispose();
    super.dispose();
  }

  Future<void> _answer(TomSecretsServiceConnection c) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final prompt = c.prompt(widget.approvalId);
    final ssh = prompt?.ssh;
    final lasting = _decision != 'once' && !(prompt?.confirmOnly ?? false);
    try {
      await c.approve(
        widget.approvalId,
        decision: _decision,
        secret: _secret,
        folder: _decision == 'folder' ? _folder!.text.trim() : null,
        pin: lasting ? _pin : null,
        sshHost: lasting && _sshHost && ssh?.hostKeyFingerprint != null,
        withParent: lasting && _withParent && _decision != 'folder',
      );
      if (mounted) Navigator.of(context).pop();
    } on TomSecretsAdminException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.kind == 'not_found'
            ? 'The request ended meanwhile.'
            : tomSecretsDescribeAdminError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final prompt = c.prompt(widget.approvalId);
    if (prompt == null) {
      // Answered on another device, timed out or abandoned.
      if (!_closing) {
        _closing = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
      return const SizedBox.shrink();
    }
    _folder ??= TextEditingController(text: prompt.suggestedFolder);
    final ssh = prompt.ssh;
    final confirmOnly = prompt.confirmOnly;
    if (confirmOnly && _decision != 'once' && _decision != 'never') {
      _decision = 'once';
    }
    // `exe-from` names an executable with its parent (not a script).
    final canWithParent = prompt.parentExe != null && prompt.script == null;
    final theme = Theme.of(context);
    final label = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget line(String name, String? value) => value == null || value.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 92, child: Text(name, style: label)),
                Expanded(
                  child: SelectableText(
                    value,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          );
    return AlertDialog(
      key: const Key('tsm-approval-prompt'),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      title: Row(
        children: [
          Icon(Icons.how_to_reg_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ssh == null
                  ? 'A program asks for secrets'
                  : confirmOnly
                  ? 'Confirm an SSH signature'
                  : 'A program wants to use an SSH key',
              style: theme.textTheme.titleMedium,
            ),
          ),
          TomSecretsChip(
            prompt.host,
            colour: tomSecretsVaultColour(prompt.host),
            icon: Icons.computer_rounded,
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TomSecretsSection(
                title: 'Who asks',
                icon: Icons.terminal_rounded,
                children: [
                  line(
                    prompt.script != null ? 'Interpreter' : 'Executable',
                    prompt.script != null
                        ? (prompt.interpreter ?? prompt.exe)
                        : prompt.exe,
                  ),
                  line('Script', prompt.script),
                  line('Arguments', prompt.args.join(' ')),
                  line('Folder', prompt.cwd),
                  line('Started by', prompt.parentExe),
                  if (prompt.remote)
                    Text(
                      'It connected from another machine.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              ),
              if (ssh == null)
                TomSecretsSection(
                  title: 'Which secrets',
                  icon: Icons.key_rounded,
                  children: [
                    for (final ref in prompt.refs) line('Reference', ref),
                    for (final r in prompt.resolved)
                      line('Entry', '${r.store}/${r.path} (${r.kind})'),
                  ],
                )
              else
                TomSecretsSection(
                  key: const Key('tsm-approval-ssh'),
                  title: 'Which SSH key, for what',
                  icon: Icons.vpn_key_rounded,
                  children: [
                    line('Key', ssh.title ?? ssh.keyFingerprint),
                    for (final r in prompt.resolved)
                      line('Entry', '${r.store}/${r.path}'),
                    line('Fingerprint', '${ssh.keyType} ${ssh.keyFingerprint}'),
                    line('For host', ssh.destinationText),
                    if (ssh.hostNames.isNotEmpty)
                      line('Host key', ssh.hostKeyFingerprint),
                    line('Purpose', ssh.purposeText),
                    if (ssh.forwarded)
                      Text(
                        'It comes over a forwarded agent: a program on '
                        'another machine asks to sign with your key.',
                        key: const Key('tsm-approval-ssh-forwarded'),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                  ],
                ),
              TomSecretsSection(
                title: 'Your answer',
                icon: Icons.rule_rounded,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final (value, text)
                          in confirmOnly
                              ? const [
                                  ('once', 'Allow this signature'),
                                  ('never', 'Refuse it'),
                                ]
                              : const [
                                  ('once', 'Once'),
                                  ('always', 'Always'),
                                  ('folder', 'Always for this folder'),
                                  ('never', 'Never'),
                                ])
                        ChoiceChip(
                          key: Key('tsm-approval-decision-$value'),
                          label: Text(text),
                          selected: _decision == value,
                          onSelected: (_) => setState(() => _decision = value),
                        ),
                    ],
                  ),
                  if (_decision == 'folder')
                    TextField(
                      key: const Key('tsm-approval-folder'),
                      controller: _folder,
                      decoration: const InputDecoration(
                        labelText: 'Everything below this folder',
                        isDense: true,
                      ),
                    ),
                  if (confirmOnly)
                    Text(
                      ssh?.forwarded ?? false
                          ? 'A grant lets this key be used over a forwarded '
                                'agent; every such signature is confirmed.'
                          : 'This key (or its vault) asks to confirm every '
                                'signature.',
                      key: const Key('tsm-approval-confirm-only'),
                      style: label,
                    ),
                  if (_decision != 'once' && !confirmOnly) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('Covers ', style: label),
                        SegmentedButton<String>(
                          key: const Key('tsm-approval-secret'),
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: ssh == null
                              ? const [
                                  ButtonSegment(
                                    value: 'ref',
                                    label: Text('This reference'),
                                  ),
                                  ButtonSegment(
                                    value: 'store',
                                    label: Text('Store'),
                                  ),
                                  ButtonSegment(
                                    value: 'all',
                                    label: Text('All'),
                                  ),
                                ]
                              : const [
                                  ButtonSegment(
                                    value: 'ref',
                                    label: Text('This key'),
                                  ),
                                  ButtonSegment(
                                    value: 'store',
                                    label: Text("Its vault's keys"),
                                  ),
                                  ButtonSegment(
                                    value: 'all',
                                    label: Text('All keys'),
                                  ),
                                ],
                          selected: {_secret},
                          onSelectionChanged: (s) =>
                              setState(() => _secret = s.single),
                        ),
                      ],
                    ),
                    if (ssh?.hostKeyFingerprint != null)
                      CheckboxListTile(
                        key: const Key('tsm-approval-ssh-host'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _sshHost,
                        onChanged: (v) => setState(() => _sshHost = v == true),
                        title: Text(
                          'Only for this host (${ssh!.destinationText})',
                        ),
                      ),
                    if (canWithParent && _decision != 'folder')
                      CheckboxListTile(
                        key: const Key('tsm-approval-with-parent'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _withParent,
                        onChanged: (v) =>
                            setState(() => _withParent = v == true),
                        title: Text('Only when started by ${prompt.parentExe}'),
                      ),
                    CheckboxListTile(
                      key: const Key('tsm-approval-pin'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _pin == 'hash',
                      onChanged: (v) =>
                          setState(() => _pin = v == true ? 'hash' : 'off'),
                      title: const Text(
                        'Only while the program file is unchanged (pinned)',
                      ),
                    ),
                    if (prompt.wantClientToken && _decision == 'always')
                      Text(
                        'The program asked for a client token: it gets one '
                        'with this answer and is known by it from now on.',
                        style: label,
                      ),
                  ],
                  if (prompt.approvalCode != null)
                    Text(
                      'The host also shows the approval code '
                      '${prompt.approvalCode}.',
                      style: label,
                    ),
                ],
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('tsm-approval-later'),
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton(
          key: const Key('tsm-approval-answer'),
          style: _decision == 'never'
              ? FilledButton.styleFrom(backgroundColor: theme.colorScheme.error)
              : null,
          onPressed: _sending ? null : () => _answer(c),
          child: Text(_decision == 'never' ? 'Refuse' : 'Allow'),
        ),
      ],
    );
  }
}
