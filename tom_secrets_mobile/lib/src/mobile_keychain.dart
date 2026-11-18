// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The phone's keychain for what the pairing delivered (the vaults' key
/// files and repository keys, the GitHub tokens): the iOS keychain and, on
/// Android, a file encrypted under a key of the Android Keystore, both
/// through `tom_biometric_storage` without a biometric check (the check
/// guards only the OS unlock's item). Nothing is in a backup (the app's
/// backup rules exclude every file; keychain items are this device only).
library;

import 'dart:convert';

import 'package:tom_biometric_storage/tom_biometric_storage.dart';
import 'package:tom_core_storage/settings.dart' show TomSecretStore;

/// [TomSecretStore] over the platform's keystore.
final class TomSecretsMobileKeychain implements TomSecretStore {
  /// The keychain over [storage] (default the plugin's instance).
  TomSecretsMobileKeychain({BiometricStorage? storage})
    : _storage = storage ?? BiometricStorage();

  final BiometricStorage _storage;

  static final _options = StorageFileInitOptions(
    authenticationRequired: false,
  );

  /// A handle as a storage name: Android keeps each item as a file, so the
  /// handle (`tom_secrets.keyfile.github:owner/repo/x.kdbx`) is encoded to
  /// file-name characters.
  static String nameOf(String handle) =>
      'tsm_${base64Url.encode(utf8.encode(handle)).replaceAll('=', '')}';

  Future<BiometricStorageFile> _file(String handle) =>
      _storage.getStorage(nameOf(handle), options: _options);

  @override
  Future<String?> read(String handle) async =>
      (await _file(handle)).read();

  @override
  Future<void> write(String handle, String secret) async =>
      (await _file(handle)).write(secret);

  @override
  Future<void> delete(String handle) async => (await _file(handle)).delete();
}
