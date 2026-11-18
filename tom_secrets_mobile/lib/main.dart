// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The composition root of the mobile app.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tom_biometric_storage/tom_gated_secret_store.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';

Future<void> main() async {
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
      biometricLabel: Platform.isIOS ? 'Face ID or Touch ID' : 'your fingerprint',
    ),
  );
}
