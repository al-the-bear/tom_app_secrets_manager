// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Clients screen (part-app, Screens › Clients): the waiting approvals;
/// the allow list of every host, filtered by host and grouped by executable,
/// by interpreter and script, and by folder, each grant with its secret,
/// last use and Revoke; pre-approving a client for any host; the approval
/// code a waiting request on a headless machine shows, answered with a
/// one-time token (and, for a lasting decision, its grant); and the audit
/// log with filters by time, host, client, reference and outcome.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsSshGrantSecret;

import '../state/clients.dart';
import '../state/service_connection.dart';
import '../widgets/style.dart';
import 'approval_prompt.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;
import 'vault_browser.dart' show tomSecretsAge, tomSecretsGuarded;

/// The Clients screen.
class TomSecretsClientsView extends StatelessWidget {
  /// The screen.
  const TomSecretsClientsView({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: TabBar(
              key: const Key('tsm-clients-tabs'),
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(
                  child: Badge.count(
                    count: c.pendingApprovals,
                    isLabelVisible: c.pendingApprovals > 0,
                    child: const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text('Approvals'),
                    ),
                  ),
                ),
                const Tab(text: 'Allow list'),
                const Tab(text: 'Pre-approve'),
                const Tab(text: 'Approval code'),
                const Tab(text: 'Audit log'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                _ApprovalsTab(),
                _AllowListTab(),
                _PreApproveTab(),
                _ApprovalCodeTab(),
                _AuditTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalsTab extends StatelessWidget {
  const _ApprovalsTab();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final prompts = c.prompts;
    if (prompts.isEmpty) {
      return const Center(child: Text('No request waits for an approval.'));
    }
    return ListView(
      key: const Key('tsm-approvals-list'),
      padding: const EdgeInsets.all(8),
      children: [
        for (final p in prompts)
          Card(
            child: ListTile(
              key: Key('tsm-approval-${p.approvalId}'),
              dense: true,
              leading: TomSecretsChip(
                p.host,
                colour: tomSecretsVaultColour(p.host),
                icon: Icons.computer_rounded,
              ),
              title: Text(
                p.who,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: Text(p.refs.join(', ')),
              trailing: FilledButton.tonal(
                key: Key('tsm-approval-open-${p.approvalId}'),
                onPressed: () => unawaited(
                  tomSecretsShowApprovalPrompt(context, p.approvalId),
                ),
                child: const Text('Answer…'),
              ),
            ),
          ),
      ],
    );
  }
}

class _AllowListTab extends StatefulWidget {
  const _AllowListTab();

  @override
  State<_AllowListTab> createState() => _AllowListState();
}

class _AllowListState extends State<_AllowListTab> {
  List<TomSecretsGrant>? _grants;
  String? _host;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final api = TomSecretsClientsApi(
      context.read<TomSecretsServiceConnection>(),
    );
    try {
      final grants = await api.grants();
      if (mounted) setState(() => _grants = grants);
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final grants = _grants;
    if (_error != null) return Center(child: Text(_error!));
    if (grants == null) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final hosts = {for (final g in grants) g.host, ?_host}.toList()..sort();
    final shown = grants.where((g) => _host == null || g.host == _host);
    final groups = <String, List<TomSecretsGrant>>{};
    for (final g in shown) {
      groups.putIfAbsent(g.group, () => []).add(g);
    }
    final api = TomSecretsClientsApi(
      context.read<TomSecretsServiceConnection>(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Text('${shown.length} grants'),
              const SizedBox(width: 16),
              DropdownButton<String?>(
                key: const Key('tsm-grants-host'),
                value: _host,
                isDense: true,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Every host'),
                  ),
                  for (final h in hosts)
                    DropdownMenuItem(value: h, child: Text(h)),
                ],
                onChanged: (h) => setState(() => _host = h),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Read again',
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(_load()),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: groups.isEmpty
              ? const Center(child: Text('No grants.'))
              : ListView(
                  key: const Key('tsm-grants-list'),
                  padding: const EdgeInsets.all(8),
                  children: [
                    for (final MapEntry(key: group, value: items)
                        in groups.entries)
                      TomSecretsSection(
                        title: group,
                        icon: Icons.terminal_rounded,
                        children: [
                          for (final g in items)
                            ListTile(
                              key: Key('tsm-grant-${g.id}'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                g.decision == 'never'
                                    ? Icons.block
                                    : Icons.check_circle_outline,
                                color: g.decision == 'never'
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.primary,
                              ),
                              title: Text(
                                g.secretText,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: Text(
                                [
                                  g.host,
                                  if (g.subjectKind == 'exe-token')
                                    'with its client token',
                                  g.lastUsed == null
                                      ? 'not used yet'
                                      : 'last used ${tomSecretsAge(g.lastUsed!)}',
                                  if (!g.accepted) 'signature not accepted',
                                ].join(' · '),
                              ),
                              trailing: TextButton(
                                key: Key('tsm-grant-revoke-${g.id}'),
                                onPressed: () =>
                                    tomSecretsGuarded(context, () async {
                                      await api.revoke(g);
                                      await _load();
                                    }),
                                child: const Text('Revoke'),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// The subject kinds a pre-approval or a code's grant may name.
const _subjectKinds = [
  ('exe', 'Executable'),
  ('exe-from', 'Executable started by a parent'),
  ('script', 'Script (interpreter and script)'),
  ('folder', 'Folder'),
  ('interpreter', 'Interpreter'),
];

/// Host, subject, secret and pin fields, shared by the pre-approval and the
/// approval code's grant.
class _GrantFields extends StatelessWidget {
  const _GrantFields({
    required this.kind,
    required this.onKind,
    required this.path,
    required this.interpreter,
    required this.parent,
    required this.secret,
    required this.pin,
    required this.onPin,
    this.secretLabel = 'Secret',
    this.secretHelp =
        'a reference (e.g. telegram.bot_token), store <name>, '
        'or all',
  });

  final String kind;
  final ValueChanged<String> onKind;
  final TextEditingController path;
  final TextEditingController interpreter;
  final TextEditingController parent;
  final String secretLabel;
  final String secretHelp;
  final TextEditingController secret;
  final bool pin;
  final ValueChanged<bool> onPin;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        key: const Key('tsm-grant-kind'),
        isExpanded: true,
        initialValue: kind,
        decoration: const InputDecoration(labelText: 'Who', isDense: true),
        items: [
          for (final (value, text) in _subjectKinds)
            DropdownMenuItem(
              value: value,
              child: Text(text, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => onKind(v ?? kind),
      ),
      if (kind == 'exe-from')
        TextField(
          key: const Key('tsm-grant-parent'),
          controller: parent,
          decoration: const InputDecoration(
            labelText: 'Started by (the parent executable, path)',
            helperText: 'e.g. /usr/bin/git for the ssh git starts',
            isDense: true,
          ),
        ),
      if (kind == 'script')
        TextField(
          key: const Key('tsm-grant-interpreter'),
          controller: interpreter,
          decoration: const InputDecoration(
            labelText: 'Interpreter (path)',
            isDense: true,
          ),
        ),
      TextField(
        key: const Key('tsm-grant-path'),
        controller: path,
        decoration: InputDecoration(
          labelText: switch (kind) {
            'script' => 'Script (path)',
            'folder' => 'Folder (path)',
            'interpreter' => 'Interpreter (path)',
            _ => 'Executable (path)',
          },
          isDense: true,
        ),
      ),
      TextField(
        key: const Key('tsm-grant-secret'),
        controller: secret,
        decoration: InputDecoration(
          labelText: secretLabel,
          helperText: secretHelp,
          isDense: true,
        ),
      ),
      CheckboxListTile(
        key: const Key('tsm-grant-pin'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: pin,
        onChanged: (v) => onPin(v == true),
        title: const Text('Only while the program file is unchanged (pinned)'),
      ),
    ],
  );

  /// The subject [kind] with [path] (and [interpreter], or the [parent]
  /// executable) as the grant names it, or null when a path is missing.
  static String? subjectOf(
    String kind,
    String path,
    String interpreter, [
    String parent = '',
  ]) {
    final p = path.trim();
    if (p.isEmpty) return null;
    if (kind == 'exe-from') {
      final from = parent.trim();
      return from.isEmpty ? null : 'exe-from $from => $p';
    }
    if (kind == 'script') {
      final i = interpreter.trim();
      return i.isEmpty ? null : 'script $i $p';
    }
    return '$kind $p';
  }
}

class _PreApproveTab extends StatefulWidget {
  const _PreApproveTab();

  @override
  State<_PreApproveTab> createState() => _PreApproveState();
}

class _PreApproveState extends State<_PreApproveTab> {
  final _host = TextEditingController();
  final _path = TextEditingController();
  final _interpreter = TextEditingController();
  final _parent = TextEditingController();
  final _secret = TextEditingController();
  final _sshHosts = TextEditingController();
  String _kind = 'exe';
  String _decision = 'allow';
  bool _pin = true;
  bool _ssh = false;
  bool _forward = false;
  String? _message;

  @override
  void dispose() {
    for (final c in [_host, _path, _interpreter, _parent, _secret, _sshHosts]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The grant's secret: as typed, or for the ssh-agent the agent secret of
  /// the keys typed with the hosts and forwarding (protocol.md 7.6); null
  /// with [_message] set when it cannot be one.
  String? _secretOf() {
    final typed = _secret.text.trim();
    if (!_ssh) return typed;
    final ssh = TomSecretsSshGrantSecret(
      typed,
      hosts: [
        for (final h in _sshHosts.text.split(RegExp(r'[,\s]+')))
          if (h.trim().isNotEmpty) h.trim(),
      ],
      forward: _forward,
    );
    if (!ssh.valid) {
      setState(
        () => _message =
            'Forwarding is only for one key and named hosts (DP-49).',
      );
      return null;
    }
    return ssh.text;
  }

  Future<void> _add() async {
    final subject = _GrantFields.subjectOf(
      _kind,
      _path.text,
      _interpreter.text,
      _parent.text,
    );
    if (_host.text.trim().isEmpty ||
        subject == null ||
        _secret.text.trim().isEmpty) {
      setState(() => _message = 'Host, who and secret are needed.');
      return;
    }
    final secret = _secretOf();
    if (secret == null) return;
    final api = TomSecretsClientsApi(
      context.read<TomSecretsServiceConnection>(),
    );
    try {
      await api.addGrant(
        host: _host.text.trim(),
        subject: subject,
        secret: secret,
        decision: _decision,
        pin: _pin ? 'hash' : 'off',
      );
      if (mounted) {
        setState(() => _message = 'Added for ${_host.text.trim()}.');
      }
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _message = tomSecretsDescribeAdminError(e));
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(12),
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 560,
        child: TomSecretsSection(
          title: 'Pre-approve a client for a host',
          icon: Icons.playlist_add_check_rounded,
          children: [
            TextField(
              key: const Key('tsm-grant-host'),
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host',
                isDense: true,
              ),
            ),
            CheckboxListTile(
              key: const Key('tsm-grant-ssh'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _ssh,
              onChanged: (v) => setState(() => _ssh = v == true),
              title: const Text('For the ssh-agent (SSH keys)'),
            ),
            _GrantFields(
              kind: _kind,
              onKind: (k) => setState(() => _kind = k),
              path: _path,
              interpreter: _interpreter,
              parent: _parent,
              secret: _secret,
              pin: _pin,
              onPin: (v) => setState(() => _pin = v),
              secretLabel: _ssh ? 'Keys' : 'Secret',
              secretHelp: _ssh
                  ? "a key entry's reference (store/~uuid or store/path), "
                        'store <name>, or all'
                  : 'a reference (e.g. telegram.bot_token), store <name>, '
                        'or all',
            ),
            if (_ssh) ...[
              TextField(
                key: const Key('tsm-grant-ssh-hosts'),
                controller: _sshHosts,
                decoration: const InputDecoration(
                  labelText: 'Only for these hosts',
                  helperText:
                      'host key fingerprints (SHA256:…, ssh-keygen -lf), '
                      'comma separated; empty: any host',
                  isDense: true,
                ),
              ),
              CheckboxListTile(
                key: const Key('tsm-grant-ssh-forward'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _forward,
                onChanged: (v) => setState(() => _forward = v == true),
                title: const Text(
                  'Also over a forwarded agent (ssh -A); each signature is '
                  'confirmed',
                ),
              ),
            ],
            SegmentedButton<String>(
              key: const Key('tsm-grant-decision'),
              segments: const [
                ButtonSegment(value: 'allow', label: Text('Allow')),
                ButtonSegment(value: 'never', label: Text('Never')),
              ],
              selected: {_decision},
              onSelectionChanged: (s) => setState(() => _decision = s.single),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  key: const Key('tsm-grant-add'),
                  onPressed: () => unawaited(_add()),
                  child: const Text('Add the grant'),
                ),
                const SizedBox(width: 12),
                if (_message != null)
                  Expanded(
                    child: Text(_message!, key: const Key('tsm-grant-message')),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ApprovalCodeTab extends StatefulWidget {
  const _ApprovalCodeTab();

  @override
  State<_ApprovalCodeTab> createState() => _ApprovalCodeState();
}

class _ApprovalCodeState extends State<_ApprovalCodeTab> {
  final _host = TextEditingController();
  final _code = TextEditingController();
  final _path = TextEditingController();
  final _interpreter = TextEditingController();
  final _parent = TextEditingController();
  final _secret = TextEditingController();
  String _kind = 'exe';
  String _decision = 'once';
  bool _pin = true;
  String? _token;
  String? _message;

  @override
  void dispose() {
    for (final c in [_host, _code, _path, _interpreter, _parent, _secret]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _lasting => _decision != 'once';

  Future<void> _issue() async {
    final host = _host.text.trim();
    final code = _code.text.trim();
    if (host.isEmpty || code.isEmpty) {
      setState(() => _message = 'The host and its code are needed.');
      return;
    }
    // A lasting decision is applied from the signed grant only (protocol.md
    // 9.6): the code alone does not say who asks, so the user names it as
    // the waiting host shows it (`tsm approvals`).
    final subject = _lasting
        ? _GrantFields.subjectOf(
            _decision == 'folder' ? 'folder' : _kind,
            _path.text,
            _interpreter.text,
            _parent.text,
          )
        : null;
    if (_lasting && (subject == null || _secret.text.trim().isEmpty)) {
      setState(
        () => _message =
            'A lasting answer needs who asks and the secret, as the host '
            'shows them (tsm approvals).',
      );
      return;
    }
    final api = TomSecretsClientsApi(
      context.read<TomSecretsServiceConnection>(),
    );
    try {
      final token = await api.issueToken(
        host: host,
        code: code,
        decision: _decision,
      );
      if (subject != null) {
        await api.addGrant(
          host: host,
          subject: subject,
          secret: _secret.text.trim(),
          decision: _decision == 'never' ? 'never' : 'allow',
          pin: _pin ? 'hash' : 'off',
        );
      }
      if (mounted) {
        setState(() {
          _token = token;
          _message = subject == null
              ? null
              : 'The grant for $host is written; it applies once the host '
                    'reads the vault again.';
        });
      }
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() {
          _token = null;
          _message = e.kind == 'not_found'
              ? 'This device is not paired with $host.'
              : tomSecretsDescribeAdminError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(12),
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 560,
        child: TomSecretsSection(
          title: 'Answer an approval code',
          icon: Icons.pin_rounded,
          children: [
            const Text(
              'A request waiting on a machine without an attached app shows '
              'a ten-character code. Enter it here and type the token into '
              'that machine: tsm approve <token>.',
            ),
            TextField(
              key: const Key('tsm-code-host'),
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host that shows the code',
                isDense: true,
              ),
            ),
            TextField(
              key: const Key('tsm-code-code'),
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Approval code',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final (value, text) in const [
                  ('once', 'Once'),
                  ('always', 'Always'),
                  ('folder', 'Always for a folder'),
                  ('never', 'Never'),
                ])
                  ChoiceChip(
                    key: Key('tsm-code-decision-$value'),
                    label: Text(text),
                    selected: _decision == value,
                    onSelected: (_) => setState(() => _decision = value),
                  ),
              ],
            ),
            if (_lasting)
              _GrantFields(
                kind: _decision == 'folder' ? 'folder' : _kind,
                onKind: (k) => setState(() => _kind = k),
                path: _path,
                interpreter: _interpreter,
                parent: _parent,
                secret: _secret,
                pin: _pin,
                onPin: (v) => setState(() => _pin = v),
              ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('tsm-code-issue'),
              onPressed: () => unawaited(_issue()),
              child: const Text('Make the token'),
            ),
            if (_token != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    Flexible(
                      child: SelectableText(
                        _token!,
                        key: const Key('tsm-code-token'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: _token!)),
                    ),
                  ],
                ),
              ),
            if (_message != null)
              Text(_message!, key: const Key('tsm-code-message')),
          ],
        ),
      ),
    ),
  );
}

class _AuditTab extends StatefulWidget {
  const _AuditTab();

  @override
  State<_AuditTab> createState() => _AuditState();
}

class _AuditState extends State<_AuditTab> {
  static const _periods = [
    ('1 h', Duration(hours: 1)),
    ('24 h', Duration(hours: 24)),
    ('7 days', Duration(days: 7)),
    ('30 days', Duration(days: 30)),
  ];
  Duration _period = const Duration(hours: 24);
  final _client = TextEditingController();
  final _ref = TextEditingController();
  String? _host;
  String? _outcome;
  List<TomSecretsAuditEntry>? _records;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _client.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = TomSecretsClientsApi(
      context.read<TomSecretsServiceConnection>(),
    );
    final now = DateTime.now();
    try {
      final records = await api.audit(
        from: now.subtract(_period),
        to: now,
        ref: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
      );
      if (mounted) {
        setState(() {
          _records = records;
          _error = null;
        });
      }
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = _records;
    final client = _client.text.trim().toLowerCase();
    final shown = [
      for (final r in records ?? const <TomSecretsAuditEntry>[])
        if ((_host == null || r.host == _host) &&
            (_outcome == null || r.outcome == _outcome) &&
            (client.isEmpty || r.client.toLowerCase().contains(client)))
          r,
    ];
    final hosts = {
      for (final r in records ?? const <TomSecretsAuditEntry>[]) r.host,
      ?_host,
    }.toList()..sort();
    final outcomes = {
      for (final r in records ?? const <TomSecretsAuditEntry>[]) r.outcome,
      ?_outcome,
    }.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<Duration>(
                key: const Key('tsm-audit-period'),
                value: _period,
                isDense: true,
                items: [
                  for (final (label, d) in _periods)
                    DropdownMenuItem(value: d, child: Text('Last $label')),
                ],
                onChanged: (d) {
                  setState(() => _period = d ?? _period);
                  unawaited(_load());
                },
              ),
              DropdownButton<String?>(
                key: const Key('tsm-audit-host'),
                value: _host,
                isDense: true,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Every host'),
                  ),
                  for (final h in hosts)
                    DropdownMenuItem(value: h, child: Text(h)),
                ],
                onChanged: (h) => setState(() => _host = h),
              ),
              DropdownButton<String?>(
                key: const Key('tsm-audit-outcome'),
                value: _outcome,
                isDense: true,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Every outcome'),
                  ),
                  for (final o in outcomes)
                    DropdownMenuItem(value: o, child: Text(o)),
                ],
                onChanged: (o) => setState(() => _outcome = o),
              ),
              SizedBox(
                width: 200,
                child: TextField(
                  key: const Key('tsm-audit-client'),
                  controller: _client,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Client',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  key: const Key('tsm-audit-ref'),
                  controller: _ref,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Reference',
                  ),
                  onSubmitted: (_) => unawaited(_load()),
                ),
              ),
              IconButton(
                tooltip: 'Read again',
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(_load()),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : records == null
              ? const Center(child: CircularProgressIndicator())
              : shown.isEmpty
              ? const Center(child: Text('No records.'))
              : ListView.builder(
                  key: const Key('tsm-audit-list'),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final r = shown[i];
                    final denied = r.outcome != 'allowed';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        denied ? Icons.block : Icons.check_circle_outline,
                        size: 18,
                        color: denied
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                      ),
                      title: Text(r.client),
                      subtitle: Text(
                        '${r.sshText ?? r.refs.join(', ')} · ${r.outcome}'
                        '${r.grantId == null ? '' : ' · grant ${r.grantId}'}',
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          TomSecretsChip(
                            r.host,
                            colour: tomSecretsVaultColour(r.host),
                          ),
                          Text(
                            tomSecretsAge(r.time),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
