// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Tom Secrets Manager's desktop app: the composition root (part-app).
///
/// One instance per user (a second launch brings the window to the front);
/// started at login with `--hidden` it starts in the tray (DP-30). The host's
/// capabilities come from `tom_secrets_desktop`, the screens from
/// `tom_secrets_ui`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tom_secrets_client/admin.dart' show tomSecretsDataDirectory;
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The app's name, in the window title, the tray and notifications.
const String appName = 'Tom Secrets Manager';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final hidden = args.contains(tomSecretsHiddenArgument);
  final data = tomSecretsDataDirectory(environment: Platform.environment);

  TomSecretsWindowHost? shown;
  final instance = await TomSecretsSingleInstance.claim(
    File('$data${Platform.pathSeparator}app.port'),
    onActivate: () => unawaited(shown?.show()),
  );
  if (instance == null) exit(0);

  TomSecretsTray? tray;
  try {
    tray = TomSecretsPluginTray();
  } on Object {
    // No tray here (a Linux desktop without a StatusNotifierItem host): the
    // window stays reachable by minimising instead of hiding.
    tray = null;
  }
  final window = await TomSecretsPluginWindow.create(
    title: appName,
    hidden: hidden && tray != null,
    hideOnClose: tray != null,
  );
  shown = window;
  TomSecretsNotifier? notifier;
  try {
    notifier = await TomSecretsPluginNotifier.create(appName);
  } on Object {
    notifier = null;
  }
  // TSM_LOGIN_ITEM=off: a development run neither registers its build as a
  // login item nor keeps one it registered before (DP-30 is the installed
  // app's default).
  TomSecretsLoginItem? loginItem = TomSecretsDesktopLoginItem(appName: appName);
  if (Platform.environment['TSM_LOGIN_ITEM'] == 'off') {
    try {
      await loginItem.setEnabled(false);
    } on Object {
      // Not registered, or the platform refuses: nothing to undo.
    }
    loginItem = null;
  }
  const files = TomSecretsDesktopFiles();
  final serviceHost = TomSecretsDesktopServiceHost();
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final host = TomSecretsHost(
    service: serviceHost,
    tray: tray,
    window: window,
    notifier: notifier,
    loginItem: loginItem,
    captureGuard: TomSecretsPlatformCaptureGuard(),
    preferences: await TomSecretsFilePreferences.open(
      File('$data${Platform.pathSeparator}app-preferences.json'),
    ),
    keyFiles: files,
    files: files,
    printer: const TomSecretsDesktopPrinter(),
    openUrl: tomSecretsDesktopOpenUrl,
    clipboard: tomSecretsDesktopClipboard(),
    // Pairing on the LAN finds the other machine by the code alone.
    pairingDiscovery: const TomSecretsBonsoirPairingDiscovery(),
    startedHidden: hidden,
    // The First run wizard's last step offers the import and pairing
    // another desktop (part-app).
    firstRunActions: {
      TomSecretsFirstRunActions.import: tomSecretsShowImport,
      TomSecretsFirstRunActions.pair: tomSecretsShowPairing,
    },
    // Settings › Integrations writes into this user's tool configuration;
    // the git helper links to the tsm beside the service.
    integrationPaths: home == null
        ? null
        : (home: home, tsmExecutable: serviceHost.tsmExecutable),
  );
  runApp(TomSecretsApp(host: host));
}
