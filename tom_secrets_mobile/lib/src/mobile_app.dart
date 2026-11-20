// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's composition: the setup screen until the phone is set
/// up, then the shared app (`tom_secrets_ui`) over the in-app engine, with
/// the mobile shell, system vaults read-only, the biometric unlock and the
/// mobile clipboard.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:tom_basics/utilities.dart' show TomClipboardPort;
import 'package:tom_core_storage/settings.dart'
    show TomGatedSecretStore, TomSecretStore;
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsBreachCheck, tomSecretsPairingAddresses;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'mobile_autofill.dart';
import 'mobile_autofill_view.dart';
import 'mobile_documents.dart';
import 'mobile_engine.dart';
import 'mobile_host.dart';
import 'mobile_lifecycle.dart';
import 'mobile_ports.dart';
import 'mobile_setup.dart';
import 'mobile_shell.dart';
import 'setup_screen.dart';

/// The app.
class TomSecretsMobileApp extends StatefulWidget {
  /// The app over [preferences], [keychain] and [gated] (the biometric
  /// store) on [platform] (`ios`, `android`); [clipboard], [httpClient],
  /// [githubBaseUrl] and [receive] are for tests.
  const TomSecretsMobileApp({
    super.key,
    required this.preferences,
    required this.keychain,
    required this.platform,
    this.gated,
    this.biometricLabel = 'biometrics',
    this.clipboard,
    this.httpClient,
    this.githubBaseUrl,
    this.receive,
    this.profileExpiry = tomSecretsMobileProfileExpiry,
    this.scanner,
    this.discovery,
    this.ownAddresses,
    this.documents,
    this.kdfMemoryLimit = TomSecretsMobileEngine.defaultKdfMemoryLimit,
    this.autofill,
    this.autofillUnlock,
    this.assetLinks,
    this.breachCheck,
  });

  /// The device preferences.
  final TomSecretsPreferences preferences;

  /// The keychain of the keys and tokens.
  final TomSecretStore keychain;

  /// `ios` or `android`.
  final String platform;

  /// The biometric store of the OS unlock, or null without one.
  final TomGatedSecretStore? gated;

  /// The biometric check's name (Face ID, Touch ID, fingerprint).
  final String biometricLabel;

  /// The clipboard port; default the app's channel.
  final TomClipboardPort? clipboard;

  /// The HTTP client to GitHub.
  final http.Client? httpClient;

  /// GitHub's API base URL.
  final String? githubBaseUrl;

  /// How a pairing is received.
  final TomSecretsMobileReceive? receive;

  /// When this build stops starting (iOS), read once at the start.
  final Future<DateTime?> Function() profileExpiry;

  /// The camera's QR reader (the desktop's pairing code, TOTP secrets), or
  /// null.
  final TomSecretsCodeScanner? scanner;

  /// mDNS finding the desktop's open pairing window, or null.
  final TomSecretsPairingDiscovery? discovery;

  /// This device's addresses; default its network interfaces'.
  final Future<List<InternetAddress>> Function()? ownAddresses;

  /// The phone's documents (`file:` vaults, attachments), or null.
  final TomSecretsDocuments? documents;

  /// The most memory a vault's key derivation may take on this device.
  final int kdfMemoryLimit;

  /// The Android Autofill service's channel to the running app (answering
  /// from its memory, the proposals of `onSaveRequest`), or null.
  final TomSecretsAutofillPlatform? autofill;

  /// Set when the app runs as the service's unlock (`autofillMain`): it
  /// unlocks on an engine of its own, answers the request and ends.
  final TomSecretsAutofillUnlockPlatform? autofillUnlock;

  /// The Digital Asset Links checker of package matches.
  final TomSecretsAssetLinks? assetLinks;

  /// The breach check of the health report (DP-39); default the Have I Been
  /// Pwned range API over [httpClient].
  final TomSecretsBreachCheck? breachCheck;

  @override
  State<TomSecretsMobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<TomSecretsMobileApp> {
  late final TomSecretsMobileSetup _setup = TomSecretsMobileSetup(
    preferences: widget.preferences,
    keychain: widget.keychain,
  );
  TomSecretsMobileEngine? _engine;
  DateTime? _expiry;
  // The health report's breach check: the given one, else the range API
  // over the app's HTTP client (closed with the app when it made its own).
  late final TomSecretsBreachCheck _breachCheck =
      widget.breachCheck ?? TomSecretsBreachCheck(client: widget.httpClient);
  late final TomSecretsAssetLinks _links =
      widget.assetLinks ?? TomSecretsAssetLinks(client: widget.httpClient);

  @override
  void initState() {
    super.initState();
    if (_setup.isSetUp) _open();
    unawaited(
      widget.profileExpiry().then((at) {
        if (mounted && at != null) setState(() => _expiry = at);
      }),
    );
  }

  void _open() {
    _engine = TomSecretsMobileEngine(
      primaryLocator: _setup.primaryLocator!,
      device: _setup.device!,
      platform: widget.platform,
      keychain: widget.keychain,
      preferences: widget.preferences,
      httpClient: widget.httpClient,
      githubBaseUrl: widget.githubBaseUrl ?? 'https://api.github.com',
      documents: widget.documents,
      kdfMemoryLimit: widget.kdfMemoryLimit,
    );
    if (widget.autofillUnlock == null) _attachAutofill(_engine!);
  }

  /// The service asks the running app (DP-175): its state, the logins from
  /// the vaults it holds, a login seen submitted (`proposal`).
  void _attachAutofill(TomSecretsMobileEngine engine) {
    final platform = widget.autofill;
    if (platform == null) return;
    final responder = TomSecretsAutofillResponder(
      stores: () => engine.autofillStores,
      links: _links,
    );
    platform.setHandler((method, arguments) async {
      if (method == 'proposal') {
        _deliverProposal(
          engine,
          (arguments as Map<Object?, Object?>).cast<String, Object?>(),
        );
        return null;
      }
      return responder.handle(method, arguments);
    });
    unawaited(
      platform.takeProposal().then((p) {
        if (p != null) _deliverProposal(engine, p);
      }),
    );
  }

  /// A login the service saw submitted, handed to the Proposals screen once
  /// the app is unlocked (the lock forgets proposals).
  void _deliverProposal(TomSecretsMobileEngine engine, Map<String, Object?> p) {
    final url = p['url'];
    final userName = p['userName'];
    final password = p['password'];
    if (url is! String || userName is! String || password is! String) return;
    void deliver() => engine.propose(
      url: url,
      userName: userName,
      password: password,
      title: p['title'] as String?,
    );
    if (!engine.isLocked) {
      scheduleMicrotask(deliver);
      return;
    }
    unawaited(
      engine.events
          .firstWhere((e) => e['op'] == 'unlocked')
          .then((_) => scheduleMicrotask(deliver), onError: (_) {}),
    );
  }

  Future<void> _forget() async {
    final engine = _engine;
    setState(() => _engine = null);
    await engine?.close();
    await _setup.reset();
  }

  /// From the unlock screen (a refused GitHub token): asks, then forgets the
  /// setup.
  Future<void> _forgetAsked(BuildContext context) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set this device up again?'),
        content: const Text(
          'Pair with a desktop again (it gives this device a new GitHub '
          'token), or set the primary up by hand. The vaults stay on GitHub.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('tsm-mobile-unlock-setup-again-go'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Set up again'),
          ),
        ],
      ),
    );
    if (sure == true) await _forget();
  }

  @override
  void dispose() {
    widget.autofill?.setHandler(null);
    unawaited(_engine?.close());
    if (widget.breachCheck == null) _breachCheck.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final autofillUnlock = widget.autofillUnlock;
    if (engine == null && autofillUnlock != null) {
      return MaterialApp(
        title: 'Tom Secrets',
        theme: tomSecretsTheme(Brightness.light),
        darkTheme: tomSecretsTheme(Brightness.dark),
        home: TomSecretsAutofillMessage(
          message: 'Set Tom Secrets Manager up first: open the app.',
          onClose: autofillUnlock.cancel,
        ),
      );
    }
    if (engine == null) {
      return MaterialApp(
        title: 'Tom Secrets',
        theme: tomSecretsTheme(Brightness.light),
        darkTheme: tomSecretsTheme(Brightness.dark),
        home: TomSecretsMobileSetupScreen(
          setup: _setup,
          receive: widget.receive ?? tomSecretsMobileReceive,
          scanner: widget.scanner,
          discovery: widget.discovery,
          ownAddresses: widget.ownAddresses ?? tomSecretsPairingAddresses,
          onSetUp: () => setState(_open),
        ),
      );
    }
    final settings = engine.settings;
    Duration clearAfter() => Duration(seconds: settings.clipboardSeconds);
    final gated = widget.gated;
    return TomSecretsMobileLifecycle(
      key: ObjectKey(engine),
      engine: engine,
      child: TomSecretsApp(
        host: TomSecretsHost(
          service: TomSecretsMobileServiceHost(engine),
          preferences: widget.preferences,
          clipboard:
              widget.clipboard ??
              TomSecretsMobileClipboardPort(clearAfter: clearAfter),
          clipboardClearAfter: clearAfter,
          systemVaultsReadOnly: true,
          sendsShares: false,
          scanner: widget.scanner,
          files: widget.documents == null
              ? null
              : TomSecretsMobileFiles(widget.documents!),
          attachmentsShare: true,
          breachCheck: _breachCheck,
          unlockFooter: (context) => autofillUnlock != null
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('tsm-autofill-unlock-cancel'),
                    onPressed: () => unawaited(autofillUnlock.cancel()),
                    child: const Text('Cancel'),
                  ),
                )
              : Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('tsm-mobile-unlock-setup-again'),
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('Set this device up again'),
                    onPressed: () => unawaited(_forgetAsked(context)),
                  ),
                ),
          osUnlock: gated == null
              ? null
              : TomSecretsOsUnlockHost(
                  store: gated,
                  label: widget.biometricLabel,
                  keepSaved: () => settings.biometric,
                ),
          shell: (context, clipboard) => autofillUnlock != null
              ? TomSecretsAutofillAnswer(
                  engine: engine,
                  platform: autofillUnlock,
                  links: _links,
                )
              : TomSecretsMobileShell(
                  engine: engine,
                  clipboard: clipboard,
                  onForget: _forget,
                  profileExpiry: _expiry,
                  autofill: widget.autofill,
                ),
        ),
      ),
    );
  }
}
