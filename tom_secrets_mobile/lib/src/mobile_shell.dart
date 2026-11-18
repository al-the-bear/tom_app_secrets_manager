// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's adaptive shell (part-mobile, Layouts), chosen by window
/// width so iPad Split View and foldables switch on their own:
///
/// | Width | Layout | Navigation |
/// | --- | --- | --- |
/// | below 600 | one pane at a time: vaults, entries, the entry | a bottom bar: Vaults, Search, Generator, Settings |
/// | 600–900 | two panes: the entry list and the entry | a navigation rail |
/// | above 900 | three panes: the desktop's tree view | a navigation rail |
///
/// Every list refreshes by pull-to-refresh; the lock button locks (asking
/// first when a change is not written to GitHub yet).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'mobile_engine.dart';
import 'mobile_settings_view.dart';

/// The width below which the phone layout is used.
const double tomSecretsPhoneWidth = 600;

/// The width above which the three-pane layout is used.
const double tomSecretsWideWidth = 900;

/// How long before the provisioning profile's expiry the shell asks for a
/// reinstall (part-mobile, Edge cases).
const Duration tomSecretsProfileWarning = Duration(days: 2);

/// The shell.
class TomSecretsMobileShell extends StatefulWidget {
  /// The shell over [engine], copying through [clipboard].
  const TomSecretsMobileShell({
    super.key,
    required this.engine,
    required this.clipboard,
    this.onForget,
    this.profileExpiry,
    this.clock = DateTime.now,
  });

  /// The engine (settings, refresh).
  final TomSecretsMobileEngine engine;

  /// The protected clipboard.
  final TomProtectedClipboard clipboard;

  /// Forgets this device's setup (the settings' "Set this device up
  /// again"), or null.
  final Future<void> Function()? onForget;

  /// When this build stops starting (iOS, free personal team), or null.
  final DateTime? profileExpiry;

  /// The clock.
  final DateTime Function() clock;

  @override
  State<TomSecretsMobileShell> createState() => _ShellState();
}

enum _Tab { vaults, search, generator, settings }

class _ShellState extends State<TomSecretsMobileShell> {
  _Tab _tab = _Tab.vaults;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth;
      final body = switch (_tab) {
        _Tab.vaults || _Tab.search =>
          width > tomSecretsWideWidth
              ? TomSecretsVaultBrowser(clipboard: widget.clipboard)
              : width >= tomSecretsPhoneWidth
              ? _TwoPanes(
                  clipboard: widget.clipboard,
                  search: _tab == _Tab.search,
                )
              : (_tab == _Tab.search
                    ? _SearchPane(clipboard: widget.clipboard)
                    : _VaultsPane(clipboard: widget.clipboard)),
        _Tab.generator => _GeneratorPane(clipboard: widget.clipboard),
        _Tab.settings => TomSecretsMobileSettingsView(
          engine: widget.engine,
          onForget: widget.onForget,
        ),
      };
      final destinations = [
        (Icons.lock_outline_rounded, 'Vaults'),
        (Icons.search_rounded, 'Search'),
        (Icons.password_rounded, 'Generator'),
        (Icons.settings_rounded, 'Settings'),
      ];
      final expiry = widget.profileExpiry;
      final reinstall =
          expiry != null &&
          expiry.difference(widget.clock()) < tomSecretsProfileWarning;
      final content = reinstall
          ? Column(
              children: [
                MaterialBanner(
                  key: const Key('tsm-mobile-reinstall'),
                  leading: const Icon(Icons.update_rounded),
                  content: Text(
                    'This build stops starting on '
                    '${MaterialLocalizations.of(context).formatMediumDate(expiry.toLocal())}'
                    ': install it again from Xcode.',
                  ),
                  actions: const [SizedBox.shrink()],
                ),
                Expanded(child: body),
              ],
            )
          : body;
      final scaffold = Scaffold(
        appBar: AppBar(
          title: const Text('Tom Secrets'),
          actions: [
            IconButton(
              key: const Key('tsm-mobile-sync'),
              tooltip: 'Sync',
              icon: const Icon(Icons.sync_rounded),
              onPressed: () => unawaited(_sync(context)),
            ),
            IconButton(
              key: const Key('tsm-mobile-lock'),
              tooltip: 'Lock',
              icon: const Icon(Icons.lock_rounded),
              onPressed: () => unawaited(_lock(context)),
            ),
          ],
        ),
        body: width >= tomSecretsPhoneWidth
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: _tab.index,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (i) =>
                        setState(() => _tab = _Tab.values[i]),
                    destinations: [
                      for (final (icon, label) in destinations)
                        NavigationRailDestination(
                          icon: Icon(icon),
                          label: Text(label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              )
            : content,
        bottomNavigationBar: width < tomSecretsPhoneWidth
            ? NavigationBar(
                key: const Key('tsm-mobile-tabs'),
                selectedIndex: _tab.index,
                onDestinationSelected: (i) =>
                    setState(() => _tab = _Tab.values[i]),
                destinations: [
                  for (final (icon, label) in destinations)
                    NavigationDestination(icon: Icon(icon), label: label),
                ],
              )
            : null,
      );
      return scaffold;
    },
  );

  Future<void> _sync(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await context.read<TomSecretsServiceConnection>().reload();
    } on TomSecretsAdminException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _lock(BuildContext context) async {
    final connection = context.read<TomSecretsServiceConnection>();
    final pending = connection.stores.values.fold<int>(
      0,
      (n, s) => n + s.notPushed,
    );
    if (pending > 0) {
      final write = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Not written to GitHub'),
          content: Text(
            '$pending change${pending == 1 ? ' is' : 's are'} not written to '
            'GitHub yet. Locking drops ${pending == 1 ? 'it' : 'them'}: this '
            'device keeps no copy.',
          ),
          actions: [
            TextButton(
              key: const Key('tsm-mobile-lock-discard'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Discard'),
            ),
            FilledButton(
              key: const Key('tsm-mobile-lock-write'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Write now'),
            ),
          ],
        ),
      );
      if (write == null) return;
      if (write) {
        try {
          await connection.reload();
        } on TomSecretsAdminException {
          // Still not written: the user chose to lock anyway below only on
          // Discard; stay unlocked.
          return;
        }
      }
    }
    await connection.lock();
  }
}

/// The open vaults: each with its kind, state, last fetch and changes not
/// written; a tap lists its entries.
class _VaultsPane extends StatelessWidget {
  const _VaultsPane({required this.clipboard});

  final TomProtectedClipboard clipboard;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final connection = context.watch<TomSecretsServiceConnection>();
    if (session.loading && session.vaults.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: () => connection.reload().catchError((Object _) {}),
      child: ListView(
        key: const Key('tsm-mobile-vaults'),
        children: [
          if (session.conflictRows.isNotEmpty)
            ListTile(
              key: const Key('tsm-mobile-conflicts'),
              leading: const Icon(Icons.call_split_rounded),
              title: Text('${session.conflictRows.length} conflicts to settle'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Conflicts')),
                    body: const TomSecretsConflictsView(),
                  ),
                ),
              ),
            ),
          for (final v in session.vaults)
            ListTile(
              key: Key('tsm-mobile-vault-${v.store}'),
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(v.store),
              subtitle: Text(
                _stateLine(connection.stores[v.store], session, v),
              ),
              onTap: () {
                session.selectGroup(v.store, null);
                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          _EntriesPage(store: v.store, clipboard: clipboard),
                    ),
                  ),
                );
              },
            ),
          for (final f in session.failures)
            ListTile(
              leading: const Icon(Icons.error_outline_rounded),
              title: Text(f.store),
              subtitle: Text(f.message),
            ),
        ],
      ),
    );
  }

  static String _stateLine(
    TomSecretsStoreState? state,
    TomSecretsSession session,
    TomSecretsOpenVault vault,
  ) {
    final parts = <String>[
      ?session.readOnlyReason(vault.store),
      if (state?.fetchedAt case final at?) 'fetched ${_ago(at)}',
      if ((state?.notPushed ?? 0) > 0)
        '${state!.notPushed} change${state.notPushed == 1 ? '' : 's'} not '
            'written to GitHub',
    ];
    return parts.isEmpty ? 'current' : parts.join(' · ');
  }

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }
}

/// One vault's entries (its root group's, or every entry of it through the
/// search's list view).
class _EntriesPage extends StatelessWidget {
  const _EntriesPage({required this.store, required this.clipboard});

  final String store;
  final TomProtectedClipboard clipboard;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final entries = [
      for (final e in session.index)
        if (e.ref.store == store && !e.inRecycleBin) e,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return Scaffold(
      appBar: AppBar(
        title: Text(store),
        actions: [
          if (session.readOnlyReason(store) == null)
            IconButton(
              tooltip: 'New entry',
              icon: const Icon(Icons.add_rounded),
              onPressed: () => unawaited(tomSecretsNewEntry(context)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => context
            .read<TomSecretsServiceConnection>()
            .reload()
            .catchError((Object _) {}),
        child: _EntryList(entries: entries, clipboard: clipboard),
      ),
    );
  }
}

class _EntryList extends StatelessWidget {
  const _EntryList({
    required this.entries,
    required this.clipboard,
    this.onSelected,
  });

  final List<TomSecretsEntryView> entries;
  final TomProtectedClipboard clipboard;
  final void Function(TomSecretsEntryRef ref)? onSelected;

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: const Key('tsm-mobile-entries'),
    itemCount: entries.length,
    itemBuilder: (context, i) {
      final e = entries[i];
      return ListTile(
        key: Key('tsm-mobile-entry-${e.title}'),
        leading: TomSecretsTypeAvatar(e.type),
        title: Text(e.title.isEmpty ? '(untitled)' : e.title),
        subtitle: Text(
          [
            if (e.userName.isNotEmpty) e.userName,
            if (e.url.isNotEmpty) e.url,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          final session = context.read<TomSecretsSession>();
          session.selectedEntry = e.ref;
          if (onSelected != null) {
            onSelected!(e.ref);
            return;
          }
          unawaited(
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text(e.title)),
                  body: TomSecretsEntryEditor(ref: e.ref, clipboard: clipboard),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Search over every open vault, by title, user name, URL or key.
class _SearchPane extends StatelessWidget {
  const _SearchPane({required this.clipboard, this.onSelected});

  final TomProtectedClipboard clipboard;
  final void Function(TomSecretsEntryRef ref)? onSelected;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            key: const Key('tsm-mobile-search'),
            autofocus: onSelected == null,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Search every vault',
            ),
            onChanged: (q) => session.query = q,
          ),
        ),
        Expanded(
          child: _EntryList(
            entries: [
              for (final e in session.listResults)
                if (!e.inRecycleBin) e,
            ],
            clipboard: clipboard,
            onSelected: onSelected,
          ),
        ),
      ],
    );
  }
}

/// Tablet in portrait: the entry list and the entry side by side.
class _TwoPanes extends StatelessWidget {
  const _TwoPanes({required this.clipboard, required this.search});

  final TomProtectedClipboard clipboard;
  final bool search;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final selected = session.selectedEntry;
    return Row(
      children: [
        SizedBox(
          width: 320,
          child: _SearchPane(clipboard: clipboard, onSelected: (_) {}),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null || session.entryOf(selected) == null
              ? const Center(child: Text('Pick an entry'))
              : TomSecretsEntryEditor(
                  key: ValueKey(selected),
                  ref: selected,
                  clipboard: clipboard,
                ),
        ),
      ],
    );
  }
}

/// The password generator on its own: a password made and copied.
class _GeneratorPane extends StatefulWidget {
  const _GeneratorPane({required this.clipboard});

  final TomProtectedClipboard clipboard;

  @override
  State<_GeneratorPane> createState() => _GeneratorPaneState();
}

class _GeneratorPaneState extends State<_GeneratorPane> {
  String? _made;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('A password for something outside the vaults.'),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('tsm-mobile-generate'),
            icon: const Icon(Icons.password_rounded),
            label: const Text('Generate'),
            onPressed: () async {
              final made = await tomSecretsShowGenerator(context);
              if (made != null) setState(() => _made = made);
            },
          ),
          if (_made != null) ...[
            const SizedBox(height: 16),
            SelectableText(_made!, key: const Key('tsm-mobile-generated')),
            TextButton.icon(
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy'),
              onPressed: () => unawaited(widget.clipboard.copy(_made!)),
            ),
          ],
        ],
      ),
    ),
  );
}
