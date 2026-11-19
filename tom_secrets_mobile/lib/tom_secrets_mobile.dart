// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Tom Secrets Manager on phones and tablets (part-mobile): the vaults
/// fetched from GitHub into memory, synced while the app is open, unlocked
/// with the master password or biometrics, set up by pairing with a desktop;
/// system vaults read-only.
library;

export 'src/mobile_app.dart';
export 'src/mobile_autofill.dart';
export 'src/mobile_autofill_view.dart';
export 'src/mobile_documents.dart';
export 'src/mobile_engine.dart';
export 'src/mobile_host.dart';
export 'src/mobile_kdf_guard.dart';
export 'src/mobile_keychain.dart';
export 'src/mobile_lifecycle.dart';
export 'src/mobile_ports.dart';
export 'src/mobile_scanner.dart';
export 'src/mobile_settings_view.dart';
export 'src/mobile_setup.dart';
export 'src/mobile_shell.dart';
export 'src/setup_screen.dart';
