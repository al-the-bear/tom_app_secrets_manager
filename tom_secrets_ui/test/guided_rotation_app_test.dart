// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The guided rotation of the own vaults from the Keys screen
/// (part-key-rotation) against the fake service: a further vault's key file
/// prepared beside the old one (the record started, the paired device
/// listed until it takes the key), switched (the vault re-keyed) and
/// finished now (the record gone, the history cut, the emergency sheet
/// offered); a repository key rotated alone (two slots after the switch, one
/// after the finish); a rotation cancelled before its switch, and the
/// rotation by hand refused while one runs. Demo keys only.
library;

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

const _repo = 'al-the-bear/demo-vaults';
const _team = 'github:$_repo/team.kdbx';
const _secrets = 'github:$_repo/secrets.kdbx.tsmx';

void main() {
  late FakeService service;
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
        );
      TomSecretsDeviceRecords(f).put(
        TomSecretsDeviceRecord(
          device: 'bomber',
          paired: DateTime.utc(2026, 11, 1),
        ),
      );
    });
    final team = await demoVault('team', 'team-demo-pw', (f) {
      addEntry(f, 'Api/Token', password: 'demo-api-token');
    });
    final secrets = tomSecretsNewVault(
      tomSecretsVaultCredentials(password: 'secrets-demo-pw'),
      'secrets',
      argon2: testArgon2,
    );
    addEntry(secrets, 'Api/Key', password: 'demo-secrets-key');
    service = FakeService([
      FakeStore('primary', demoPassword, primary),
      FakeStore('team', 'team-demo-pw', team, location: _team),
      FakeStore(
        'secrets',
        'secrets-demo-pw',
        await tomSecretsEncodeStored(_secrets, secrets, outerKey: repoKey),
        location: _secrets,
        outerKey: repoKey,
      ),
    ]);
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: _Clipboard(),
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

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  Future<TomSecretsSession> keysScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1600);
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

  /// The primary as the fake service holds it now, with its keys there.
  Future<KdbxFile> primaryNow(WidgetTester tester) async =>
      (await tester.runAsync(
        () => KdbxFormat().read(
          service.store('primary').stored,
          tomSecretsVaultCredentials(
            password: demoPassword,
            keyFile: service.store('primary').keyFile,
          ),
        ),
      ))!;

  /// bomber's service taking the next keys: its device record written into
  /// the primary the fake holds, the app reading it again.
  Future<void> bomberTakes(WidgetTester tester, TomSecretsSession s) async {
    final primary = await primaryNow(tester);
    tomSecretsTakeNextKeys(primary, device: 'bomber', now: DateTime.now());
    final bytes = await tester.runAsync(primary.save);
    service.store('primary')
      ..stored = Uint8List.fromList(bytes!)
      ..revision = tomSecretsBlobId(bytes);
    await tester.runAsync(s.load);
    await wait(tester, 3);
  }

  testWidgets('a key file: prepared beside the old one, bomber listed until '
      'it takes it, switched, finished now', (tester) async {
    final session = await keysScreen(tester);
    await tap(tester, find.byKey(const Key('tsm-guided-team')));
    await wait(tester, 2);
    expect(find.byKey(const Key('tsm-guided-repository-key')), findsNothing);
    await tap(tester, find.byKey(const Key('tsm-guided-go')));
    await wait(tester, 10);

    var primary = await primaryNow(tester);
    final entry = TomSecretsPrimaryVaults(primary).byName('team')!;
    expect(entry.nextKeyFile, isNotNull);
    expect(entry.keyFile, isNull);
    final record = TomSecretsRotations(
      primary,
    ).of(TomSecretsRotationKind.vaultKeys, 'team')!;
    expect(record.newKeyId, TomSecretsKeyFile.parse(entry.nextKeyFile!).hash);
    expect(record.by, 'mbp');
    expect(record.pending, ['bomber']);
    expect(service.rekeyedSaves, isEmpty);
    expect(find.byKey(const Key('tsm-guided-running-team')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('tsm-guided-missing-team')))
          .data,
      'Still without the new key: bomber.',
    );
    // The rotation by hand waits for the guided one.
    expect(find.byKey(const Key('tsm-rotate-team')), findsNothing);
    final byHand = await tester.runAsync(() async {
      try {
        await session.rotateKeys(
          'team',
          const TomSecretsKeyChanges(password: 'other-pw'),
        );
        return 'rotated';
      } on TomSecretsRotationException catch (e) {
        return e.message;
      }
    });
    expect(byHand, contains('guided rotation'));

    await bomberTakes(tester, session);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('tsm-guided-missing-team')))
          .data,
      'Every paired device holds the new key.',
    );

    await tap(tester, find.byKey(const Key('tsm-guided-switch-team')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-guided-switch-go')));
    await wait(tester, 15);
    expect(service.rekeyedSaves, ['team']);
    primary = await primaryNow(tester);
    final switched = TomSecretsPrimaryVaults(primary).byName('team')!;
    expect(switched.keyFile, entry.nextKeyFile);
    expect(switched.hasNext, isFalse);
    await tester.runAsync(
      () => tomSecretsDecodeStored(
        _team,
        service.store('team').stored,
        tomSecretsVaultCredentials(
          password: 'team-demo-pw',
          keyFile: entry.nextKeyFile,
        ),
      ),
    );
    expect(
      TomSecretsRotations(
        primary,
      ).of(TomSecretsRotationKind.vaultKeys, 'team')!.switched,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('tsm-guided-finish-team')))
          .onPressed,
      isNull,
    );

    await tap(tester, find.byKey(const Key('tsm-guided-finish-now-team')));
    await wait(tester, 15);
    expect(find.byKey(const Key('tsm-guided-finished')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('tsm-guided-finished-missing')))
          .data,
      'Every paired device took the new key.',
    );
    expect(service.compactions.map((c) => c['repository']), [_repo]);
    expect(service.compactions.single['retentionDays'], 0);
    primary = await primaryNow(tester);
    expect(TomSecretsRotations(primary).list(), isEmpty);
    await tap(tester, find.byKey(const Key('tsm-guided-finished-close')));
    await wait(tester, 3);
    expect(find.byKey(const Key('tsm-rotate-team')), findsOneWidget);
  });

  testWidgets('a repository key alone: two slots after the switch, one after '
      'the finish', (tester) async {
    final session = await keysScreen(tester);
    await tap(tester, find.byKey(const Key('tsm-guided-secrets')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-guided-key-file')));
    await tap(tester, find.byKey(const Key('tsm-guided-repository-key')));
    await tester.pump();
    await tap(tester, find.byKey(const Key('tsm-guided-go')));
    await wait(tester, 10);

    var primary = await primaryNow(tester);
    final newKey = TomSecretsPrimaryVaults(
      primary,
    ).byName('secrets')!.nextOuterKey!;
    final record = TomSecretsRotations(primary).list().single;
    expect(record.kind, TomSecretsRotationKind.repositoryKey);
    expect(
      record.newKeyId,
      TomSecretsRepositoryKey.fromBase64(newKey).keyIdHex,
    );
    expect(session.guidedRotationOf('secrets'), isNotNull);

    await tap(tester, find.byKey(const Key('tsm-guided-switch-secrets')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-guided-switch-go')));
    await wait(tester, 15);
    final ids = [
      TomSecretsRepositoryKey.fromBase64(newKey).keyIdHex,
      TomSecretsRepositoryKey.fromBase64(repoKey).keyIdHex,
    ];
    expect(tomSecretsOuterKeyIds(service.store('secrets').stored), ids);
    primary = await primaryNow(tester);
    final entry = TomSecretsPrimaryVaults(primary).byName('secrets')!;
    expect(entry.outerKey, newKey);
    expect(entry.previousOuterKey, repoKey);

    await tap(tester, find.byKey(const Key('tsm-guided-finish-now-secrets')));
    await wait(tester, 15);
    expect(tomSecretsOuterKeyIds(service.store('secrets').stored), [ids.first]);
    primary = await primaryNow(tester);
    expect(
      TomSecretsPrimaryVaults(primary).byName('secrets')!.previousOuterKey,
      isNull,
    );
    expect(TomSecretsRotations(primary).list(), isEmpty);
  });

  testWidgets('cancelled before the switch: the next key and the record go', (
    tester,
  ) async {
    await keysScreen(tester);
    await tap(tester, find.byKey(const Key('tsm-guided-team')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-guided-go')));
    await wait(tester, 10);
    await tap(tester, find.byKey(const Key('tsm-guided-cancel-team')));
    await wait(tester, 10);
    final primary = await primaryNow(tester);
    expect(TomSecretsPrimaryVaults(primary).byName('team')!.hasNext, isFalse);
    expect(TomSecretsRotations(primary).list(), isEmpty);
    expect(service.rekeyedSaves, isEmpty);
    expect(find.byKey(const Key('tsm-guided-team')), findsOneWidget);
  });

  testWidgets('the primary\'s own key file: its next keys in next-keys, the '
      'switch saves it re-keyed with them, the finish clears them', (
    tester,
  ) async {
    await keysScreen(tester);
    await tap(tester, find.byKey(const Key('tsm-guided-primary')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-guided-go')));
    await wait(tester, 10);
    var primary = await primaryNow(tester);
    final next = TomSecretsPrimaryNextKeys.of(primary)!;
    expect(next.keyFile, isNotNull);
    expect(
      TomSecretsRotations(
        primary,
      ).of(TomSecretsRotationKind.vaultKeys, 'primary'),
      isNotNull,
    );

    await tap(tester, find.byKey(const Key('tsm-guided-switch-primary')));
    await wait(tester, 2);
    await tap(tester, find.byKey(const Key('tsm-guided-switch-go')));
    await wait(tester, 15);
    expect(service.rekeyedSaves, ['primary']);
    expect(service.store('primary').keyFile, next.keyFile);
    primary = (await tester.runAsync(
      () => KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(
          password: demoPassword,
          keyFile: next.keyFile,
        ),
      ),
    ))!;
    // The next keys stay until the finish, for the devices to switch with.
    expect(TomSecretsPrimaryNextKeys.of(primary), isNotNull);

    await tap(tester, find.byKey(const Key('tsm-guided-finish-now-primary')));
    await wait(tester, 15);
    primary = (await tester.runAsync(
      () => KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(
          password: demoPassword,
          keyFile: next.keyFile,
        ),
      ),
    ))!;
    expect(TomSecretsPrimaryNextKeys.of(primary), isNull);
    expect(TomSecretsRotations(primary).list(), isEmpty);
  });
}
