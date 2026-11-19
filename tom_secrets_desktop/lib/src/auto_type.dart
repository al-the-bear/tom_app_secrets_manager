// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop's auto-type keyboard and global hotkeys (part-app,
/// part-password-manager, DP-41, DP-32):
///
/// - [tomSecretsDesktopKeyboard]: the keyboard of this OS
///   ([TomSecretsMacKeyboard], [TomSecretsWindowsKeyboard],
///   [TomSecretsX11Keyboard]; on Wayland one that says why not).
/// - [tomSecretsDesktopHotkeys]: global hotkeys through this package's own
///   platform code on macOS (Carbon `RegisterEventHotKey`) and Windows
///   (`RegisterHotKey`), and through FFI on X11 (`XGrabKey` on the root
///   window, its events read every 100 ms); none on Wayland.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsAutoTypeModifier;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'keyboard_macos.dart';
import 'keyboard_windows.dart';
import 'keyboard_x11.dart';

/// This desktop's keyboard for auto-type, or null where there is none.
TomSecretsKeyboard? tomSecretsDesktopKeyboard() {
  if (Platform.isMacOS) return TomSecretsMacKeyboard.open();
  if (Platform.isWindows) return TomSecretsWindowsKeyboard.open();
  if (Platform.isLinux) return TomSecretsX11Keyboard.open();
  return null;
}

/// This desktop's global hotkeys, or null where there are none (Wayland).
TomSecretsHotkeys? tomSecretsDesktopHotkeys() {
  if (Platform.isMacOS || Platform.isWindows) {
    return TomSecretsChannelHotkeys(macOS: Platform.isMacOS);
  }
  if (Platform.isLinux &&
      tomSecretsX11Unavailable(Platform.environment) == null) {
    return TomSecretsX11Hotkeys.open();
  }
  return null;
}

String _modifierName(TomSecretsAutoTypeModifier m) => switch (m) {
  TomSecretsAutoTypeModifier.control => 'control',
  TomSecretsAutoTypeModifier.alt => 'alt',
  TomSecretsAutoTypeModifier.shift => 'shift',
  TomSecretsAutoTypeModifier.meta => 'meta',
};

/// The virtual key of [key] (a [TomSecretsHotkey.key]) on macOS.
int tomSecretsMacKeyCode(String key) {
  const letters = {
    'A': 0, 'S': 1, 'D': 2, 'F': 3, 'H': 4, 'G': 5, 'Z': 6, 'X': 7, //
    'C': 8, 'V': 9, 'B': 11, 'Q': 12, 'W': 13, 'E': 14, 'R': 15, 'Y': 16,
    'T': 17, '1': 18, '2': 19, '3': 20, '4': 21, '6': 22, '5': 23, '9': 25,
    '7': 26, '8': 28, '0': 29, 'O': 31, 'U': 32, 'I': 34, 'P': 35, 'L': 37,
    'J': 38, 'K': 40, 'N': 45, 'M': 46,
  };
  const functions = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111];
  return switch (key) {
    'Space' => 49,
    'Enter' => 36,
    'Tab' => 48,
    _ when key.startsWith('F') && key.length > 1 =>
      functions[int.parse(key.substring(1)) - 1],
    _ => letters[key]!,
  };
}

/// The virtual key of [key] on Windows.
int tomSecretsWindowsKeyCode(String key) => switch (key) {
  'Space' => 0x20,
  'Enter' => 0x0D,
  'Tab' => 0x09,
  _ when key.startsWith('F') && key.length > 1 =>
    0x70 + int.parse(key.substring(1)) - 1,
  _ => key.codeUnitAt(0),
};

/// Hotkeys through `tom_secrets_desktop/hotkeys` (macOS, Windows).
final class TomSecretsChannelHotkeys implements TomSecretsHotkeys {
  /// On macOS when [macOS], else Windows.
  TomSecretsChannelHotkeys({required this.macOS}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pressed') _handlers[call.arguments as String]?.call();
    });
  }

  /// Whether this is macOS (its virtual keys).
  final bool macOS;

  static const _channel = MethodChannel('tom_secrets_desktop/hotkeys');
  final Map<String, void Function()> _handlers = {};

  @override
  Future<void> register(
    String id,
    TomSecretsHotkey hotkey,
    void Function() onPressed,
  ) async {
    final error = await _channel.invokeMethod<String>('register', {
      'id': id,
      'keyCode': macOS
          ? tomSecretsMacKeyCode(hotkey.key)
          : tomSecretsWindowsKeyCode(hotkey.key),
      'modifiers': [for (final m in hotkey.modifiers) _modifierName(m)],
    });
    if (error != null) throw StateError(error);
    _handlers[id] = onPressed;
  }

  @override
  Future<void> unregister(String id) async {
    _handlers.remove(id);
    await _channel.invokeMethod<void>('unregister', {'id': id});
  }
}

// The Xlib error handler: a refused grab (BadAccess) is noted, never fatal.
int _xError = 0;
int _onXError(Pointer<Void> display, Pointer<Uint8> event) {
  // XErrorEvent: type (4), padding (4), display (8), resourceid (8),
  // serial (8), error_code (1).
  _xError = event[32];
  return 0;
}

/// Hotkeys on X11: `XGrabKey` on the root window (also with Caps Lock and
/// Num Lock held), the key events read every 100 ms on a display connection
/// of its own.
final class TomSecretsX11Hotkeys implements TomSecretsHotkeys {
  TomSecretsX11Hotkeys._(this._x11, this._display);

  /// Opens a display connection; null when there is none.
  static TomSecretsX11Hotkeys? open() {
    try {
      final x11 = DynamicLibrary.open('libX11.so.6');
      final display = x11
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('XOpenDisplay')(nullptr);
      if (display == nullptr) return null;
      x11.lookupFunction<
        Pointer<Void> Function(Pointer<NativeFunction<_ErrorHandler>>),
        Pointer<Void> Function(Pointer<NativeFunction<_ErrorHandler>>)
      >('XSetErrorHandler')(Pointer.fromFunction<_ErrorHandler>(_onXError, 0));
      return TomSecretsX11Hotkeys._(x11, display);
    } on ArgumentError {
      return null;
    }
  }

  final DynamicLibrary _x11;
  final Pointer<Void> _display;
  final Map<String, (int keycode, int modifiers, void Function())> _keys = {};
  Timer? _poll;

  late final _root = _x11
      .lookupFunction<
        UnsignedLong Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('XDefaultRootWindow');
  late final _keysymToKeycode = _x11
      .lookupFunction<
        Uint8 Function(Pointer<Void>, UnsignedLong),
        int Function(Pointer<Void>, int)
      >('XKeysymToKeycode');
  late final _grab = _x11
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Uint32,
          UnsignedLong,
          Int32,
          Int32,
          Int32,
        ),
        int Function(Pointer<Void>, int, int, int, int, int, int)
      >('XGrabKey');
  late final _ungrab = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Uint32, UnsignedLong),
        int Function(Pointer<Void>, int, int, int)
      >('XUngrabKey');
  late final _sync = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('XSync');
  late final _pending = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('XPending');
  late final _nextEvent = _x11
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>),
        int Function(Pointer<Void>, Pointer<Uint8>)
      >('XNextEvent');

  static const _lock = 2;
  static const _numLock = 16;

  static int _keysymOf(String key) => switch (key) {
    'Space' => 0x20,
    'Enter' => 0xff0d,
    'Tab' => 0xff09,
    _ when key.startsWith('F') && key.length > 1 =>
      0xffbe + int.parse(key.substring(1)) - 1,
    _ => key.toLowerCase().codeUnitAt(0),
  };

  static int _maskOf(Set<TomSecretsAutoTypeModifier> modifiers) {
    var mask = 0;
    for (final m in modifiers) {
      mask |= switch (m) {
        TomSecretsAutoTypeModifier.shift => 1,
        TomSecretsAutoTypeModifier.control => 4,
        TomSecretsAutoTypeModifier.alt => 8,
        TomSecretsAutoTypeModifier.meta => 64,
      };
    }
    return mask;
  }

  @override
  Future<void> register(
    String id,
    TomSecretsHotkey hotkey,
    void Function() onPressed,
  ) async {
    await unregister(id);
    final keycode = _keysymToKeycode(_display, _keysymOf(hotkey.key));
    if (keycode == 0) throw StateError('no key for ${hotkey.key}');
    final mask = _maskOf(hotkey.modifiers);
    final root = _root(_display);
    _xError = 0;
    for (final extra in const [0, _lock, _numLock, _lock | _numLock]) {
      _grab(_display, keycode, mask | extra, root, 0, 1, 1);
    }
    _sync(_display, 0);
    if (_xError != 0) {
      for (final extra in const [0, _lock, _numLock, _lock | _numLock]) {
        _ungrab(_display, keycode, mask | extra, root);
      }
      _sync(_display, 0);
      throw StateError('another program holds $hotkey');
    }
    _keys[id] = (keycode, mask, onPressed);
    _poll ??= Timer.periodic(const Duration(milliseconds: 100), (_) => _read());
  }

  void _read() {
    final event = calloc<Uint8>(192);
    try {
      while (_pending(_display) > 0) {
        _nextEvent(_display, event);
        // XKeyEvent: type at 0 (KeyPress 2), state at 80, keycode at 84.
        final data = event.asTypedList(192).buffer.asByteData();
        if (data.getInt32(0, Endian.host) != 2) continue;
        final state =
            data.getUint32(80, Endian.host) & ~(_lock | _numLock) & 0xff;
        final keycode = data.getUint32(84, Endian.host);
        for (final (code, mask, run) in _keys.values) {
          if (code == keycode && mask == state) run();
        }
      }
    } finally {
      calloc.free(event);
    }
  }

  @override
  Future<void> unregister(String id) async {
    final key = _keys.remove(id);
    if (key == null) return;
    final root = _root(_display);
    for (final extra in const [0, _lock, _numLock, _lock | _numLock]) {
      _ungrab(_display, key.$1, key.$2 | extra, root);
    }
    _sync(_display, 0);
    if (_keys.isEmpty) {
      _poll?.cancel();
      _poll = null;
    }
  }
}

typedef _ErrorHandler = Int32 Function(Pointer<Void>, Pointer<Uint8>);
