// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The composition root of the mobile app.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tom_biometric_storage/tom_gated_secret_store.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsBonsoirPairingDiscovery;

Future<void> main() => _run();

/// The Android Autofill service's unlock (part-os-integration, DP-175): the
/// service's native activity starts this entry point on an engine of its own
/// when the app's process holds no unlocked vault. The app's own unlock,
/// then the request's logins handed back as datasets; the vaults are dropped
/// when the activity ends.
@pragma('vm:entry-point')
Future<void> autofillMain() =>
    _run(autofillUnlock: const TomSecretsChannelAutofillUnlock());

/// **[C]** The Credential Manager provider's unlock (DP-120): its native
/// activity starts this entry point on an engine of its own when the app's
/// process holds no unlocked vault; the app's own unlock, then the passkey
/// request answered.
@pragma('vm:entry-point')
Future<void> passkeyMain() =>
    _run(passkeyUnlock: const TomSecretsChannelPasskeyUnlock());

Future<void> _run({
  TomSecretsAutofillUnlockPlatform? autofillUnlock,
  TomSecretsPasskeyUnlockPlatform? passkeyUnlock,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final preferences = await TomSecretsMobilePreferences.open(
    File('${support.path}/app-preferences.json'),
  );
  runApp(
    TomSecretsMobileApp(
      preferences: preferences,
      keychain: TomSecretsMobileKeychain(),
      platform: Platform.operatingSystem,
      gated: TomBiometricGatedSecretStore(),
      biometricLabel: Platform.isIOS
          ? 'Face ID or Touch ID'
          : 'your fingerprint',
      scanner: const TomSecretsMobileCodeScanner(),
      documents: const TomSecretsChannelDocuments(),
      kdfMemoryLimit: await tomSecretsMobileKdfMemoryLimit(),
      discovery: const TomSecretsBonsoirPairingDiscovery(),
      // The Autofill service is Android's; iOS has none (TD-4).
      autofill:
          Platform.isAndroid && autofillUnlock == null && passkeyUnlock == null
          ? const TomSecretsChannelAutofill()
          : null,
      autofillUnlock: autofillUnlock,
      passkeyUnlock: passkeyUnlock,
    ),
  );
}
