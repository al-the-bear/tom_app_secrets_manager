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
}
