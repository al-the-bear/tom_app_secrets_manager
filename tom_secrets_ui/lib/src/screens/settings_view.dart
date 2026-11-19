// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Settings screen (part-app, Screens › Settings, phase A): each setting
/// says whose it is.
///
/// - **This machine's service** (the device settings, `settings.get` /
///   `settings.set`): the files served and the default environment, the lock
///   mode with its timeouts, the approval timeout and the code's validity,
///   the pull interval, the offline cache, the reminder period, the approval
///   link; and command-line approvals (DP-19), switchable only here.
/// - **This machine's app**: screen capture (DP-33), start at login (DP-30),
///   stopping the service.
/// - **Shared**, in the primary vault: the dimensions with their priority and
///   the files per environment (`tsm.config`, BP-43).
///
/// - **Integrations** (part-os-integration): ssh using the service's agent
///   (`IdentityAgent` in `~/.ssh/config`, its host patterns editable) and
///   git asking `git-credential-tsm`, each a marked block written and
///   removed by the client library; what is not right is said.
///
/// The keys (protection layers, the GitHub token, rotation ages) are on the
/// Keys screen.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_ui_support/tom_ui_support.dart' show tomShowNotice;
import 'package:tom_secrets_client/admin.dart'
    show
        TomSecretsAdminException,
        TomSecretsBrowser,
        TomSecretsBrowserHostState,
        TomSecretsIntegration,
        TomSecretsIntegrationState;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../host_bridge.dart' show TomSecretsHostPreferenceKeys;
import '../ports/desktop_ports.dart';
import '../state/clients.dart';
import '../state/autofill.dart';
import '../state/integrations.dart';
import '../state/os_unlock.dart';
import '../state/service_connection.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// The Settings screen.
class TomSecretsSettingsView extends StatefulWidget {
  /// The screen.
  const TomSecretsSettingsView({super.key});

  @override
  State<TomSecretsSettingsView> createState() => _SettingsState();
}

class _SettingsState extends State<TomSecretsSettingsView> {
  TomSecretsSettingsReport? _report;
  Map<String, Object?> _draft = const {};
  String? _error;
  String? _deviceMessage;
  bool? _loginItem;
  late final TextEditingController _config;
  String? _configError;
  final _link = TextEditingController();
  final _sshHosts = TextEditingController(text: '*');
  Map<TomSecretsIntegration, TomSecretsIntegrationState>? _integrations;
  String? _integrationError;

  TomSecretsClientsApi get _api =>
      TomSecretsClientsApi(context.read<TomSecretsServiceConnection>());

  @override
  void initState() {
    super.initState();
    _config = TextEditingController(
      text: context.read<TomSecretsSession>().sharedConfigYaml ?? '',
    );
    unawaited(_load());
    unawaited(context.read<TomSecretsOsUnlock>().refresh());
    final login = context.read<TomSecretsHost>().loginItem;
    if (login != null) {
      unawaited(
        login.isEnabled().then((on) {
          if (mounted) setState(() => _loginItem = on);
        }),
      );
    }
  }

  @override
  void dispose() {
    _config.dispose();
    _link.dispose();
    _sshHosts.dispose();
    super.dispose();
  }

  List<TomSecretsBrowserHostState>? _browsers;

  Future<void> _loadBrowsers() async {
    final hosts = tomSecretsBrowserHostsOf(context.read<TomSecretsHost>());
    if (hosts == null) return;
    final states = await hosts.states();
    if (mounted) setState(() => _browsers = states);
  }

  Future<void> _switchBrowser(TomSecretsBrowser browser, bool on) async {
    final hosts = tomSecretsBrowserHostsOf(context.read<TomSecretsHost>());
    if (hosts == null) return;
    try {
      if (on) {
        await hosts.install(browser);
      } else {
        await hosts.remove(browser);
      }
      if (mounted) setState(() => _integrationError = null);
    } on Object catch (e) {
      if (mounted) setState(() => _integrationError = '$e');
    }
    await _loadBrowsers();
  }

  Future<void> _loadIntegrations() async {
    unawaited(_loadBrowsers());
    // The provider may have been turned on in System Settings meanwhile.
    unawaited(context.read<TomSecretsAutofill?>()?.refresh());
    final integrations = await tomSecretsIntegrationsOf(
      context.read<TomSecretsHost>(),
      context.read<TomSecretsServiceConnection>(),
    );
    if (integrations == null) return;
    final states = {
      for (final i in TomSecretsIntegration.values)
        i: await integrations.status(i),
    };
    if (!mounted) return;
    setState(() {
      _integrations = states;
      final hosts = states[TomSecretsIntegration.ssh]?.hosts;
      if (hosts != null) _sshHosts.text = hosts;
    });
  }

  Future<void> _switchIntegration(
    TomSecretsIntegration integration,
    bool on,
  ) async {
    final integrations = await tomSecretsIntegrationsOf(
      context.read<TomSecretsHost>(),
      context.read<TomSecretsServiceConnection>(),
    );
    if (integrations == null) return;
    try {
      if (on) {
        final hosts = _sshHosts.text.trim();
        await integrations.install(
          integration,
          hosts: integration == TomSecretsIntegration.ssh && hosts.isNotEmpty
              ? hosts
              : null,
        );
      } else {
        await integrations.uninstall(integration);
      }
      if (mounted) setState(() => _integrationError = null);
    } on Object catch (e) {
      if (mounted) setState(() => _integrationError = '$e');
    }
    await _loadIntegrations();
  }

  Future<void> _load() async {
    unawaited(_loadIntegrations());
    try {
      final report = await _api.settings();
      if (!mounted) return;
      setState(() {
        _report = report;
        _draft = report.device.toJson();
        _link.text = report.device.approvalLink ?? '';
        _error = null;
      });
    } on TomSecretsAdminException catch (e) {
      if (mounted) setState(() => _error = tomSecretsDescribeAdminError(e));
    }
  }

  void _set(String key, Object? value) => setState(() {
    _draft = {..._draft};
    if (value == null) {
      _draft.remove(key);
    } else {
      _draft[key] = value;
    }
    _deviceMessage = null;
  });

  Map<String, Object?> get _lock =>
      (_draft['serviceLock'] as Map? ?? const {}).cast<String, Object?>();

  void _setLock(String key, Object? value) {
    final lock = {..._lock};
    if (value == null) {
      lock.remove(key);
    } else {
      lock[key] = value;
    }
    _set('serviceLock', lock);
  }

  Future<void> _saveDevice() async {
    final link = _link.text.trim();
    final draft = {..._draft};
    if (link.isEmpty) {
      draft.remove('approvalLink');
    } else {
      draft['approvalLink'] = link;
    }
    try {
      final later = await _api.writeSettings(
        TomSecretsDeviceSettings.fromJson(draft),
      );
      if (!mounted) return;
      // Lock mode (c) keeps the session's OS unlock now, so the next lock
      // opens with it; another mode forgets it.
      final connection = context.read<TomSecretsServiceConnection>();
      final osUnlock = context.read<TomSecretsOsUnlock>();
      await connection.refreshStatus();
      if (connection.lockMode == 'c') {
        await osUnlock.keep();
      } else {
        await osUnlock.forgetSession();
      }
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _deviceMessage = later.isEmpty
            ? 'Saved; in effect now.'
            : 'Saved. ${later.map(_settingName).join(', ')} '
                  '${later.length == 1 ? 'applies' : 'apply'} at the next '
                  'unlock.';
      });
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() => _deviceMessage = tomSecretsDescribeAdminError(e));
      }
    }
  }

  static String _settingName(String key) => switch (key) {
    'servedStores' => 'The files served',
    'defaultEnvironment' => 'the default environment',
    'approvalLink' => 'the approval link',
    _ => key,
  };

  Future<void> _setCli(bool on) async {
    try {
      await _api.setCliApprovals(on);
      await _load();
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        tomShowNotice(
          ScaffoldMessenger.maybeOf(context),
          kind: 'settings',
          message: tomSecretsDescribeAdminError(e),
        );
      }
    }
  }

  Future<void> _saveConfig() async {
    final session = context.read<TomSecretsSession>();
    try {
      await session.saveSharedConfig(_config.text);
      if (mounted) setState(() => _configError = null);
      if (mounted) {
        tomShowNotice(
          ScaffoldMessenger.maybeOf(context),
          kind: 'settings',
          message: 'The shared configuration is saved in the primary vault.',
        );
      }
    } on TomSecretsConfigException catch (e) {
      if (mounted) setState(() => _configError = e.message);
    } on TomSecretsAdminException catch (e) {
      if (mounted) {
        setState(() => _configError = tomSecretsDescribeAdminError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = context.read<TomSecretsHost>();
    final session = context.watch<TomSecretsSession>();
    return ListView(
      key: const Key('tsm-settings'),
      padding: const EdgeInsets.all(12),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 720,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _device(context, session),
                _app(context, host),
                if (host.integrationPaths != null) _integrationsSection(theme),
                ?_autofillSection(theme),
                _shared(context, theme),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _whose(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _device(BuildContext context, TomSecretsSession session) {
    final report = _report;
    if (_error != null) {
      return TomSecretsSection(
        title: 'This machine',
        icon: Icons.dns_rounded,
        children: [Text(_error!)],
      );
    }
    if (report == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final served = (_draft['servedStores'] as List?)?.cast<String>();
    final primary = report.stores.firstOrNull;
    final envs = {
      ...session.resolution.config.stores.keys,
      ?_draft['defaultEnvironment'] as String?,
    }.toList()..sort();
    final lock = _lock;
    final never = lock['mode'] == 'never';
    final mode = (lock['mode'] as String?) ?? 'idle';
    final os = context.watch<TomSecretsOsUnlock>();
    int seconds(String key, int fallback) =>
        _draft[key] is int ? _draft[key]! as int : fallback;
    return TomSecretsSection(
      title: 'This machine',
      icon: Icons.dns_rounded,
      children: [
        _whose('Kept in this machine\'s device settings, by its service.'),
        SwitchListTile(
          key: const Key('tsm-settings-serve-all'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Serve every file the primary vault names'),
          value: served == null,
          onChanged: (all) => _set(
            'servedStores',
            all ? null : [for (final s in report.stores.skip(1)) s],
          ),
        ),
        if (served != null)
          Wrap(
            spacing: 6,
            children: [
              if (primary != null)
                FilterChip(
                  label: Text('$primary (primary)'),
                  selected: true,
                  onSelected: null,
                ),
              for (final s in report.stores.skip(1))
                FilterChip(
                  key: Key('tsm-settings-serve-$s'),
                  label: Text(s),
                  selected: served.contains(s),
                  onSelected: (on) => _set('servedStores', [
                    for (final x in report.stores.skip(1))
                      if (x == s ? on : served.contains(x)) x,
                  ]),
                ),
            ],
          ),
        Row(
          children: [
            const Text('Default environment  '),
            DropdownButton<String?>(
              key: const Key('tsm-settings-env'),
              value: _draft['defaultEnvironment'] as String?,
              isDense: true,
              items: [
                const DropdownMenuItem(value: null, child: Text('none')),
                for (final e in envs)
                  DropdownMenuItem(value: e, child: Text(e)),
              ],
              onChanged: (e) => _set('defaultEnvironment', e),
            ),
          ],
        ),
        const Divider(),
        Row(
          children: [
            const Text('The service locks  '),
            Flexible(
              child: SegmentedButton<String>(
                key: const Key('tsm-settings-lock'),
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(
                    value: 'idle',
                    label: Text('(b) when idle'),
                  ),
                  const ButtonSegment(value: 'never', label: Text('(a) never')),
                  if (os.host != null)
                    ButtonSegment(
                      value: 'osUnlock',
                      enabled: os.offered || mode == 'osUnlock',
                      label: Text('(c) idle or screen lock, ${os.label}'),
                    ),
                ],
                selected: {mode},
                onSelectionChanged: (s) => _setLock('mode', s.single),
              ),
            ),
          ],
        ),
        _osUnlockNote(os, mode),
        if (!never)
          _number(
            'tsm-settings-idle',
            'Idle minutes before it locks',
            ((lock['idleSeconds'] as int?) ?? 1800) ~/ 60,
            (v) => _setLock('idleSeconds', v * 60),
            min: 1,
          ),
        SwitchListTile(
          key: const Key('tsm-settings-lock-sleep'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Lock when the system sleeps'),
          value: lock['lockOnSleep'] == true,
          onChanged: (v) => _setLock('lockOnSleep', v),
        ),
        _number(
          'tsm-settings-max',
          'Longest unlocked time, hours (0: no limit)',
          ((lock['maxUnlockedSeconds'] as int?) ?? 0) ~/ 3600,
          (v) => _setLock('maxUnlockedSeconds', v == 0 ? null : v * 3600),
        ),
        _number(
          'tsm-settings-approval-timeout',
          'Seconds a request waits for an approval',
          seconds('approvalTimeoutSeconds', 60),
          (v) => _set('approvalTimeoutSeconds', v),
          min: 5,
        ),
        _number(
          'tsm-settings-code-timeout',
          'Minutes an approval code is valid',
          seconds('codeTimeoutSeconds', 300) ~/ 60,
          (v) => _set('codeTimeoutSeconds', v * 60),
          min: 1,
        ),
        _number(
          'tsm-settings-refresh',
          'Minutes between pulls of the GitHub vaults (0: off)',
          seconds('refreshMinutes', 5),
          (v) => _set('refreshMinutes', v),
        ),
        SwitchListTile(
          key: const Key('tsm-settings-cache'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Keep the last fetched vault files as an offline '
            'cache',
          ),
          value: _draft['offlineCache'] != false,
          onChanged: (v) => _set('offlineCache', v),
        ),
        _number(
          'tsm-settings-reminders',
          'Days before a key expires that the reminders start',
          seconds('keyExpiryWarningDays', 14),
          (v) => _set('keyExpiryWarningDays', v),
          min: 1,
        ),
        TextField(
          key: const Key('tsm-settings-link'),
          controller: _link,
          decoration: const InputDecoration(
            isDense: true,
            labelText:
                'Approval link address (VPN or LAN address:port; '
                'empty: no link)',
          ),
          onChanged: (_) => setState(() => _deviceMessage = null),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              key: const Key('tsm-settings-save'),
              onPressed: () => unawaited(_saveDevice()),
              child: const Text('Save'),
            ),
            const SizedBox(width: 12),
            if (_deviceMessage != null)
              Expanded(
                child: Text(
                  _deviceMessage!,
                  key: const Key('tsm-settings-message'),
                ),
              ),
          ],
        ),
        const Divider(),
        SwitchListTile(
          key: const Key('tsm-settings-cli'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Command-line approvals'),
          subtitle: const Text(
            'Let tsm allow and tsm approve-code on this machine pre-approve '
            'clients and make approval tokens, so agents can set up '
            'environments without a person. Off by default; switched only '
            'here.',
          ),
          value: report.cliApprovals,
          onChanged: (on) => unawaited(_setCli(on)),
        ),
      ],
    );
  }

  /// Under the lock mode: what the OS unlock is here (part-os-unlock), and
  /// the saved master password (BP-37).
  Widget _osUnlockNote(TomSecretsOsUnlock os, String mode) {
    final muted = TextStyle(color: Theme.of(context).hintColor);
    if (os.host == null) {
      return Text(
        'This machine has no OS unlock (on Linux the master password is the '
        'only unlock): lock mode (c) and a saved master password are not '
        'offered.',
        key: const Key('tsm-settings-os-unlock-none'),
        style: muted,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!os.offered)
          Text(
            '${os.label} is not set up here or cannot be used now (a remote '
            'session): lock mode (c) and a saved master password need it.',
            key: const Key('tsm-settings-os-unlock-unavailable'),
            style: muted,
          ),
        if (os.offered && os.gateOnly)
          Text(
            '${os.label} here is the weaker, gate-only form: it guards the '
            'unlock, but the unlock is kept in the login keychain, where a '
            'program running as you can read it without ${os.label}. The '
            'key-bound form comes with a team-signed build of the app.',
            key: const Key('tsm-settings-os-unlock-gate-only'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (mode == 'osUnlock')
          Text(
            'In mode (c) the first unlock with the master password is kept '
            'under ${os.label} until the service stops or you lock '
            'completely (the tray).',
            style: muted,
          ),
        SwitchListTile(
          key: const Key('tsm-settings-os-unlock-saved'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Remember the master password of ${os.primary ?? 'the primary'} '
            'with ${os.label}',
          ),
          subtitle: const Text(
            'On this machine only, and it unlocks after restarts too. It '
            'opens the vault even when the password is forgotten, so on this '
            'machine a new one could be set.',
          ),
          value: os.saved,
          onChanged: os.offered && !os.busy
              ? (on) => unawaited(os.setSaved(on))
              : null,
        ),
        if (os.message != null)
          Text(
            os.message!,
            key: const Key('tsm-settings-os-unlock-message'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }

  Widget _number(
    String key,
    String label,
    int value,
    ValueChanged<int> onChanged, {
    int min = 0,
  }) => Row(
    children: [
      Expanded(child: Text(label)),
      IconButton(
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.remove),
        onPressed: value <= min ? null : () => onChanged(value - 1),
      ),
      SizedBox(
        width: 48,
        child: Text(
          '$value',
          key: Key(key),
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      IconButton(
        key: Key('$key-more'),
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add),
        onPressed: () => onChanged(value + 1),
      ),
    ],
  );

  Widget _app(BuildContext context, TomSecretsHost host) {
    final guard = host.captureGuard;
    final excluded =
        host.preferences.read(TomSecretsHostPreferenceKeys.captureExcluded) !=
        'off';
    return TomSecretsSection(
      title: 'This app',
      icon: Icons.desktop_windows_rounded,
      children: [
        _whose('Kept in this machine\'s app preferences.'),
        SwitchListTile(
          key: const Key('tsm-settings-capture'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Keep the window out of screenshots and screen '
            'sharing',
          ),
          subtitle: guard.supported
              ? null
              : const Text('This system cannot exclude a window (Linux).'),
          value: excluded,
          onChanged: guard.supported
              ? (on) async {
                  await host.preferences.write(
                    TomSecretsHostPreferenceKeys.captureExcluded,
                    on ? 'on' : 'off',
                  );
                  await guard.setExcluded(on);
                  if (mounted) setState(() {});
                }
              : null,
        ),
        if (host.loginItem case final login?)
          SwitchListTile(
            key: const Key('tsm-settings-login'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Start the app at login, in the tray'),
            value: _loginItem ?? false,
            onChanged: _loginItem == null
                ? null
                : (on) async {
                    await login.setEnabled(on);
                    final now = await login.isEnabled();
                    if (mounted) setState(() => _loginItem = now);
                  },
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('tsm-settings-stop'),
            icon: const Icon(Icons.power_settings_new),
            label: const Text('Stop the service'),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Stop the secrets service?'),
                  content: const Text(
                    'Programs on this machine get no secrets until the '
                    'service is started and unlocked again.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('tsm-settings-stop-confirm'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Stop'),
                    ),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                // The session's OS unlock ends with the service.
                await context.read<TomSecretsOsUnlock>().forgetSession();
                if (!context.mounted) return;
                await context.read<TomSecretsServiceConnection>().stopService();
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _integrationsSection(ThemeData theme) {
    final states = _integrations;
    Widget row(TomSecretsIntegration integration, String title, String what) {
      final state = states?[integration];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: Key('tsm-integration-${integration.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(title),
            subtitle: Text(
              state == null
                  ? what
                  : '$what\n${state.file}'
                        '${state.installed && !state.current ? ' — needs repair' : ''}',
            ),
            value: state?.installed ?? false,
            onChanged: state == null
                ? null
                : (v) => unawaited(_switchIntegration(integration, v)),
          ),
          for (final p in state?.problems ?? const <String>[])
            Text(
              p,
              key: Key('tsm-integration-${integration.name}-problem'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      );
    }

    final ssh = states?[TomSecretsIntegration.ssh];
    return TomSecretsSection(
      key: const Key('tsm-settings-integrations'),
      title: 'Integrations',
      icon: Icons.extension_rounded,
      children: [
        _whose(
          "This user's tool configuration on this machine; each is a marked "
          'block (# >>> tom secrets >>>) the app writes and removes; nothing '
          'outside it changes.',
        ),
        row(
          TomSecretsIntegration.ssh,
          'ssh uses the ssh-agent',
          'IdentityAgent in ~/.ssh/config: ssh, git, scp and rsync sign '
              'with the vaults\' SSH keys.',
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('tsm-integration-ssh-hosts'),
                controller: _sshHosts,
                decoration: const InputDecoration(
                  labelText: 'For the hosts (ssh Host patterns)',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('tsm-integration-ssh-apply'),
              onPressed: ssh?.installed ?? false
                  ? () => unawaited(
                      _switchIntegration(TomSecretsIntegration.ssh, true),
                    )
                  : null,
              child: const Text('Apply'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        row(
          TomSecretsIntegration.git,
          'git asks Tom Secrets Manager for credentials',
          'credential.helper tsm in ~/.gitconfig and git-credential-tsm '
              'beside tsm: git takes the login of its host from the vaults.',
        ),
        ..._browserRows(theme),
        if (_integrationError != null)
          Text(
            _integrationError!,
            key: const Key('tsm-integration-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }

  /// Password AutoFill on macOS (part-os-integration, DP-50, DP-51): whether
  /// this build has the provider, whether it is turned on in System
  /// Settings (with the way there), the app's switch (off deletes the
  /// snapshot, its key and the QuickType identities) and QuickType.
  Widget? _autofillSection(ThemeData theme) {
    final autofill = context.watch<TomSecretsAutofill?>();
    if (autofill == null) return null;
    final state = autofill.state;
    return TomSecretsSection(
      key: const Key('tsm-settings-autofill'),
      title: 'Password AutoFill',
      icon: Icons.password_rounded,
      children: [
        _whose(
          "macOS fills logins in apps and Safari through the app's AutoFill "
          'provider. It reads an encrypted copy of the logins of the personal '
          'and shared vaults on this Mac (never a system vault\'s), each use '
          'after Touch ID or your login password.',
        ),
        if (!state.available)
          Text(
            state.unavailableReason ?? 'This build has no AutoFill provider.',
            key: const Key('tsm-autofill-unavailable'),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  state.providerEnabled
                      ? 'Tom Secrets Manager is turned on as an AutoFill '
                            'provider in System Settings.'
                      : 'Turn on Tom Secrets Manager in System Settings › '
                            'General › AutoFill & Passwords (macOS 15; '
                            'Passwords › Password Options before).',
                  key: const Key('tsm-autofill-system'),
                ),
              ),
              TextButton(
                key: const Key('tsm-autofill-open-settings'),
                onPressed: () => unawaited(autofill.openSettings()),
                child: const Text('Open System Settings'),
              ),
            ],
          ),
          SwitchListTile(
            key: const Key('tsm-autofill-enabled'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Fill passwords with Tom Secrets Manager'),
            subtitle: Text(
              autofill.lastWritten == null
                  ? 'Off deletes the copy and its key from this Mac.'
                  : 'Copy written ${TimeOfDay.fromDateTime(autofill.lastWritten!).format(context)}; '
                        'off deletes it and its key from this Mac.',
            ),
            value: autofill.enabled,
            onChanged: (v) => unawaited(autofill.setEnabled(v)),
          ),
          SwitchListTile(
            key: const Key('tsm-autofill-quicktype'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('QuickType suggestions'),
            subtitle: const Text(
              'The keyboard suggests the login of the site (its site and user '
              'name are registered with macOS, never a password).',
            ),
            value: autofill.quickType,
            onChanged: autofill.enabled
                ? (v) => unawaited(autofill.setQuickType(v))
                : null,
          ),
          if (autofill.error case final error?)
            Text(
              error,
              key: const Key('tsm-autofill-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ],
    );
  }

  /// The browsers (part-browser): a switch per browser found on this
  /// machine (or with a manifest installed), writing the native-messaging
  /// manifest that names the browser host beside the service; a browser in
  /// a Flatpak or Snap is named, not offered.
  List<Widget> _browserRows(ThemeData theme) {
    final browsers = _browsers;
    if (browsers == null) return const [];
    final host = context
        .read<TomSecretsHost>()
        .integrationPaths
        ?.browserHostExecutable;
    final missing = host != null && !File(host).existsSync();
    final shown = [
      for (final b in browsers)
        if (b.present || b.installed || b.sandboxed != null) b,
    ];
    return [
      const SizedBox(height: 8),
      Text('Browsers', style: theme.textTheme.titleSmall),
      _whose(
        'The browser extension reaches the vaults through the browser host, '
        'which the browser starts by its native-messaging manifest.',
      ),
      if (missing)
        Text(
          'The browser host is not beside the service ($host): this build '
          'has none.',
          key: const Key('tsm-browser-host-missing'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      if (shown.isEmpty)
        const Text(
          'No Chrome, Chromium, Edge, Brave or Firefox found for this user.',
          key: Key('tsm-browsers-none'),
        ),
      for (final b in shown)
        if (b.sandboxed case final reason?)
          ListTile(
            key: Key('tsm-browser-${b.browser.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(b.browser.label),
            subtitle: Text(reason),
          )
        else
          SwitchListTile(
            key: Key('tsm-browser-${b.browser.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(b.browser.label),
            subtitle: Text(
              '${b.manifest}'
              '${b.installed && !b.current ? ' — needs repair: ${b.problems.join(', ')}' : ''}',
            ),
            value: b.installed,
            onChanged: missing
                ? null
                : (v) => unawaited(_switchBrowser(b.browser, v)),
          ),
    ];
  }

  Widget _shared(BuildContext context, ThemeData theme) => TomSecretsSection(
    title: 'Shared by every device',
    icon: Icons.hub_rounded,
    children: [
      _whose(
        'Kept in the primary vault (tsm.config): the dimensions in '
        'priority order and the files per environment.',
      ),
      TextField(
        key: const Key('tsm-settings-config'),
        controller: _config,
        maxLines: 14,
        minLines: 6,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: InputDecoration(
          hintText:
              'dimensions:\n  - name: host\n  - name: env\n'
              '    default: dev\nstores:\n  prod:\n    - name: prod\n'
              '      github: {repository: owner/vault, path: prod.kdbx}',
          errorText: _configError,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          key: const Key('tsm-settings-config-save'),
          onPressed: () => unawaited(_saveConfig()),
          child: const Text('Save in the primary vault'),
        ),
      ),
    ],
  );
}
