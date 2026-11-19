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

/// The exports the app reads.
enum TomSecretsImportFormat {
  /// 1Password's 1PUX export (a zip; recommended).
  onePux('1Password (1PUX)'),

  /// 1Password's CSV export.
  onePasswordCsv('1Password (CSV)'),

  /// Enpass's JSON export (recommended).
  enpassJson('Enpass (JSON)'),

  /// Enpass's CSV export.
  enpassCsv('Enpass (CSV)'),

  /// Bitwarden's JSON export, plain or password-protected.
  bitwardenJson('Bitwarden (JSON)'),

  /// Chrome's password export (also other Chromium browsers).
  chromeCsv('Chrome (CSV)'),

  /// Edge's password export.
  edgeCsv('Edge (CSV)'),

  /// Firefox's password export.
  firefoxCsv('Firefox (CSV)'),

  /// Safari's (and the Passwords app's) export.
  safariCsv('Safari (CSV)'),

  /// Another KDBX file (KeePass, KeePassXC, …): imported as a group or
  /// merged, opened with its own password or key file.
  keepass('KeePass (KDBX)');

  const TomSecretsImportFormat(this.label);

  /// How the user reads it.
  final String label;

  /// Whether the export names no vault of its own (Enpass exports one
  /// vault per file): the user names it.
  bool get asksVaultName => this == enpassJson || this == enpassCsv;

  /// Whether it is a KDBX file rather than an export.
  bool get isKdbx => this == keepass;

  /// The browser of a browser CSV, else null.
  TomSecretsCsvBrowser? get browser => switch (this) {
    chromeCsv => TomSecretsCsvBrowser.chrome,
    edgeCsv => TomSecretsCsvBrowser.edge,
    firefoxCsv => TomSecretsCsvBrowser.firefox,
    safariCsv => TomSecretsCsvBrowser.safari,
    _ => null,
  };
}

/// The formats a file named [fileName] can be: by its extension; a CSV or
/// a JSON can be several sources', an unknown extension any of them.
List<TomSecretsImportFormat> tomSecretsImportFormatsOf(String fileName) {
  final name = fileName.toLowerCase();
  if (name.endsWith('.1pux')) return const [TomSecretsImportFormat.onePux];
  if (name.endsWith('.kdbx')) return const [TomSecretsImportFormat.keepass];
  if (name.endsWith('.json')) {
    return const [
      TomSecretsImportFormat.enpassJson,
      TomSecretsImportFormat.bitwardenJson,
    ];
  }
  if (name.endsWith('.csv')) {
    return const [
      TomSecretsImportFormat.onePasswordCsv,
      TomSecretsImportFormat.enpassCsv,
      TomSecretsImportFormat.chromeCsv,
      TomSecretsImportFormat.edgeCsv,
      TomSecretsImportFormat.firefoxCsv,
      TomSecretsImportFormat.safariCsv,
    ];
  }
  return TomSecretsImportFormat.values;
}

/// Which of [candidates] the content [bytes] looks like, when it can tell:
/// Bitwarden's JSON by its `encrypted` and `items` keys; Firefox's and
/// Safari's CSV by their columns; Chrome's (or Edge's) by
/// `name,url,username,password`; 1Password's by `Title` with `Url`. Null
/// when it cannot tell (the user picks).
TomSecretsImportFormat? tomSecretsGuessImportFormat(
  List<TomSecretsImportFormat> candidates,
  Uint8List bytes,
) {
  if (candidates.length == 1) return candidates.single;
  final text = utf8.decode(bytes, allowMalformed: true);
  TomSecretsImportFormat? only(TomSecretsImportFormat f) =>
      candidates.contains(f) ? f : null;
  final start = text.trimLeft();
  if (start.startsWith('{')) {
    try {
      final json = jsonDecode(text);
      if (json is Map && json.containsKey('encrypted')) {
        return only(TomSecretsImportFormat.bitwardenJson);
      }
      if (json is Map && json.containsKey('folders')) {
        return only(TomSecretsImportFormat.enpassJson);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
  switch (tomSecretsBrowserOfCsv(text)) {
    case TomSecretsCsvBrowser.firefox:
      return only(TomSecretsImportFormat.firefoxCsv);
    case TomSecretsCsvBrowser.safari:
      return only(TomSecretsImportFormat.safariCsv);
    default:
  }
  final header = text.split(RegExp(r'\r?\n')).first.toLowerCase();
  final columns = [
    for (final c in header.split(',')) c.trim().replaceAll('"', ''),
  ];
  if (columns.take(4).join(',') == 'name,url,username,password') {
    return only(TomSecretsImportFormat.chromeCsv);
  }
  if (columns.contains('title') && columns.contains('url')) {
    return only(TomSecretsImportFormat.onePasswordCsv);
  }
  return null;
}

/// Reads [bytes] as [format]; an Enpass export's vault is [vaultName], a
/// password-protected Bitwarden export is opened with [password]. Throws
/// `TomSecretsImportFormatException` or `FormatException` when the file is
/// not that export. A KeePass file is not read here (the KeePass import
/// opens it with its own key).
Future<TomSecretsImportSource> tomSecretsReadExport(
  TomSecretsImportFormat format,
  Uint8List bytes, {
  String vaultName = 'Vault',
  String? password,
}) async {
  String text() => utf8.decode(bytes, allowMalformed: true);
  final browser = format.browser;
  if (browser != null) {
    return tomSecretsReadBrowserCsv(text(), browser: browser);
  }
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
    TomSecretsImportFormat.bitwardenJson => await tomSecretsReadBitwardenJson(
      text(),
      password: password,
    ),
    _ => throw ArgumentError('$format is not an export'),
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
