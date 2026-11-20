// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The shell once unlocked (part-app, Navigation): the rail on the left,
/// the top bar (search over every open vault, the tree/list and the
/// vault-aware/uniform switches, the sync
/// status of the GitHub vaults, the pending-approvals and key-expiry badges,
/// the lock button) and the keyboard shortcuts.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_core_sync/tom_core_sync.dart' show TomSyncState;
import 'package:tom_sync_ui/tom_sync_ui.dart';
import 'package:tom_ui_support/tom_ui_support.dart' show tomShowNotice;

import '../ports/desktop_ports.dart';
import '../state/entry_requests.dart';
import '../state/auto_type.dart';
import '../state/health.dart';
import '../state/integrations.dart';
import '../state/reminders.dart';
import '../state/service_connection.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'approval_prompt.dart';
import 'clients_view.dart';
import 'conflicts_view.dart';
import 'import_view.dart';
import 'keys_view.dart';
import 'pairing_view.dart';
import 'health_view.dart';
import 'proposals_view.dart';
import 'quick_access.dart';
import 'environments_view.dart';
import 'settings_view.dart';
import 'sharing_view.dart';
import 'status_view.dart';
import 'vault_browser.dart';

/// The rail's destinations.
enum TomSecretsDestination {
  /// The vault browser.
  vaults,

  /// The same keys across the environments' files.
  environments,

  /// The unsettled merge conflicts.
  conflicts,

  /// The approvals, the allow list, approval codes and the audit log.
  clients,

  /// The logins the browser extension and git's helper proposed.
  proposals,

  /// The health report: weak, reused, old, expiring, breached, short keys.
  health,

  /// The keys with their dates, the rotation ages.
  keys,

  /// Pairing another device, the paired devices (part-sharing).
  pairing,

  /// The user's member key and the directory of members (part-sharing,
  /// phase C).
  sharing,

  /// Importing an export of another password manager.
  import,

  /// The settings.
  settings,

  /// The Status screen.
  status,
}

/// The shell.
class TomSecretsMainShell extends StatefulWidget {
  /// The shell; [clipboard] is the protected clipboard.
  const TomSecretsMainShell({super.key, required this.clipboard});

  /// The protected clipboard.
  final TomProtectedClipboard clipboard;

  @override
  State<TomSecretsMainShell> createState() => _MainShellState();
}

class _MainShellState extends State<TomSecretsMainShell> {
  final FocusNode _search = FocusNode(debugLabel: 'search');
  final TextEditingController _query = TextEditingController();
  TomSecretsDestination _destination = TomSecretsDestination.vaults;
  final Set<String> _prompted = {};
  bool _promptOpen = false;
  TomSecretsServiceConnection? _connection;
  TomSecretsEntryRequests? _requests;
  TomSecretsSession? _session;
  TomSecretsHealth? _health;
  int _healthShown = 0;
  TomSecretsQuickAccess? _quickAccess;
  TomSecretsQuickAccessRequest? _quickShown;

  /// Quick access asked for its popup (a hotkey, the tray): shown once.
  void _showQuickAccess() {
    final request = _quickAccess?.request;
    if (request == null || identical(request, _quickShown) || !mounted) {
      return;
    }
    _quickShown = request;
    unawaited(
      tomSecretsShowQuickAccess(
        context,
        request: request,
        clipboard: widget.clipboard,
      ),
    );
  }

  /// A notification of the breach check was clicked: show Health.
  void _showHealth() {
    final health = _health;
    if (health == null || !mounted) return;
    if (health.showRequests == _healthShown) return;
    _healthShown = health.showRequests;
    setState(() => _destination = TomSecretsDestination.health);
  }

  /// An entry asked for from outside (the browser host's `openApp`), shown
  /// in the vault browser once its vault is open.
  void _showRequested() {
    final requests = _requests;
    final session = _session;
    final ref = requests?.pending;
    if (ref == null || session == null || !mounted) return;
    if (session.entryOf(ref) == null) return;
    requests!.take();
    setState(() => _destination = TomSecretsDestination.vaults);
    session.selectedEntry = ref;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final requests = context.read<TomSecretsHost>().entryRequests;
    final session = context.read<TomSecretsSession>();
    if (!identical(requests, _requests) || !identical(session, _session)) {
      _requests?.removeListener(_showRequested);
      _session?.removeListener(_showRequested);
      _requests = requests?..addListener(_showRequested);
      _session = session..addListener(_showRequested);
      WidgetsBinding.instance.addPostFrameCallback((_) => _showRequested());
    }
    final quick = context.read<TomSecretsQuickAccess>();
    if (!identical(quick, _quickAccess)) {
      _quickAccess?.removeListener(_showQuickAccess);
      _quickAccess = quick..addListener(_showQuickAccess);
      WidgetsBinding.instance.addPostFrameCallback((_) => _showQuickAccess());
    }
    final health = context.read<TomSecretsHealth>();
    if (!identical(health, _health)) {
      _health?.removeListener(_showHealth);
      _health = health..addListener(_showHealth);
      _healthShown = health.showRequests;
    }
    final c = context.read<TomSecretsServiceConnection>();
    if (!identical(c, _connection)) {
      _connection?.removeListener(_onConnection);
      _connection = c..addListener(_onConnection);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onConnection());
      if (!_integrationsChecked) {
        _integrationsChecked = true;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_checkIntegrations()),
        );
      }
    }
  }

  bool _integrationsChecked = false;

  /// At every start (part-os-integration, "Keeping it right"): the
  /// installed integrations still name this machine's agent and helper,
  /// else they are written again and the user is told.
  Future<void> _checkIntegrations() async {
    final repaired = await tomSecretsCheckIntegrations(
      context.read<TomSecretsHost>(),
      context.read<TomSecretsServiceConnection>(),
    );
    if (!mounted) return;
    final browsers = await tomSecretsCheckBrowserHosts(
      context.read<TomSecretsHost>(),
    );
    if (!mounted) return;
    if (repaired.isNotEmpty) {
      tomShowNotice(
        ScaffoldMessenger.maybeOf(context),
        kind: 'integrations',
        message:
            'Updated the ${repaired.map((i) => i.name).join(' and ')} '
            'integration to name this machine\'s '
            '${repaired.length == 1 && repaired.single.name == 'git' ? 'helper' : 'agent'}.',
      );
    }
    if (browsers.isNotEmpty) {
      tomShowNotice(
        ScaffoldMessenger.maybeOf(context),
        kind: 'browser-integration',
        message:
            'Updated the browser integration of '
            '${browsers.map((b) => b.label).join(', ')}: the app moved or '
            'was updated.',
      );
    }
  }

  @override
  void dispose() {
    _requests?.removeListener(_showRequested);
    _session?.removeListener(_showRequested);
    _connection?.removeListener(_onConnection);
    _health?.removeListener(_showHealth);
    _quickAccess?.removeListener(_showQuickAccess);
    _search.dispose();
    _query.dispose();
    super.dispose();
  }

  /// A new prompt is shown as a dialog on top at once (part-app, Approval
  /// prompt); with the window closed the host bridge's notification opens
  /// the window, where the dialog waits. One dialog at a time, the others
  /// after it; a prompt dismissed with Later stays under Clients.
  void _onConnection() {
    final c = _connection;
    if (c == null || _promptOpen || !mounted) return;
    final next = c.prompts
        .where((p) => !_prompted.contains(p.approvalId))
        .firstOrNull;
    if (next == null) return;
    _prompted.add(next.approvalId);
    _promptOpen = true;
    unawaited(
      tomSecretsShowApprovalPrompt(context, next.approvalId).whenComplete(() {
        _promptOpen = false;
        if (mounted) _onConnection();
      }),
    );
  }

  void _lock() => unawaited(
    context.read<TomSecretsServiceConnection>().lock().catchError(
      (Object _) {},
    ),
  );

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final session = context.read<TomSecretsSession>();
    final bindings = <ShortcutActivator, VoidCallback>{};
    for (final meta in [true, false]) {
      SingleActivator key(LogicalKeyboardKey k) =>
          SingleActivator(k, meta: meta, control: !meta);
      bindings[key(LogicalKeyboardKey.keyF)] = () {
        setState(() => _destination = TomSecretsDestination.vaults);
        _search.requestFocus();
      };
      bindings[key(LogicalKeyboardKey.keyL)] = _lock;
      bindings[key(LogicalKeyboardKey.keyN)] = () =>
          unawaited(tomSecretsNewEntry(context));
      bindings[key(LogicalKeyboardKey.digit1)] = () => session.listView = false;
      bindings[key(LogicalKeyboardKey.digit2)] = () => session.listView = true;
    }
    return bindings;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TomSecretsServiceConnection>();
    final session = context.watch<TomSecretsSession>();
    if (_query.text != session.query) _query.text = session.query;
    final reminders = TomSecretsReminders(
      c,
      context.read<TomSecretsHost>().preferences,
    );
    final conflicts = {for (final r in session.conflictRows) r.ref}.length;
    final github = c.stores.values.where(
      (s) => s.source == 'github' || s.source == 'cache',
    );
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                key: const Key('tsm-rail'),
                selectedIndex: _destination.index,
                labelType: NavigationRailLabelType.all,
                leading: const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 12),
                  child: Tooltip(
                    message: 'Tom Secrets Manager',
                    child: TomSecretsAvatar(
                      icon: Icons.shield_rounded,
                      colour: tomSecretsSeed,
                      size: 38,
                    ),
                  ),
                ),
                onDestinationSelected: (i) => setState(
                  () => _destination = TomSecretsDestination.values[i],
                ),
                destinations: [
                  const NavigationRailDestination(
                    icon: Icon(Icons.inventory_2_outlined),
                    selectedIcon: Icon(Icons.inventory_2_rounded),
                    label: Text('Vaults'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.view_column_outlined),
                    selectedIcon: Icon(Icons.view_column_rounded),
                    label: Text('Environments'),
                  ),
                  NavigationRailDestination(
                    icon: Badge.count(
                      key: const Key('tsm-conflicts-badge'),
                      count: conflicts,
                      isLabelVisible: conflicts > 0,
                      child: const Icon(Icons.call_split_outlined),
                    ),
                    selectedIcon: const Icon(Icons.call_split_rounded),
                    label: const Text('Conflicts'),
                  ),
                  NavigationRailDestination(
                    icon: Badge.count(
                      key: const Key('tsm-clients-badge'),
                      count: c.pendingApprovals,
                      isLabelVisible: c.pendingApprovals > 0,
                      child: const Icon(Icons.how_to_reg_outlined),
                    ),
                    selectedIcon: const Icon(Icons.how_to_reg_rounded),
                    label: const Text('Clients'),
                  ),
                  NavigationRailDestination(
                    icon: Badge.count(
                      key: const Key('tsm-proposals-badge'),
                      count: c.proposals.length,
                      isLabelVisible: c.proposals.isNotEmpty,
                      child: const Icon(Icons.add_task_outlined),
                    ),
                    selectedIcon: const Icon(Icons.add_task_rounded),
                    label: const Text('Proposals'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.health_and_safety_outlined),
                    selectedIcon: Icon(Icons.health_and_safety_rounded),
                    label: Text('Health'),
                  ),
                  NavigationRailDestination(
                    icon: Badge.count(
                      key: const Key('tsm-keys-rail-badge'),
                      count: reminders.shown.length,
                      isLabelVisible: reminders.shown.isNotEmpty,
                      child: const Icon(Icons.key_outlined),
                    ),
                    selectedIcon: const Icon(Icons.key_rounded),
                    label: const Text('Keys'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.devices_other_outlined),
                    selectedIcon: Icon(Icons.devices_other_rounded),
                    label: Text('Pairing'),
                  ),
                  NavigationRailDestination(
                    icon: Badge.count(
                      key: const Key('tsm-sharing-badge'),
                      count: session.inbox.length,
                      isLabelVisible: session.inbox.isNotEmpty,
                      child: const Icon(Icons.group_outlined),
                    ),
                    selectedIcon: const Icon(Icons.group_rounded),
                    label: const Text('Sharing'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.download_outlined),
                    selectedIcon: Icon(Icons.download_rounded),
                    label: Text('Import'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings_rounded),
                    label: Text('Settings'),
                  ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.monitor_heart_outlined),
                    selectedIcon: Icon(Icons.monitor_heart),
                    label: Text('Status'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('tsm-search'),
                              controller: _query,
                              focusNode: _search,
                              decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                hintText: 'Search every vault',
                                isDense: true,
                              ),
                              onChanged: (q) {
                                session.query = q;
                                if (_destination !=
                                    TomSecretsDestination.vaults) {
                                  setState(
                                    () => _destination =
                                        TomSecretsDestination.vaults,
                                  );
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          SegmentedButton<bool>(
                            key: const Key('tsm-view-switch'),
                            segments: const [
                              ButtonSegment(
                                value: false,
                                icon: Icon(Icons.account_tree_outlined),
                                label: Text('Tree'),
                              ),
                              ButtonSegment(
                                value: true,
                                icon: Icon(Icons.view_list_outlined),
                                label: Text('List'),
                              ),
                            ],
                            selected: {session.listView},
                            onSelectionChanged: (s) =>
                                session.listView = s.single,
                          ),
                          const SizedBox(width: 8),
                          SegmentedButton<bool>(
                            key: const Key('tsm-vaults-switch'),
                            segments: const [
                              ButtonSegment(
                                value: true,
                                icon: Icon(Icons.dns_outlined),
                                label: Text('Vault-aware'),
                                tooltip:
                                    'System vaults show keys, overlays, '
                                    'bindings and readers; personal ones '
                                    'logins, URLs and TOTP',
                              ),
                              ButtonSegment(
                                value: false,
                                icon: Icon(Icons.table_rows_outlined),
                                label: Text('Uniform'),
                                tooltip: 'One column set for every vault',
                              ),
                            ],
                            selected: {session.vaultAware},
                            onSelectionChanged: (s) =>
                                session.vaultAware = s.single,
                          ),
                          const SizedBox(width: 12),
                          for (final s in github)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: TomSyncIndicator(
                                key: Key('tsm-sync-${s.name}'),
                                iconOnly: true,
                                presentation: TomSyncPresentation.of(
                                  tomSecretsSyncSummary(s),
                                ),
                              ),
                            ),
                          if (c.pendingApprovals > 0)
                            Tooltip(
                              message:
                                  '${c.pendingApprovals} approvals waiting',
                              child: Badge.count(
                                key: const Key('tsm-approvals-badge'),
                                count: c.pendingApprovals,
                                child: const Icon(Icons.how_to_reg_outlined),
                              ),
                            ),
                          if (c.expiringKeys.isNotEmpty)
                            IconButton(
                              tooltip:
                                  '${c.expiringKeys.length} keys due: open '
                                  'Keys',
                              onPressed: () => setState(
                                () => _destination = TomSecretsDestination.keys,
                              ),
                              icon: Badge.count(
                                key: const Key('tsm-keys-badge'),
                                count: c.expiringKeys.length,
                                child: const Icon(Icons.key_outlined),
                              ),
                            ),
                          IconButton(
                            key: const Key('tsm-lock'),
                            tooltip: 'Lock',
                            icon: const Icon(Icons.lock_outline),
                            onPressed: _lock,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    if (reminders.shown.isNotEmpty &&
                        _destination != TomSecretsDestination.keys)
                      TomSecretsReminderBanner(
                        keys: reminders.shown,
                        onOpen: () => setState(
                          () => _destination = TomSecretsDestination.keys,
                        ),
                        onSnooze: () async {
                          await reminders.snooze(reminders.shown);
                          if (mounted) setState(() {});
                        },
                      ),
                    Expanded(
                      child: switch (_destination) {
                        TomSecretsDestination.vaults => TomSecretsVaultBrowser(
                          clipboard: widget.clipboard,
                        ),
                        TomSecretsDestination.environments =>
                          TomSecretsEnvironmentsView(
                            clipboard: widget.clipboard,
                          ),
                        TomSecretsDestination.conflicts =>
                          const TomSecretsConflictsView(),
                        TomSecretsDestination.clients =>
                          const TomSecretsClientsView(),
                        TomSecretsDestination.proposals =>
                          const TomSecretsProposalsView(),
                        TomSecretsDestination.health => TomSecretsHealthView(
                          onOpen: (ref) {
                            setState(
                              () => _destination = TomSecretsDestination.vaults,
                            );
                            context.read<TomSecretsSession>().selectedEntry =
                                ref;
                          },
                        ),
                        TomSecretsDestination.keys => TomSecretsKeysView(
                          onOpen: (ref) {
                            setState(
                              () => _destination = TomSecretsDestination.vaults,
                            );
                            context.read<TomSecretsSession>().selectedEntry =
                                ref;
                          },
                        ),
                        TomSecretsDestination.pairing =>
                          const TomSecretsPairingView(),
                        TomSecretsDestination.sharing =>
                          const TomSecretsSharingView(),
                        TomSecretsDestination.import =>
                          const TomSecretsImportView(),
                        TomSecretsDestination.settings =>
                          const TomSecretsSettingsView(),
                        TomSecretsDestination.status =>
                          const TomSecretsStatusView(),
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sync summary of a GitHub vault for `tom_sync_ui`'s indicator:
/// its changes not yet pushed, offline while served from its cached copy,
/// last synced at its last fetch.
TomSyncSummary tomSecretsSyncSummary(TomSecretsStoreState s) => TomSyncSummary(
  scope: s.name,
  state: s.notPushed > 0 ? TomSyncState.dirty : TomSyncState.clean,
  offline: s.isOffline,
  pendingCount: s.notPushed,
  lastSyncedAt: s.fetchedAt,
  offlineLocations: s.isOffline
      ? [TomOfflineLocation(label: s.name, pendingCount: s.notPushed)]
      : const [],
  noun: 'change',
  nounPlural: 'changes',
  applicationName: 'the secrets service',
);

/// The banner of the keys due (part-key-rotation, Reminders): what is due,
/// [openLabel] (the screen where the key is renewed), and Snooze until each
/// key's next reminder step.
class TomSecretsReminderBanner extends StatelessWidget {
  /// The banner of [keys].
  const TomSecretsReminderBanner({
    super.key,
    required this.keys,
    required this.onOpen,
    required this.onSnooze,
    this.openLabel = 'Open Keys',
  });

  /// The keys due.
  final List<TomSecretsDueKey> keys;

  /// Opens where they are renewed.
  final VoidCallback onOpen;

  /// Snoozes them until their next step.
  final Future<void> Function() onSnooze;

  /// The open button's label.
  final String openLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expired = keys.any((k) => k.daysLeft < 0);
    return MaterialBanner(
      key: const Key('tsm-reminder-banner'),
      dividerColor: Colors.transparent,
      backgroundColor: expired
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.tertiaryContainer,
      leading: Icon(
        Icons.key_rounded,
        color: expired ? theme.colorScheme.error : theme.colorScheme.tertiary,
      ),
      content: Text(
        '${keys.length == 1 ? 'A key is due' : '${keys.length} keys are due'}: '
        '${keys.take(3).map((k) => k.label).join(', ')}'
        '${keys.length > 3 ? ', …' : ''}',
      ),
      actions: [
        TextButton(
          key: const Key('tsm-reminder-snooze'),
          onPressed: () => unawaited(onSnooze()),
          child: const Text('Snooze'),
        ),
        FilledButton.tonal(
          key: const Key('tsm-reminder-open'),
          onPressed: onOpen,
          child: Text(openLabel),
        ),
      ],
    );
  }
}
