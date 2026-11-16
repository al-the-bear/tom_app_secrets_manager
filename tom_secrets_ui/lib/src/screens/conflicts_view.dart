// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Conflicts screen (part-app, Screens › Conflicts): the entries with an
/// unsettled conflict (`tsm.conflict`), and per entry the attributes both
/// sides changed, side by side with masked values (`TomMergeView`). The user
/// keeps one side or edits; confirming writes the value, takes the attribute
/// off the record (the last one clears it) and saves.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tom_sync_ui/tom_sync_ui.dart'
    show
        TomMergeBodyRequest,
        TomMergeFieldTable,
        TomMergeRendererRegistry,
        TomMergeView;
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;

import '../state/conflicts.dart';
import '../state/session_state.dart';
import '../widgets/style.dart';
import 'gate_screens.dart' show tomSecretsDescribeAdminError;

/// The Conflicts screen: one line per conflicted entry, and the merge view.
class TomSecretsConflictsView extends StatelessWidget {
  /// The screen.
  const TomSecretsConflictsView({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final rows = session.conflictRows;
    final theme = Theme.of(context);
    final byEntry = <TomSecretsEntryRef, List<TomSecretsConflictRow>>{};
    for (final r in rows) {
      byEntry.putIfAbsent(r.ref, () => []).add(r);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Icon(Icons.call_split_rounded, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Text('Conflicts', style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              Text(
                byEntry.isEmpty
                    ? 'none'
                    : '${byEntry.length} entries, ${rows.length} fields',
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              FilledButton.icon(
                key: const Key('tsm-resolve-conflicts'),
                icon: const Icon(Icons.merge_type_rounded),
                label: const Text('Resolve…'),
                onPressed: rows.isEmpty
                    ? null
                    : () => unawaited(tomSecretsShowConflicts(context)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Both sides of a merge changed these fields differently. The '
            'newer value was kept; the other one is in the entry\'s history. '
            'Keep one side or write the value, and confirm.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: byEntry.isEmpty
              ? const Center(child: Text('No conflicts.'))
              : ListView(
                  key: const Key('tsm-conflict-list'),
                  children: [
                    for (final MapEntry(key: ref, value: fields)
                        in byEntry.entries)
                      ListTile(
                        key: Key('tsm-conflict-$ref'),
                        dense: true,
                        leading: Icon(
                          Icons.warning_amber,
                          color: theme.colorScheme.error,
                        ),
                        title: Text(
                          fields.first.title.isEmpty
                              ? '(untitled)'
                              : fields.first.title,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(fields.first.where),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            for (final f in fields)
                              TomSecretsChip(
                                tomSecretsAttributeLabel(f.attribute),
                                colour: theme.colorScheme.error,
                              ),
                            TomSecretsChip(
                              ref.store,
                              colour: tomSecretsVaultColour(ref.store),
                              icon: Icons.inventory_2_outlined,
                            ),
                          ],
                        ),
                        onTap: () => unawaited(
                          tomSecretsShowConflicts(context, entry: ref),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// The renderers of the conflict rows: the attribute's value, masked when
/// protected (revealed on request), edited in place in the result pane.
TomMergeRendererRegistry tomSecretsConflictRenderers() =>
    TomMergeRendererRegistry()..register(
      tomSecretsConflictKind,
      (context, request) => _AttributeBody(request: request),
    );

/// Opens the merge view over the open conflicts (those of [entry] only when
/// given).
Future<void> tomSecretsShowConflicts(
  BuildContext context, {
  TomSecretsEntryRef? entry,
}) {
  final session = context.read<TomSecretsSession>();
  final renderers = tomSecretsConflictRenderers();
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: session,
      child: Dialog(
        child: Builder(
          builder: (context) {
            final rows = context
                .watch<TomSecretsSession>()
                .conflictRows
                .where((r) => entry == null || r.ref == entry)
                .toList();
            return TomMergeView(
              title: 'Resolve conflicts',
              rows: rows,
              renderers: renderers,
              onConfirm: (row, resolution) async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                try {
                  await session.settleConflict(
                    row as TomSecretsConflictRow,
                    resolution.value as TomSecretsConflictValue?,
                  );
                } on TomSecretsAdminException catch (e) {
                  messenger?.showSnackBar(
                    SnackBar(content: Text(tomSecretsDescribeAdminError(e))),
                  );
                }
              },
            );
          },
        ),
      ),
    ),
  );
}

class _AttributeBody extends StatefulWidget {
  const _AttributeBody({required this.request});

  final TomMergeBodyRequest request;

  @override
  State<_AttributeBody> createState() => _AttributeBodyState();
}

class _AttributeBodyState extends State<_AttributeBody> {
  late final TextEditingController _text = TextEditingController(
    text: _value.text,
  );
  bool _revealed = false;

  TomSecretsConflictValue get _value =>
      widget.request.value as TomSecretsConflictValue;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final value = _value;
    final row = request.row as TomSecretsConflictRow;
    final label = tomSecretsAttributeLabel(row.attribute);
    final masked = value.isProtected && !_revealed;
    final reveal = value.isProtected
        ? IconButton(
            key: Key('tsm-conflict-reveal-${request.label}'),
            tooltip: _revealed ? 'Hide' : 'Reveal',
            icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _revealed = !_revealed),
          )
        : null;
    if (!request.readOnly) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          key: const Key('tsm-conflict-result'),
          controller: _text,
          obscureText: masked,
          autocorrect: false,
          enableSuggestions: false,
          maxLines: masked ? 1 : null,
          decoration: InputDecoration(labelText: label, suffixIcon: reveal),
          onChanged: (t) {
            value.text = t;
            request.onChanged?.call();
          },
        ),
      );
    }
    return Stack(
      children: [
        TomMergeFieldTable(
          fields: [
            (
              label,
              masked ? '•' * 10 : (value.text.isEmpty ? '(none)' : value.text),
            ),
          ],
        ),
        if (reveal != null) Positioned(right: 4, top: 4, child: reveal),
      ],
    );
  }
}
