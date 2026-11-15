// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Overlay editor (part-app, Screens › Overlay editor): one entry and
/// its overlays as a matrix — one row per dimension value, the value that row
/// gets and where it comes from (the shared entry, an overlay, another
/// environment's file). A cell is edited in place; a click on a cell without
/// an overlay of its own creates one (`@host:<value>/…`, copied from the
/// shared entry); an overlay is removed with its menu. "Which value does …
/// get?" resolves a set of qualifiers step by step; ambiguities are red.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../state/overlays.dart';
import '../state/session_state.dart';
import '../widgets/protected_field.dart';
import '../widgets/style.dart';
import 'vault_browser.dart' show tomSecretsGuarded;

/// Opens the overlay editor of [ref] as a dialog.
Future<void> tomSecretsShowOverlayEditor(
  BuildContext context,
  TomSecretsEntryRef ref, {
  required TomProtectedClipboard clipboard,
}) {
  final session = context.read<TomSecretsSession>();
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: session,
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1040,
          height: 720,
          child: TomSecretsOverlayEditor(entry: ref, clipboard: clipboard),
        ),
      ),
    ),
  );
}

/// The overlay editor of [entry].
class TomSecretsOverlayEditor extends StatefulWidget {
  /// The editor of [entry]; values are copied through [clipboard].
  const TomSecretsOverlayEditor({
    super.key,
    required this.entry,
    required this.clipboard,
  });

  /// The shared entry.
  final TomSecretsEntryRef entry;

  /// The protected clipboard.
  final TomProtectedClipboard clipboard;

  @override
  State<TomSecretsOverlayEditor> createState() => _OverlayEditorState();
}

class _OverlayEditorState extends State<TomSecretsOverlayEditor> {
  final TomSecretsRevealController _reveal = TomSecretsRevealController();
  final TextEditingController _which = TextEditingController();
  String _field = KdbxKeyCommon.PASSWORD.key;
  String? _editing;
  final TextEditingController _edit = TextEditingController();
  TomSecretsResolved? _answer;
  String? _whichError;

  @override
  void dispose() {
    _reveal.dispose();
    _which.dispose();
    _edit.dispose();
    super.dispose();
  }

  void _startEdit(String cell, String text) => setState(() {
    _editing = cell;
    _edit.text = text;
  });

  Future<void> _commit(TomSecretsEntryRef target) async {
    final session = context.read<TomSecretsSession>();
    await tomSecretsGuarded(
      context,
      () => session.setField(target, _field, _edit.text),
    );
    if (mounted) setState(() => _editing = null);
  }

  Future<void> _cellTapped(
    TomSecretsIndexedEntry base,
    TomSecretsMatrixRow row,
    String cell,
  ) async {
    final session = context.read<TomSecretsSession>();
    if (row.ownOverlay case final own?) {
      _startEdit(cell, _text(own.entry));
      return;
    }
    final bound = session.resolution.store(base.store)?.metadata.binding;
    final fileBinding = bound?[row.dimension];
    if (fileBinding != null && fileBinding != row.value) {
      // The file is bound to another value of this dimension: an overlay
      // here would bind it twice. Its value lives in that value's file.
      final winner = row.resolved.winner;
      if (winner == null) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'No open file serves ${row.dimension}:${row.value}; open it '
              'under Environments.',
            ),
          ),
        );
        return;
      }
      _startEdit(cell, _text(winner.entry));
      return;
    }
    TomSecretsEntryRef? created;
    await tomSecretsGuarded(context, () async {
      created = await session.createOverlay(
        widget.entry,
        row.dimension,
        row.value,
      );
    });
    final overlay = created == null ? null : session.entryOf(created!);
    if (overlay != null && mounted) _startEdit(cell, _text(overlay));
  }

  String _text(KdbxEntry entry) =>
      entry.getString(KdbxKey(_field))?.getText() ?? '';

  void _resolveWhich(
    TomSecretsResolutionModel model,
    TomSecretsIndexedEntry b,
  ) {
    try {
      final qualifiers = TomSecretsResolutionModel.parseQualifiers(_which.text);
      setState(() {
        _whichError = null;
        _answer = model.resolve(b, qualifiers);
      });
    } on FormatException catch (e) {
      setState(() {
        _whichError = e.message;
        _answer = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final model = session.resolution;
    final base = model.indexed(widget.entry.store, widget.entry.uuid);
    final theme = Theme.of(context);
    if (base == null) {
      return const Center(child: Text('The entry is no longer open.'));
    }
    final readOnly = session.readOnlyReason(base.store);
    final rows = model.matrix(base);
    final fields = <String>{
      KdbxKeyCommon.PASSWORD.key,
      KdbxKeyCommon.USER_NAME.key,
      KdbxKeyCommon.URL.key,
      KdbxKeyCommon.NOTES.key,
      for (final e in base.entry.stringEntries)
        if (!e.key.key.startsWith('tsm.') && e.key != KdbxKeyCommon.TITLE)
          e.key.key,
    }.toList();
    final dimensionOrder = [for (final d in model.config.dimensions) d.name];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.layers_rounded, size: 20),
              const SizedBox(width: 8),
              Text('Overlays of ', style: theme.textTheme.titleMedium),
              Flexible(
                child: Text(
                  base.entry.label ?? '(untitled)',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TomSecretsChip(
                base.store,
                colour: tomSecretsVaultColour(base.store),
                icon: Icons.inventory_2_outlined,
              ),
              const Spacer(),
              const Text('Field '),
              DropdownButton<String>(
                key: const Key('tsm-overlay-field'),
                value: _field,
                isDense: true,
                items: [
                  for (final f in fields)
                    DropdownMenuItem(value: f, child: Text(f)),
                ],
                onChanged: (f) => setState(() {
                  _field = f ?? _field;
                  _editing = null;
                }),
              ),
              IconButton(
                key: const Key('tsm-overlay-close'),
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              Text('Clients name it ', style: theme.textTheme.bodySmall),
              SelectableText(
                model.referenceOf(base),
                key: const Key('tsm-overlay-reference'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              IconButton(
                tooltip: 'Copy the reference',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: model.referenceOf(base)),
                ),
              ),
              const Spacer(),
              if (readOnly != null)
                Text(
                  readOnly,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            key: const Key('tsm-overlay-matrix'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              _MatrixRowView(
                cell: 'shared',
                label: 'shared entry',
                labelStyle: const TextStyle(fontWeight: FontWeight.w600),
                value: _text(base.entry),
                protected:
                    base.entry.getString(KdbxKey(_field)) is ProtectedValue,
                source: const TomSecretsChip(
                  'the shared entry',
                  icon: Icons.inventory_2_outlined,
                ),
                reveal: _reveal,
                clipboard: widget.clipboard,
                editing: _editing == 'shared',
                edit: _edit,
                onTap: readOnly != null
                    ? null
                    : () => _startEdit('shared', _text(base.entry)),
                onCommit: () => _commit(widget.entry),
                onCancel: () => setState(() => _editing = null),
              ),
              for (final dimension in dimensionOrder) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: Text(
                    '$dimension · priority '
                    '${dimensionOrder.indexOf(dimension) + 1}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                for (final row in rows.where((r) => r.dimension == dimension))
                  _row(context, model, base, row, readOnly),
              ],
              const SizedBox(height: 12),
              _WhichBox(
                controller: _which,
                error: _whichError,
                answer: _answer,
                field: _field,
                dimensions: dimensionOrder,
                base: base,
                onResolve: () => _resolveWhich(model, base),
              ),
              if (model.warnings.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    model.warnings.join('\n'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    TomSecretsResolutionModel model,
    TomSecretsIndexedEntry base,
    TomSecretsMatrixRow row,
    String? readOnly,
  ) {
    final session = context.read<TomSecretsSession>();
    final cell = '${row.dimension}:${row.value}';
    final winner = row.resolved.winner;
    final own = row.ownOverlay;
    final shown = own ?? winner;
    final target = own ?? winner;
    final value = shown?.entry.getString(KdbxKey(_field));
    return _MatrixRowView(
      key: Key('tsm-matrix-$cell'),
      cell: cell,
      label: row.value,
      value: value?.getText() ?? '',
      inherited: own == null,
      protected: value is ProtectedValue,
      source: _SourceChip(row.resolved, base),
      reveal: _reveal,
      clipboard: widget.clipboard,
      editing: _editing == cell,
      edit: _edit,
      onTap: readOnly != null ? null : () => _cellTapped(base, row, cell),
      onCommit: target == null
          ? null
          : () => _commit(TomSecretsEntryRef(target.store, target.entry.uuid)),
      onCancel: () => setState(() => _editing = null),
      menu: own == null || readOnly != null
          ? null
          : PopupMenuButton<String>(
              key: Key('tsm-matrix-menu-$cell'),
              tooltip: 'Overlay',
              iconSize: 18,
              onSelected: (_) => tomSecretsGuarded(
                context,
                () => session.deleteEntries([
                  TomSecretsEntryRef(own.store, own.entry.uuid),
                ]),
              ),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove the overlay'),
                ),
              ],
            ),
    );
  }
}

/// One line of the matrix: the value name, the value cell and the source.
class _MatrixRowView extends StatelessWidget {
  const _MatrixRowView({
    super.key,
    required this.cell,
    required this.label,
    required this.value,
    required this.protected,
    required this.source,
    required this.reveal,
    required this.clipboard,
    required this.editing,
    required this.edit,
    required this.onTap,
    required this.onCommit,
    required this.onCancel,
    this.inherited = false,
    this.labelStyle,
    this.menu,
  });

  final String cell;
  final String label;
  final String value;
  final bool protected;
  final bool inherited;
  final Widget source;
  final TomSecretsRevealController reveal;
  final TomProtectedClipboard clipboard;
  final bool editing;
  final TextEditingController edit;
  final VoidCallback? onTap;
  final VoidCallback? onCommit;
  final VoidCallback onCancel;
  final TextStyle? labelStyle;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget valueCell;
    if (editing) {
      valueCell = Row(
        children: [
          Expanded(
            child: TextField(
              key: Key('tsm-matrix-edit-$cell'),
              controller: edit,
              autofocus: true,
              obscureText: protected && reveal.revealed != cell,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (_) => onCommit?.call(),
            ),
          ),
          IconButton(
            key: Key('tsm-matrix-save-$cell'),
            tooltip: 'Save',
            iconSize: 18,
            icon: const Icon(Icons.check),
            onPressed: onCommit,
          ),
          IconButton(
            tooltip: 'Cancel',
            iconSize: 18,
            icon: const Icon(Icons.close),
            onPressed: onCancel,
          ),
        ],
      );
    } else {
      valueCell = ListenableBuilder(
        listenable: reveal,
        builder: (context, _) {
          final shown = !protected || reveal.revealed == cell;
          final text = value.isEmpty
              ? (inherited ? '' : '(empty)')
              : shown
              ? value
              : '•' * 10;
          return InkWell(
            key: Key('tsm-matrix-cell-$cell'),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: inherited
                      ? theme.dividerColor
                      : theme.colorScheme.tertiary,
                ),
                color: inherited
                    ? null
                    : theme.colorScheme.tertiaryContainer.withValues(
                        alpha: 0.35,
                      ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      text.isEmpty
                          ? 'click to give it its own value'
                          : inherited
                          ? '$text  (inherited)'
                          : text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: text.isEmpty ? null : 'monospace',
                        fontSize: 13,
                        color: inherited
                            ? theme.colorScheme.onSurfaceVariant
                            : null,
                        fontStyle: text.isEmpty ? FontStyle.italic : null,
                      ),
                    ),
                  ),
                  if (protected && value.isNotEmpty) ...[
                    IconButton(
                      key: Key('tsm-matrix-reveal-$cell'),
                      tooltip: shown ? 'Hide' : 'Reveal for 30 seconds',
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        shown ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () => reveal.toggle(cell),
                    ),
                    IconButton(
                      tooltip: 'Copy (cleared after 30 seconds)',
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.copy),
                      onPressed: () => unawaited(clipboard.copy(value)),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
          Expanded(child: valueCell),
          const SizedBox(width: 8),
          SizedBox(
            width: 230,
            child: Align(alignment: Alignment.centerLeft, child: source),
          ),
          SizedBox(width: 40, child: menu),
        ],
      ),
    );
  }
}

/// Where a row's value comes from, as a chip; ambiguous in red.
class _SourceChip extends StatelessWidget {
  const _SourceChip(this.resolved, this.base);

  final TomSecretsResolved resolved;
  final TomSecretsIndexedEntry base;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final winner = resolved.winner;
    return switch (resolved.source) {
      TomSecretsValueSource.shared => const TomSecretsChip(
        'the shared entry',
        icon: Icons.inventory_2_outlined,
      ),
      TomSecretsValueSource.overlay => TomSecretsChip(
        tomSecretsOverlayLabel(winner!),
        colour: scheme.tertiary,
        icon: Icons.layers_rounded,
      ),
      TomSecretsValueSource.otherFile => TomSecretsChip(
        '${winner!.store}\'s file',
        colour: tomSecretsVaultColour(winner.store),
        icon: Icons.description_outlined,
      ),
      TomSecretsValueSource.none => const TomSecretsChip(
        'no value',
        icon: Icons.block,
      ),
      TomSecretsValueSource.ambiguous => Tooltip(
        message: [
          for (final t in resolved.tied)
            '${t.store}/${t.pathText} ${t.bindings}',
        ].join('\n'),
        child: TomSecretsChip(
          'ambiguous: ${resolved.tied.length} rank equal',
          colour: scheme.error,
          icon: Icons.error_outline,
        ),
      ),
      TomSecretsValueSource.malformed => TomSecretsChip(
        resolved.error ?? 'refused',
        colour: scheme.error,
        icon: Icons.error_outline,
      ),
    };
  }
}

/// An overlay as `@host:bomber`, several bindings comma-separated.
String tomSecretsOverlayLabel(TomSecretsIndexedEntry e) => [
  for (final MapEntry(:key, :value) in e.overlayBindings.entries)
    '$tomSecretsOverlayPrefix$key:$value',
].join(', ');

/// "Which value does … get?": qualifiers in, the resolution step by step out.
class _WhichBox extends StatelessWidget {
  const _WhichBox({
    required this.controller,
    required this.error,
    required this.answer,
    required this.field,
    required this.dimensions,
    required this.base,
    required this.onResolve,
  });

  final TextEditingController controller;
  final String? error;
  final TomSecretsResolved? answer;
  final String field;
  final List<String> dimensions;
  final TomSecretsIndexedEntry base;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final answer = this.answer;
    final bad = TextStyle(color: theme.colorScheme.error);
    return TomSecretsSection(
      title: 'Which value does … get?',
      icon: Icons.help_outline_rounded,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('tsm-which-input'),
                controller: controller,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '[env:prod,host:bomber]',
                  helperText:
                      'dimensions not named take their default '
                      '(${dimensions.join(', ')})',
                  errorText: error,
                ),
                onSubmitted: (_) => onResolve(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('tsm-which-resolve'),
              onPressed: onResolve,
              child: const Text('Resolve'),
            ),
          ],
        ),
        if (answer != null) ...[
          const SizedBox(height: 10),
          Text(
            answer.reference,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text('1. The request', style: theme.textTheme.labelLarge),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final MapEntry(:key, :value) in answer.request.entries)
                TomSecretsChip('$key = $value'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '2. The candidates (${answer.steps.length})',
            style: theme.textTheme.labelLarge,
          ),
          for (final step in answer.steps)
            Padding(
              key: Key('tsm-which-step-${step.entry.store}-${step.entry.uuid}'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    step.kept ? Icons.check_circle_outline : Icons.cancel,
                    size: 16,
                    color: step.kept
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${step.entry.store}/${step.entry.pathText}'
                      '${step.entry.bindings.isEmpty ? '' : '  ${_bindings(step.entry)}'}'
                      '  —  ${step.kept ? 'kept, rank ${step.vector!.join(' ')}' : 'dropped: ${answer.dropReasonOf(step)}'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text('3. The answer', style: theme.textTheme.labelLarge),
          Text(
            key: const Key('tsm-which-answer'),
            switch (answer.source) {
              TomSecretsValueSource.ambiguous =>
                'Ambiguous: ${answer.tied.length} entries rank equal; the '
                    'service refuses the request.',
              TomSecretsValueSource.none => 'No entry: the request fails.',
              TomSecretsValueSource.malformed => 'Refused: ${answer.error}',
              TomSecretsValueSource.shared => '$field from the shared entry.',
              TomSecretsValueSource.overlay =>
                '$field from the overlay ${tomSecretsOverlayLabel(answer.winner!)}.',
              TomSecretsValueSource.otherFile =>
                '$field from ${answer.winner!.store}\'s file '
                    '(${answer.winner!.pathText}).',
            },
            style: switch (answer.source) {
              TomSecretsValueSource.ambiguous ||
              TomSecretsValueSource.malformed ||
              TomSecretsValueSource.none => bad,
              _ => const TextStyle(fontWeight: FontWeight.w600),
            },
          ),
        ],
      ],
    );
  }

  static String _bindings(TomSecretsIndexedEntry e) => [
    for (final MapEntry(:key, :value) in e.bindings.entries) '$key:$value',
  ].join(',');
}
