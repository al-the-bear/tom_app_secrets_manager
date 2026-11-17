// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Environments screen (part-app, Screens › Environments, BP-15): the
/// same key across several environments' files side by side — the files the
/// service serves, and the vaults the primary lists that this machine does
/// not serve, opened for editing only through the service (it reads them
/// from their location with their listed keys and writes their saves there,
/// protocol.md 6.4). A cell is edited in place and saved; an empty cell
/// creates the entry.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../state/session_state.dart';
import '../widgets/protected_field.dart';
import '../widgets/style.dart';
import 'new_vault_dialog.dart';
import 'vault_browser.dart' show tomSecretsGuarded;

/// One file of the table: a served vault, or one not served open for
/// editing only.
final class _FileColumn {
  _FileColumn(this.index, {this.editOnly = false})
    : binding = index.metadata.binding;

  final TomSecretsStore index;
  final bool editOnly;
  final Map<String, String> binding;

  String get title => index.name;

  List<TomSecretsIndexedEntry> entriesFor(String key) => [
    for (final e in index.entries)
      if (e.key == key && !e.isOverlay) e,
  ];

  int overlaysFor(String key) =>
      index.entries.where((e) => e.key == key && e.isOverlay).length;
}

/// The Environments screen.
class TomSecretsEnvironmentsView extends StatefulWidget {
  /// The screen; values are copied through [clipboard].
  const TomSecretsEnvironmentsView({super.key, required this.clipboard});

  /// The protected clipboard.
  final TomProtectedClipboard clipboard;

  @override
  State<TomSecretsEnvironmentsView> createState() => _EnvironmentsState();
}

class _EnvironmentsState extends State<TomSecretsEnvironmentsView> {
  final TomSecretsRevealController _reveal = TomSecretsRevealController();
  final TextEditingController _edit = TextEditingController();
  final TextEditingController _filter = TextEditingController();
  String _field = KdbxKeyCommon.PASSWORD.key;
  String? _editing;

  @override
  void dispose() {
    _reveal.dispose();
    _edit.dispose();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _commit(_FileColumn column, TomSecretsIndexedEntry entry) async {
    final session = context.read<TomSecretsSession>();
    await tomSecretsGuarded(
      context,
      () => session.setField(
        TomSecretsEntryRef(column.title, entry.entry.uuid),
        _field,
        _edit.text,
      ),
    );
    if (mounted) setState(() => _editing = null);
  }

  Future<void> _create(_FileColumn column, String key) async {
    final session = context.read<TomSecretsSession>();
    await tomSecretsGuarded(context, () async {
      final ref = await session.createEntry(
        column.title,
        title: key.split('.').last,
        type: TomSecretsEntryType.apiToken,
        select: !column.editOnly,
      );
      await session.updateEntry(
        ref,
        (e) => e.setString(TomSecretsEntryFields.key, PlainValue(key)),
      );
    });
  }

  Future<void> _open(String store) => tomSecretsGuarded(
    context,
    () => context.read<TomSecretsSession>().openUnserved(store),
  );

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final model = session.resolution;
    final theme = Theme.of(context);
    final columns = [
      for (final s in model.stores) _FileColumn(s),
      for (final v in session.editOnly)
        _FileColumn(
          TomSecretsStore.fromFile(v.file, name: v.store),
          editOnly: true,
        ),
    ];
    final filter = _filter.text.trim().toLowerCase();
    final keys = {
      for (final c in columns)
        for (final e in c.index.entries)
          if (e.key case final k? when k.contains(filter)) k,
    }.toList()..sort();
    final served = {for (final s in model.stores) s.name};
    final listed = {for (final u in session.unserved) u.store};
    final envOf = {
      for (final MapEntry(key: env, value: specs)
          in model.config.stores.entries)
        for (final spec in specs) spec.name: env,
    };
    // Openable: the vaults the primary lists that are not served and not
    // open yet. Without keys: configured files the primary does not list.
    final openable = [
      for (final u in session.unserved)
        if (!session.isEditOnly(u.store)) u,
    ];
    final noKeys = [
      for (final name in envOf.keys)
        if (!served.contains(name) && !listed.contains(name)) name,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(
            children: [
              Icon(Icons.view_column_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Environments', style: theme.textTheme.titleMedium),
              const SizedBox(width: 16),
              SizedBox(
                width: 220,
                child: TextField(
                  key: const Key('tsm-env-filter'),
                  controller: _filter,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.filter_list),
                    hintText: 'Filter keys',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              const Text('Field '),
              DropdownButton<String>(
                key: const Key('tsm-env-field'),
                value: _field,
                isDense: true,
                items: [
                  for (final f in [
                    KdbxKeyCommon.PASSWORD.key,
                    KdbxKeyCommon.USER_NAME.key,
                    KdbxKeyCommon.URL.key,
                    KdbxKeyCommon.NOTES.key,
                  ])
                    DropdownMenuItem(value: f, child: Text(f)),
                ],
                onChanged: (f) => setState(() {
                  _field = f ?? _field;
                  _editing = null;
                }),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('tsm-env-new-vault'),
                icon: const Icon(Icons.add_box_outlined),
                label: const Text('New vault…'),
                onPressed: () => unawaited(
                  tomSecretsShowNewVaultDialog(
                    context,
                    kind: TomSecretsVaultKind.system,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (openable.isNotEmpty || noKeys.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Not served on this machine:',
                  style: theme.textTheme.bodySmall,
                ),
                for (final u in openable)
                  Tooltip(
                    message:
                        '${u.location} — open it for editing; saves are '
                        'written there',
                    child: ActionChip(
                      key: Key('tsm-env-open-${u.store}'),
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        Icons.edit_document,
                        size: 16,
                        color: tomSecretsVaultColour(u.store),
                      ),
                      label: Text(
                        envOf[u.store] == null
                            ? 'Open ${u.store}'
                            : 'Open ${u.store} (env:${envOf[u.store]})',
                      ),
                      onPressed: () => unawaited(_open(u.store)),
                    ),
                  ),
                for (final name in noKeys)
                  Tooltip(
                    message:
                        'The primary vault lists no keys for $name: create '
                        'it as a new vault, or add an existing vault\'s keys '
                        'to the primary, to edit it here',
                    child: ActionChip(
                      key: Key('tsm-env-create-vault-$name'),
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        Icons.key_off_outlined,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                      label: Text('$name (env:${envOf[name]}): no keys'),
                      onPressed: () => unawaited(
                        tomSecretsShowNewVaultDialog(
                          context,
                          name: name,
                          kind: TomSecretsVaultKind.system,
                          environment: envOf[name],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: keys.isEmpty
              ? const Center(
                  child: Text(
                    'No entry has a key (tsm.key) yet: keys name the same '
                    'secret in every environment\'s file.',
                  ),
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: 232.0 + columns.length * 280,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(context, columns),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView.builder(
                            key: const Key('tsm-env-table'),
                            itemCount: keys.length,
                            itemBuilder: (context, i) =>
                                _keyRow(context, session, columns, keys[i]),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, List<_FileColumn> columns) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 208, child: Text('Key')),
          for (final c in columns)
            SizedBox(
              key: Key('tsm-env-column-${c.title}'),
              width: 280,
              child: Row(
                children: [
                  TomSecretsChip(
                    c.title,
                    colour: tomSecretsVaultColour(c.title),
                    icon: c.editOnly
                        ? Icons.edit_document
                        : Icons.inventory_2_outlined,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      [
                        for (final MapEntry(:key, :value) in c.binding.entries)
                          '$key:$value',
                        if (c.editOnly) 'not served: editing only',
                      ].join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (c.editOnly)
                    IconButton(
                      key: Key('tsm-env-close-${c.title}'),
                      tooltip: 'Close (its saves are written)',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close),
                      onPressed: () => context
                          .read<TomSecretsSession>()
                          .closeEditOnly(c.title),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _keyRow(
    BuildContext context,
    TomSecretsSession session,
    List<_FileColumn> columns,
    String key,
  ) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 208,
            child: Text(
              key,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          for (final c in columns)
            SizedBox(width: 280, child: _cell(context, session, c, key)),
        ],
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    TomSecretsSession session,
    _FileColumn column,
    String key,
  ) {
    final theme = Theme.of(context);
    final cell = '${column.title}|$key';
    final entries = column.entriesFor(key);
    final readOnly = session.readOnlyReason(column.title);
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: readOnly != null
            ? Text('—', style: TextStyle(color: theme.colorScheme.outline))
            : TextButton.icon(
                key: Key('tsm-env-create-$cell'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  alignment: Alignment.centerLeft,
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('add'),
                onPressed: () => unawaited(_create(column, key)),
              ),
      );
    }
    final entry = entries.first;
    final value = entry.entry.getString(KdbxKey(_field));
    final protected = value is ProtectedValue;
    final text = value?.getText() ?? '';
    if (_editing == cell) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              key: Key('tsm-env-edit-$cell'),
              controller: _edit,
              autofocus: true,
              obscureText: protected && _reveal.revealed != cell,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(isDense: true),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onSubmitted: (_) => unawaited(_commit(column, entry)),
            ),
          ),
          IconButton(
            key: Key('tsm-env-commit-$cell'),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.check),
            onPressed: () => unawaited(_commit(column, entry)),
          ),
          IconButton(
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _editing = null),
          ),
        ],
      );
    }
    final overlays = column.overlaysFor(key);
    return ListenableBuilder(
      listenable: _reveal,
      builder: (context, _) {
        final shown = !protected || _reveal.revealed == cell;
        return InkWell(
          key: Key('tsm-env-cell-$cell'),
          onTap: readOnly != null
              ? null
              : () => setState(() {
                  _editing = cell;
                  _edit.text = text;
                }),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text.isEmpty ? '(empty)' : (shown ? text : '•' * 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: text.isEmpty ? theme.colorScheme.outline : null,
                    ),
                  ),
                ),
                if (entries.length > 1)
                  Tooltip(
                    message: '${entries.length} entries carry this key',
                    child: Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                  ),
                if (overlays > 0)
                  Tooltip(
                    message: '$overlays overlays',
                    child: Icon(
                      Icons.layers_rounded,
                      size: 16,
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                if (protected && text.isNotEmpty) ...[
                  IconButton(
                    key: Key('tsm-env-reveal-$cell'),
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    tooltip: shown ? 'Hide' : 'Reveal for 30 seconds',
                    icon: Icon(shown ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => _reveal.toggle(cell),
                  ),
                  IconButton(
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Copy (cleared after 30 seconds)',
                    icon: const Icon(Icons.copy),
                    onPressed: () => unawaited(widget.clipboard.copy(text)),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
