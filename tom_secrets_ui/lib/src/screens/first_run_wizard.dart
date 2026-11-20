// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The First run wizard (part-app, Screens › First run; DP-80, DP-83, DP-84,
/// BP-18), opened when the machine is not set up: the primary vault, its
/// protection layers, this machine's settings, then what to do next.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_credentials_ui/tom_credentials_ui.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/first_run_model.dart';
import '../state/service_connection.dart';
import '../widgets/emergency_sheet_offer.dart';
import '../widgets/style.dart';

/// The wizard.
class TomSecretsFirstRunWizard extends StatefulWidget {
  /// The wizard over [model].
  const TomSecretsFirstRunWizard({super.key, required this.model});

  /// Its state.
  final TomSecretsFirstRunModel model;

  @override
  State<TomSecretsFirstRunWizard> createState() => _WizardState();
}

class _WizardState extends State<TomSecretsFirstRunWizard> {
  TomSecretsFirstRunModel get m => widget.model;

  late final _path = TextEditingController(text: m.localPath);
  late final _owner = TextEditingController(text: m.owner);
  late final _repository = TextEditingController(text: m.repository);
  late final _repositoryPath = TextEditingController(text: m.repositoryPath);
  final _password = TextEditingController();
  final _pairAddress = TextEditingController();
  final _pairCode = TextEditingController();
  final _pairLink = TextEditingController();
  final _pairRelay = TextEditingController();
  final _pairRelayToken = TextEditingController();
  final _pairPassword = TextEditingController();
  final _repeat = TextEditingController();
  final _openKey = TomKeyStepController();
  final _repositoryKey = TextEditingController();
  late final _host = TextEditingController(text: m.host);
  final _environment = TextEditingController();
  late final _idle = TextEditingController(text: '${m.idleMinutes}');

  @override
  void initState() {
    super.initState();
    m.addListener(_rebuild);
    _openKey.addListener(() {
      m.password = _openKey.passphrase.text;
      m.openKeyFile = _openKey.keyFile;
      m.changed();
    });
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    m.removeListener(_rebuild);
    for (final c in [
      _pairAddress,
      _pairCode,
      _pairLink,
      _pairRelay,
      _pairRelayToken,
      _pairPassword,
      _path,
      _owner,
      _repository,
      _repositoryPath,
      _password,
      _repeat,
      _repositoryKey,
      _host,
      _environment,
      _idle,
    ]) {
      c.dispose();
    }
    _openKey.dispose();
    super.dispose();
  }

  TomSecretsHost get _host0 => context.read<TomSecretsHost>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = [
      ('The vault', Icons.inventory_2_outlined),
      ('Protection', Icons.shield_outlined),
      ('This machine', Icons.computer_outlined),
      ('Done', Icons.check_circle_outline),
    ];
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const TomSecretsAvatar(
                          icon: Icons.key_rounded,
                          colour: tomSecretsSeed,
                          size: 44,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Set up Tom Secrets Manager',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        for (final (i, (label, icon)) in steps.indexed) ...[
                          if (i > 0)
                            Expanded(
                              child: Divider(
                                indent: 4,
                                endIndent: 4,
                                color: i <= m.step.index
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                            ),
                          TomSecretsChip(
                            i == m.step.index ? '${i + 1}  $label' : '${i + 1}',
                            icon: icon,
                            colour: i == m.step.index
                                ? theme.colorScheme.primary
                                : i < m.step.index
                                ? Colors.green
                                : theme.colorScheme.outline,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 20),
                    switch (m.step) {
                      TomSecretsFirstRunStep.primary => _primaryStep(),
                      TomSecretsFirstRunStep.protection => _protectionStep(),
                      TomSecretsFirstRunStep.machine => _machineStep(),
                      TomSecretsFirstRunStep.done => _doneStep(),
                    },
                    if (m.error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        key: const Key('tsm-fr-error'),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                m.error!,
                                style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    _buttons(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buttons() {
    final c = context.read<TomSecretsServiceConnection>();
    if (m.step == TomSecretsFirstRunStep.done) {
      return FilledButton.icon(
        key: const Key('tsm-fr-finish'),
        onPressed: c.endFirstRun,
        icon: const Icon(Icons.arrow_forward),
        label: Text(
          c.phase == TomSecretsConnectionPhase.attached
              ? 'Open my vaults'
              : 'Continue',
        ),
      );
    }
    final blocker = m.blocker;
    final last = m.step == TomSecretsFirstRunStep.machine;
    return Row(
      children: [
        if (m.step != TomSecretsFirstRunStep.primary)
          TextButton(
            key: const Key('tsm-fr-back'),
            onPressed: m.busy ? null : m.back,
            child: const Text('Back'),
          ),
        const Spacer(),
        if (blocker != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                blocker,
                key: const Key('tsm-fr-blocker'),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        if (m.busy)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          FilledButton(
            key: Key(last ? 'tsm-fr-setup' : 'tsm-fr-next'),
            onPressed: blocker != null
                ? null
                : last
                ? () => unawaited(m.setUp())
                : m.next,
            child: Text(last ? 'Set up this machine' : 'Next'),
          ),
      ],
    );
  }

  // ---- Step 1 ----

  Widget _primaryStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(
            value: false,
            icon: Icon(Icons.inventory_2_outlined),
            label: Text('Set up the vault here', key: Key('tsm-fr-here')),
          ),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.devices_outlined),
            label: Text('Pair with another desktop', key: Key('tsm-fr-pair')),
          ),
        ],
        selected: {m.byPairing},
        onSelectionChanged: (s) {
          _pairPassword.clear();
          m.password = '';
          m.byPairing = s.single;
        },
      ),
      const SizedBox(height: 16),
      if (m.byPairing) _pairingPanel() else _vaultPanel(),
    ],
  );

  Widget _pairingPanel() {
    final theme = Theme.of(context);
    final receipt = m.receipt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'On a desktop that is set up, open Pairing and choose "Pair a '
          'device": it shows an address and a code. This machine gets the '
          'vaults and keys you choose there; you only type the master '
          'password here.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('tsm-fr-pair-address'),
          controller: _pairAddress,
          enabled: receipt == null && !m.receiving,
          decoration: InputDecoration(
            labelText: m.canFind
                ? 'Its address (as shown; leave it empty on the same '
                      'network)'
                : 'Its address (as shown, e.g. 192.168.1.20:47900)',
            prefixIcon: const Icon(Icons.lan_outlined),
          ),
          onChanged: (v) {
            m.pairAddress = v;
            m.changed();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('tsm-fr-pair-code'),
          controller: _pairCode,
          enabled: receipt == null && !m.receiving,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'The code (e.g. 7-guitar-orbit)',
            prefixIcon: Icon(Icons.password_outlined),
          ),
          onChanged: (v) {
            m.pairCode = v;
            m.changed();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('tsm-fr-pair-relay'),
          controller: _pairRelay,
          enabled: receipt == null && !m.receiving,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'The relay it names (optional, e.g. github:owner/repo)',
            helperText:
                'When the other machine is not on this network or the VPN: '
                'the pairing goes through that GitHub repository instead '
                '(tried after the address).',
            prefixIcon: Icon(Icons.hub_outlined),
          ),
          onChanged: (v) {
            m.pairRelay = v;
            m.changed();
          },
        ),
        if (_pairRelay.text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          TextField(
            key: const Key('tsm-fr-pair-relay-token'),
            controller: _pairRelayToken,
            enabled: receipt == null && !m.receiving,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'This machine\'s GitHub token for that repository',
              helperText:
                  'A fine-grained token with contents read and write: the '
                  'pairing needs the repository before it starts. It also '
                  'opens the primary when that lives there.',
              prefixIcon: Icon(Icons.key_outlined),
            ),
            onChanged: (v) {
              m.pairRelayToken = v;
              m.changed();
            },
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          key: const Key('tsm-fr-pair-link'),
          controller: _pairLink,
          enabled: receipt == null && !m.receiving,
          decoration: const InputDecoration(
            labelText: 'This machine\'s approval link (optional)',
            helperText:
                'A VPN or LAN address of this machine and a port, e.g. '
                '10.8.0.6:47731: the other machine then answers this one\'s '
                'prompts. Empty: no link.',
            prefixIcon: Icon(Icons.link),
          ),
          onChanged: (v) {
            m.pairLink = v;
            m.changed();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('tsm-fr-pair-host'),
          controller: _host,
          enabled: receipt == null && !m.receiving,
          decoration: const InputDecoration(
            labelText: 'This machine\'s name',
            prefixIcon: Icon(Icons.computer_outlined),
          ),
          onChanged: (v) {
            m.host = v.trim();
            m.changed();
          },
        ),
        const SizedBox(height: 12),
        if (receipt == null)
          Align(
            alignment: Alignment.centerLeft,
            child: m.receiving
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Waiting for the other machine…'),
                  )
                : FilledButton.tonalIcon(
                    key: const Key('tsm-fr-pair-receive'),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Pair'),
                    onPressed: () => unawaited(m.receive()),
                  ),
          )
        else ...[
          Container(
            key: const Key('tsm-fr-pair-received'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Paired with ${receipt.giver} '
                  '(${m.pairedThrough ?? m.pairAddress}). It gave:',
                  style: theme.textTheme.titleSmall,
                ),
                for (final v in receipt.bundle.vaults)
                  Text(
                    '${v.name}${v.primary ? ' (primary)' : ''} — ${v.locator}',
                  ),
                if (receipt.bundle.configYaml != null)
                  const Text('the shared configuration'),
                for (final t in receipt.bundle.tokens)
                  Text('a GitHub token for ${t.repository}'),
                const SizedBox(height: 4),
                Text(
                  'Nothing is stored before "Set up this machine".',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('tsm-fr-pair-password'),
            controller: _pairPassword,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Master password of the primary vault',
              prefixIcon: Icon(Icons.lock_outline),
            ),
            onChanged: (v) {
              m.password = v;
              m.changed();
            },
          ),
        ],
      ],
    );
  }

  Widget _vaultPanel() {
    final files = _host0.files;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'The primary vault holds your secrets and the keys of every other '
          'vault: unlocking it opens them all.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              icon: Icon(Icons.add_circle_outline),
              label: Text('Create a new vault', key: Key('tsm-fr-create')),
            ),
            ButtonSegment(
              value: false,
              icon: Icon(Icons.folder_open_outlined),
              label: Text('Open an existing one', key: Key('tsm-fr-open')),
            ),
          ],
          selected: {m.create},
          onSelectionChanged: (s) => m.create = s.single,
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.computer_outlined),
              label: Text('On this computer', key: Key('tsm-fr-local')),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.cloud_outlined),
              label: Text('In a GitHub repository', key: Key('tsm-fr-github')),
            ),
          ],
          selected: {m.onGitHub},
          onSelectionChanged: (s) => m.onGitHub = s.single,
        ),
        const SizedBox(height: 12),
        if (!m.onGitHub)
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('tsm-fr-path'),
                  controller: _path,
                  decoration: const InputDecoration(
                    labelText: 'Vault file',
                    prefixIcon: Icon(Icons.description_outlined),
                  ),
                  onChanged: (v) {
                    m.localPath = v;
                    m.changed();
                  },
                ),
              ),
              if (files != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('tsm-fr-choose'),
                  tooltip: 'Choose…',
                  icon: const Icon(Icons.folder_outlined),
                  onPressed: () async {
                    final path = await files.choosePath(
                      save: m.create,
                      suggestedName: 'primary.kdbx',
                    );
                    if (path == null) return;
                    _path.text = path;
                    m.localPath = path;
                    m.changed();
                  },
                ),
              ],
            ],
          )
        else
          ..._gitHubFields(),
        const SizedBox(height: 16),
        Text('Master password', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (m.create) ...[
          TextField(
            key: const Key('tsm-fr-password'),
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Master password',
              prefixIcon: Icon(Icons.password),
            ),
            onChanged: (v) {
              m.password = v;
              m.changed();
            },
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('tsm-fr-repeat'),
            controller: _repeat,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'The same again',
              prefixIcon: Icon(Icons.password),
            ),
            onChanged: (v) {
              m.repeat = v;
              m.changed();
            },
          ),
          const SizedBox(height: 6),
          Text(
            'Nobody can recover it for you: keep it where you keep your '
            'other recovery codes.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ] else
          TomKeyFields(
            controller: _openKey,
            keyPrefix: 'tsm-fr-key',
            keyFiles: _host0.keyFiles,
            offersRemember: false,
          ),
      ],
    );
  }

  List<Widget> _gitHubFields() {
    final check = m.checked;
    String date(DateTime d) => d.toLocal().toString().split(' ').first;
    void repositoryEdited(void Function() set) {
      set();
      m.repositoryChanged();
    }

    return [
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('tsm-fr-owner'),
              controller: _owner,
              decoration: const InputDecoration(labelText: 'Owner'),
              onChanged: (v) => repositoryEdited(() => m.owner = v),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text('/'),
          ),
          Expanded(
            child: TextField(
              key: const Key('tsm-fr-repository'),
              controller: _repository,
              decoration: const InputDecoration(labelText: 'Repository'),
              onChanged: (v) => repositoryEdited(() => m.repository = v),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      TextField(
        key: const Key('tsm-fr-repo-path'),
        controller: _repositoryPath,
        decoration: const InputDecoration(
          labelText: 'File in the repository',
          prefixIcon: Icon(Icons.description_outlined),
        ),
        onChanged: (v) {
          m.repositoryPath = v;
          m.changed();
        },
      ),
      const SizedBox(height: 8),
      Text(
        'The repository is private and has a first commit (create it with a '
        'README). The token is a fine-grained personal access token for this '
        'repository with read and write access to its contents; it is kept '
        'in this machine\'s keychain.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            key: const Key('tsm-fr-token'),
            icon: const Icon(Icons.vpn_key_outlined),
            label: Text(m.hasToken ? 'Replace the token…' : 'Enter a token…'),
            onPressed: () async {
              final token = await showTomTokenDialog(
                context,
                host: tomSecretsGitHubHost,
              );
              if (token != null) await m.storeToken(token);
            },
          ),
          FilledButton.tonalIcon(
            key: const Key('tsm-fr-check'),
            icon: const Icon(Icons.verified_outlined),
            label: const Text('Check the repository'),
            onPressed: m.owner.trim().isEmpty || m.repository.trim().isEmpty
                ? null
                : () async {
                    try {
                      await withTomTokenFlow(
                        context,
                        keeper: m,
                        action: m.checkGitHub,
                      );
                    } on TomSecretsFirstRunException catch (e) {
                      m.fail(e.message);
                    }
                  },
          ),
        ],
      ),
      if (check != null) ...[
        const SizedBox(height: 8),
        Row(
          key: const Key('tsm-fr-checked'),
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'The token sees ${m.owner.trim()}/${m.repository.trim()} '
                '(branch ${check.defaultBranch}). '
                '${m.tokenExpires == null ? 'GitHub reports no expiry.' : 'It expires on ${date(m.tokenExpires!)}.'}',
              ),
            ),
            if (check.expires == null)
              TextButton(
                key: const Key('tsm-fr-expiry'),
                child: Text(
                  m.tokenExpires == null ? 'Set its expiry…' : 'Change…',
                ),
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: now,
                    lastDate: now.add(const Duration(days: 366 * 2)),
                    initialDate:
                        m.tokenExpires?.toLocal() ??
                        now.add(const Duration(days: 90)),
                  );
                  if (picked != null) {
                    m.tokenExpires = picked.toUtc();
                    m.changed();
                  }
                },
              ),
          ],
        ),
      ],
    ];
  }

  // ---- Step 2 ----

  Future<void> _saveCopy(
    String name,
    List<int> bytes,
    void Function() saved,
  ) async {
    final files = _host0.files;
    if (files == null) return;
    if (await files.save(name, Uint8List.fromList(bytes))) {
      saved();
      m.changed();
    }
  }

  Widget _protectionStep() {
    final theme = Theme.of(context);
    final files = _host0.files;
    if (!m.create) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (m.openIsOuter) ...[
            Text(
              '${m.fileName} is outer encrypted. Give its repository key: '
              'it is kept in this machine\'s keychain.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('tsm-fr-repokey'),
                    controller: _repositoryKey,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Repository key (base64)',
                      prefixIcon: Icon(Icons.enhanced_encryption_outlined),
                    ),
                    onChanged: (v) {
                      m.openRepositoryKey = v;
                      m.changed();
                    },
                  ),
                ),
                if (files != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('tsm-fr-repokey-load'),
                    onPressed: () async {
                      final picked = await files.pick();
                      if (picked == null) return;
                      final text = utf8
                          .decode(picked.bytes, allowMalformed: true)
                          .trim();
                      _repositoryKey.text = text;
                      m.openRepositoryKey = text;
                      m.changed();
                    },
                    child: const Text('From a file…'),
                  ),
                ],
              ],
            ),
          ] else
            Text(
              '${m.fileName} has no outer encryption. '
              '${m.openKeyFile == null ? 'No key file was chosen with the password.' : 'The key file ${m.openKeyFile!.name} is kept in this machine\'s keychain.'}',
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Both layers are optional. Each adds a key you must not lose: '
          'without it the vault cannot be opened on another machine.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        TomSecretsSection(
          title: 'Key file',
          icon: Icons.key_outlined,
          trailing: Switch(
            key: const Key('tsm-fr-keyfile-switch'),
            value: m.useKeyFile,
            onChanged: (v) => m.useKeyFile = v,
          ),
          children: [
            const Text(
              'A KeePass key file joins the master password: the vault opens '
              'only with both. It never goes to GitHub; this machine keeps it '
              'in its keychain.',
            ),
            if (m.useKeyFile) ...[
              const SizedBox(height: 8),
              _copyRow(
                key: const Key('tsm-fr-keyfile-save'),
                saved: m.keyFileSaved,
                what: 'the key file',
                onSave: files == null
                    ? null
                    : () => _saveCopy(
                        'primary.keyx',
                        m.newKeyFile!,
                        () => m.keyFileSaved = true,
                      ),
              ),
            ],
          ],
        ),
        TomSecretsSection(
          title: 'Outer encryption',
          icon: Icons.enhanced_encryption_outlined,
          trailing: Switch(
            key: const Key('tsm-fr-outer-switch'),
            value: m.useOuter,
            onChanged: (v) => m.useOuter = v,
          ),
          children: [
            Text(
              'The file is encrypted once more under a repository key '
              '(${m.useOuter ? m.fileName : 'primary.kdbx.tsmx'}), so the '
              'repository holds nothing other KeePass apps or GitHub can '
              'read without it.',
            ),
            if (m.useOuter) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<TomSecretsOuterCipher>(
                key: const Key('tsm-fr-cipher'),
                initialValue: m.cipher,
                decoration: const InputDecoration(labelText: 'Cipher'),
                items: const [
                  DropdownMenuItem(
                    value: TomSecretsOuterCipher.xchacha20Poly1305,
                    child: Text('XChaCha20-Poly1305 (recommended)'),
                  ),
                  DropdownMenuItem(
                    value: TomSecretsOuterCipher.aes256Gcm,
                    child: Text('AES-256-GCM'),
                  ),
                ],
                onChanged: (v) {
                  m.cipher = v!;
                  m.changed();
                },
              ),
              const SizedBox(height: 8),
              _copyRow(
                key: const Key('tsm-fr-repokey-save'),
                saved: m.repositoryKeySaved,
                what: 'the repository key',
                onSave: files == null
                    ? null
                    : () => _saveCopy(
                        'primary.repository-key.txt',
                        utf8.encode('${m.newRepositoryKey!.toBase64()}\n'),
                        () => m.repositoryKeySaved = true,
                      ),
              ),
            ],
          ],
        ),
        if (m.useKeyFile || m.useOuter)
          Text(
            'They are due for rotation in $tomSecretsPrimaryKeyMonths months; '
            'the app reminds you.',
            style: theme.textTheme.bodySmall,
          ),
        if (m.locator != null)
          TomSecretsSection(
            title: 'Emergency sheet',
            icon: Icons.print_outlined,
            children: [
              TomSecretsEmergencySheetOffer(
                sheet: () async => m.emergencySheet,
              ),
            ],
          ),
      ],
    );
  }

  Widget _copyRow({
    required Key key,
    required bool saved,
    required String what,
    required Future<void> Function()? onSave,
  }) => Row(
    children: [
      Icon(
        saved ? Icons.check_circle : Icons.warning_amber_rounded,
        size: 18,
        color: saved ? Colors.green : Colors.orange,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          saved
              ? 'A copy of $what is saved. Keep it offline.'
              : 'Save a copy of $what where you keep your recovery codes.',
        ),
      ),
      if (onSave != null)
        OutlinedButton(
          key: key,
          onPressed: () => unawaited(onSave()),
          child: const Text('Save a copy…'),
        ),
    ],
  );

  // ---- Step 3 ----

  Widget _machineStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('tsm-fr-host'),
        controller: _host,
        // A paired machine keeps the name the other machine recorded.
        enabled: m.receipt == null,
        decoration: const InputDecoration(
          labelText: 'This machine\'s name',
          prefixIcon: Icon(Icons.computer_outlined),
        ),
        onChanged: (v) {
          m.host = v.trim();
          m.changed();
        },
      ),
      const SizedBox(height: 8),
      TextField(
        key: const Key('tsm-fr-env'),
        controller: _environment,
        decoration: const InputDecoration(
          labelText: 'Default environment (optional, e.g. prod)',
          prefixIcon: Icon(Icons.layers_outlined),
        ),
        onChanged: (v) => m.defaultEnvironment = v,
      ),
      SwitchListTile(
        key: const Key('tsm-fr-served'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Serve only the primary vault'),
        subtitle: const Text(
          'Off: this machine serves every vault the primary lists.',
        ),
        value: m.servesPrimaryOnly,
        onChanged: (v) {
          m.servesPrimaryOnly = v;
          m.changed();
        },
      ),
      const SizedBox(height: 4),
      Text('Lock', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<TomSecretsFirstRunLock>(
            segments: const [
              ButtonSegment(
                value: TomSecretsFirstRunLock.idle,
                label: Text('When idle', key: Key('tsm-fr-lock-idle')),
              ),
              ButtonSegment(
                value: TomSecretsFirstRunLock.never,
                label: Text('Never on its own', key: Key('tsm-fr-lock-never')),
              ),
            ],
            selected: {m.lock},
            onSelectionChanged: (s) {
              m.lock = s.single;
              m.changed();
            },
          ),
          if (m.lock == TomSecretsFirstRunLock.idle)
            SizedBox(
              width: 140,
              child: TextField(
                key: const Key('tsm-fr-idle'),
                controller: _idle,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Minutes'),
                onChanged: (v) {
                  m.idleMinutes = int.tryParse(v.trim()) ?? 0;
                  m.changed();
                },
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      ExpansionTile(
        key: const Key('tsm-fr-advanced'),
        tilePadding: EdgeInsets.zero,
        title: const Text('Advanced'),
        children: [
          DropdownButtonFormField<TomSecretsDeviceKeyMode>(
            key: const Key('tsm-fr-device-key'),
            initialValue: m.deviceKey,
            decoration: const InputDecoration(
              labelText: 'Where the device settings\' key is kept',
            ),
            items: const [
              DropdownMenuItem(
                value: TomSecretsDeviceKeyMode.auto,
                child: Text('The keychain where there is one, else the vault'),
              ),
              DropdownMenuItem(
                value: TomSecretsDeviceKeyMode.keychain,
                child: Text('The keychain'),
              ),
              DropdownMenuItem(
                value: TomSecretsDeviceKeyMode.vault,
                child: Text('The primary vault'),
              ),
              DropdownMenuItem(
                value: TomSecretsDeviceKeyMode.keyfile,
                child: Text('A key file beside the settings'),
              ),
            ],
            onChanged: (v) {
              m.deviceKey = v!;
              m.changed();
            },
          ),
        ],
      ),
    ],
  );

  // ---- Step 4 ----

  Widget _doneStep() {
    final result = m.result;
    final actions = _host0.firstRunActions;
    final theme = Theme.of(context);
    String date(DateTime d) => d.toLocal().toString().split(' ').first;
    Widget offer(String id, String title, String text, IconData icon) {
      final action = actions[id];
      return Card(
        child: ListTile(
          key: Key('tsm-fr-offer-$id'),
          enabled: action != null,
          leading: TomSecretsAvatar(
            icon: icon,
            colour: tomSecretsVaultColour(id),
          ),
          title: Text(title),
          subtitle: Text(
            action == null ? 'Not available in this version yet.' : text,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: action == null ? null : () => unawaited(action(context)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result != null) ...[
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.created
                      ? 'This machine is set up with a new primary vault.'
                      : m.receipt != null
                      ? 'This machine is set up by pairing with '
                            '${m.receipt!.giver}.'
                      : 'This machine is set up with your primary vault.',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(m.primaryLocatorText ?? '', key: const Key('tsm-fr-summary')),
          if (result.keysDue != null)
            Text(
              'Its key file and repository key are due on '
              '${date(result.keysDue!)}.',
            ),
          if (result.githubTokenExpires != null)
            Text(
              'The GitHub token expires on '
              '${date(result.githubTokenExpires!)}; the app reminds you '
              'before.',
            ),
          const SizedBox(height: 16),
        ],
        Text('Next', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        offer(
          TomSecretsFirstRunActions.import,
          'Import from 1Password or Enpass',
          'Bring your items over from an export.',
          Icons.move_to_inbox_outlined,
        ),
        offer(
          TomSecretsFirstRunActions.pair,
          'Pair another desktop',
          'Give another machine the keys it needs, over the LAN or the VPN.',
          Icons.devices_outlined,
        ),
      ],
    );
  }
}
