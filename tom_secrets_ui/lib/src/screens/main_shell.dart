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
import 'package:tom_reusable_ui/tom_reusable_ui.dart';

import '../state/service_connection.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'approval_prompt.dart';
import 'clients_view.dart';
import 'conflicts_view.dart';
import 'environments_view.dart';
import 'settings_view.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<TomSecretsServiceConnection>();
    if (!identical(c, _connection)) {
      _connection?.removeListener(_onConnection);
      _connection = c..addListener(_onConnection);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onConnection());
    }
  }

  @override
  void dispose() {
    _connection?.removeListener(_onConnection);
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
                            Tooltip(
                              message:
                                  '${c.expiringKeys.length} keys expire soon',
                              child: Badge.count(
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

/// The sync summary of a GitHub vault for `tom_reusable_ui`'s indicator:
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
