// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The emergency sheet (BP-37): the vaults with their locators,
/// repositories, formats and ciphers, a blank line for the master password,
/// every key file and repository key once with its key id and a QR text that
/// gives the key back, never a password; and the PDF it renders. Demo data
/// only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

void main() {
  const masterPassword = 'demo-master-password';
  final primaryKeyFile = TomSecretsKeyFile.generate();
  final teamKeyFile = TomSecretsKeyFile.generate();
  final repoKey = TomSecretsRepositoryKey.generate();
  final otherKey = TomSecretsRepositoryKey.generate();

  TomSecretsEmergencySheet sheet() => TomSecretsEmergencySheet.of(
    primaryName: 'primary',
    primaryLocator: 'github:al-the-bear/demo-vaults/primary.kdbx.tsmx',
    primaryKeyFile: primaryKeyFile.toBytes(),
    primaryOuterKey: repoKey.toBase64(),
    primaryCipher: TomSecretsOuterCipher.xchacha20Poly1305,
    listed: [
      TomSecretsVaultKeys(
        name: 'team',
        locator: 'file:/demo/vaults/team.kdbx',
        password: 'team-demo-pw',
        keyFile: teamKeyFile.toBytes(),
      ),
      TomSecretsVaultKeys(
        name: 'secrets',
        locator: 'github:al-the-bear/demo-vaults/secrets.kdbx.tsmx',
        password: 'secrets-demo-pw',
        outerKey: repoKey.toBase64(),
        githubToken: 'demo-github-token',
      ),
      TomSecretsVaultKeys(
        name: 'certs',
        locator: 'github:al-the-bear/other-vaults/certs.kdbx.tsmx',
        password: 'certs-demo-pw',
        outerKey: otherKey.toBase64(),
      ),
    ],
    ciphers: const {'secrets': TomSecretsOuterCipher.aes256Gcm},
    created: DateTime.utc(2026, 11, 15),
  );

  const secrets = [
    masterPassword,
    'team-demo-pw',
    'secrets-demo-pw',
    'certs-demo-pw',
    'demo-github-token',
  ];

  test('the vaults: locator, repository, format, cipher and key ids, the '
      'primary first', () {
    final s = sheet();
    expect(s.vaults.map((v) => v.name), [
      'primary',
      'team',
      'secrets',
      'certs',
    ]);
    final primary = s.vaults.first;
    expect(primary.primary, isTrue);
    expect(primary.repository, 'github.com/al-the-bear/demo-vaults');
    expect(primary.outer, isTrue);
    expect(primary.cipherName, 'XChaCha20-Poly1305');
    expect(primary.keyFileId, primaryKeyFile.hash);
    expect(primary.repositoryKeyId, repoKey.keyIdHex);
    final team = s.vaults[1];
    expect(team.repository, '/demo/vaults');
    expect(team.outer, isFalse);
    expect(team.cipherName, '-');
    expect(team.keyFileId, teamKeyFile.hash);
    expect(team.repositoryKeyId, isNull);
    expect(s.vaults[2].cipherName, 'AES-256-GCM');
    expect(s.vaults[3].cipherName, 'not read on this machine');
    expect(s.fileName, 'primary-emergency-sheet.pdf');
  });

  test('every key once, with its id and a QR text that gives it back', () {
    final s = sheet();
    expect(s.keys.map((k) => k.title), [
      'Key file ${primaryKeyFile.hash}',
      'Repository key ${repoKey.keyIdHex}',
      'Key file ${teamKeyFile.hash}',
      'Repository key ${otherKey.keyIdHex}',
    ]);
    final shared = s.keys[1];
    expect(shared.usedBy, ['primary', 'secrets'], reason: 'printed once');
    for (final k in s.keys) {
      expect(k.keyId, isNotEmpty);
      switch (k.kind) {
        case TomSecretsSheetKeyKind.keyFile:
          final back = TomSecretsKeyFile.parse(
            Uint8List.fromList(utf8.encode(k.qrText)),
          );
          expect(back.hash, k.keyId);
        case TomSecretsSheetKeyKind.repositoryKey:
          expect(
            TomSecretsRepositoryKey.fromBase64(k.qrText).keyIdHex,
            k.keyId,
          );
      }
    }
    expect(
      TomSecretsKeyFile.parse(
        Uint8List.fromList(utf8.encode(s.keys.first.qrText)),
      ).key,
      primaryKeyFile.key,
    );
  });

  test('the master password is a blank line; no password or token is on '
      'the sheet', () {
    final s = sheet();
    expect(s.lines, contains(startsWith('Master password: ______')));
    final text = [...s.lines, for (final k in s.keys) k.qrText].join('\n');
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)));
    }
  });

  test(
    'the PDF: one document with the text and the codes, no password',
    () async {
      final s = sheet();
      final pdf = await s.toPdf(compress: false);
      final raw = latin1.decode(pdf);
      expect(raw, startsWith('%PDF-'));
      expect(raw, contains('(Master)'));
      expect(raw, contains('(primary)'));
      expect(raw, contains(repoKey.keyIdHex));
      expect(raw, contains(teamKeyFile.hash));
      for (final secret in secrets) {
        expect(raw, isNot(contains(secret)));
      }
      final compressed = await s.toPdf();
      expect(latin1.decode(compressed.sublist(0, 5)), '%PDF-');
    },
  );

  test('a new primary without keys: the locator and the blank line', () {
    final s = TomSecretsEmergencySheet.of(
      primaryName: 'primary',
      primaryLocator: 'file:/demo/primary.kdbx',
    );
    expect(s.keys, isEmpty);
    expect(s.vaults.single.keyFileId, isNull);
    expect(s.lines, contains('Primary vault primary: file:/demo/primary.kdbx'));
  });
}
