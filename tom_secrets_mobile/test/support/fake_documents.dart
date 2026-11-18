// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The phone's documents in memory, for the tests: the files "picked"
/// (`next`), read and written by id; what the share sheet was handed.
library;

import 'dart:typed_data';

import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';

final class FakeDocuments implements TomSecretsDocuments {
  /// The documents by id.
  final Map<String, Uint8List> files = {};

  /// The next vault document the picker answers.
  TomSecretsPickedDocument? nextVault;

  /// The next file the picker answers.
  ({String name, Uint8List bytes})? nextFile;

  /// What the share sheet was handed.
  final List<(String, Uint8List)> shared = [];

  @override
  Future<TomSecretsPickedDocument?> pickVault() async => nextVault;

  @override
  Future<Uint8List> read(String id) async =>
      files[id] ?? (throw TomSecretsDocumentException('no document $id'));

  @override
  Future<void> write(String id, Uint8List bytes) async {
    if (!files.containsKey(id)) {
      throw TomSecretsDocumentException('no document $id');
    }
    files[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<({String name, Uint8List bytes})?> pickFile() async => nextFile;

  @override
  Future<bool> share(String name, Uint8List bytes) async {
    shared.add((name, bytes));
    return true;
  }
}
