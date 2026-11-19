// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The other imports and the exports in the app (part-password-manager,
/// DP-40): a password-protected Bitwarden export opened with its password,
/// a browser's CSV told by its columns, a KeePass file as a group (and
/// refused as a merge when it is another vault), and the Export dialog from
/// a vault's menu: CSV and Bitwarden JSON with the plaintext warning, KDBX
/// under a new password. Demo data only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

final class _Files implements TomSecretsFiles {
  final Map<String, Uint8List> disk = {};
  final Map<String, Uint8List> saved = {};
  String? next;

  @override
  Future<({String name, Uint8List bytes})?> pick() async => null;

  @override
  Future<bool> save(String name, Uint8List bytes) async {
    saved[name] = Uint8List.fromList(bytes);
    return true;
  }

  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => next;

  @override
  Future<Uint8List> read(String path) async => Uint8List.fromList(disk[path]!);

  @override
  Future<bool> delete(String path) async => disk.remove(path) != null;
}

/// A password-protected Bitwarden export of one demo login, written as
/// Bitwarden writes it (PBKDF2, HKDF, AES-256-CBC with HMAC).
Future<Uint8List> _bitwardenProtected(String password) async {
  final plain = jsonEncode({
    'encrypted': false,
    'folders': [
      {'id': 'f1', 'name': 'Work'},
    ],
    'items': [
      {
        'id': 'b1',
        'folderId': 'f1',
        'type': 1,
        'name': 'Bw login',
        'revisionDate': '2026-01-01T00:00:00.000Z',
        'login': {
          'username': 'demo-bw',
          'password': 'demo-bw-pw',
          'uris': [
            {'uri': 'https://bw.example.com'},
          ],
        },
      },
    ],
  });
  const salt = 'demo-salt';
  final keys = await tomSecretsBitwardenExportKeys(
    password: password,
    salt: salt,
    iterations: 1000,
  );
  Future<String> encrypt(List<int> data) async {
    final iv = List<int>.generate(16, (i) => i);
    final box = await cg.AesCbc.with256bits(
      macAlgorithm: cg.MacAlgorithm.empty,
    ).encrypt(data, secretKey: cg.SecretKey(keys.encryption), nonce: iv);
    final mac = (await cg.Hmac.sha256().calculateMac([
      ...iv,
      ...box.cipherText,
    ], secretKey: cg.SecretKey(keys.mac))).bytes;
    return '2.${base64.encode(iv)}|${base64.encode(box.cipherText)}|'
        '${base64.encode(mac)}';
  }

  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'encrypted': true,
        'passwordProtected': true,
        'salt': salt,
        'kdfType': 0,
        'kdfIterations': 1000,
        'encKeyValidation_DO_NOT_EDIT': await encrypt(utf8.encode('check')),
        'data': await encrypt(utf8.encode(plain)),
      }),
    ),
  );
}

void main() {
  late FakeService service;
  late _Files files;

  setUp(() async {
    service = FakeService(await demoStores());
    files = _Files();
  });

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> unlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TomSecretsApp(
        host: TomSecretsHost(
          service: FakeHost(service),
          preferences: TomSecretsMemoryPreferences(),
          clipboard: _Clipboard(),
          files: files,
          breachCheck: TomSecretsBreachCheck(
            endpoint: Uri.parse('http://127.0.0.1:9/'),
          ),
        ),
      ),
    );
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
  }

  Future<KdbxFile> stored(WidgetTester tester) async => (await tester.runAsync(
    () => KdbxFormat().read(
      service.store('primary').stored,
      tomSecretsVaultCredentials(password: demoPassword),
    ),
  ))!;

  KdbxEntry? byTitle(KdbxFile file, String title) => file.body.rootGroup
      .getAllEntries()
      .where((e) => e.label == title)
      .firstOrNull;

  Future<void> pick(WidgetTester tester, String path) async {
    files.next = path;
    await tester.tap(find.text('Import'));
    await wait(tester);
    await tester.tap(find.byKey(const Key('tsm-import-pick')));
    await wait(tester, 5);
  }

  Future<void> previewAndImport(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tsm-import-preview')));
    await wait(tester, 5);
    await tester.ensureVisible(find.byKey(const Key('tsm-import-run')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-import-run')));
    await wait(tester, 6);
  }

  testWidgets('a password-protected Bitwarden export: told by its content, '
      'opened with its password (a wrong one said so), imported', (
    tester,
  ) async {
    files.disk['/demo/bitwarden.json'] = (await tester.runAsync(
      () => _bitwardenProtected('demo-bw-export'),
    ))!;
    await unlocked(tester);
    await pick(tester, '/demo/bitwarden.json');
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('tsm-import-format-bitwardenJson')),
          )
          .selected,
      isTrue,
    );
    expect(find.byKey(const Key('tsm-import-export-password')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('tsm-import-export-password')),
      'wrong',
    );
    await tester.tap(find.byKey(const Key('tsm-import-open')));
    await wait(tester, 5);
    expect(
      find.textContaining('cannot be opened: the export password is wrong'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('tsm-import-export-password')),
      'demo-bw-export',
    );
    await tester.tap(find.byKey(const Key('tsm-import-open')));
    await wait(tester, 5);
    expect(find.textContaining('Bitwarden, Bitwarden (JSON)'), findsOneWidget);
    await previewAndImport(tester);
    final login = byTitle(await stored(tester), 'Bw login');
    expect(login, isNotNull);
    expect(login!.getString(KdbxKeyCommon.PASSWORD)?.getText(), 'demo-bw-pw');
    expect(login.parent?.name.get(), 'Work');
  });

  testWidgets("a browser's CSV is told by its columns and imported", (
    tester,
  ) async {
    files.disk['/demo/firefox.csv'] = Uint8List.fromList(
      utf8.encode(
        '"url","username","password","httpRealm","formActionOrigin","guid",'
        '"timeCreated","timeLastUsed","timePasswordChanged"\n'
        '"https://ff.example.com","demo-ff","demo-ff-pw",,"",'
        '"{x}","1","1","1"\n',
      ),
    );
    await unlocked(tester);
    await pick(tester, '/demo/firefox.csv');
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('tsm-import-format-firefoxCsv')),
          )
          .selected,
      isTrue,
    );
    await previewAndImport(tester);
    final login = byTitle(await stored(tester), 'ff.example.com');
    expect(login?.getString(KdbxKeyCommon.USER_NAME)?.getText(), 'demo-ff');
    expect(
      login?.getString(const KdbxKey('tsm.import.firefox.id'))?.getText(),
      startsWith('csv:'),
    );
  });

  testWidgets('a KeePass file: imported as a group with its password; '
      'merging another vault is refused', (tester) async {
    files.disk['/demo/team.kdbx'] = (await tester.runAsync(
      () => demoVault('team', 'demo-kp-pw', (f) {
        addEntry(f, 'Servers/Kp login', password: 'demo-kp-login');
      }),
    ))!;
    await unlocked(tester);
    await pick(tester, '/demo/team.kdbx');
    expect(find.byKey(const Key('tsm-import-kdbx')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('tsm-import-kdbx-password')),
      'not-it',
    );
    await tester.tap(find.byKey(const Key('tsm-import-kdbx-run')));
    await wait(tester, 6);
    expect(find.textContaining('Wrong password or key file'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('tsm-import-kdbx-password')),
      'demo-kp-pw',
    );
    await tester.tap(find.byKey(const Key('tsm-import-kdbx-merge')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-import-kdbx-run')));
    await wait(tester, 6);
    expect(find.textContaining('another vault, not a copy'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tsm-import-kdbx-as-group')));
    await tester.pump();
    expect(find.text('team'), findsWidgets);
    await tester.tap(find.byKey(const Key('tsm-import-kdbx-run')));
    await wait(tester, 6);
    expect(
      find.text('1 entries in 1 groups copied into primary › team.'),
      findsOneWidget,
    );
    final login = byTitle(await stored(tester), 'Kp login');
    expect(login?.parent?.name.get(), 'Servers');
    expect(login?.parent?.parent?.name.get(), 'team');
  });

  testWidgets("a vault's menu exports it: CSV and Bitwarden JSON after the "
      'plaintext warning, KDBX under a new password', (tester) async {
    await unlocked(tester);
    await tester.tap(find.text('Tree'));
    await tester.pumpAndSettle();
    Future<void> openExport() async {
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('tsm-vault-primary')),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-vault-export-primary')));
      await tester.pumpAndSettle();
    }

    await openExport();
    expect(find.byKey(const Key('tsm-export-warning')), findsNothing);
    await tester.tap(find.byKey(const Key('tsm-export-format-csv')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-export-warning')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-export-run')));
    await wait(tester, 3);
    final csv = utf8.decode(files.saved['primary.csv']!);
    expect(csv, startsWith('Title,URL,Username,Password'));
    expect(csv, contains('demo-db-pw'));
    expect(csv, isNot(contains(tomSecretsMetadataTitle)));
    expect(find.byKey(const Key('tsm-export-result')), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await openExport();
    await tester.tap(find.byKey(const Key('tsm-export-format-bitwardenJson')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-export-warning')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-export-run')));
    await wait(tester, 3);
    final json =
        jsonDecode(utf8.decode(files.saved['primary_bitwarden.json']!))
            as Map<String, Object?>;
    expect(
      (json['items'] as List).map((i) => (i as Map)['name']),
      contains('Main'),
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await openExport();
    await tester.enterText(
      find.byKey(const Key('tsm-export-password')),
      'demo-copy-pw',
    );
    await tester.enterText(find.byKey(const Key('tsm-export-repeat')), 'x');
    await tester.tap(find.byKey(const Key('tsm-export-run')));
    await tester.pump();
    expect(find.text('The passwords differ.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('tsm-export-repeat')),
      'demo-copy-pw',
    );
    await tester.tap(find.byKey(const Key('tsm-export-run')));
    await wait(tester, 30);
    final copy = (await tester.runAsync(
      () => KdbxFormat().read(
        files.saved['primary.kdbx']!,
        tomSecretsVaultCredentials(password: 'demo-copy-pw'),
      ),
    ))!;
    expect(byTitle(copy, 'Main'), isNotNull);
    expect(byTitle(copy, tomSecretsMetadataTitle), isNull);
  });
}
