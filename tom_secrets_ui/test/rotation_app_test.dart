// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Rotating keys by hand from the Keys screen (part-key-rotation) against
/// the fake service: a further vault's master password and a new key file,
/// a repository key with the outer cipher across the vaults of one
/// repository (one of them not served here), the primary's own master
/// password, and a rotation whose re-keyed save failed, finished from the
/// banner. The new keys go into the primary first, the vaults are saved
/// re-keyed, and the GitHub repository's history is cut. Demo data only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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
  final Map<String, Uint8List> saved = {};

  @override
  Future<({String name, Uint8List bytes})?> pick() async => null;

  @override
  Future<bool> save(String name, Uint8List bytes) async {
    saved[name] = bytes;
    return true;
  }

  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => null;

  @override
  Future<Uint8List> read(String path) async => throw StateError(path);

  @override
  Future<bool> delete(String path) async => false;
}

const _repo = 'al-the-bear/demo-vaults';
const _team = 'github:$_repo/team.kdbx';
const _secrets = 'github:$_repo/secrets.kdbx.tsmx';
const _certs = 'github:$_repo/certs.kdbx.tsmx';

/// A `.tsmx` vault at [location] under [password] and [outerKey].
Future<Uint8List> _outerVault(
  String name,
  String location,
  String password,
  String outerKey,
) async {
  final file = tomSecretsNewVault(
    tomSecretsVaultCredentials(password: password),
    name,
    argon2: testArgon2,
  );
  addEntry(file, 'Api/Key', password: 'demo-$name-key');
  return tomSecretsEncodeStored(location, file, outerKey: outerKey);
}

void main() {
  late FakeService service;
  late _Files files;
  late TomSecretsHost host;
  late String repoKey;

  setUp(() async {
    repoKey = TomSecretsRepositoryKey.generate().toBase64();
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Db/Main', password: 'demo-db-pw');
      TomSecretsPrimaryVaults(f)
        ..put(
          TomSecretsVaultKeys(
            name: 'team',
            locator: _team,
            password: 'team-demo-pw',
          ),
        )
        ..put(
          TomSecretsVaultKeys(
            name: 'secrets',
            locator: _secrets,
            password: 'secrets-demo-pw',
            outerKey: repoKey,
          ),
        )
        ..put(
          TomSecretsVaultKeys(
            name: 'certs',
            locator: _certs,
            password: 'certs-demo-pw',
            outerKey: repoKey,
          ),
        );
    });
    final team = await demoVault('team', 'team-demo-pw', (f) {
      addEntry(f, 'Api/Token', password: 'demo-api-token');
    });
    service = FakeService(
      [
        FakeStore('primary', demoPassword, primary),
        FakeStore('team', 'team-demo-pw', team, location: _team),
        FakeStore(
          'secrets',
          'secrets-demo-pw',
          await _outerVault('secrets', _secrets, 'secrets-demo-pw', repoKey),
          location: _secrets,
          outerKey: repoKey,
        ),
      ],
      unserved: [
        FakeStore(
          'certs',
          'certs-demo-pw',
          await _outerVault('certs', _certs, 'certs-demo-pw', repoKey),
          location: _certs,
          outerKey: repoKey,
        ),
      ],
    );
    files = _Files();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
      files: files,
    );
  });

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<TomSecretsSession> keysScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TomSecretsApp(host: host));
    await wait(tester, 1);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
    await tester.tap(find.text('Keys'));
    await wait(tester, 5);
    return tester
        .element(find.byKey(const Key('tsm-rail')))
        .read<TomSecretsSession>();
  }

  Future<void> rotate(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tsm-rotate-go')));
    await wait(tester, 15);
  }

  /// [s]'s stored file opened with the keys the fake service holds.
  Future<KdbxFile> openStored(WidgetTester tester, FakeStore s) async =>
      (await tester.runAsync(
        () => tomSecretsDecodeStored(
          s.location,
          s.stored,
          tomSecretsVaultCredentials(password: s.password, keyFile: s.keyFile),
          outerKey: s.outerKey,
        ),
      ))!;

  testWidgets('a further vault: a new master password and a new key file; '
      'listed first, saved re-keyed, the history cut, a copy offered', (
    tester,
  ) async {
    final session = await keysScreen(tester);
    expect(find.byKey(const Key('tsm-vault-keys-primary')), findsOneWidget);
    expect(find.byKey(const Key('tsm-vault-keys-certs')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-rotate-team')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-rotate')), findsOneWidget);
    expect(
      find.byKey(const Key('tsm-rotate-repokey')),
      findsNothing,
      reason: 'team.kdbx has no outer encryption',
    );
    await tester.tap(find.byKey(const Key('tsm-rotate-password-on')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('tsm-rotate-password')),
      'team-demo-pw-2',
    );
    await tester.tap(find.byKey(const Key('tsm-rotate-keyfile-renew')));
    await tester.pump();
    await rotate(tester);
    expect(find.byKey(const Key('tsm-rotate-result')), findsOneWidget);
    expect(service.rekeyedSaves, ['team']);
    final team = service.store('team');
    expect(team.password, 'team-demo-pw-2');
    expect(team.keyFile, isNotNull);
    final listed = service.listed['team']!;
    expect(listed.password, 'team-demo-pw-2');
    expect(listed.keyFile, team.keyFile);
    final due = listed.expires!;
    final inAYear = DateTime.now().toUtc().add(const Duration(days: 365));
    expect(due.difference(inAYear).inDays.abs(), lessThan(3));
    expect(service.compactions, [
      {'repository': _repo, 'retentionDays': 0},
    ]);
    final saves = service.saves.map((s) => s['store']).toList();
    expect(saves, ['primary', 'team'], reason: 'the primary first');
    await openStored(tester, team);

    await tester.tap(find.byKey(const Key('tsm-rotate-save-keyfile')));
    await wait(tester);
    expect(files.saved['team.keyx'], team.keyFile);
    await tester.tap(find.byKey(const Key('tsm-rotate-done')));
    await wait(tester, 5);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tsm-rotate')), findsNothing);
    expect(
      session.index.map((v) => v.title),
      contains('Token'),
      reason: 'the vault is read again under its new keys',
    );
    expect(find.byKey(const Key('tsm-rotate-pending')), findsNothing);
  });

  testWidgets('a repository key and the outer cipher: every vault of the '
      'repository under that key, the one not served too', (tester) async {
    final session = await keysScreen(tester);
    await tester.tap(find.byKey(const Key('tsm-rotate-secrets')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-rotate-repokey')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-rotate-cipher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AES-256-GCM').last);
    await tester.pumpAndSettle();
    await rotate(tester);
    expect(service.rekeyedSaves, ['secrets', 'certs']);
    final secrets = service.store('secrets');
    final certs = service.store('certs');
    expect(secrets.outerKey, isNot(repoKey));
    expect(certs.outerKey, secrets.outerKey);
    expect(service.listed['secrets']!.outerKey, secrets.outerKey);
    expect(service.listed['certs']!.outerKey, secrets.outerKey);
    expect(service.listed['team']!.outerKey, isNull);
    expect(
      tomSecretsOuterCipherOf(secrets.stored),
      TomSecretsOuterCipher.aes256Gcm,
    );
    expect(
      tomSecretsOuterCipherOf(certs.stored),
      TomSecretsOuterCipher.aes256Gcm,
    );
    await openStored(tester, certs);
    final oldKeyOpens = await tester.runAsync(() async {
      try {
        await tomSecretsDecodeStored(
          _certs,
          certs.stored,
          tomSecretsVaultCredentials(password: 'certs-demo-pw'),
          outerKey: repoKey,
        );
        return true;
      } on Object {
        return false;
      }
    });
    expect(oldKeyOpens, isFalse, reason: 'the old repository key is gone');
    expect(session.editOnly, isEmpty, reason: 'opened for the rotation only');
    expect(service.compactions.single['repository'], _repo);
    await tester.tap(find.byKey(const Key('tsm-rotate-save-repokey')));
    await wait(tester);
    expect(
      utf8.decode(files.saved['secrets.repository-key.txt']!).trim(),
      secrets.outerKey,
    );
  });

  testWidgets('the primary\'s own master password: its save carries the new '
      'keys, its keys-due date moves by the primary\'s age', (tester) async {
    await keysScreen(tester);
    await tester.tap(find.byKey(const Key('tsm-rotate-primary')));
    await tester.pumpAndSettle();
    expect(find.textContaining('by pairing or by hand'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-rotate-password-on')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('tsm-rotate-password')),
      'demo-master-password-2',
    );
    await tester.pump();
    await rotate(tester);
    expect(service.rekeyedSaves, ['primary']);
    expect(service.saves.single['keys'], {
      'password': 'demo-master-password-2',
    });
    final primary = service.store('primary');
    expect(primary.password, 'demo-master-password-2');
    final due = TomSecretsMetadata.read(
      await openStored(tester, primary),
    ).keysDue!;
    final inTwoYears = DateTime.now().toUtc().add(const Duration(days: 730));
    expect(due.difference(inTwoYears).inDays.abs(), lessThan(3));
    expect(service.compactions, isEmpty, reason: 'a file: primary');
  });

  testWidgets('a re-keyed save that fails leaves the rotation pending; the '
      'banner finishes it', (tester) async {
    await keysScreen(tester);
    service.failNextSaveOf = 'team';
    await tester.tap(find.byKey(const Key('tsm-rotate-team')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tsm-rotate-password-on')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('tsm-rotate-password')),
      'team-demo-pw-2',
    );
    await tester.pump();
    await rotate(tester);
    expect(find.byKey(const Key('tsm-rotate-error')), findsOneWidget);
    expect(service.listed['team']!.password, 'team-demo-pw-2');
    expect(service.store('team').password, 'team-demo-pw');
    await tester.tap(find.text('Cancel'));
    await wait(tester, 5);
    expect(find.byKey(const Key('tsm-rotate-pending')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-rotate-finish')));
    await wait(tester, 10);
    expect(service.rekeyedSaves, ['team']);
    expect(service.store('team').password, 'team-demo-pw-2');
    expect(find.text('Re-keyed: team.'), findsOneWidget);
  });
}
