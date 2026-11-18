// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// This package's own platform code (DP-32, DP-33): keeping the window out of
/// screen capture, the protected clipboard on macOS, and starting at login
/// on macOS.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tom_biometric_storage/tom_gated_secret_store.dart';
import 'package:win32_registry/win32_registry.dart';
import 'package:tom_basics/utilities.dart' show TomClipboardPort;
import 'package:tom_host_ui/desktop.dart' show TomDesktopClipboardPort;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The channel of the screen-capture setting.
const MethodChannel tomSecretsCaptureChannel = MethodChannel(
  'tom_secrets_desktop/capture',
);

/// The channel of the macOS protected clipboard.
const MethodChannel tomSecretsClipboardChannel = MethodChannel(
  'tom_secrets_desktop/clipboard',
);

/// The channel of the desktop session's screen lock and sleep.
const MethodChannel tomSecretsSessionChannel = MethodChannel(
  'tom_secrets_desktop/session',
);

/// The desktop session's screen lock and sleep from this package's own code
/// (`event` with `screenLocked` or `sleep`): macOS distributed notifications
/// and NSWorkspace, Windows `WM_WTSSESSION_CHANGE` and `WM_POWERBROADCAST`.
/// Linux sends none: it has no lock mode (c) (no OS unlock, DP-70).
final class TomSecretsDesktopSessionEvents implements TomSecretsSessionEvents {
  /// The events of [channel].
  TomSecretsDesktopSessionEvents({
    MethodChannel channel = tomSecretsSessionChannel,
  }) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'event') return;
      final event = switch (call.arguments) {
        'screenLocked' => TomSecretsSessionEvent.screenLocked,
        'sleep' => TomSecretsSessionEvent.sleep,
        _ => null,
      };
      if (event != null) _events.add(event);
    });
  }

  final StreamController<TomSecretsSessionEvent> _events =
      StreamController.broadcast();

  @override
  Stream<TomSecretsSessionEvent> get events => _events.stream;
}

/// The OS unlock of this desktop (part-os-unlock): Touch ID on macOS (the
/// gate-only form in an ad-hoc signed build, DP-181), Windows Hello
/// (key-bound, DP-69), through `tom_biometric_storage`; null on Linux, which
/// has none (DP-70).
TomSecretsOsUnlockHost? tomSecretsDesktopOsUnlock({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  return switch (os) {
    'macos' => TomSecretsOsUnlockHost(
      store: TomBiometricGatedSecretStore(operatingSystem: os),
      label: 'Touch ID',
    ),
    'windows' => TomSecretsOsUnlockHost(
      store: TomBiometricGatedSecretStore(operatingSystem: os),
      label: 'Windows Hello',
    ),
    _ => null,
  };
}

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
      return await _channel.invokeMethod<bool>(
            'setCaptureExcluded',
            excluded,
          ) ??
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

/// Starting at login with `--hidden`, so the app starts in the tray
/// (DP-30), by this package's own code (DP-32): macOS through `SMAppService`
/// (the login channel), Windows through the user's `Run` key
/// (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, the value named
/// [appName]), Linux through an XDG autostart entry
/// (`$XDG_CONFIG_HOME/autostart/<appName>.desktop`, default `~/.config`).
final class TomSecretsDesktopLoginItem implements TomSecretsLoginItem {
  /// The login item of the app named [appName] at [appPath] (default this
  /// executable); [environment] (default the process's) gives the home and
  /// config folders on Linux.
  TomSecretsDesktopLoginItem({
    required this.appName,
    String? appPath,
    String? operatingSystem,
    Map<String, String>? environment,
    MethodChannel channel = tomSecretsLoginChannel,
  }) : _os = operatingSystem ?? Platform.operatingSystem,
       _path = appPath ?? Platform.resolvedExecutable,
       _environment = environment ?? Platform.environment,
       _channel = channel;

  /// The app's name: the Run value's, the autostart entry's.
  final String appName;

  final String _os;
  final String _path;
  final Map<String, String> _environment;
  final MethodChannel _channel;

  static const String _runKey =
      r'Software\Microsoft\Windows\CurrentVersion\Run';

  /// The command the login runs: the app, quoted, with `--hidden`.
  String get command => '"$_path" $tomSecretsHiddenArgument';

  /// The Linux autostart entry's file.
  File get autostartFile {
    final config = _environment['XDG_CONFIG_HOME'];
    final base = config != null && config.isNotEmpty
        ? config
        : '${_environment['HOME'] ?? ''}/.config';
    return File('$base/autostart/$appName.desktop');
  }

  /// The autostart entry's text.
  String get autostartEntry =>
      '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=$appName\n'
      'Exec=$command\n'
      'X-GNOME-Autostart-enabled=true\n';

  @override
  Future<bool> isEnabled() async {
    switch (_os) {
      case 'macos':
        return await _channel.invokeMethod<bool>('isEnabled') ?? false;
      case 'windows':
        final key = CURRENT_USER.open(_runKey);
        try {
          return key.getString(appName) == command;
        } finally {
          key.close();
        }
      default:
        final file = autostartFile;
        return file.existsSync() && file.readAsStringSync() == autostartEntry;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    switch (_os) {
      case 'macos':
        await _channel.invokeMethod<bool>('setEnabled', enabled);
      case 'windows':
        final key = CURRENT_USER.create(_runKey);
        try {
          if (enabled) {
            key.setValue(appName, RegistryValue.string(command));
          } else if (key.getString(appName) != null) {
            key.removeValue(appName);
          }
        } finally {
          key.close();
        }
      default:
        final file = autostartFile;
        if (enabled) {
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(autostartEntry);
        } else if (file.existsSync()) {
          file.deleteSync();
        }
    }
  }
}

/// The argument a start at login passes: the app starts hidden in the tray.
const String tomSecretsHiddenArgument = '--hidden';
