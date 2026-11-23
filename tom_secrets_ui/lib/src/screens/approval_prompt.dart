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
///
/// A helper's pick prompt (git's credential helper, protocol.md 5.5) lists
/// the logins of the host for the user to pick one: once, or always (the
/// pick remembered as a grant), or never (nothing given).
///
/// A browser prompt (the browser extension's first lookup that no grant
/// covers, protocol.md 5.5, DP-44) lists the page's logins: once (for ten
/// minutes), always (for this browser only, the scope these logins, their
/// vaults or all, preset to all) or never. **[C]** The same prompt asks for
/// a page's passkeys (protocol.md 5.8).
///
/// **[C]** A new passkey (protocol.md 5.8): a site creates a passkey
/// through the browser extension; "Save in Tom Secrets Manager" makes it
/// and keeps it in the site's login, "Not now" lets the browser offer its
/// own.
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
  String? _picked;
  bool _sending = false;
  String? _error;
  bool _closing = false;
  bool _browserDefaults = false;

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
    final picking = prompt?.pick != null;
    final lasting =
        _decision != 'once' && !(prompt?.confirmOnly ?? false) && !picking;
    try {
      await c.approve(
        widget.approvalId,
        decision: _decision,
        secret: _secret,
        folder: _decision == 'folder' ? _folder!.text.trim() : null,
        pin: lasting ? _pin : null,
        sshHost: lasting && _sshHost && ssh?.hostKeyFingerprint != null,
        // A browser prompt's lasting answer names the browser by itself.
        withParent:
            lasting &&
            _withParent &&
            _decision != 'folder' &&
            !(prompt?.browser ?? false),
        pick: picking && _decision != 'never' ? _picked : null,
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
    final pick = prompt.pick;
    if (confirmOnly && _decision != 'once' && _decision != 'never') {
      _decision = 'once';
    }
    if (pick != null) {
      if (_decision == 'folder') _decision = 'once';
      _picked ??= pick.firstOrNull?.entryId;
    }
    final browser = prompt.browser;
    final passkeyCreate = prompt.passkeyCreate;
    if (browser && !_browserDefaults) {
      // DP-44: one grant per browser for its logins; the host is the
      // product's own executable, updated with it, so not pinned.
      _browserDefaults = true;
      _secret = 'all';
      _pin = 'off';
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
              passkeyCreate != null
                  ? 'Save a passkey for ${passkeyCreate.rpId}?'
                  : browser
                  ? prompt.passkey
                        ? 'The browser extension asks for passkeys'
                        : 'The browser extension asks for logins'
                  : pick != null
                  ? 'A tool asks for a login'
                  : ssh == null
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
              if (pick != null)
                TomSecretsSection(
                  key: const Key('tsm-approval-pick'),
                  title: 'Which login for ${prompt.url ?? 'this host'}',
                  icon: Icons.person_search_rounded,
                  children: [
                    RadioGroup<String>(
                      groupValue: _picked,
                      onChanged: (v) => setState(() => _picked = v),
                      child: Column(
                        children: [
                          for (final p in pick)
                            RadioListTile<String>(
                              key: Key('tsm-approval-pick-${p.entryId}'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              value: p.entryId,
                              title: Text(p.title),
                              subtitle: Text('${p.userName} · ${p.matchedUrl}'),
                            ),
                        ],
                      ),
                    ),
                  ],
                )
              else if (passkeyCreate != null)
                TomSecretsSection(
                  key: const Key('tsm-approval-passkey-create'),
                  title: 'A new passkey',
                  icon: Icons.key_rounded,
                  children: [
                    line('Site', passkeyCreate.rpId),
                    line('User', passkeyCreate.userName),
                    line('Page', passkeyCreate.url),
                    line('Browser', prompt.parentExe),
                    Text(
                      'It goes into the login of this site and user in your '
                      'vaults (a new login when there is none), and every '
                      'device has it from there.',
                      style: label,
                    ),
                  ],
                )
              else if (browser)
                TomSecretsSection(
                  key: const Key('tsm-approval-browser'),
                  title: prompt.passkey
                      ? 'The passkeys of ${prompt.site}'
                      : 'The logins of ${prompt.site}',
                  icon: Icons.language_rounded,
                  children: [
                    line('Page', prompt.url),
                    line('Browser', prompt.parentExe),
                    for (final r in prompt.resolved)
                      line(
                        prompt.passkey ? 'Passkey' : 'Login',
                        '${r.store}/${r.path}',
                      ),
                  ],
                )
              else if (ssh == null)
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
                          in passkeyCreate != null
                              ? const [
                                  ('once', 'Save in Tom Secrets Manager'),
                                  ('never', 'Not now'),
                                ]
                              : browser
                              ? const [
                                  ('once', 'This time'),
                                  ('always', 'Always in this browser'),
                                  ('never', 'Never'),
                                ]
                              : pick != null
                              ? const [
                                  ('once', 'This time'),
                                  ('always', 'Always this login'),
                                  ('never', 'None'),
                                ]
                              : confirmOnly
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
                  if (confirmOnly && passkeyCreate == null)
                    Text(
                      ssh?.forwarded ?? false
                          ? 'A grant lets this key be used over a forwarded '
                                'agent; every such signature is confirmed.'
                          : 'This key (or its vault) asks to confirm every '
                                'signature.',
                      key: const Key('tsm-approval-confirm-only'),
                      style: label,
                    ),
                  if (browser && _decision == 'once')
                    Text(
                      prompt.passkey
                          ? 'The extension may list these passkeys and sign '
                                'in with them in the next ten minutes.'
                          : 'The extension may list these logins and fill '
                                'each once in the next ten minutes.',
                      key: const Key('tsm-approval-browser-once'),
                      style: label,
                    ),
                  if (browser && _decision != 'once')
                    Text(
                      'This holds for '
                      '${prompt.parentExe ?? 'this browser'} only; another '
                      'browser asks on its own. System vaults are never given '
                      'to a browser.',
                      key: const Key('tsm-approval-browser-lasting'),
                      style: label,
                    ),
                  if (pick != null && _decision == 'always')
                    Text(
                      'The next time this tool asks for this host, it gets '
                      'the login picked without asking.',
                      key: const Key('tsm-approval-pick-always'),
                      style: label,
                    ),
                  if (_decision != 'once' && !confirmOnly && pick == null) ...[
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
                          segments: browser
                              ? const [
                                  ButtonSegment(
                                    value: 'ref',
                                    label: Text('These logins'),
                                  ),
                                  ButtonSegment(
                                    value: 'store',
                                    label: Text('Their vaults'),
                                  ),
                                  ButtonSegment(
                                    value: 'all',
                                    label: Text('All logins'),
                                  ),
                                ]
                              : ssh == null
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
                    if (canWithParent && _decision != 'folder' && !browser)
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
