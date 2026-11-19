// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Auto-type's keyboard on macOS (part-password-manager, DP-41), through
/// FFI into the system frameworks, no plugin:
///
/// - **Typing:** keyboard events posted with `CGEventPost` to the HID event
///   tap. A character is a key event carrying its Unicode text
///   (`CGEventKeyboardSetUnicodeString`), so the keyboard layout does not
///   matter; a key with modifiers (`^v`) uses the virtual key of the ANSI
///   layout with the modifier flags.
/// - **The permission:** posting into other applications needs the
///   Accessibility permission (`AXIsProcessTrusted`); the app asks for it
///   with the system prompt (`AXIsProcessTrustedWithOptions`).
/// - **The active window's title:** the focused application's focused
///   window's `AXTitle` (the Accessibility API; the same permission).
/// - **Secure input:** `IsSecureEventInputEnabled` (Carbon) tells when a
///   password field or a terminal's secure keyboard entry refuses typed
///   keys.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show
        TomSecretsAutoTypeKey,
        TomSecretsAutoTypeKeyPress,
        TomSecretsAutoTypeModifier;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

final class _CFRange extends Struct {
  @Long()
  external int location;

  @Long()
  external int length;
}

/// The macOS keyboard.
final class TomSecretsMacKeyboard implements TomSecretsKeyboard {
  TomSecretsMacKeyboard._(this._app, this._cf, this._carbon);

  /// Opens the frameworks; null when they cannot be loaded.
  static TomSecretsMacKeyboard? open() {
    try {
      return TomSecretsMacKeyboard._(
        DynamicLibrary.open(
          '/System/Library/Frameworks/ApplicationServices.framework/'
          'ApplicationServices',
        ),
        DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/'
          'CoreFoundation',
        ),
        DynamicLibrary.open(
          '/System/Library/Frameworks/Carbon.framework/Carbon',
        ),
      );
    } on Object {
      return null;
    }
  }

  final DynamicLibrary _app;
  final DynamicLibrary _cf;
  final DynamicLibrary _carbon;

  late final _isTrusted = _app.lookupFunction<Bool Function(), bool Function()>(
    'AXIsProcessTrusted',
  );
  late final _isTrustedWithOptions = _app
      .lookupFunction<
        Bool Function(Pointer<Void>),
        bool Function(Pointer<Void>)
      >('AXIsProcessTrustedWithOptions');
  late final _sourceCreate = _app
      .lookupFunction<
        Pointer<Void> Function(Int32),
        Pointer<Void> Function(int)
      >('CGEventSourceCreate');
  late final _keyEvent = _app
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
        Pointer<Void> Function(Pointer<Void>, int, bool)
      >('CGEventCreateKeyboardEvent');
  late final _setUnicode = _app
      .lookupFunction<
        Void Function(Pointer<Void>, UnsignedLong, Pointer<Uint16>),
        void Function(Pointer<Void>, int, Pointer<Uint16>)
      >('CGEventKeyboardSetUnicodeString');
  late final _setFlags = _app
      .lookupFunction<
        Void Function(Pointer<Void>, Uint64),
        void Function(Pointer<Void>, int)
      >('CGEventSetFlags');
  late final _post = _app
      .lookupFunction<
        Void Function(Uint32, Pointer<Void>),
        void Function(int, Pointer<Void>)
      >('CGEventPost');
  late final _systemWide = _app
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'AXUIElementCreateSystemWide',
      );
  late final _copyAttribute = _app
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)
      >('AXUIElementCopyAttributeValue');
  late final _release = _cf
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
  late final _stringCreate = _cf
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
      >('CFStringCreateWithCString');
  late final _stringLength = _cf
      .lookupFunction<
        Long Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CFStringGetLength');
  late final _stringCharacters = _cf
      .lookupFunction<
        Void Function(Pointer<Void>, _CFRange, Pointer<Uint16>),
        void Function(Pointer<Void>, _CFRange, Pointer<Uint16>)
      >('CFStringGetCharacters');
  late final _typeId = _cf
      .lookupFunction<
        UnsignedLong Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CFGetTypeID');
  late final _stringTypeId = _cf
      .lookupFunction<UnsignedLong Function(), int Function()>(
        'CFStringGetTypeID',
      );
  late final _dictionaryCreate = _cf
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Long,
          Pointer<Void>,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          int,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('CFDictionaryCreate');
  late final _secureInput = _carbon
      .lookupFunction<Uint8 Function(), int Function()>(
        'IsSecureEventInputEnabled',
      );

  static const _hidSystemState = 1;
  static const _hidEventTap = 0;
  static const _utf8 = 0x08000100;

  late final Pointer<Void> _source = _sourceCreate(_hidSystemState);

  @override
  TomSecretsAutoTypeSupport support() => _isTrusted()
      ? TomSecretsAutoTypeSupport.ok
      : const TomSecretsAutoTypeSupport(
          available: false,
          permissionNeeded: true,
          reason:
              'macOS lets the app type into other windows only with the '
              'Accessibility permission (System Settings › Privacy & Security '
              '› Accessibility).',
        );

  @override
  Future<bool> requestPermission() async {
    // {kAXTrustedCheckOptionPrompt: true}: macOS shows its prompt.
    final keys = calloc<Pointer<Void>>();
    final values = calloc<Pointer<Void>>();
    try {
      keys.value = _app
          .lookup<Pointer<Void>>('kAXTrustedCheckOptionPrompt')
          .value;
      values.value = _cf.lookup<Pointer<Void>>('kCFBooleanTrue').value;
      final options = _dictionaryCreate(
        nullptr,
        keys,
        values,
        1,
        _cf.lookup<Void>('kCFTypeDictionaryKeyCallBacks'),
        _cf.lookup<Void>('kCFTypeDictionaryValueCallBacks'),
      );
      final trusted = _isTrustedWithOptions(options);
      _release(options);
      return trusted;
    } finally {
      calloc
        ..free(keys)
        ..free(values);
    }
  }

  @override
  bool secureInputActive() => _secureInput() != 0;

  @override
  String? takeRefusal() => null;

  @override
  String? activeWindowTitle() {
    final system = _systemWide();
    try {
      final app = _attribute(system, 'AXFocusedApplication');
      if (app == null) return null;
      try {
        final window = _attribute(app, 'AXFocusedWindow');
        if (window == null) return null;
        try {
          final title = _attribute(window, 'AXTitle');
          if (title == null) return null;
          try {
            return _string(title);
          } finally {
            _release(title);
          }
        } finally {
          _release(window);
        }
      } finally {
        _release(app);
      }
    } finally {
      _release(system);
    }
  }

  /// The attribute [name] of the AX element [element] (retained), or null.
  Pointer<Void>? _attribute(Pointer<Void> element, String name) {
    final key = name.toNativeUtf8();
    final cfKey = _stringCreate(nullptr, key, _utf8);
    final out = calloc<Pointer<Void>>();
    try {
      final error = _copyAttribute(element, cfKey, out);
      return error == 0 && out.value != nullptr ? out.value : null;
    } finally {
      _release(cfKey);
      calloc
        ..free(key)
        ..free(out);
    }
  }

  String? _string(Pointer<Void> cf) {
    if (_typeId(cf) != _stringTypeId()) return null;
    final length = _stringLength(cf);
    final buffer = calloc<Uint16>(length == 0 ? 1 : length);
    final range = calloc<_CFRange>();
    try {
      range.ref
        ..location = 0
        ..length = length;
      _stringCharacters(cf, range.ref, buffer);
      return String.fromCharCodes(buffer.asTypedList(length));
    } finally {
      calloc
        ..free(buffer)
        ..free(range);
    }
  }

  void _postKey(int keyCode, bool down, int flags, [String? text]) {
    final event = _keyEvent(_source, keyCode, down);
    if (event == nullptr) return;
    try {
      _setFlags(event, flags);
      if (text != null) {
        final units = text.codeUnits;
        final buffer = calloc<Uint16>(units.length);
        try {
          buffer.asTypedList(units.length).setAll(0, units);
          _setUnicode(event, units.length, buffer);
        } finally {
          calloc.free(buffer);
        }
      }
      _post(_hidEventTap, event);
    } finally {
      _release(event);
    }
  }

  @override
  void typeCharacter(String character) {
    _postKey(0, true, 0, character);
    _postKey(0, false, 0, character);
  }

  @override
  void press(TomSecretsAutoTypeKeyPress press) {
    var flags = 0;
    for (final m in press.modifiers) {
      flags |= switch (m) {
        TomSecretsAutoTypeModifier.shift => 0x00020000,
        TomSecretsAutoTypeModifier.control => 0x00040000,
        TomSecretsAutoTypeModifier.alt => 0x00080000,
        TomSecretsAutoTypeModifier.meta => 0x00100000,
      };
    }
    final key = press.key;
    if (key != null) {
      final code = _keyCode(key, press.function);
      _postKey(code, true, flags);
      _postKey(code, false, flags);
      return;
    }
    final character = press.character!;
    final code = _ansi[character.toLowerCase()];
    if (code == null) {
      // No key for it on the ANSI layout: its text with the flags.
      _postKey(0, true, flags, character);
      _postKey(0, false, flags, character);
      return;
    }
    _postKey(code, true, flags);
    _postKey(code, false, flags);
  }

  static int _keyCode(TomSecretsAutoTypeKey key, int function) => switch (key) {
    TomSecretsAutoTypeKey.tab => 48,
    TomSecretsAutoTypeKey.enter => 36,
    TomSecretsAutoTypeKey.space => 49,
    TomSecretsAutoTypeKey.backspace => 51,
    TomSecretsAutoTypeKey.delete => 117,
    TomSecretsAutoTypeKey.escape => 53,
    TomSecretsAutoTypeKey.left => 123,
    TomSecretsAutoTypeKey.right => 124,
    TomSecretsAutoTypeKey.down => 125,
    TomSecretsAutoTypeKey.up => 126,
    TomSecretsAutoTypeKey.home => 115,
    TomSecretsAutoTypeKey.end => 119,
    TomSecretsAutoTypeKey.pageUp => 116,
    TomSecretsAutoTypeKey.pageDown => 121,
    TomSecretsAutoTypeKey.insert => 114,
    TomSecretsAutoTypeKey.function => const [
      122, 120, 99, 118, 96, 97, 98, 100, //
      101, 109, 103, 111, 105, 107, 113, 106,
    ][(function - 1).clamp(0, 15)],
  };

  /// The ANSI layout's virtual keys of the characters a shortcut uses.
  static const Map<String, int> _ansi = {
    'a': 0, 's': 1, 'd': 2, 'f': 3, 'h': 4, 'g': 5, 'z': 6, 'x': 7, //
    'c': 8, 'v': 9, 'b': 11, 'q': 12, 'w': 13, 'e': 14, 'r': 15, 'y': 16,
    't': 17, '1': 18, '2': 19, '3': 20, '4': 21, '6': 22, '5': 23, '=': 24,
    '9': 25, '7': 26, '-': 27, '8': 28, '0': 29, ']': 30, 'o': 31, 'u': 32,
    '[': 33, 'i': 34, 'p': 35, 'l': 37, 'j': 38, "'": 39, 'k': 40, ';': 41,
    r'\': 42, ',': 43, '/': 44, 'n': 45, 'm': 46, '.': 47, '`': 50,
  };
}
