// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// This package's own platform code (DP-32, DP-33): keeping the window out of
/// screen capture, the protected clipboard on macOS, and starting at login
/// on macOS.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tom_basics/utilities.dart' show TomClipboardPort;
import 'package:tom_reusable_ui/desktop.dart' show TomDesktopClipboardPort;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The channel of the screen-capture setting.
const MethodChannel tomSecretsCaptureChannel = MethodChannel(
  'tom_secrets_desktop/capture',
);

/// The channel of the macOS protected clipboard.
const MethodChannel tomSecretsClipboardChannel = MethodChannel(
  'tom_secrets_desktop/clipboard',
);

/// The channel of the macOS login item.
const MethodChannel tomSecretsLoginChannel = MethodChannel(
  'tom_secrets_desktop/login',
);

/// Keeps the window out of screenshots and screen sharing:
/// `NSWindow.sharingType = .none` on macOS,
/// `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on Windows; Linux
/// cannot (DP-33).
final class TomSecretsPlatformCaptureGuard implements TomSecretsCaptureGuard {
  /// The guard; [operatingSystem] defaults to this platform's.
  TomSecretsPlatformCaptureGuard({
    String? operatingSystem,
    MethodChannel channel = tomSecretsCaptureChannel,
  }) : _os = operatingSystem ?? Platform.operatingSystem,
       _channel = channel;

  final String _os;
  final MethodChannel _channel;

  @override
  bool get supported => _os == 'macos' || _os == 'windows';

  @override
  Future<bool> setExcluded(bool excluded) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('setCaptureExcluded', excluded) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// The clipboard protected values are copied to: concealed on macOS through
/// this package's channel, plain elsewhere (`TomDesktopClipboardPort`).
TomClipboardPort tomSecretsDesktopClipboard() =>
    const TomDesktopClipboardPort(channel: tomSecretsClipboardChannel);

/// Starting at login: macOS through this package's `SMAppService` code,
/// Windows (the Run key) and Linux (an autostart entry) through
/// `launch_at_startup`, with `--hidden`, so the app starts in the tray
/// (DP-30).
final class TomSecretsDesktopLoginItem implements TomSecretsLoginItem {
  /// The login item of the app named [appName] at [appPath] (default this
  /// executable).
  TomSecretsDesktopLoginItem({
    required String appName,
    String? appPath,
    String? operatingSystem,
    MethodChannel channel = tomSecretsLoginChannel,
  }) : _os = operatingSystem ?? Platform.operatingSystem,
       _channel = channel {
    if (_os != 'macos') {
      launchAtStartup.setup(
        appName: appName,
        appPath: appPath ?? Platform.resolvedExecutable,
        args: const [tomSecretsHiddenArgument],
      );
    }
  }

  final String _os;
  final MethodChannel _channel;

  @override
  Future<bool> isEnabled() async => _os == 'macos'
      ? await _channel.invokeMethod<bool>('isEnabled') ?? false
      : launchAtStartup.isEnabled();

  @override
  Future<void> setEnabled(bool enabled) async {
    if (_os == 'macos') {
      await _channel.invokeMethod<bool>('setEnabled', enabled);
    } else if (enabled) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}

/// The argument a start at login passes: the app starts hidden in the tray.
const String tomSecretsHiddenArgument = '--hidden';
