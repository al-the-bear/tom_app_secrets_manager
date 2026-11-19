// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Auto-type's keyboard on Linux with X11 (part-password-manager, DP-41),
/// through FFI into `libX11` and `libXtst`, no plugin.
///
/// - **Wayland:** not offered. A Wayland session lets no program type into
///   another's window (the browser extension and copying cover logins
///   there); [TomSecretsX11Keyboard.open] says so.
/// - **Typing:** `XTestFakeKeyEvent`. A character is typed by its keysym's
///   key on the current layout (with Shift when it sits on the second
///   level); a character the layout does not have is mapped onto a spare
///   keycode for the moment it is typed, then the mapping is removed again.
/// - **The active window's title:** the root window's `_NET_ACTIVE_WINDOW`
///   and that window's `_NET_WM_NAME` (else `WM_NAME`).
library;

import 'dart:ffi';
import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show
        TomSecretsAutoTypeKey,
        TomSecretsAutoTypeKeyPress,
        TomSecretsAutoTypeModifier;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// Why auto-type is not offered in this Linux session, or null on X11.
String? tomSecretsX11Unavailable(Map<String, String> environment) {
  final session = (environment['XDG_SESSION_TYPE'] ?? '').toLowerCase();
  if (session == 'wayland' ||
      (environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty) {
    return 'This desktop runs Wayland, which lets no program type into '
        'another\'s window: use the browser extension or copy the values.';
  }
  if ((environment['DISPLAY'] ?? '').isEmpty) {
    return 'No X11 display: auto-type needs an X11 session.';
  }
  return null;
}

/// The X11 keyboard.
final class TomSecretsX11Keyboard implements TomSecretsKeyboard {
  TomSecretsX11Keyboard._(this._x11, this._xtst, this._display);

  /// Opens the display; a keyboard that only says why not when this is a
  /// Wayland session, there is no display, or a library is missing.
  static TomSecretsKeyboard open({Map<String, String>? environment}) {
    final why = tomSecretsX11Unavailable(environment ?? Platform.environment);
    if (why != null) return _Unavailable(why);
    try {
      final x11 = DynamicLibrary.open('libX11.so.6');
      final xtst = DynamicLibrary.open('libXtst.so.6');
      final openDisplay = x11
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('XOpenDisplay');
      final display = openDisplay(nullptr);
      if (display == nullptr) {
        return const _Unavailable('The X11 display cannot be opened.');
      }
      return TomSecretsX11Keyboard._(x11, xtst, display);
    } on ArgumentError {
      return const _Unavailable(
        'Auto-type needs libX11 and libXtst (the package libxtst6).',
      );
    }
  }

  final DynamicLibrary _x11;
  final DynamicLibrary _xtst;
  final Pointer<Void> _display;

  late final _root = _x11
      .lookupFunction<
        UnsignedLong Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('XDefaultRootWindow');
  late final _internAtom = _x11
      .lookupFunction<
        UnsignedLong Function(Pointer<Void>, Pointer<Utf8>, Int32),
        int Function(Pointer<Void>, Pointer<Utf8>, int)
      >('XInternAtom');
  late final _getProperty = _x11
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          UnsignedLong,
          UnsignedLong,
          Long,
          Long,
          Int32,
          UnsignedLong,
          Pointer<UnsignedLong>,
          Pointer<Int32>,
          Pointer<UnsignedLong>,
          Pointer<UnsignedLong>,
          Pointer<Pointer<Uint8>>,
        ),
        int Function(
          Pointer<Void>,
          int,
          int,
          int,
          int,
          int,
          int,
          Pointer<UnsignedLong>,
          Pointer<Int32>,
          Pointer<UnsignedLong>,
          Pointer<UnsignedLong>,
          Pointer<Pointer<Uint8>>,
        )
      >('XGetWindowProperty');
  late final _free = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('XFree');
  late final _keysymToKeycode = _x11
      .lookupFunction<
        Uint8 Function(Pointer<Void>, UnsignedLong),
        int Function(Pointer<Void>, int)
      >('XKeysymToKeycode');
  late final _keycodeToKeysym = _x11
      .lookupFunction<
        UnsignedLong Function(Pointer<Void>, Uint8, Int32, Int32),
        int Function(Pointer<Void>, int, int, int)
      >('XkbKeycodeToKeysym');
  late final _displayKeycodes = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Int32>, Pointer<Int32>)
      >('XDisplayKeycodes');
  late final _getMapping = _x11
      .lookupFunction<
        Pointer<UnsignedLong> Function(
          Pointer<Void>,
          Uint8,
          Int32,
          Pointer<Int32>,
        ),
        Pointer<UnsignedLong> Function(Pointer<Void>, int, int, Pointer<Int32>)
      >('XGetKeyboardMapping');
  late final _changeMapping = _x11
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Int32,
          Pointer<UnsignedLong>,
          Int32,
        ),
        int Function(Pointer<Void>, int, int, Pointer<UnsignedLong>, int)
      >('XChangeKeyboardMapping');
  late final _sync = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('XSync');
  late final _flush = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('XFlush');
  late final _fakeKey = _xtst
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Int32, UnsignedLong),
        int Function(Pointer<Void>, int, int, int)
      >('XTestFakeKeyEvent');

  int? _spare;

  @override
  TomSecretsAutoTypeSupport support() => TomSecretsAutoTypeSupport.ok;

  @override
  Future<bool> requestPermission() async => true;

  @override
  bool secureInputActive() => false;

  @override
  String? takeRefusal() => null;

  int _atom(String name) {
    final n = name.toNativeUtf8();
    try {
      return _internAtom(_display, n, 0);
    } finally {
      calloc.free(n);
    }
  }

  /// The bytes of [property] of [window] (and their format), or null.
  (List<int>, int)? _property(int window, String property) {
    final type = calloc<UnsignedLong>();
    final format = calloc<Int32>();
    final count = calloc<UnsignedLong>();
    final after = calloc<UnsignedLong>();
    final data = calloc<Pointer<Uint8>>();
    try {
      final status = _getProperty(
        _display,
        window,
        _atom(property),
        0,
        4096,
        0,
        0, // AnyPropertyType
        type,
        format,
        count,
        after,
        data,
      );
      if (status != 0 || data.value == nullptr) return null;
      try {
        // Format 32 comes as C longs (8 bytes here).
        final size = switch (format.value) {
          8 => count.value,
          16 => count.value * 2,
          _ => count.value * sizeOf<UnsignedLong>(),
        };
        return (List.of(data.value.asTypedList(size)), format.value);
      } finally {
        _free(data.value.cast());
      }
    } finally {
      calloc
        ..free(type)
        ..free(format)
        ..free(count)
        ..free(after)
        ..free(data);
    }
  }

  @override
  String? activeWindowTitle() {
    final active = _property(_root(_display), '_NET_ACTIVE_WINDOW');
    if (active == null || active.$1.length < sizeOf<UnsignedLong>()) {
      return null;
    }
    var window = 0;
    for (var i = sizeOf<UnsignedLong>() - 1; i >= 0; i--) {
      window = (window << 8) | active.$1[i];
    }
    if (window == 0) return null;
    final name =
        _property(window, '_NET_WM_NAME') ?? _property(window, 'WM_NAME');
    if (name == null) return null;
    return String.fromCharCodes(
      _decodeUtf8(name.$1.takeWhile((b) => b != 0).toList()),
    );
  }

  static List<int> _decodeUtf8(List<int> bytes) {
    try {
      return const Utf8Decoder().convert(bytes).runes.toList();
    } on FormatException {
      return bytes; // Latin-1 (WM_NAME)
    }
  }

  /// The keysym of [character] (X11's Unicode keysyms past Latin-1).
  static int _keysymOf(String character) {
    final rune = character.runes.first;
    if (rune == 0x0A || rune == 0x0D) return 0xff0d;
    if (rune == 0x09) return 0xff09;
    return rune < 0x100 ? rune : 0x01000000 | rune;
  }

  void _key(int keycode, bool down) =>
      _fakeKey(_display, keycode, down ? 1 : 0, 0);

  /// Types [keysym] with [modifiers] held (their keysyms).
  void _typeKeysym(int keysym, List<int> modifiers) {
    var keycode = _keysymToKeycode(_display, keysym);
    var shift = false;
    var remapped = false;
    if (keycode != 0) {
      final level0 = _keycodeToKeysym(_display, keycode, 0, 0);
      final level1 = _keycodeToKeysym(_display, keycode, 0, 1);
      if (level0 != keysym) {
        if (level1 == keysym) {
          shift = true;
        } else {
          keycode = 0; // only on a third level (AltGr): remap
        }
      }
    }
    if (keycode == 0) {
      keycode = _remap(keysym);
      if (keycode == 0) return;
      remapped = true;
    }
    final held = [
      for (final m in modifiers) _keysymToKeycode(_display, m),
      if (shift) _keysymToKeycode(_display, 0xffe1),
    ];
    for (final m in held) {
      _key(m, true);
    }
    _key(keycode, true);
    _key(keycode, false);
    for (final m in held.reversed) {
      _key(m, false);
    }
    _flush(_display);
    if (remapped) {
      // The application reads the key before the mapping goes away.
      _sync(_display, 0);
      sleep(const Duration(milliseconds: 15));
      _setMapping(keycode, 0);
    }
  }

  /// Maps [keysym] onto a keycode no layout key uses; answers it (0: none).
  int _remap(int keysym) {
    final spare = _spare ??= _findSpare();
    if (spare == 0) return 0;
    _setMapping(spare, keysym);
    _sync(_display, 0);
    sleep(const Duration(milliseconds: 15));
    return spare;
  }

  void _setMapping(int keycode, int keysym) {
    final syms = calloc<UnsignedLong>(2);
    try {
      syms[0] = keysym;
      syms[1] = keysym;
      _changeMapping(_display, keycode, 2, syms, 1);
      _flush(_display);
    } finally {
      calloc.free(syms);
    }
  }

  int _findSpare() {
    final min = calloc<Int32>();
    final max = calloc<Int32>();
    final per = calloc<Int32>();
    try {
      _displayKeycodes(_display, min, max);
      final count = max.value - min.value + 1;
      final map = _getMapping(_display, min.value, count, per);
      if (map == nullptr) return 0;
      try {
        for (var k = count - 1; k >= 0; k--) {
          var empty = true;
          for (var j = 0; j < per.value; j++) {
            if (map[k * per.value + j] != 0) empty = false;
          }
          if (empty) return min.value + k;
        }
        return 0;
      } finally {
        _free(map.cast());
      }
    } finally {
      calloc
        ..free(min)
        ..free(max)
        ..free(per);
    }
  }

  @override
  void typeCharacter(String character) =>
      _typeKeysym(_keysymOf(character), const []);

  @override
  void press(TomSecretsAutoTypeKeyPress press) {
    final modifiers = [
      for (final m in press.modifiers)
        switch (m) {
          TomSecretsAutoTypeModifier.shift => 0xffe1,
          TomSecretsAutoTypeModifier.control => 0xffe3,
          TomSecretsAutoTypeModifier.alt => 0xffe9,
          TomSecretsAutoTypeModifier.meta => 0xffeb,
        },
    ];
    final key = press.key;
    final keysym = key == null
        ? _keysymOf(press.character!)
        : switch (key) {
            TomSecretsAutoTypeKey.tab => 0xff09,
            TomSecretsAutoTypeKey.enter => 0xff0d,
            TomSecretsAutoTypeKey.space => 0x20,
            TomSecretsAutoTypeKey.backspace => 0xff08,
            TomSecretsAutoTypeKey.delete => 0xffff,
            TomSecretsAutoTypeKey.escape => 0xff1b,
            TomSecretsAutoTypeKey.left => 0xff51,
            TomSecretsAutoTypeKey.up => 0xff52,
            TomSecretsAutoTypeKey.right => 0xff53,
            TomSecretsAutoTypeKey.down => 0xff54,
            TomSecretsAutoTypeKey.home => 0xff50,
            TomSecretsAutoTypeKey.end => 0xff57,
            TomSecretsAutoTypeKey.pageUp => 0xff55,
            TomSecretsAutoTypeKey.pageDown => 0xff56,
            TomSecretsAutoTypeKey.insert => 0xff63,
            TomSecretsAutoTypeKey.function =>
              0xffbe + (press.function - 1).clamp(0, 15),
          };
    _typeKeysym(keysym, modifiers);
  }
}

/// A keyboard that cannot type here, saying why.
final class _Unavailable implements TomSecretsKeyboard {
  const _Unavailable(this.reason);

  final String reason;

  @override
  TomSecretsAutoTypeSupport support() =>
      TomSecretsAutoTypeSupport(available: false, reason: reason);

  @override
  Future<bool> requestPermission() async => false;

  @override
  String? activeWindowTitle() => null;

  @override
  bool secureInputActive() => false;

  @override
  String? takeRefusal() => null;

  @override
  void typeCharacter(String character) {}

  @override
  void press(TomSecretsAutoTypeKeyPress press) {}
}
