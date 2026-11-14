// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The device's own preferences (a JSON file in the data directory, never
/// synced), the key-file picker of the unlock screen and the attachments'
/// files (`file_selector`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:tom_reusable_ui/tom_reusable_ui.dart'
    show TomKeyFile, TomKeyFilePicker;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

/// [TomSecretsPreferences] in `app-preferences.json` of the data directory.
final class TomSecretsFilePreferences implements TomSecretsPreferences {
  TomSecretsFilePreferences._(this.file, this._values);

  /// Reads [file]; a missing or unreadable file starts empty.
  static Future<TomSecretsFilePreferences> open(File file) async {
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
    return TomSecretsFilePreferences._(file, values);
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
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_values),
    );
    await temp.rename(file.path);
  }
}

/// The platform file dialogs for key files and attachments.
final class TomSecretsDesktopFiles
    implements TomSecretsFiles, TomKeyFilePicker {
  /// The dialogs.
  const TomSecretsDesktopFiles();

  @override
  Future<({String name, Uint8List bytes})?> pick() async {
    final file = await openFile();
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }

  @override
  Future<bool> save(String name, Uint8List bytes) async {
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await File(location.path).writeAsBytes(bytes, flush: true);
    return true;
  }

  @override
  Future<TomKeyFile?> pickKeyFile(BuildContext context) async {
    final file = await openFile(confirmButtonText: 'Use as key file');
    if (file == null) return null;
    return TomKeyFile(locator: file.path, bytes: await file.readAsBytes());
  }
}
