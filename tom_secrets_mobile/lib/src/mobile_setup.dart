// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Setting a phone or tablet up (part-mobile, Receiving keys by pairing):
/// the pairing with a desktop app delivers the vault locators, the key files
/// and repository keys of the vaults the user picked there, and the phone's
/// own GitHub token; they go into the keychain (the keys, the tokens) and
/// the device preferences (the primary's locator, the device name). The
/// master password never travels: the user types it once on the phone. A
/// primary without key file and outer key can also be set up by hand, its
/// locator and a token pasted.
library;

import 'dart:convert';

import 'package:tom_core_storage/settings.dart' show TomSecretStore;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart' show TomSecretsPreferences;

import 'mobile_engine.dart';

/// The phone's setup: where its primary is, what it is called.
final class TomSecretsMobileSetup {
  /// The setup kept in [preferences] and [keychain].
  TomSecretsMobileSetup({required this.preferences, required this.keychain});

  /// The device preferences.
  final TomSecretsPreferences preferences;

  /// The keychain.
  final TomSecretStore keychain;

  /// The primary's locator, or null before the setup.
  String? get primaryLocator => preferences.read(TomSecretsMobileKeys.primary);

  /// This device's name, or null before the setup.
  String? get device => preferences.read(TomSecretsMobileKeys.device);

  /// Whether the phone is set up.
  bool get isSetUp => primaryLocator != null && device != null;

  /// Keeps what [bundle] delivered as device [device]: every vault's key
  /// file and repository key, every token, then the primary's locator; and
  /// [ownTokens], the tokens this phone brought itself (by `owner/name`, a
  /// pairing through a GitHub relay, part-relay), for the repositories the
  /// bundle carries no token for. Throws [ArgumentError] for a bundle
  /// without the primary (refused before by
  /// `tomSecretsReceivePairingForSetup`).
  Future<void> applyPairing(
    TomSecretsPairingBundle bundle, {
    required String device,
    Map<String, String> ownTokens = const {},
  }) async {
    final primary = bundle.vaults.where((v) => v.primary).firstOrNull;
    if (primary == null) {
      throw ArgumentError('the bundle carries no primary vault');
    }
    for (final v in bundle.vaults) {
      final locator = TomSecretsVaultLocator.parse(v.locator);
      final keyFile = v.keyFile;
      if (keyFile != null) {
        await keychain.write(locator.keyFileHandle, base64.encode(keyFile));
      }
      final repositoryKey = v.repositoryKey;
      if (repositoryKey != null) {
        await keychain.write(locator.repositoryKeyHandle, repositoryKey);
      }
    }
    final settings = TomSecretsMobileSettings(preferences);
    final expiries = {...settings.pairedTokenExpiries};
    for (final t in bundle.tokens) {
      final [owner, repository] = t.repository.split('/');
      await keychain.write(
        tomSecretsGitHubTokenHandle(owner, repository),
        t.token,
      );
      final expires = t.expires;
      if (expires != null) {
        expiries[t.repository] = expires;
      } else {
        expiries.remove(t.repository);
      }
    }
    for (final MapEntry(key: slug, value: token) in ownTokens.entries) {
      if (bundle.tokens.any((t) => t.repository == slug)) continue;
      final [owner, repository] = slug.split('/');
      await keychain.write(
        tomSecretsGitHubTokenHandle(owner, repository),
        token,
      );
      expiries.remove(slug);
    }
    await settings.setPairedTokenExpiries(expiries);
    await preferences.write(TomSecretsMobileKeys.device, device);
    await preferences.write(TomSecretsMobileKeys.primary, primary.locator);
  }

  /// Sets the phone up by hand: the primary at [locator] (a `github:` vault
  /// without key file or outer encryption), [token] for its repository.
  /// Throws [TomSecretsLocatorException] or [ArgumentError].
  Future<void> setUpByHand({
    required String locator,
    required String token,
    required String device,
  }) async {
    final parsed = TomSecretsVaultLocator.parse(locator.trim());
    if (parsed is! TomSecretsGitHubLocator) {
      throw ArgumentError('the primary is a github: vault on a phone');
    }
    if (parsed.fileName.endsWith(tomSecretsOuterSuffix)) {
      throw ArgumentError(
        'an outer-encrypted primary needs its repository key: pair with a '
        'desktop',
      );
    }
    if (token.trim().isEmpty) throw ArgumentError('a GitHub token is needed');
    await keychain.write(
      tomSecretsGitHubTokenHandle(parsed.owner, parsed.repository),
      token.trim(),
    );
    await preferences.write(TomSecretsMobileKeys.device, device.trim());
    await preferences.write(TomSecretsMobileKeys.primary, parsed.toString());
  }

  /// Forgets the setup (the keys and tokens stay in the keychain until the
  /// app is removed, so a new pairing replaces them).
  Future<void> reset() async {
    await preferences.write(TomSecretsMobileKeys.primary, null);
    await preferences.write(TomSecretsMobileKeys.device, null);
  }
}
