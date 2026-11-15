// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Environments screen (part-app, Screens › Environments, BP-15): the
/// same key across several environments' files side by side — the files the
/// service serves, and files this machine does not serve, opened for editing
/// only with their own keys and saved back where the user chooses. A cell is
/// edited in place; an empty cell of a served file creates the entry.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_core_storage/tom_core_storage.dart'
    show TomKeyRequiredException;
import 'package:tom_reusable_ui/tom_reusable_ui.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import '../state/session_state.dart';
import '../widgets/protected_field.dart';
import '../widgets/style.dart';
import 'vault_browser.dart' show tomSecretsGuarded;

/// One file of the table: a served vault or a file opened for editing only.
final class _FileColumn {
  _FileColumn.served(TomSecretsStore this.store)
    : extra = null,
      index = store,
      binding = store.metadata.binding;

  _FileColumn.extra(TomSecretsExtraFile this.extra)
    : store = null,
      index = TomSecretsStore.fromFile(extra.file, name: 'opened'),
      binding = TomSecretsMetadata.read(extra.file).binding;

  final TomSecretsStore? store;
  final TomSecretsExtraFile? extra;
  final TomSecretsStore index;
  final Map<String, String> binding;

  String get title => store?.name ?? extra!.name;

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
    final text = _edit.text;
    if (column.store case final store?) {
      await tomSecretsGuarded(
        context,
        () => session.setField(
          TomSecretsEntryRef(store.name, entry.entry.uuid),
          _field,
          text,
        ),
      );
    } else {
      final key = KdbxKey(_field);
      final protected =
          entry.entry.getString(key) is ProtectedValue ||
          key == KdbxKeyCommon.PASSWORD;
      entry.entry.setString(
        key,
        protected ? ProtectedValue.fromString(text) : PlainValue(text),
      );
      column.extra!.dirty = true;
      session.extraFileChanged();
    }
    if (mounted) setState(() => _editing = null);
  }

  Future<void> _create(_FileColumn column, String key) async {
    final session = context.read<TomSecretsSession>();
    final store = column.store;
    if (store == null) return;
    await tomSecretsGuarded(context, () async {
      final ref = await session.createEntry(
        store.name,
        title: key.split('.').last,
        type: TomSecretsEntryType.apiToken,
      );
      await session.updateEntry(
        ref,
        (e) => e.setString(TomSecretsEntryFields.key, PlainValue(key)),
      );
    });
  }

  Future<void> _saveExtra(TomSecretsExtraFile extra) async {
    final session = context.read<TomSecretsSession>();
    final files = context.read<TomSecretsHost>().files;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (files == null) {
      tomShowNotice(
        messenger,
        kind: 'environments',
        message: 'This app cannot save files.',
      );
      return;
    }
    final bytes = await session.encodeExtraFile(extra.name);
    try {
      if (await files.save(extra.name, bytes)) {
        extra.dirty = false;
        session.extraFileChanged();
        tomShowNotice(messenger, kind: 'environments', message: 'Saved');
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final model = session.resolution;
    final theme = Theme.of(context);
    final columns = [
      for (final s in model.stores) _FileColumn.served(s),
      for (final x in session.extraFiles) _FileColumn.extra(x),
    ];
    final filter = _filter.text.trim().toLowerCase();
    final keys = {
      for (final c in columns)
        for (final e in c.index.entries)
          if (e.key case final k? when k.contains(filter)) k,
    }.toList()..sort();
    final served = {for (final s in model.stores) s.name};
    final notHere = [
      for (final MapEntry(key: env, value: specs)
          in model.config.stores.entries)
        for (final spec in specs)
          if (!served.contains(spec.name)) (env, spec),
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
              OutlinedButton.icon(
                key: const Key('tsm-env-open'),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Open a file…'),
                onPressed: () => unawaited(tomSecretsOpenExtraFile(context)),
              ),
            ],
          ),
        ),
        if (notHere.isNotEmpty)
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
                for (final (env, spec) in notHere)
                  Tooltip(
                    message: switch (spec.location) {
                      TomSecretsGitHubLocation(
                        :final repository,
                        :final path,
                      ) =>
                        'github: $repository $path — open a copy of the file',
                      TomSecretsLocalLocation(:final path) =>
                        '$path — open the file',
                    },
                    child: TomSecretsChip(
                      '${spec.name} (env:$env)',
                      colour: tomSecretsVaultColour(spec.name),
                      icon: Icons.cloud_off_outlined,
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
                    icon: c.extra == null
                        ? Icons.inventory_2_outlined
                        : Icons.edit_document,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      [
                        for (final MapEntry(:key, :value) in c.binding.entries)
                          '$key:$value',
                        if (c.extra != null) 'editing only',
                      ].join(' · '),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (c.extra case final x?) ...[
                    IconButton(
                      key: Key('tsm-env-save-${x.name}'),
                      tooltip: 'Save the file…',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.save_outlined,
                        color: x.dirty ? theme.colorScheme.tertiary : null,
                      ),
                      onPressed: () => unawaited(_saveExtra(x)),
                    ),
                    IconButton(
                      tooltip: x.dirty ? 'Close without saving' : 'Close',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close),
                      onPressed: () => context
                          .read<TomSecretsSession>()
                          .closeExtraFile(x.name),
                    ),
                  ],
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
    final readOnly = column.store == null
        ? null
        : session.readOnlyReason(column.store!.name);
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: column.store == null || readOnly != null
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

/// Picks a file this machine does not serve and opens it for editing only,
/// asking for its password, key file and (for a `.tsmx` file) its
/// repository key.
Future<void> tomSecretsOpenExtraFile(BuildContext context) async {
  final host = context.read<TomSecretsHost>();
  final files = host.files;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (files == null) {
    tomShowNotice(
      messenger,
      kind: 'environments',
      message: 'This app cannot open files.',
    );
    return;
  }
  final picked = await files.pick();
  if (picked == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _OpenFileDialog(
      name: picked.name,
      bytes: picked.bytes,
      session: context.read<TomSecretsSession>(),
      keyFiles: host.keyFiles,
      pickerContext: context,
    ),
  );
}

class _OpenFileDialog extends StatefulWidget {
  const _OpenFileDialog({
    required this.name,
    required this.bytes,
    required this.session,
    required this.keyFiles,
    required this.pickerContext,
  });

  final String name;
  final Uint8List bytes;
  final TomSecretsSession session;
  final TomKeyFilePicker? keyFiles;
  final BuildContext pickerContext;

  @override
  State<_OpenFileDialog> createState() => _OpenFileDialogState();
}

class _OpenFileDialogState extends State<_OpenFileDialog> {
  final TomKeyStepController _key = TomKeyStepController();
  final TextEditingController _outer = TextEditingController();
  String? _error;
  bool _opening = false;

  bool get _outerLayer => widget.name.endsWith(tomSecretsOuterSuffix);

  @override
  void initState() {
    super.initState();
    _key.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _key.dispose();
    _outer.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final material = _key.material;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await widget.session.openExtraFile(
        widget.name,
        widget.bytes,
        tomSecretsVaultCredentials(
          password: material.passphrase,
          keyFile: material.keyFileBytes,
        ),
        outerKey: _outerLayer ? _outer.text.trim() : null,
      );
      if (mounted) Navigator.of(context).pop();
    } on KdbxInvalidKeyException {
      if (mounted) setState(() => _error = 'Wrong password or key file.');
    } on TomKeyRequiredException {
      if (mounted) {
        setState(() => _error = 'The repository key does not open it.');
      }
    } on TomSecretsOuterException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on KdbxFormatException catch (e) {
      if (mounted) setState(() => _error = 'Not a vault file: ${e.message}');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Open ${widget.name}'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'The file is opened for editing only: this machine does not '
            'serve it. Save it where it belongs when you are done.',
          ),
          const SizedBox(height: 12),
          TomKeyFields(
            controller: _key,
            keyPrefix: 'tsm-extra',
            keyFiles: widget.keyFiles,
            pickerContext: widget.pickerContext,
            offersRemember: false,
            autofocus: true,
            onSubmitted: _open,
          ),
          if (_outerLayer)
            TextField(
              key: const Key('tsm-extra-outer'),
              controller: _outer,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Repository key (base64)',
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('tsm-extra-open'),
        onPressed: _opening ? null : _open,
        child: const Text('Open'),
      ),
    ],
  );
}
