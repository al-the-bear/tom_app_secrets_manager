// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's platform ports: the device preferences (a JSON file in
/// the app's support directory, never synced or backed up) and the
/// clipboard (iOS: local only, never Universal Clipboard, expiring after the
/// clipboard timeout; Android: marked sensitive, cleared only while it still
/// holds the copy).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tom_basics/utilities.dart'
    show TomClipboardPort, TomClipboardReceipt;
import 'package:tom_secrets_ui/tom_secrets_ui.dart' show TomSecretsPreferences;

/// [TomSecretsPreferences] in a JSON file.
final class TomSecretsMobilePreferences implements TomSecretsPreferences {
  TomSecretsMobilePreferences._(this.file, this._values);

  /// Reads [file]; a missing or unreadable file starts empty.
  static Future<TomSecretsMobilePreferences> open(File file) async {
    var values = <String, String>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        values = {
          for (final MapEntry(:key, :value) in decoded.entries)
            if (key is String && value is String) key: value,
        };
      }
    } on Object {
      // A new or damaged file: the defaults.
    }
    return TomSecretsMobilePreferences._(file, values);
  }

  /// The file.
  final File file;
  final Map<String, String> _values;

  @override
  String? read(String key) => _values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(_values));
    await temp.rename(file.path);
  }
}

/// [TomClipboardPort] over the app's own clipboard channel.
final class TomSecretsMobileClipboardPort implements TomClipboardPort {
  /// The port; [clearAfter] is the timeout the iOS expiry takes.
  const TomSecretsMobileClipboardPort({
    required this.clearAfter,
    this.channel = const MethodChannel('tom_secrets_mobile/clipboard'),
  });

  /// The clipboard timeout.
  final Duration Function() clearAfter;

  /// The channel (`place`, `clear`).
  final MethodChannel channel;

  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async {
    try {
      final generation = await channel.invokeMethod<int>('place', {
        'text': text,
        'seconds': clearAfter().inSeconds,
      });
      return TomClipboardReceipt(text, generation: generation);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async {
    try {
      return await channel.invokeMethod<bool>('clear', {
            'text': receipt.text,
            'generation': receipt.generation,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// When this iOS build stops starting (its provisioning profile's expiry; a
/// free personal team's lasts 7 days, DP-130), or null: Android, the
/// simulator, no profile.
Future<DateTime?> tomSecretsMobileProfileExpiry({
  MethodChannel channel = const MethodChannel('tom_secrets_mobile/app'),
}) async {
  if (!Platform.isIOS) return null;
  try {
    final text = await channel.invokeMethod<String>('profileExpiry');
    return text == null ? null : DateTime.tryParse(text);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
