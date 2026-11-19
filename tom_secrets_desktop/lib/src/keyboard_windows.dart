// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Auto-type's keyboard on Windows (part-password-manager, DP-41), through
/// FFI into `user32.dll`, no plugin:
///
/// - **Typing:** `SendInput`. A character goes as Unicode
///   (`KEYEVENTF_UNICODE`, each UTF-16 unit), so the keyboard layout does
///   not matter; a key with modifiers (`^v`) uses the virtual key
///   `VkKeyScanW` gives for the character on the current layout.
/// - **The active window's title:** `GetForegroundWindow` and
///   `GetWindowTextW`.
/// - **Limits:** Windows drops input into a window of a program running as
///   administrator (UIPI) when this app is not; `SendInput` then sends
///   fewer events, and typing stops with that said.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show
        TomSecretsAutoTypeKey,
        TomSecretsAutoTypeKeyPress,
        TomSecretsAutoTypeModifier;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The Windows keyboard.
final class TomSecretsWindowsKeyboard implements TomSecretsKeyboard {
  TomSecretsWindowsKeyboard._(this._user32);

  /// Opens `user32.dll`; null when it cannot be loaded.
  static TomSecretsWindowsKeyboard? open() {
    try {
      return TomSecretsWindowsKeyboard._(DynamicLibrary.open('user32.dll'));
    } on Object {
      return null;
    }
  }

  final DynamicLibrary _user32;

  late final _sendInput = _user32
      .lookupFunction<
        Uint32 Function(Uint32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)
      >('SendInput');
  late final _foreground = _user32
      .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
  late final _textLength = _user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'GetWindowTextLengthW',
      );
  late final _text = _user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Int32),
        int Function(int, Pointer<Uint16>, int)
      >('GetWindowTextW');
  late final _vkKeyScan = _user32
      .lookupFunction<Int16 Function(Uint16), int Function(int)>('VkKeyScanW');

  // INPUT on 64-bit Windows: type (4) + padding (4) + KEYBDINPUT inside the
  // 32-byte union (wVk 2, wScan 2, dwFlags 4, time 4, padding 4,
  // dwExtraInfo 8) = 40 bytes.
  static const _inputSize = 40;
  static const _inputKeyboard = 1;
  static const _keyUp = 0x0002;
  static const _unicode = 0x0004;
  static const _extended = 0x0001;

  // Why the last `SendInput` sent fewer events than asked, or null.
  String? _lastRefusal;

  @override
  String? takeRefusal() {
    final why = _lastRefusal;
    _lastRefusal = null;
    return why;
  }

  void _send(List<(int vk, int scan, int flags)> events) {
    final buffer = calloc<Uint8>(_inputSize * events.length);
    try {
      final data = buffer
          .asTypedList(_inputSize * events.length)
          .buffer
          .asByteData();
      for (final (i, (vk, scan, flags)) in events.indexed) {
        final at = i * _inputSize;
        data
          ..setUint32(at, _inputKeyboard, Endian.little)
          ..setUint16(at + 8, vk, Endian.little)
          ..setUint16(at + 10, scan, Endian.little)
          ..setUint32(at + 12, flags, Endian.little);
      }
      final sent = _sendInput(events.length, buffer, _inputSize);
      _lastRefusal = sent == events.length
          ? null
          : 'Windows refused the keys (the window may belong to a program '
                'running as administrator).';
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  TomSecretsAutoTypeSupport support() => TomSecretsAutoTypeSupport.ok;

  @override
  Future<bool> requestPermission() async => true;

  @override
  bool secureInputActive() => false;

  @override
  String? activeWindowTitle() {
    final window = _foreground();
    if (window == 0) return null;
    final length = _textLength(window);
    final buffer = calloc<Uint16>(length + 1);
    try {
      final read = _text(window, buffer, length + 1);
      return String.fromCharCodes(buffer.asTypedList(read));
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  void typeCharacter(String character) {
    _send([
      for (final unit in character.codeUnits) ...[
        (0, unit, _unicode),
        (0, unit, _unicode | _keyUp),
      ],
    ]);
  }

  @override
  void press(TomSecretsAutoTypeKeyPress press) {
    final modifiers = [
      for (final m in press.modifiers)
        switch (m) {
          TomSecretsAutoTypeModifier.shift => 0x10,
          TomSecretsAutoTypeModifier.control => 0x11,
          TomSecretsAutoTypeModifier.alt => 0x12,
          TomSecretsAutoTypeModifier.meta => 0x5B,
        },
    ];
    final int vk;
    var flags = 0;
    final key = press.key;
    if (key != null) {
      (vk, flags) = _virtualKey(key, press.function);
    } else {
      final scan = _vkKeyScan(press.character!.codeUnitAt(0));
      if (scan == -1) {
        // Not on this layout: its text.
        typeCharacter(press.character!);
        return;
      }
      vk = scan & 0xff;
      // The layout's own shift state for the character.
      if (scan & 0x100 != 0 && !modifiers.contains(0x10)) modifiers.add(0x10);
    }
    _send([
      for (final m in modifiers) (m, 0, 0),
      (vk, 0, flags),
      (vk, 0, flags | _keyUp),
      for (final m in modifiers.reversed) (m, 0, _keyUp),
    ]);
  }

  static (int, int) _virtualKey(TomSecretsAutoTypeKey key, int function) =>
      switch (key) {
        TomSecretsAutoTypeKey.tab => (0x09, 0),
        TomSecretsAutoTypeKey.enter => (0x0D, 0),
        TomSecretsAutoTypeKey.space => (0x20, 0),
        TomSecretsAutoTypeKey.backspace => (0x08, 0),
        TomSecretsAutoTypeKey.delete => (0x2E, _extended),
        TomSecretsAutoTypeKey.escape => (0x1B, 0),
        TomSecretsAutoTypeKey.left => (0x25, _extended),
        TomSecretsAutoTypeKey.up => (0x26, _extended),
        TomSecretsAutoTypeKey.right => (0x27, _extended),
        TomSecretsAutoTypeKey.down => (0x28, _extended),
        TomSecretsAutoTypeKey.home => (0x24, _extended),
        TomSecretsAutoTypeKey.end => (0x23, _extended),
        TomSecretsAutoTypeKey.pageUp => (0x21, _extended),
        TomSecretsAutoTypeKey.pageDown => (0x22, _extended),
        TomSecretsAutoTypeKey.insert => (0x2D, _extended),
        TomSecretsAutoTypeKey.function => (
          0x70 + (function - 1).clamp(0, 15),
          0,
        ),
      };
}
