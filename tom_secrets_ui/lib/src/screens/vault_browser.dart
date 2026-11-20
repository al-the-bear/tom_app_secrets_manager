// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The vault browser (part-app, Screens › Vault browser, BP-24): the tree
/// view (group tree, entry list, details) and the list view (one list with
/// vault, type and tag filters, details beside it), each in the vault-aware
/// or the uniform view (BP-25, [tomSecretsEntryDetails]). Overlay groups
/// (`@host:…`) are not folders: they show as the entry's overlays. Multi-
/// select moves, tags and deletes (to the recycle bin); groups are created,
/// renamed and moved in the tree.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_ui_support/tom_ui_support.dart' show tomShowNotice;
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import 'export_dialog.dart';
import '../state/service_connection.dart';
import '../state/overlays.dart' show TomSecretsGrantUse;
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'entry_editor.dart';
import 'gate_screens.dart';
import 'new_vault_dialog.dart';
import 'rewritten_question.dart';
import 'share_dialogs.dart';

/// The browser in the view the session has chosen.
class TomSecretsVaultBrowser extends StatelessWidget {
  /// The browser; [clipboard] is the protected clipboard.
  const TomSecretsVaultBrowser({super.key, required this.clipboard});

  /// The protected clipboard the editor copies through.
  final TomProtectedClipboard clipboard;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    if (session.loading && session.vaults.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final selected = session.selectedEntry;
    final details = selected == null
        ? const Center(child: Text('Choose an entry.'))
        : TomSecretsEntryEditor(
            key: ValueKey(selected),
            ref: selected,
            clipboard: clipboard,
          );
    final results = session.listView
        ? session.listResults
        : session.groupResults;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 260,
          child: session.listView ? const _ListFilters() : const _GroupTree(),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 360,
          child: _EntryList(entries: results, showPath: session.listView),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: details),
      ],
    );
  }
}

Future<String?> _ask(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) {
  final text = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('tsm-ask'),
        controller: text,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.of(dialog).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('tsm-ask-ok'),
          onPressed: () => Navigator.of(dialog).pop(text.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  ).whenComplete(text.dispose);
}

/// A group of a vault to pick, as a path.
typedef _GroupChoice = ({String store, KdbxUuid? group, String path});

List<_GroupChoice> _groupsOf(TomSecretsSession session, {String? only}) => [
  for (final vault in session.vaults)
    if (only == null || vault.store == only) ...[
      (store: vault.store, group: null, path: vault.store),
      for (final (group, path) in _walk(vault.file.body.rootGroup, const []))
        if (vault.file.recycleBin?.uuid != group.uuid)
          (
            store: vault.store,
            group: group.uuid,
            path: [vault.store, ...path].join(' / '),
          ),
    ],
];

Iterable<(KdbxGroup, List<String>)> _walk(
  KdbxGroup group,
  List<String> path,
) sync* {
  for (final child in group.groups) {
    final name = child.name.get() ?? '';
    if (tomSecretsIsOverlayGroup(name)) continue;
    yield (child, [...path, name]);
    yield* _walk(child, [...path, name]);
  }
}

Future<_GroupChoice?> _pickGroup(
  BuildContext context,
  String title, {
  String? only,
}) {
  final choices = _groupsOf(context.read<TomSecretsSession>(), only: only);
  return showDialog<_GroupChoice>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(title),
      children: [
        for (final c in choices)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialog).pop(c),
            child: Text(c.path),
          ),
      ],
    ),
  );
}

/// **[C]** Lets the user pick a group of a vault that can be written now
/// (a share imported into it, part-sharing): its store, the group (null:
/// the vault's root) and its path; null when cancelled.
Future<({String store, KdbxUuid? group, String path})?> tomSecretsPickGroup(
  BuildContext context,
  String title,
) {
  final session = context.read<TomSecretsSession>();
  final choices = [
    for (final c in _groupsOf(session))
      if (session.readOnlyReason(c.store) == null) c,
  ];
  return showDialog<_GroupChoice>(
    context: context,
    builder: (dialog) => SimpleDialog(
      key: const Key('tsm-pick-group'),
      title: Text(title),
      children: [
        for (final c in choices)
          SimpleDialogOption(
            key: Key('tsm-pick-group-${c.path}'),
            onPressed: () => Navigator.of(dialog).pop(c),
            child: Text(c.path),
          ),
      ],
    ),
  );
}

/// Runs [f], showing a refused change (an admin error) as a notice.
Future<void> tomSecretsGuarded(
  BuildContext context,
  Future<void> Function() f,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await f();
  } on TomSecretsAdminException catch (e) {
    tomShowNotice(
      messenger,
      kind: 'vault-change',
      message: tomSecretsDescribeAdminError(e),
    );
  }
}

class _GroupTree extends StatelessWidget {
  const _GroupTree();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final connection = context.watch<TomSecretsServiceConnection>();
    final host = context.read<TomSecretsHost>();
    final waiting = connection.stores.values
        // A store whose key changed on another device is served read-only
        // from its old copy (its header says so), not waiting for a password.
        .where((s) => s.state == 'needs_unlock' && !s.keyChanged)
        .toList();
    return ListView(
      key: const Key('tsm-group-tree'),
      children: [
        for (final failure in session.failures)
          ListTile(
            dense: true,
            leading: const Icon(Icons.error_outline),
            title: Text(failure.store),
            subtitle: Text(failure.message),
          ),
        for (final store in waiting)
          ListTile(
            key: Key('tsm-needs-unlock-${store.name}'),
            dense: true,
            leading: const Icon(Icons.lock),
            title: Text(store.name),
            subtitle: const Text('has a password of its own'),
            trailing: TextButton(
              onPressed: () => unawaited(
                tomSecretsUnlockStoreDialog(
                  context,
                  store.name,
                  keyFiles: host.keyFiles,
                ),
              ),
              child: const Text('Open…'),
            ),
          ),
        for (final vault in session.vaults) ...[
          _VaultHeader(vault: vault, state: connection.stores[vault.store]),
          for (final (group, path) in _walk(
            vault.file.body.rootGroup,
            const [],
          ))
            _GroupRow(
              store: vault.store,
              group: group,
              depth: path.length,
              isRecycleBin: vault.file.recycleBin?.uuid == group.uuid,
            ),
        ],
        if (session.vaults.isNotEmpty)
          ListTile(
            key: const Key('tsm-new-vault'),
            dense: true,
            leading: const Icon(Icons.add_box_outlined),
            title: const Text('New vault…'),
            onTap: () => unawaited(tomSecretsShowNewVaultDialog(context)),
          ),
      ],
    );
  }
}

class _VaultHeader extends StatelessWidget {
  const _VaultHeader({required this.vault, required this.state});

  final TomSecretsOpenVault vault;
  final TomSecretsStoreState? state;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final selected =
        session.selectedStore == vault.store && session.selectedGroup == null;
    final offline = state?.isOffline ?? false;
    final rewritten = state?.rewrittenHead != null;
    return ListTile(
      key: Key('tsm-vault-${vault.store}'),
      selected: selected,
      leading: TomSecretsAvatar(
        icon: offline ? Icons.cloud_off_rounded : Icons.inventory_2_rounded,
        colour: offline
            ? Theme.of(context).colorScheme.error
            : tomSecretsVaultColour(vault.store),
        size: 26,
      ),
      title: Text(
        vault.store,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: rewritten
          ? Text(
              'the branch on GitHub was rewritten: choose how to go on',
              key: Key('tsm-rewritten-${vault.store}'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          : offline
          ? Text(
              'offline copy: ${state!.offlineReason}'
              '${state!.fetchedAt == null ? '' : ', from ${tomSecretsAge(state!.fetchedAt!)}'}'
              '${state!.isStaleAt(DateTime.now()) ? ' — it may be out of date' : ''}',
              key: Key('tsm-offline-${vault.store}'),
              style: state!.isStaleAt(DateTime.now())
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            )
          : null,
      onTap: () => session.selectGroup(vault.store, null),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'rewritten') {
            await tomSecretsShowRewrittenQuestion(context, vault.store);
            return;
          }
          if (v == 'export') {
            await tomSecretsShowExportDialog(context, store: vault.store);
            return;
          }
          if (v == 'ssh-confirm') {
            await tomSecretsGuarded(
              context,
              () => session.setVaultSshConfirm(
                vault.store,
                !session.sshConfirmOf(vault.store),
              ),
            );
            return;
          }
          if (v != 'group') return;
          final name = await _ask(context, title: 'New group', label: 'Name');
          if (name == null || name.isEmpty || !context.mounted) return;
          await tomSecretsGuarded(
            context,
            () => session.createGroup(vault.store, null, name),
          );
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'group', child: Text('New group')),
          CheckedPopupMenuItem(
            key: Key('tsm-vault-ssh-confirm-${vault.store}'),
            value: 'ssh-confirm',
            checked: session.sshConfirmOf(vault.store),
            enabled: session.readOnlyReason(vault.store) == null,
            child: const Text('Confirm every SSH signature'),
          ),
          if (rewritten)
            const PopupMenuItem(
              value: 'rewritten',
              child: Text('The rewritten branch…'),
            ),
          PopupMenuItem(
            key: Key('tsm-vault-export-${vault.store}'),
            value: 'export',
            child: const Text('Export…'),
          ),
        ],
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.store,
    required this.group,
    required this.depth,
    required this.isRecycleBin,
  });

  final String store;
  final KdbxGroup group;
  final int depth;
  final bool isRecycleBin;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final selected =
        session.selectedStore == store && session.selectedGroup == group.uuid;
    return ListTile(
      key: Key('tsm-group-$store-${group.name.get()}'),
      dense: true,
      selected: selected,
      contentPadding: EdgeInsets.only(left: 18.0 + 14 * depth, right: 4),
      leading: Icon(
        isRecycleBin ? Icons.delete_outline_rounded : Icons.folder_rounded,
        size: 18,
        color: isRecycleBin
            ? Theme.of(context).colorScheme.outline
            : tomSecretsOnSurface(context, tomSecretsVaultColour(store)),
      ),
      title: Text(group.name.get() ?? ''),
      onTap: () => session.selectGroup(store, group.uuid),
      trailing: isRecycleBin
          ? null
          : PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'new':
                    final name = await _ask(
                      context,
                      title: 'New group',
                      label: 'Name',
                    );
                    if (name == null || name.isEmpty || !context.mounted) {
                      return;
                    }
                    await tomSecretsGuarded(
                      context,
                      () => session.createGroup(store, group.uuid, name),
                    );
                  case 'rename':
                    final name = await _ask(
                      context,
                      title: 'Rename group',
                      label: 'Name',
                      initial: group.name.get() ?? '',
                    );
                    if (name == null || name.isEmpty || !context.mounted) {
                      return;
                    }
                    await tomSecretsGuarded(
                      context,
                      () => session.renameGroup(store, group.uuid, name),
                    );
                  case 'move':
                    final target = await _pickGroup(
                      context,
                      'Move the group into',
                      only: store,
                    );
                    if (target == null || !context.mounted) return;
                    await tomSecretsGuarded(
                      context,
                      () => session.moveGroup(store, group.uuid, target.group),
                    );
                  case 'export':
                    await tomSecretsShowExportDialog(
                      context,
                      store: store,
                      group: group.uuid,
                    );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'new', child: Text('New group in it')),
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'move', child: Text('Move…')),
                PopupMenuItem(value: 'export', child: Text('Export…')),
              ],
            ),
    );
  }
}

class _ListFilters extends StatelessWidget {
  const _ListFilters();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    return ListView(
      key: const Key('tsm-list-filters'),
      padding: const EdgeInsets.all(12),
      children: [
        Text('Vault', style: Theme.of(context).textTheme.titleSmall),
        DropdownButton<String?>(
          key: const Key('tsm-filter-vault'),
          isExpanded: true,
          value: session.filterStore,
          items: [
            const DropdownMenuItem(value: null, child: Text('All vaults')),
            for (final v in session.vaults)
              DropdownMenuItem(value: v.store, child: Text(v.store)),
          ],
          onChanged: (v) => session.filterStore = v,
        ),
        const SizedBox(height: 12),
        Text('Type', style: Theme.of(context).textTheme.titleSmall),
        DropdownButton<TomSecretsEntryType?>(
          key: const Key('tsm-filter-type'),
          isExpanded: true,
          value: session.filterType,
          items: [
            const DropdownMenuItem(value: null, child: Text('All types')),
            for (final t in const [
              TomSecretsEntryType.login,
              TomSecretsEntryType.apiToken,
              TomSecretsEntryType.note,
              TomSecretsEntryType.sshKey,
            ])
              DropdownMenuItem(value: t, child: Text(tomSecretsTypeName(t))),
          ],
          onChanged: (t) => session.filterType = t,
        ),
        const SizedBox(height: 12),
        Text('Tag', style: Theme.of(context).textTheme.titleSmall),
        DropdownButton<String?>(
          key: const Key('tsm-filter-tag'),
          isExpanded: true,
          value: session.filterTag,
          items: [
            const DropdownMenuItem(value: null, child: Text('All tags')),
            for (final t in session.allTags)
              DropdownMenuItem(value: t, child: Text(t)),
          ],
          onChanged: (t) => session.filterTag = t,
        ),
      ],
    );
  }
}

/// The name of an entry type for the user.
String tomSecretsTypeName(TomSecretsEntryType type) => switch (type) {
  TomSecretsEntryType.apiToken => 'API token',
  TomSecretsEntryType.note => 'Secure note',
  TomSecretsEntryType.sshKey => 'SSH key',
  TomSecretsEntryType.certificate => 'Certificate',
  TomSecretsEntryType.pgpKey => 'PGP key',
  TomSecretsEntryType.memberKey => 'Member key',
  TomSecretsEntryType.member => 'Member',
  TomSecretsEntryType.login => 'Login',
};

/// The columns an entry's line shows after its path, by the vault-aware or
/// uniform view (BP-25): in the vault-aware view a system vault's entry shows
/// its key, the dimensions it is bound in and which clients read it and
/// when, a personal or shared vault's entry its login and URL; the uniform
/// view shows every one of them the entry has.
List<String> tomSecretsEntryDetails(
  TomSecretsSession session,
  TomSecretsEntryView view,
) {
  final system = session.kindOf(view.ref.store) == TomSecretsVaultKind.system;
  final login = [
    if (view.userName.isNotEmpty) view.userName,
    if (view.url.isNotEmpty) view.url,
  ];
  if (session.vaultAware && !system) {
    return login.isEmpty && view.key != null ? [view.key!] : login;
  }
  final indexed = session.indexedOf(view.ref);
  final readers = indexed == null
      ? const <TomSecretsGrantUse>[]
      : session.resolution.readersOf(indexed);
  final last = readers.map((r) => r.lastUsed).nonNulls.firstOrNull;
  final machine = [
    if (view.key case final key?) key else if (session.vaultAware) '(no key)',
    if (indexed != null && indexed.bindings.isNotEmpty)
      'bound ${[for (final MapEntry(:key, :value) in indexed.bindings.entries) '$key:$value'].join(',')}',
    if (readers.isNotEmpty)
      '${readers.length} client${readers.length == 1 ? '' : 's'}'
          '${last == null ? ', not used yet' : ', last ${tomSecretsAge(last)}'}',
  ];
  return session.vaultAware ? machine : [...login, ...machine];
}

/// How long ago [time] was, for the user.
String tomSecretsAge(DateTime time, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(time);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

/// Creates an entry where the user is: the tree view's group, else the first
/// vault's root; opens it in the editor.
Future<void> tomSecretsNewEntry(
  BuildContext context, {
  TomSecretsEntryType type = TomSecretsEntryType.login,
}) async {
  final session = context.read<TomSecretsSession>();
  final store = session.selectedStore ?? session.vaults.firstOrNull?.store;
  if (store == null) return;
  if (session.readOnlyReason(store) != null) return;
  final title = await _ask(context, title: 'New entry', label: 'Title');
  if (title == null || title.isEmpty || !context.mounted) return;
  await tomSecretsGuarded(
    context,
    () => session.createEntry(
      store,
      group: session.selectedStore == store ? session.selectedGroup : null,
      title: title,
      type: type,
    ),
  );
}

class _EntryList extends StatelessWidget {
  const _EntryList({required this.entries, required this.showPath});

  final List<TomSecretsEntryView> entries;
  final bool showPath;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final marked = session.marked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: marked.isEmpty
              ? Row(
                  children: [
                    Text('${entries.length} entries'),
                    const Spacer(),
                    PopupMenuButton<TomSecretsEntryType>(
                      key: const Key('tsm-new-entry'),
                      tooltip: 'New entry',
                      icon: const Icon(Icons.add),
                      onSelected: (t) =>
                          unawaited(tomSecretsNewEntry(context, type: t)),
                      itemBuilder: (_) => [
                        for (final t in const [
                          TomSecretsEntryType.login,
                          TomSecretsEntryType.apiToken,
                          TomSecretsEntryType.note,
                          TomSecretsEntryType.sshKey,
                        ])
                          PopupMenuItem(
                            value: t,
                            child: Text(tomSecretsTypeName(t)),
                          ),
                      ],
                    ),
                  ],
                )
              : Row(
                  key: const Key('tsm-marked-actions'),
                  children: [
                    Expanded(
                      child: Text(
                        '${marked.length} marked',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      key: const Key('tsm-move-marked'),
                      tooltip: 'Move…',
                      icon: const Icon(Icons.drive_file_move_outline),
                      onPressed: () async {
                        final target = await _pickGroup(context, 'Move into');
                        if (target == null || !context.mounted) return;
                        await tomSecretsGuarded(
                          context,
                          () => session.moveEntries(
                            marked,
                            target.store,
                            target.group,
                          ),
                        );
                      },
                    ),
                    if (context.read<TomSecretsHost>().sendsShares)
                      IconButton(
                        key: const Key('tsm-share-marked'),
                        tooltip: 'Share…',
                        icon: const Icon(Icons.ios_share_rounded),
                        onPressed: () => unawaited(
                          tomSecretsShowShareDialog(context, marked.toList()),
                        ),
                      ),
                    IconButton(
                      key: const Key('tsm-tag-marked'),
                      tooltip: 'Tag…',
                      icon: const Icon(Icons.sell_outlined),
                      onPressed: () async {
                        final tag = await _ask(
                          context,
                          title: 'Add a tag',
                          label: 'Tag',
                        );
                        if (tag == null || tag.isEmpty || !context.mounted) {
                          return;
                        }
                        await tomSecretsGuarded(
                          context,
                          () => session.tagEntries(marked, tag),
                        );
                      },
                    ),
                    IconButton(
                      key: const Key('tsm-delete-marked'),
                      tooltip: 'Move to the recycle bin',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => tomSecretsGuarded(
                        context,
                        () => session.deleteEntries(marked),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Clear the marks',
                      icon: const Icon(Icons.close),
                      onPressed: session.clearMarked,
                    ),
                  ],
                ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            key: const Key('tsm-entry-list'),
            itemCount: entries.length,
            itemBuilder: (context, i) => _EntryRow(
              view: entries[i],
              showPath: showPath,
              selected: session.selectedEntry == entries[i].ref,
              marked: marked.contains(entries[i].ref),
            ),
          ),
        ),
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.view,
    required this.showPath,
    required this.selected,
    required this.marked,
  });

  final TomSecretsEntryView view;
  final bool showPath;
  final bool selected;
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final session = context.read<TomSecretsSession>();
    final expires = view.expires;
    final now = DateTime.now();
    final details = tomSecretsEntryDetails(session, view);
    final hasTotp = TomSecretsTotp.fromEntry(view.entry) != null;
    final showTotp =
        hasTotp &&
        (!session.vaultAware ||
            session.kindOf(view.ref.store) != TomSecretsVaultKind.system);
    return ListTile(
      key: Key('tsm-entry-${view.ref}'),
      dense: true,
      selected: selected,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 24,
            child: Checkbox(
              value: marked,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => session.toggleMarked(view.ref),
            ),
          ),
          const SizedBox(width: 6),
          TomSecretsTypeAvatar(view.type),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              view.title.isEmpty ? '(untitled)' : view.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          for (final tag in view.tags.take(3))
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: TomSecretsChip(tag, colour: tomSecretsTagColour(tag)),
            ),
        ],
      ),
      subtitle: Text(
        key: Key('tsm-entry-details-${view.ref}'),
        [
          if (showPath) [view.ref.store, ...view.groups].join(' / '),
          ...details,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (view.overlays > 0)
            Tooltip(
              message: '${view.overlays} overlays',
              child: Badge.count(
                count: view.overlays,
                backgroundColor: Theme.of(context).colorScheme.tertiary,
                child: Icon(
                  Icons.layers_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ),
          if (showTotp)
            Tooltip(
              message: 'one-time code (TOTP)',
              child: Icon(
                Icons.pin_outlined,
                key: Key('tsm-entry-totp-${view.ref}'),
                size: 18,
              ),
            ),
          if (expires != null)
            Tooltip(
              message: expires.isBefore(now) ? 'expired' : 'expires',
              child: Icon(
                Icons.timer_outlined,
                size: 18,
                color: expires.isBefore(now)
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          if (view.hasConflict)
            Tooltip(
              message: 'conflict',
              child: Icon(
                Icons.warning_amber,
                size: 18,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
      onTap: () => session.selectedEntry = view.ref,
    );
  }
}
