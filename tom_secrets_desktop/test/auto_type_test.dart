// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop's auto-type keyboard and hotkeys (DP-41): Wayland and a
/// missing display say why not; the hotkeys' virtual keys per OS; on macOS
/// the framework functions resolve and answer (nothing is typed: a test
/// would type into whatever window has the keyboard).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';

void main() {
  test('Linux: Wayland and a missing display are named, X11 passes', () {
    expect(
      tomSecretsX11Unavailable({
        'XDG_SESSION_TYPE': 'wayland',
        'DISPLAY': ':0',
      }),
      contains('Wayland'),
    );
    expect(
      tomSecretsX11Unavailable({'WAYLAND_DISPLAY': 'wayland-0'}),
      contains('Wayland'),
    );
    expect(tomSecretsX11Unavailable({}), contains('No X11 display'));
    expect(
      tomSecretsX11Unavailable({'XDG_SESSION_TYPE': 'x11', 'DISPLAY': ':0'}),
      isNull,
    );
    final keyboard = TomSecretsX11Keyboard.open(
      environment: {'XDG_SESSION_TYPE': 'wayland'},
    );
    expect(keyboard.support().available, isFalse);
    expect(keyboard.activeWindowTitle(), isNull);
  });

  test('the hotkeys\' virtual keys on macOS and Windows', () {
    expect(tomSecretsMacKeyCode('Space'), 49);
    expect(tomSecretsMacKeyCode('A'), 0);
    expect(tomSecretsMacKeyCode('K'), 40);
    expect(tomSecretsMacKeyCode('F5'), 96);
    expect(tomSecretsWindowsKeyCode('Space'), 0x20);
    expect(tomSecretsWindowsKeyCode('A'), 0x41);
    expect(tomSecretsWindowsKeyCode('7'), 0x37);
    expect(tomSecretsWindowsKeyCode('F12'), 0x7B);
  });

  test('macOS: the frameworks load and answer', () {
    final keyboard = TomSecretsMacKeyboard.open();
    expect(keyboard, isNotNull);
    final support = keyboard!.support();
    // Trusted or not depends on this machine's Accessibility list.
    expect(support.available || support.permissionNeeded, isTrue);
    expect(keyboard.secureInputActive(), isA<bool>());
    // Without the permission the title cannot be read.
    final title = keyboard.activeWindowTitle();
    if (!support.available) expect(title, isNull);
    expect(keyboard.takeRefusal(), isNull);
  }, skip: !Platform.isMacOS);
}
