// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The macOS AutoFill provider's app side (part-os-integration, DP-50,
/// DP-51) over this package's own platform code
/// (`tom_secrets_desktop/autofill`, `TomSecretsAutofillChannel.swift`):
/// the snapshot into the App Group container, its key into the shared
/// keychain group under Touch ID, the QuickType identities, the provider's
/// state in System Settings.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart' show TomSecretsPasskey;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// The channel of the macOS AutoFill provider.
const MethodChannel tomSecretsAutofillChannel = MethodChannel(
  'tom_secrets_desktop/autofill',
);

/// The AutoFill of this Mac, or null on another platform (Windows and Linux
/// have no password AutoFill API; the browser extension serves them).
TomSecretsAutofillPort? tomSecretsDesktopAutofill({String? operatingSystem}) =>
    (operatingSystem ?? Platform.operatingSystem) == 'macos'
    ? TomSecretsMacAutofill()
    : null;

/// [TomSecretsAutofillPort] over [channel].
final class TomSecretsMacAutofill implements TomSecretsAutofillPort {
  /// The port; [channel] for a test.
  TomSecretsMacAutofill({MethodChannel channel = tomSecretsAutofillChannel})
    : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<TomSecretsAutofillState> state() async {
    final Map<Object?, Object?>? answer;
    try {
      answer = await _channel.invokeMapMethod<Object?, Object?>('state');
    } on MissingPluginException {
      return const TomSecretsAutofillState(
        available: false,
        unavailableReason: 'This build has no AutoFill support.',
      );
    }
    return TomSecretsAutofillState(
      available: answer?['available'] == true,
      unavailableReason: answer?['reason'] as String?,
      providerEnabled: answer?['providerEnabled'] == true,
    );
  }

  @override
  Future<void> storeKey(Uint8List key, String keyId) =>
      _channel.invokeMethod<void>('storeKey', {'key': key, 'keyId': keyId});

  @override
  Future<void> writeSnapshot(Uint8List sealed) =>
      _channel.invokeMethod<void>('writeSnapshot', {'bytes': sealed});

  @override
  Future<void> remove() => _channel.invokeMethod<void>('remove');

  @override
  Future<void> setIdentities(List<TomSecretsAutofillIdentity> identities) =>
      _channel.invokeMethod<void>('setIdentities', {
        'identities': [for (final i in identities) i.toJson()],
      });

  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  /// The pending file as the platform read it: its bytes, its SHA-256 (the
  /// replacement's guard) and the pending key; null without a file.
  Future<({Uint8List bytes, String sha256, Uint8List key})?>
  _readPending() async {
    final Map<Object?, Object?>? m;
    try {
      m = await _channel.invokeMapMethod<Object?, Object?>('readPending');
    } on MissingPluginException {
      return null;
    }
    final bytes = m?['bytes'];
    final key = m?['key'];
    final sha = m?['sha256'];
    if (bytes is! Uint8List || key is! Uint8List || sha is! String) {
      return null;
    }
    return (bytes: bytes, sha256: sha, key: key);
  }

  @override
  Future<List<({String id, TomSecretsPasskey passkey})>>
  pendingPasskeys() async {
    final read = await _readPending();
    if (read == null) return const [];
    return TomSecretsAutofillPending.open(read.bytes, read.key);
  }

  @override
  Future<void> clearPendingPasskeys(List<String> ids) async {
    // The extension may add a passkey between the read and the write: the
    // platform replaces the file only when it is still what was read, else
    // it is read again.
    for (var attempt = 0; attempt < 5; attempt++) {
      final read = await _readPending();
      if (read == null) return;
      final kept = [
        for (final p in await TomSecretsAutofillPending.open(
          read.bytes,
          read.key,
        ))
          if (!ids.contains(p.id)) p,
      ];
      final replaced = await _channel.invokeMethod<bool>('replacePending', {
        'bytes': kept.isEmpty
            ? null
            : await TomSecretsAutofillPending.seal(
                kept,
                key: read.key,
                written: DateTime.now(),
              ),
        'expected': read.sha256,
      });
      if (replaced == true) return;
    }
    throw StateError('the pending passkeys kept changing');
  }
}
