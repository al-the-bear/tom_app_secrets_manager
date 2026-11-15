// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Import screen's model (part-app, Screens › Import; part-password-
/// manager): which export a file is, reading it with `tom_secrets_core`'s
/// importers, mapping each source vault to a vault and group, the preview
/// and the run.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:tom_secrets_core/tom_secrets_core.dart';

/// The exports the app reads in phase A.
enum TomSecretsImportFormat {
  /// 1Password's 1PUX export (a zip; recommended).
  onePux('1Password (1PUX)'),

  /// 1Password's CSV export.
  onePasswordCsv('1Password (CSV)'),

  /// Enpass's JSON export (recommended).
  enpassJson('Enpass (JSON)'),

  /// Enpass's CSV export.
  enpassCsv('Enpass (CSV)');

  const TomSecretsImportFormat(this.label);

  /// How the user reads it.
  final String label;

  /// Whether the export names no vault of its own (Enpass exports one
  /// vault per file): the user names it.
  bool get asksVaultName => this == enpassJson || this == enpassCsv;
}

/// The formats a file named [fileName] can be: by its extension; a CSV can
/// be either source's, an unknown extension any of them.
List<TomSecretsImportFormat> tomSecretsImportFormatsOf(String fileName) {
  final name = fileName.toLowerCase();
  if (name.endsWith('.1pux')) return const [TomSecretsImportFormat.onePux];
  if (name.endsWith('.json')) return const [TomSecretsImportFormat.enpassJson];
  if (name.endsWith('.csv')) {
    return const [
      TomSecretsImportFormat.onePasswordCsv,
      TomSecretsImportFormat.enpassCsv,
    ];
  }
  return TomSecretsImportFormat.values;
}

/// Reads [bytes] as [format]; an Enpass export's vault is [vaultName].
/// Throws `TomSecretsImportFormatException` or `FormatException` when the
/// file is not that export.
TomSecretsImportSource tomSecretsReadExport(
  TomSecretsImportFormat format,
  Uint8List bytes, {
  String vaultName = 'Vault',
}) {
  String text() => utf8.decode(bytes, allowMalformed: true);
  return switch (format) {
    TomSecretsImportFormat.onePux => tomSecretsRead1Pux(bytes),
    TomSecretsImportFormat.onePasswordCsv => tomSecretsRead1PasswordCsv(text()),
    TomSecretsImportFormat.enpassJson => tomSecretsReadEnpassJson(
      text(),
      vaultName: vaultName,
    ),
    TomSecretsImportFormat.enpassCsv => tomSecretsReadEnpassCsv(
      text(),
      vaultName: vaultName,
    ),
  };
}

/// Where one source vault goes: [group] (a path of group names) in the
/// open vault [store].
final class TomSecretsImportMapping {
  /// [group] in [store].
  const TomSecretsImportMapping(this.store, this.group);

  /// The open vault written to.
  final String store;

  /// The group path from its root.
  final List<String> group;

  /// [text] as a group path: `/`-separated names, empty ones dropped.
  static List<String> groupOf(String text) => [
    for (final s in text.split('/'))
      if (s.trim().isNotEmpty) s.trim(),
  ];
}

/// The outcomes as the report names them, in the order it lists them.
const Map<TomSecretsImportOutcome, String> tomSecretsImportOutcomeLabels = {
  TomSecretsImportOutcome.added: 'added',
  TomSecretsImportOutcome.updated: 'updated',
  TomSecretsImportOutcome.conflict: 'imported as conflicts',
  TomSecretsImportOutcome.unchanged: 'unchanged, skipped',
  TomSecretsImportOutcome.notInExport: 'no longer in the export, kept',
  TomSecretsImportOutcome.leftOut: 'left out (archived)',
  TomSecretsImportOutcome.notImported: 'not imported',
  TomSecretsImportOutcome.passkeyKept: 'passkeys kept, not usable yet',
};
