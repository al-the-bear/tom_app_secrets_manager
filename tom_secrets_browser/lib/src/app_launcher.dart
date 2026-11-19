// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Starting the desktop app from the host (the extension's `openApp`): the
/// app of the distribution the host is in (`tsm/bin` inside the app, as
/// `tom_secrets_client`'s `distribution.dart` lays it out), with
/// `--show-entry <reference>` when an entry is named. A running app comes to
/// the front and shows the entry (its one-instance channel passes the
/// argument on).
library;

import 'dart:io';

import 'package:tom_secrets_client/admin.dart' show tomSecretsDistributionApp;

/// The argument that makes the app show an entry.
const String tomSecretsShowEntryArgument = '--show-entry';

/// Starts [appExecutable].
final class TomSecretsAppLauncher {
  /// The launcher of [appExecutable] on [operatingSystem]; [start] runs a
  /// command detached (tests record it).
  TomSecretsAppLauncher({
    required this.appExecutable,
    String? operatingSystem,
    Future<void> Function(String executable, List<String> arguments)? start,
  }) : operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _start = start ?? _detached;

  /// The launcher of the app around this host's executable.
  factory TomSecretsAppLauncher.beside() => TomSecretsAppLauncher(
    appExecutable: tomSecretsDistributionApp(
      File(Platform.resolvedExecutable).parent.path,
      operatingSystem: Platform.operatingSystem,
    ),
  );

  /// The app's executable.
  final String appExecutable;

  /// `macos`, `linux` or `windows`.
  final String operatingSystem;

  final Future<void> Function(String, List<String>) _start;

  static Future<void> _detached(String executable, List<String> arguments) =>
      Process.start(executable, arguments, mode: ProcessStartMode.detached);

  /// Starts the app (at [entry], a reference); answers false when it is
  /// not where the distribution puts it.
  Future<bool> open({String? entry}) async {
    if (!File(appExecutable).existsSync()) return false;
    final arguments = [
      if (entry != null) ...[tomSecretsShowEntryArgument, entry],
    ];
    if (operatingSystem == 'macos') {
      // The bundle (…/X.app/Contents/MacOS/exe), opened by Launch Services
      // as a new instance (`-n`): a plain `open -a` only activates a running
      // app and drops the arguments, while a new one hands the entry to the
      // running one over its one-instance channel and ends.
      final bundle = File(appExecutable).parent.parent.parent.path;
      await _start('open', [
        '-n',
        '-a',
        bundle,
        if (arguments.isNotEmpty) '--args',
        ...arguments,
      ]);
    } else {
      await _start(appExecutable, arguments);
    }
    return true;
  }
}
