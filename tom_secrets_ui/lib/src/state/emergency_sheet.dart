// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The emergency sheet (BP-37): one printable page per primary vault with
/// what it takes to open its vaults on a new machine — the vault locators
/// and repositories, a blank line for the master password (never printed),
/// each key file and repository key as a QR code with its key id, and the
/// `.tsmx` format and each file's outer cipher. Offered when a vault is
/// created (First run) and when a key changes (rotation). The model takes no
/// password at all, so none can reach the page.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:tom_secrets_core/tom_secrets_core.dart';

/// What a key on the sheet is.
enum TomSecretsSheetKeyKind {
  /// A KeePass key file (its QR code holds the `.keyx` file's text).
  keyFile,

  /// A repository's outer key (its QR code holds the key in base64).
  repositoryKey,
}

/// One key on the sheet, printed as a QR code.
final class TomSecretsSheetKey {
  /// A key of [kind] with its [keyId], for [usedBy], whose QR code holds
  /// [qrText].
  const TomSecretsSheetKey({
    required this.kind,
    required this.keyId,
    required this.usedBy,
    required this.qrText,
  });

  /// What it is.
  final TomSecretsSheetKeyKind kind;

  /// Its key id: a key file's hash (the `.keyx` Hash), a repository key's
  /// id (the first 8 bytes of SHA-256 over it, hex).
  final String keyId;

  /// The vaults it opens.
  final List<String> usedBy;

  /// What the QR code holds: the `.keyx` file's text, or the key in base64.
  final String qrText;

  /// Its title on the sheet.
  String get title => switch (kind) {
    TomSecretsSheetKeyKind.keyFile => 'Key file $keyId',
    TomSecretsSheetKeyKind.repositoryKey => 'Repository key $keyId',
  };

  /// How to restore it from the code.
  String get restore => switch (kind) {
    TomSecretsSheetKeyKind.keyFile =>
      'Scan the code and save its text as a .keyx file.',
    TomSecretsSheetKeyKind.repositoryKey =>
      'Scan the code: the text is the repository key (base64).',
  };
}

/// One vault on the sheet.
final class TomSecretsSheetVault {
  /// A vault [name] at [locator].
  const TomSecretsSheetVault({
    required this.name,
    required this.locator,
    required this.primary,
    this.cipher,
    this.keyFileId,
    this.repositoryKeyId,
  });

  /// Its store name.
  final String name;

  /// Its locator.
  final String locator;

  /// Whether it is the primary.
  final bool primary;

  /// The outer cipher of a `.tsmx` file, when this machine read it.
  final TomSecretsOuterCipher? cipher;

  /// The id of its key file, or null.
  final String? keyFileId;

  /// The id of its repository key, or null.
  final String? repositoryKeyId;

  /// Whether it is outer encrypted (`.kdbx.tsmx`).
  bool get outer => locator.endsWith(tomSecretsOuterSuffix);

  /// Its repository: `owner/name` on GitHub, else the folder on the disk.
  String get repository {
    final parsed = TomSecretsVaultLocator.parse(locator);
    return switch (parsed) {
      TomSecretsGitHubLocator() => 'github.com/${parsed.repositorySlug}',
      TomSecretsFileLocator() => _folderOf(parsed.path),
      _ => locator,
    };
  }

  /// Its format: KDBX 4, or KDBX 4 inside the `.tsmx` outer layer.
  String get format =>
      outer ? '.kdbx.tsmx (KDBX 4 in the TSMX outer layer)' : '.kdbx (KDBX 4)';

  /// Its outer cipher in words.
  String get cipherName => !outer
      ? '-'
      : switch (cipher) {
          TomSecretsOuterCipher.xchacha20Poly1305 => 'XChaCha20-Poly1305',
          TomSecretsOuterCipher.aes256Gcm => 'AES-256-GCM',
          null => 'not read on this machine',
        };
}

String _folderOf(String path) {
  final i = path.replaceAll(r'\', '/').lastIndexOf('/');
  return i <= 0 ? path : path.substring(0, i);
}

/// The emergency sheet of a primary vault.
final class TomSecretsEmergencySheet {
  /// A sheet of [vaults] (the primary first) and [keys], made at [created].
  const TomSecretsEmergencySheet({
    required this.vaults,
    required this.keys,
    required this.created,
  });

  /// The sheet of the primary [primaryName] at [primaryLocator] with its
  /// [primaryKeyFile] (the `.keyx` bytes), [primaryOuterKey] (base64) and
  /// [primaryCipher], and the further vaults it lists ([listed]: only their
  /// locators, key files and outer keys are read, never a password), with
  /// the outer cipher of each file this machine read ([ciphers], by store).
  /// A repository key several vaults share is printed once.
  factory TomSecretsEmergencySheet.of({
    required String primaryName,
    required String primaryLocator,
    Uint8List? primaryKeyFile,
    String? primaryOuterKey,
    TomSecretsOuterCipher? primaryCipher,
    List<TomSecretsVaultKeys> listed = const [],
    Map<String, TomSecretsOuterCipher?> ciphers = const {},
    DateTime? created,
  }) {
    final keys = <String, TomSecretsSheetKey>{};
    String? keyFile(String vault, List<int>? bytes) {
      if (bytes == null) return null;
      final file = TomSecretsKeyFile.parse(Uint8List.fromList(bytes));
      final id = file.hash;
      final text = utf8.decode(file.toBytes());
      file.dispose();
      _add(
        keys,
        'keyFile:$id',
        TomSecretsSheetKeyKind.keyFile,
        id,
        vault,
        text,
      );
      return id;
    }

    String? repositoryKey(String vault, String? key) {
      if (key == null) return null;
      final id = TomSecretsRepositoryKey.fromBase64(key).keyIdHex;
      _add(
        keys,
        'repositoryKey:$id',
        TomSecretsSheetKeyKind.repositoryKey,
        id,
        vault,
        key,
      );
      return id;
    }

    final vaults = [
      TomSecretsSheetVault(
        name: primaryName,
        locator: primaryLocator,
        primary: true,
        cipher: primaryCipher,
        keyFileId: keyFile(primaryName, primaryKeyFile),
        repositoryKeyId: repositoryKey(primaryName, primaryOuterKey),
      ),
      for (final v in listed)
        TomSecretsSheetVault(
          name: v.name,
          locator: v.locator,
          primary: false,
          cipher: ciphers[v.name],
          keyFileId: keyFile(v.name, v.keyFile),
          repositoryKeyId: repositoryKey(v.name, v.outerKey),
        ),
    ];
    return TomSecretsEmergencySheet(
      vaults: vaults,
      keys: keys.values.toList(),
      created: (created ?? DateTime.now()).toUtc(),
    );
  }

  static void _add(
    Map<String, TomSecretsSheetKey> keys,
    String id,
    TomSecretsSheetKeyKind kind,
    String keyId,
    String vault,
    String qrText,
  ) {
    final old = keys[id];
    keys[id] = TomSecretsSheetKey(
      kind: kind,
      keyId: keyId,
      usedBy: [...?old?.usedBy, vault],
      qrText: qrText,
    );
  }

  /// The vaults, the primary first.
  final List<TomSecretsSheetVault> vaults;

  /// The key files and repository keys, each once.
  final List<TomSecretsSheetKey> keys;

  /// When it was made (UTC).
  final DateTime created;

  /// The primary's store name.
  String get primaryName => vaults.first.name;

  /// The file name it is saved under.
  String get fileName => '$primaryName-emergency-sheet.pdf';

  /// The sheet's text, line by line, as the page prints it (without the
  /// QR codes' contents).
  List<String> get lines => [
    'Emergency sheet: $primaryName',
    'Made ${created.toIso8601String().substring(0, 10)}',
    'Master password: ______________________________ (write it by hand)',
    for (final v in vaults) ...[
      '${v.primary ? 'Primary vault' : 'Vault'} ${v.name}: ${v.locator}',
      'Repository: ${v.repository}',
      'Format: ${v.format}',
      'Outer cipher: ${v.cipherName}',
      'Key file: ${v.keyFileId ?? 'none'}',
      'Repository key: ${v.repositoryKeyId ?? 'none'}',
    ],
    for (final k in keys) ...[
      k.title,
      'Opens: ${k.usedBy.join(', ')}',
      k.restore,
    ],
  ];

  /// The sheet as a PDF (A4); [compress] off writes its text readable in
  /// the file, for tests.
  Future<Uint8List> toPdf({bool compress = true}) async {
    final doc = pw.Document(
      compress: compress,
      title: 'Emergency sheet: $primaryName',
      author: 'Tom Secrets Manager',
    );
    final small = const pw.TextStyle(fontSize: 8);
    final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) => [
          pw.Text(
            'Emergency sheet: $primaryName',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text(
            'Made ${created.toIso8601String().substring(0, 10)} by the Tom '
            'Secrets Manager. Keep it offline, where you keep your recovery '
            'codes. With the master password it opens every vault below on '
            'a new machine.',
            style: small,
          ),
          pw.SizedBox(height: 14),
          pw.Text('Master password', style: bold),
          pw.SizedBox(height: 18),
          pw.Container(
            decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(width: 0.8)),
            ),
            height: 1,
          ),
          pw.Text('Write it by hand; it is never printed.', style: small),
          pw.SizedBox(height: 14),
          pw.Text('Vaults', style: bold),
          pw.SizedBox(height: 4),
          pw.TableHelper.fromTextArray(
            cellStyle: small,
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
            headers: [
              'Vault',
              'Locator',
              'Repository',
              'Format',
              'Outer cipher',
              'Key file',
              'Repository key',
            ],
            data: [
              for (final v in vaults)
                [
                  v.primary ? '${v.name} (primary)' : v.name,
                  v.locator,
                  v.repository,
                  v.outer ? '.kdbx.tsmx' : '.kdbx',
                  v.cipherName,
                  v.keyFileId ?? 'none',
                  v.repositoryKeyId ?? 'none',
                ],
            ],
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'A .kdbx.tsmx file is a KDBX 4 vault inside the TSMX outer layer, '
            'encrypted under its repository key with the cipher named; a '
            '.kdbx file is a plain KDBX 4 vault.',
            style: small,
          ),
          if (keys.isNotEmpty) ...[
            pw.SizedBox(height: 14),
            pw.Text('Keys', style: bold),
            pw.SizedBox(height: 6),
            pw.Wrap(
              spacing: 18,
              runSpacing: 18,
              children: [
                for (final k in keys)
                  pw.SizedBox(
                    width: 240,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(k.title, style: bold),
                        pw.Text('Opens: ${k.usedBy.join(', ')}', style: small),
                        pw.SizedBox(height: 4),
                        pw.BarcodeWidget(
                          barcode: pw.Barcode.qrCode(),
                          data: k.qrText,
                          width: 150,
                          height: 150,
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(k.restore, style: small),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    return doc.save();
  }
}
