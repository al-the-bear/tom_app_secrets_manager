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

  // `--show-entry <store>/~<uuid>`: the browser host's openApp (part-browser)
  // asks for an entry; a running app is told it and comes to the front.
  final at = args.indexOf(tomSecretsShowEntryArgument);
  final entry = at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  final entryRequests = TomSecretsEntryRequests();
  if (entry != null) entryRequests.request(entry);

  TomSecretsWindowHost? shown;
  final instance = await TomSecretsSingleInstance.claim(
    File('$data${Platform.pathSeparator}app.port'),
    entry: entry,
    onActivate: (asked) {
      unawaited(shown?.show());
      if (asked != null) entryRequests.request(asked);
    },
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
    // The OS unlock (Touch ID, Windows Hello; none on Linux) and the screen
    // lock and sleep it senses for the service (part-os-unlock).
    osUnlock: tomSecretsDesktopOsUnlock(),
    sessionEvents: TomSecretsDesktopSessionEvents(),
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
    // Settings › Integrations writes into this user's tool and browser
    // configuration; the git helper links to the tsm beside the service.
    integrationPaths: home == null
        ? null
        : (
            home: home,
            tsmExecutable: serviceHost.tsmExecutable,
            // The browsers' manifests name the host beside the service.
            browserHostExecutable: serviceHost.browserHostExecutable,
          ),
    entryRequests: entryRequests,
  );
  runApp(TomSecretsApp(host: host));
}
