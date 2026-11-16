// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The host capabilities the screens use beyond the service: the tray or
/// menu bar, the window, system notifications, start at login, keeping the
/// window out of screen capture, the device's own preferences and the files
/// an entry carries (part-app). The desktop implements them in
/// `tom_secrets_desktop`; [TomSecretsHost.headless] is the set for tests.
library;

import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show BuildContext;
import 'package:tom_basics/utilities.dart' show TomClipboardPort;
import 'package:tom_credentials_ui/tom_credentials_ui.dart'
    show TomKeyFilePicker;
import 'package:tom_host_ui/tom_host_ui.dart' show TomFlutterClipboardPort;

import 'service_host.dart';

/// The three states of the tray icon.
enum TomSecretsTrayState {
  /// The service is locked.
  locked,

  /// The service is unlocked.
  unlocked,

  /// Something waits: an unlock or approval request, a key expiring.
  attention,
}

/// One item of the tray menu.
final class TomSecretsTrayItem {
  /// An item labelled [label]; [onSelected] null shows it disabled (a status
  /// line).
  const TomSecretsTrayItem(this.label, {this.onSelected}) : separator = false;

  /// A separator line.
  const TomSecretsTrayItem.separator()
    : label = '',
      onSelected = null,
      separator = true;

  /// What it says.
  final String label;

  /// What it does, or null for a disabled line.
  final void Function()? onSelected;

  /// Whether it is a separator.
  final bool separator;
}

/// The icon in the macOS menu bar, the Windows notification area or the
/// Linux tray.
abstract interface class TomSecretsTray {
  /// Shows [state] with [tooltip] and the menu [items].
  Future<void> update({
    required TomSecretsTrayState state,
    required String tooltip,
    required List<TomSecretsTrayItem> items,
  });

  /// Removes the icon.
  Future<void> dispose();
}

/// The app's one window.
abstract interface class TomSecretsWindowHost {
  /// Shows the window and brings it to the front.
  Future<void> show();

  /// Hides the window; the app keeps running in the tray (DP-30).
  Future<void> hide();

  /// Whether the window is shown.
  Future<bool> isVisible();

  /// Ends the app: only from the tray menu (DP-30). The service keeps
  /// running (BP-14).
  Future<void> quit();
}

/// A system notification.
abstract interface class TomSecretsNotifier {
  /// Shows [title] with [body]; [onClick] runs when the user clicks it. Never
  /// carries a value (part-app, Notifications).
  Future<void> notify({
    required String title,
    required String body,
    void Function()? onClick,
  });
}

/// Starting the app at login, hidden in the tray (DP-30).
abstract interface class TomSecretsLoginItem {
  /// Whether the app starts at login.
  Future<bool> isEnabled();

  /// Turns starting at login on or off.
  Future<void> setEnabled(bool enabled);
}

/// Keeping the window out of screenshots and screen sharing (DP-33).
abstract interface class TomSecretsCaptureGuard {
  /// Whether this platform can do it (macOS and Windows; not Linux).
  bool get supported;

  /// Excludes the window from capture, or allows it again; answers whether
  /// the platform did it.
  Future<bool> setExcluded(bool excluded);
}

/// The device's own preferences (the view switches, the capture setting):
/// kept per device, never synced.
abstract interface class TomSecretsPreferences {
  /// The value of [key], or null.
  String? read(String key);

  /// Sets [key] to [value]; null removes it.
  Future<void> write(String key, String? value);
}

/// A file a user picks or saves: an entry's attachments, an export to
/// import.
abstract interface class TomSecretsFiles {
  /// A file the user picks: its name and bytes, or null when cancelled.
  Future<({String name, Uint8List bytes})?> pick();

  /// Saves [bytes] where the user chooses, suggesting [name]; answers
  /// whether it was saved.
  Future<bool> save(String name, Uint8List bytes);

  /// A path the user chooses, without reading or writing it: a file to
  /// create ([save], suggesting [suggestedName]) or one that exists; null
  /// when cancelled.
  Future<String?> choosePath({required bool save, String? suggestedName});

  /// The bytes of the file at [path] (one [choosePath] answered).
  Future<Uint8List> read(String path);

  /// Deletes the file at [path] (an export the user imported, which holds
  /// every password in plaintext); answers whether it is gone.
  Future<bool> delete(String path);
}

/// The platform's print path: a PDF handed to the system print dialog.
abstract interface class TomSecretsPrinter {
  /// Shows the print dialog for [pdf], named [name]; answers whether it was
  /// printed (false when the user cancelled).
  Future<bool> printPdf(String name, Uint8List pdf);
}

/// What the last step of the First run wizard offers to start (part-app,
/// First run, step 4), by its id in [TomSecretsFirstRunActions].
typedef TomSecretsFirstRunAction = Future<void> Function(BuildContext context);

/// The ids of the First run wizard's offers.
abstract final class TomSecretsFirstRunActions {
  /// The 1Password or Enpass import.
  static const String import = 'import';

  /// Pairing another desktop machine.
  static const String pair = 'pair';
}

/// [TomSecretsPreferences] in memory.
final class TomSecretsMemoryPreferences implements TomSecretsPreferences {
  /// Preferences starting with [values].
  TomSecretsMemoryPreferences([Map<String, String> values = const {}])
    : _values = Map.of(values);

  final Map<String, String> _values;

  @override
  String? read(String key) => _values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}

/// [TomSecretsCaptureGuard] of a platform that cannot exclude a window.
final class TomSecretsNoCaptureGuard implements TomSecretsCaptureGuard {
  /// The guard.
  const TomSecretsNoCaptureGuard();

  @override
  bool get supported => false;

  @override
  Future<bool> setExcluded(bool excluded) async => false;
}

/// Everything the app's host provides.
final class TomSecretsHost {
  /// A host; only [service] is required.
  const TomSecretsHost({
    required this.service,
    this.tray,
    this.window,
    this.notifier,
    this.loginItem,
    this.captureGuard = const TomSecretsNoCaptureGuard(),
    required this.preferences,
    this.keyFiles,
    this.files,
    this.printer,
    this.openUrl,
    this.pairingAddresses,
    this.pairingAllowsLoopback = false,
    this.clipboard = const TomFlutterClipboardPort(),
    this.startedHidden = false,
    this.firstRunActions = const {},
  });

  /// A host with the service only, for tests and a host without desktop
  /// capabilities.
  factory TomSecretsHost.headless(TomSecretsServiceHost service) =>
      TomSecretsHost(
        service: service,
        preferences: TomSecretsMemoryPreferences(),
      );

  /// The secrets service.
  final TomSecretsServiceHost service;

  /// The tray icon, where the platform has one.
  final TomSecretsTray? tray;

  /// The window.
  final TomSecretsWindowHost? window;

  /// System notifications.
  final TomSecretsNotifier? notifier;

  /// Start at login.
  final TomSecretsLoginItem? loginItem;

  /// Screen-capture exclusion.
  final TomSecretsCaptureGuard captureGuard;

  /// The device's preferences.
  final TomSecretsPreferences preferences;

  /// The key-file picker of the unlock screen; without one only a password
  /// is asked for.
  final TomKeyFilePicker? keyFiles;

  /// Attachments: picking and saving files.
  final TomSecretsFiles? files;

  /// The print path (the emergency sheet), where the platform has one.
  final TomSecretsPrinter? printer;

  /// Opens a web page in the system browser (GitHub's token pages); answers
  /// whether it was opened. Without one the app shows the address to copy.
  final Future<bool> Function(Uri url)? openUrl;

  /// The addresses a pairing window listens on; null: this machine's LAN and
  /// VPN addresses (`tomSecretsPairingAddresses`).
  final Future<List<InternetAddress>> Function()? pairingAddresses;

  /// Whether a pairing window may listen on loopback: tests only.
  final bool pairingAllowsLoopback;

  /// The clipboard protected values are copied to.
  final TomClipboardPort clipboard;

  /// Whether the app was started at login, hidden in the tray.
  final bool startedHidden;

  /// What the First run wizard's last step can start, by the ids of
  /// [TomSecretsFirstRunActions]; an offer without one is shown as not
  /// available yet.
  final Map<String, TomSecretsFirstRunAction> firstRunActions;
}
