// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Auto-type and quick access in the app (part-password-manager, part-app,
/// DP-41).
///
/// - **The keyboard** ([TomSecretsKeyboard], the host's): what the desktop
///   can do (macOS with the Accessibility permission, Windows, Linux on X11;
///   never Wayland), the active window's title, macOS's secure input, and
///   typing a character or pressing a key. The app types; the service never
///   does.
/// - **Typing** ([TomSecretsAutoTyper]): an entry's sequence for the window
///   (`tom_secrets_core`'s KeePass syntax), parsed, then typed action by
///   action, checking before each one that the window it started in is still
///   the active one; a window that changes stops it, and so does macOS's
///   secure input, with the reason said.
/// - **Quick access** ([TomSecretsQuickAccess]): the popup a global hotkey,
///   the tray or the entry editor opens; a second global hotkey types for
///   the entry associated with the active window (one: at once; several:
///   the popup lists them).
/// - **Hotkeys** ([TomSecretsHotkey], [TomSecretsHotkeys]): written like
///   `Ctrl+Shift+Space` (`Cmd` on macOS), kept per device.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';

import '../ports/desktop_ports.dart';
import 'session_state.dart';

/// What this desktop can do for auto-type.
@immutable
final class TomSecretsAutoTypeSupport {
  /// [available], else why not ([reason]); [permissionNeeded] when a
  /// permission the user can grant is missing (macOS: Accessibility).
  const TomSecretsAutoTypeSupport({
    required this.available,
    this.reason,
    this.permissionNeeded = false,
  });

  /// Auto-type works.
  static const ok = TomSecretsAutoTypeSupport(available: true);

  /// Whether it works now.
  final bool available;

  /// Why not, for the user.
  final String? reason;

  /// Whether granting a permission makes it work.
  final bool permissionNeeded;
}

/// The desktop's keyboard and windows, as auto-type uses them.
abstract interface class TomSecretsKeyboard {
  /// What auto-type can do here now.
  TomSecretsAutoTypeSupport support();

  /// Asks the user for the permission auto-type needs (macOS: opens the
  /// Accessibility prompt); answers whether it is granted now.
  Future<bool> requestPermission();

  /// The active window's title, or null when it cannot be read.
  String? activeWindowTitle();

  /// Whether a field that refuses typed keys has the keyboard (macOS's
  /// secure input).
  bool secureInputActive();

  /// Types the single character [character] (one Unicode code point).
  void typeCharacter(String character);

  /// Presses [press] (a special key or a character with modifiers).
  void press(TomSecretsAutoTypeKeyPress press);

  /// Why the system refused the keys sent last (Windows: a window of a
  /// program running as administrator), once; null when it took them.
  String? takeRefusal();
}

/// How a typing run ended.
enum TomSecretsAutoTypeResult {
  /// Every action typed.
  typed,

  /// Stopped part way (the window changed, secure input).
  stopped,

  /// Not started (auto-type unavailable, off for the entry, a bad sequence).
  refused,
}

/// A typing run's end and why.
@immutable
final class TomSecretsAutoTypeOutcome {
  /// [result] with [message] for the user.
  const TomSecretsAutoTypeOutcome(this.result, [this.message]);

  /// How it ended.
  final TomSecretsAutoTypeResult result;

  /// Why, for the user (never a value).
  final String? message;
}

/// Types an entry's sequence through a [TomSecretsKeyboard].
final class TomSecretsAutoTyper {
  /// Over [keyboard]; [pause] waits (tests pass a fake); [keyDelay] is the
  /// pause between keys until a sequence sets another (`{DELAY=n}`).
  TomSecretsAutoTyper(
    this.keyboard, {
    Future<void> Function(Duration duration)? pause,
    this.keyDelay = const Duration(milliseconds: 10),
    DateTime Function()? clock,
  }) : _pause = pause ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  /// The keyboard.
  final TomSecretsKeyboard keyboard;

  /// The default pause between keys.
  final Duration keyDelay;

  final Future<void> Function(Duration duration) _pause;
  final DateTime Function() _clock;

  /// Types [entry]'s sequence for the window titled [windowTitle] (the
  /// active one when null) into the active window, which must stay the one
  /// it started in. [sequence] overrides the entry's.
  Future<TomSecretsAutoTypeOutcome> typeEntry(
    KdbxEntry entry, {
    String? windowTitle,
    String? sequence,
  }) async {
    final support = keyboard.support();
    if (!support.available) {
      return TomSecretsAutoTypeOutcome(
        TomSecretsAutoTypeResult.refused,
        support.reason,
      );
    }
    final title = windowTitle ?? keyboard.activeWindowTitle();
    final chosen =
        sequence ?? tomSecretsAutoTypeSequenceFor(entry, windowTitle: title);
    if (chosen == null) {
      return const TomSecretsAutoTypeOutcome(
        TomSecretsAutoTypeResult.refused,
        'Auto-type is off for this entry.',
      );
    }
    final List<TomSecretsAutoTypeAction> actions;
    try {
      actions = tomSecretsParseAutoType(
        chosen,
        values: tomSecretsAutoTypeValues(entry, now: _clock()),
      );
    } on TomSecretsAutoTypeException catch (e) {
      return TomSecretsAutoTypeOutcome(
        TomSecretsAutoTypeResult.refused,
        'The sequence cannot be typed: ${e.message}.',
      );
    }
    return type(actions);
  }

  /// Types [actions] into the active window, checking before each that it
  /// is still the window typing started in, and that no secure input field
  /// has the keyboard.
  Future<TomSecretsAutoTypeOutcome> type(
    List<TomSecretsAutoTypeAction> actions,
  ) async {
    final window = keyboard.activeWindowTitle();
    var delay = keyDelay;
    TomSecretsAutoTypeOutcome? check() {
      if (keyboard.secureInputActive()) {
        return const TomSecretsAutoTypeOutcome(
          TomSecretsAutoTypeResult.stopped,
          'A secure input field (a password field or a terminal\'s secure '
          'keyboard entry) refuses typed keys. Type into it by hand, or turn '
          'secure keyboard entry off.',
        );
      }
      if (keyboard.activeWindowTitle() != window) {
        return const TomSecretsAutoTypeOutcome(
          TomSecretsAutoTypeResult.stopped,
          'The window changed while typing: auto-type stopped.',
        );
      }
      return null;
    }

    TomSecretsAutoTypeOutcome? refused() {
      final why = keyboard.takeRefusal();
      return why == null
          ? null
          : TomSecretsAutoTypeOutcome(TomSecretsAutoTypeResult.stopped, why);
    }

    for (final action in actions) {
      switch (action) {
        case TomSecretsAutoTypeDelay(:final duration):
          await _pause(duration);
        case TomSecretsAutoTypeKeyDelay(:final duration):
          delay = duration;
        case TomSecretsAutoTypeText(:final text):
          for (final rune in text.runes) {
            if (check() case final stop?) return stop;
            keyboard.typeCharacter(String.fromCharCode(rune));
            if (refused() case final stop?) return stop;
            await _pause(delay);
          }
        case TomSecretsAutoTypeKeyPress():
          if (check() case final stop?) return stop;
          keyboard.press(action);
          if (refused() case final stop?) return stop;
          await _pause(delay);
      }
    }
    return const TomSecretsAutoTypeOutcome(TomSecretsAutoTypeResult.typed);
  }
}

/// A global hotkey: [key] (a letter, digit, `Space`, `F1`…) with
/// [modifiers].
@immutable
final class TomSecretsHotkey {
  /// [key] with [modifiers].
  const TomSecretsHotkey(this.key, this.modifiers);

  /// The key: an upper-case letter or digit, `Space`, `Enter`, `Tab`,
  /// `F1`–`F12`.
  final String key;

  /// The modifiers held.
  final Set<TomSecretsAutoTypeModifier> modifiers;

  static const _names = {
    'ctrl': TomSecretsAutoTypeModifier.control,
    'control': TomSecretsAutoTypeModifier.control,
    'shift': TomSecretsAutoTypeModifier.shift,
    'alt': TomSecretsAutoTypeModifier.alt,
    'option': TomSecretsAutoTypeModifier.alt,
    'cmd': TomSecretsAutoTypeModifier.meta,
    'command': TomSecretsAutoTypeModifier.meta,
    'win': TomSecretsAutoTypeModifier.meta,
    'super': TomSecretsAutoTypeModifier.meta,
    'meta': TomSecretsAutoTypeModifier.meta,
  };

  /// Reads `Ctrl+Shift+Space` (any case; `Cmd`, `Win`, `Super` and `Meta`
  /// alike); null when it is no hotkey (no modifier, no key, an unknown
  /// name).
  static TomSecretsHotkey? parse(String text) {
    final parts = [
      for (final p in text.split('+'))
        if (p.trim().isNotEmpty) p.trim(),
    ];
    if (parts.length < 2) return null;
    final mods = <TomSecretsAutoTypeModifier>{};
    for (final p in parts.take(parts.length - 1)) {
      final m = _names[p.toLowerCase()];
      if (m == null) return null;
      mods.add(m);
    }
    final last = parts.last;
    final upper = last.toUpperCase();
    final String key;
    if (RegExp(r'^[A-Z0-9]$').hasMatch(upper)) {
      key = upper;
    } else if (RegExp(r'^F([1-9]|1[0-2])$').hasMatch(upper)) {
      key = upper;
    } else if (const {'SPACE', 'ENTER', 'TAB'}.contains(upper)) {
      key = upper[0] + upper.substring(1).toLowerCase();
    } else {
      return null;
    }
    return TomSecretsHotkey(key, mods);
  }

  /// As [parse] reads it, the modifiers in the order Ctrl, Alt, Shift,
  /// Cmd/Win.
  @override
  String toString() => [
    for (final (m, name) in const [
      (TomSecretsAutoTypeModifier.control, 'Ctrl'),
      (TomSecretsAutoTypeModifier.alt, 'Alt'),
      (TomSecretsAutoTypeModifier.shift, 'Shift'),
      (TomSecretsAutoTypeModifier.meta, 'Cmd'),
    ])
      if (modifiers.contains(m)) name,
    key,
  ].join('+');

  @override
  bool operator ==(Object other) =>
      other is TomSecretsHotkey &&
      other.key == key &&
      other.modifiers.length == modifiers.length &&
      other.modifiers.containsAll(modifiers);

  @override
  int get hashCode => Object.hash(key, Object.hashAllUnordered(modifiers));
}

/// The desktop's global hotkeys.
abstract interface class TomSecretsHotkeys {
  /// Registers [hotkey] under [id] (replacing one of that id); [onPressed]
  /// runs when it is pressed anywhere. Throws when the system refuses it
  /// (taken by another program).
  Future<void> register(
    String id,
    TomSecretsHotkey hotkey,
    void Function() onPressed,
  );

  /// Removes the hotkey [id].
  Future<void> unregister(String id);
}

/// The preference keys of quick access and auto-type.
abstract final class TomSecretsQuickAccessKeys {
  /// The quick-access hotkey (`off` for none).
  static const quickAccessHotkey = 'quickAccess.hotkey';

  /// The hotkey that types for the active window (`off` for none).
  static const autoTypeHotkey = 'autoType.hotkey';
}

/// The default hotkeys: quick access and typing for the active window.
({TomSecretsHotkey quickAccess, TomSecretsHotkey autoType})
tomSecretsDefaultHotkeys({required bool macOS}) => macOS
    ? (
        quickAccess: const TomSecretsHotkey('Space', {
          TomSecretsAutoTypeModifier.meta,
          TomSecretsAutoTypeModifier.shift,
        }),
        autoType: const TomSecretsHotkey('A', {
          TomSecretsAutoTypeModifier.meta,
          TomSecretsAutoTypeModifier.alt,
        }),
      )
    : (
        quickAccess: const TomSecretsHotkey('Space', {
          TomSecretsAutoTypeModifier.control,
          TomSecretsAutoTypeModifier.shift,
        }),
        autoType: const TomSecretsHotkey('A', {
          TomSecretsAutoTypeModifier.control,
          TomSecretsAutoTypeModifier.alt,
        }),
      );

/// A request to show the quick-access popup.
@immutable
final class TomSecretsQuickAccessRequest {
  /// For the window titled [windowTitle] (null when unknown), offering
  /// [candidates] (empty: every entry) with [message] above them.
  const TomSecretsQuickAccessRequest({
    this.windowTitle,
    this.candidates = const [],
    this.message,
  });

  /// The window that was active when it was asked for.
  final String? windowTitle;

  /// The entries matched to that window, or empty.
  final List<TomSecretsEntryRef> candidates;

  /// A line above the list, or null.
  final String? message;
}

/// Quick access and auto-type over a session: opened by the hotkeys, the
/// tray and the entry editor; types for the window that was active.
class TomSecretsQuickAccess extends ChangeNotifier {
  /// Over [session], typing through [keyboard] (null: no auto-type here),
  /// hiding [window] (null: none) to give the keyboard back; its hotkeys
  /// registered through [hotkeys] and kept in [preferences]; [macOS] picks
  /// the default hotkeys.
  TomSecretsQuickAccess({
    required this.session,
    required this.preferences,
    this.keyboard,
    this.hotkeys,
    this.window,
    this.macOS = false,
    TomSecretsAutoTyper? typer,
    Future<void> Function(Duration duration)? pause,
  }) : _typer =
           typer ?? (keyboard == null ? null : TomSecretsAutoTyper(keyboard)),
       _pause = pause ?? Future<void>.delayed;

  /// The vaults.
  final TomSecretsSession session;

  /// Where the hotkeys are kept.
  final TomSecretsPreferences preferences;

  /// The keyboard, or null where auto-type is not built in.
  final TomSecretsKeyboard? keyboard;

  /// The global hotkeys, or null.
  final TomSecretsHotkeys? hotkeys;

  /// The app's window, or null.
  final TomSecretsWindowHost? window;

  /// Whether this is macOS (the default hotkeys).
  final bool macOS;

  final TomSecretsAutoTyper? _typer;
  final Future<void> Function(Duration duration) _pause;
  TomSecretsQuickAccessRequest? _request;
  TomSecretsAutoTypeOutcome? _last;
  String? _hotkeyError;
  bool _wasHidden = false;

  /// The popup asked for, or null.
  TomSecretsQuickAccessRequest? get request => _request;

  /// The last typing run's end, or null.
  TomSecretsAutoTypeOutcome? get lastOutcome => _last;

  /// Why a hotkey could not be registered, or null.
  String? get hotkeyError => _hotkeyError;

  /// What auto-type can do here now.
  TomSecretsAutoTypeSupport get support =>
      keyboard?.support() ??
      const TomSecretsAutoTypeSupport(
        available: false,
        reason: 'Auto-type is not built into this app.',
      );

  /// The hotkey kept under [key] ([TomSecretsQuickAccessKeys]), its default
  /// when none is kept, or null when it is off.
  TomSecretsHotkey? hotkey(String key) {
    final kept = preferences.read(key);
    if (kept == 'off') return null;
    final defaults = tomSecretsDefaultHotkeys(macOS: macOS);
    final fallback = key == TomSecretsQuickAccessKeys.quickAccessHotkey
        ? defaults.quickAccess
        : defaults.autoType;
    return kept == null ? fallback : (TomSecretsHotkey.parse(kept) ?? fallback);
  }

  /// Keeps [hotkey] (null: off) under [key] and registers the hotkeys again.
  Future<void> setHotkey(String key, TomSecretsHotkey? hotkey) async {
    await preferences.write(key, hotkey?.toString() ?? 'off');
    await registerHotkeys();
  }

  /// Registers the hotkeys kept (the defaults where none is kept).
  Future<void> registerHotkeys() async {
    final keys = hotkeys;
    if (keys == null) return;
    _hotkeyError = null;
    final quick = hotkey(TomSecretsQuickAccessKeys.quickAccessHotkey);
    final type = hotkey(TomSecretsQuickAccessKeys.autoTypeHotkey);
    Future<void> one(
      String id,
      TomSecretsHotkey? hotkey,
      void Function() run,
    ) async {
      await keys.unregister(id);
      if (hotkey == null) return;
      try {
        await keys.register(id, hotkey, run);
      } on Object catch (e) {
        _hotkeyError = 'The hotkey $hotkey cannot be used: $e';
      }
    }

    await one('quick-access', quick, () => unawaited(open()));
    await one('auto-type', type, () => unawaited(typeForActiveWindow()));
    notifyListeners();
  }

  /// Opens the popup for the window active now (every entry).
  Future<void> open() async {
    final title = _activeOther();
    _wasHidden = window != null && !await window!.isVisible();
    _request = TomSecretsQuickAccessRequest(windowTitle: title);
    notifyListeners();
    await window?.show();
  }

  /// The global auto-type hotkey: types for the entry associated with the
  /// active window when there is one; opens the popup with the candidates
  /// when there are several, or with every entry and the reason when there
  /// is none.
  Future<TomSecretsAutoTypeOutcome?> typeForActiveWindow() async {
    final title = _activeOther();
    final support = this.support;
    if (title == null || !support.available) {
      _wasHidden = window != null && !await window!.isVisible();
      _request = TomSecretsQuickAccessRequest(
        windowTitle: title,
        message: support.available
            ? 'The active window\'s title cannot be read.'
            : support.reason,
      );
      notifyListeners();
      await window?.show();
      return null;
    }
    final candidates = tomSecretsAutoTypeCandidates([
      for (final v in session.index) (v.ref.store, v.entry),
    ], title);
    if (candidates.length == 1) {
      final c = candidates.single;
      return _record(await _typer!.typeEntry(c.entry, windowTitle: title));
    }
    _wasHidden = window != null && !await window!.isVisible();
    _request = TomSecretsQuickAccessRequest(
      windowTitle: title,
      candidates: [
        for (final c in candidates) TomSecretsEntryRef(c.store, c.entry.uuid),
      ],
      message: candidates.isEmpty
          ? 'No entry is associated with "$title".'
          : '${candidates.length} entries fit "$title": choose one.',
    );
    notifyListeners();
    await window?.show();
    return null;
  }

  /// Closes the popup; the window goes back to hidden when it was.
  Future<void> close() async {
    _request = null;
    notifyListeners();
    if (_wasHidden) await window?.hide();
    _wasHidden = false;
  }

  /// Types [ref] into the window the popup was opened for: the popup
  /// closes, the window hides so that window gets the keyboard back, and
  /// typing starts once it is active again (it stops when another one is).
  Future<TomSecretsAutoTypeOutcome> typeInto(TomSecretsEntryRef ref) async {
    final target = _request?.windowTitle;
    _request = null;
    notifyListeners();
    final typer = _typer;
    final entry = session.entryOf(ref);
    if (typer == null || entry == null) {
      return _record(
        TomSecretsAutoTypeOutcome(
          TomSecretsAutoTypeResult.refused,
          support.reason ?? 'The entry is not open.',
        ),
      );
    }
    await window?.hide();
    _wasHidden = false;
    // The window typed into must be active again before a key goes out.
    for (var i = 0; i < 30 && target != null; i++) {
      if (keyboard!.activeWindowTitle() == target) break;
      await _pause(const Duration(milliseconds: 50));
    }
    if (target != null && keyboard!.activeWindowTitle() != target) {
      return _record(
        TomSecretsAutoTypeOutcome(
          TomSecretsAutoTypeResult.stopped,
          'The window "$target" did not get the keyboard back: nothing typed.',
        ),
      );
    }
    return _record(await typer.typeEntry(entry, windowTitle: target));
  }

  /// Types [ref] into the window that was active before this app (the
  /// entry editor's Auto-type).
  Future<TomSecretsAutoTypeOutcome> typeFromEditor(
    TomSecretsEntryRef ref,
  ) async {
    final typer = _typer;
    final entry = session.entryOf(ref);
    if (typer == null || entry == null) {
      return _record(
        TomSecretsAutoTypeOutcome(
          TomSecretsAutoTypeResult.refused,
          support.reason ?? 'The entry is not open.',
        ),
      );
    }
    await window?.hide();
    // The window behind this one gets the keyboard back.
    await _pause(const Duration(milliseconds: 400));
    return _record(await typer.typeEntry(entry));
  }

  TomSecretsAutoTypeOutcome _record(TomSecretsAutoTypeOutcome outcome) {
    _last = outcome;
    notifyListeners();
    return outcome;
  }

  /// The active window's title, unless it is this app's own.
  String? _activeOther() {
    final title = keyboard?.activeWindowTitle();
    if (title == null || title == tomSecretsAppWindowTitle) return null;
    return title;
  }
}

/// The app window's title, which auto-type never types into.
const String tomSecretsAppWindowTitle = 'Tom Secrets Manager';
