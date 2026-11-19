// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The quick-access popup (part-app): a search over the open vaults' logins
/// and API tokens, opened by the global hotkey, the tray or the global
/// auto-type hotkey (then listing the entries that fit the active window).
///
/// - **Enter** copies the password (the protected clipboard, cleared after
///   its timeout);
/// - **Shift+Enter** copies the user name;
/// - **Alt+Enter** (Option on macOS) types it into the window that was
///   active (auto-type, part-password-manager);
/// - **Escape** closes it; the window hides again when it was hidden.
///
/// Each row has the same three as buttons.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart' show TomProtectedClipboard;
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../state/auto_type.dart';
import '../state/session_state.dart';

/// Shows the quick-access popup for [request] until it is closed.
Future<void> tomSecretsShowQuickAccess(
  BuildContext context, {
  required TomSecretsQuickAccessRequest request,
  required TomProtectedClipboard clipboard,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      TomSecretsQuickAccessDialog(request: request, clipboard: clipboard),
);

/// The popup.
class TomSecretsQuickAccessDialog extends StatefulWidget {
  /// For [request], copying through [clipboard].
  const TomSecretsQuickAccessDialog({
    super.key,
    required this.request,
    required this.clipboard,
  });

  /// What it was opened for.
  final TomSecretsQuickAccessRequest request;

  /// The protected clipboard.
  final TomProtectedClipboard clipboard;

  @override
  State<TomSecretsQuickAccessDialog> createState() => _QuickAccessState();
}

class _QuickAccessState extends State<TomSecretsQuickAccessDialog> {
  final _query = TextEditingController();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<TomSecretsEntryView> _results(TomSecretsSession session) {
    final candidates = widget.request.candidates.toSet();
    final query = _query.text.trim().toLowerCase();
    return [
      for (final v in session.index)
        if ((candidates.isEmpty || candidates.contains(v.ref)) &&
            (v.type == TomSecretsEntryType.login ||
                v.type == TomSecretsEntryType.apiToken) &&
            (query.isEmpty || v.searchText.contains(query)))
          v,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  Future<void> _finish() async {
    final quick = context.read<TomSecretsQuickAccess>();
    if (mounted) Navigator.of(context).pop();
    await quick.close();
  }

  Future<void> _copy(TomSecretsEntryView view, String field) async {
    final value = view.entry.getString(KdbxKey(field))?.getText() ?? '';
    await widget.clipboard.copy(value);
    await _finish();
  }

  Future<void> _type(TomSecretsEntryView view) async {
    final quick = context.read<TomSecretsQuickAccess>();
    if (mounted) Navigator.of(context).pop();
    await quick.typeInto(view.ref);
  }

  KeyEventResult _onKey(
    KeyEvent event,
    List<TomSecretsEntryView> results,
    bool canType,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        setState(
          () => _selected = (_selected + 1).clamp(0, results.length - 1),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        setState(
          () => _selected = (_selected - 1).clamp(0, results.length - 1),
        );
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        unawaited(_finish());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (results.isEmpty) return KeyEventResult.handled;
        final view = results[_selected.clamp(0, results.length - 1)];
        if (keys.isAltPressed) {
          if (canType) unawaited(_type(view));
        } else if (keys.isShiftPressed) {
          unawaited(_copy(view, 'UserName'));
        } else {
          unawaited(_copy(view, 'Password'));
        }
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TomSecretsSession>();
    final quick = context.watch<TomSecretsQuickAccess>();
    final support = quick.support;
    final results = _results(session);
    final theme = Theme.of(context);
    final title = widget.request.windowTitle;
    return Dialog(
      key: const Key('tsm-quick-access'),
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 24, right: 24),
      child: SizedBox(
        width: 560,
        height: 440,
        child: Focus(
          onKeyEvent: (_, event) => _onKey(event, results, support.available),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  key: const Key('tsm-quick-access-search'),
                  controller: _query,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search the logins',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() => _selected = 0),
                ),
              ),
              if (widget.request.message case final message?)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    message,
                    key: const Key('tsm-quick-access-message'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  [
                    'Enter copies the password, Shift+Enter the user name',
                    if (support.available)
                      'Alt+Enter types it into '
                          '${title == null ? 'the window you came from' : '"$title"'}'
                    else if (support.reason != null)
                      'auto-type: ${support.reason}',
                  ].join('; '),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const Divider(),
              Expanded(
                child: results.isEmpty
                    ? const Center(child: Text('No login matches.'))
                    : ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final v = results[i];
                          return ListTile(
                            key: Key('tsm-quick-access-${v.ref}'),
                            dense: true,
                            selected: i == _selected,
                            title: Text(
                              v.title.isEmpty ? '(untitled)' : v.title,
                            ),
                            subtitle: Text(
                              [
                                v.ref.store,
                                if (v.userName.isNotEmpty) v.userName,
                              ].join(' · '),
                            ),
                            onTap: () => setState(() => _selected = i),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: Key('tsm-quick-access-password-$i'),
                                  tooltip: 'Copy the password (Enter)',
                                  icon: const Icon(Icons.key),
                                  onPressed: () =>
                                      unawaited(_copy(v, 'Password')),
                                ),
                                IconButton(
                                  key: Key('tsm-quick-access-user-$i'),
                                  tooltip: 'Copy the user name (Shift+Enter)',
                                  icon: const Icon(Icons.person),
                                  onPressed: () =>
                                      unawaited(_copy(v, 'UserName')),
                                ),
                                IconButton(
                                  key: Key('tsm-quick-access-type-$i'),
                                  tooltip: support.available
                                      ? 'Type it (Alt+Enter)'
                                      : support.reason,
                                  icon: const Icon(Icons.keyboard),
                                  onPressed: support.available
                                      ? () => unawaited(_type(v))
                                      : null,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
