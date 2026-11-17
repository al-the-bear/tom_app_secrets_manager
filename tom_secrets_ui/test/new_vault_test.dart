// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// A further vault created beside the primary (`vault.create`): where it
/// goes, what the session sends and what it answers, the New vault dialog
/// from the vault browser and the Environments screen, and the Import
/// screen's "Into a new vault…", against the fake service. Demo data only.
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

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

/// The new vault files of the tests: Argon2id, light.
KdbxFile _light(String password, Uint8List? keyFile, String name) =>
    tomSecretsNewVault(
      tomSecretsVaultCredentials(password: password, keyFile: keyFile),
      name,
      argon2: testArgon2,
    );

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
    saved[name] = bytes;
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

/// A 1Password CSV export with demo data.
const _csv =
    '"Title","Url","Username","Password","OTPAuth","Favorite","Archived","Tags","Notes"\n'
    '"Demo Mail","https://mail.example.com","demo.user@example.com","demo-pw-1","","false","false","",""\n';

void main() {
  group('the location', () {
    String at(TomSecretsNewVaultSpec spec, String primary) =>
        tomSecretsNewVaultLocation(spec, primary);

    test('beside the primary: its repository or its folder', () {
      expect(
        at(
          const TomSecretsNewVaultSpec(name: 'ops'),
          'github:al-the-bear/demo-vaults/primary.kdbx.tsmx',
        ),
        'github:al-the-bear/demo-vaults/ops.kdbx',
      );
      expect(
        at(
          const TomSecretsNewVaultSpec(name: 'ops', outer: true),
          'github:al-the-bear/demo-vaults@main/v/primary.kdbx',
        ),
        'github:al-the-bear/demo-vaults@main/v/ops.kdbx.tsmx',
      );
      expect(
        at(const TomSecretsNewVaultSpec(name: 'me'), 'file:/demo/primary.kdbx'),
        'file:/demo/me.kdbx',
      );
      expect(
        at(
          const TomSecretsNewVaultSpec(name: 'me'),
          r'file:C:\Vaults\primary.kdbx',
        ),
        r'file:C:\Vaults\me.kdbx',
      );
    });

    test('another repository, with a folder; a file in a folder', () {
      expect(
        at(
          const TomSecretsNewVaultSpec(
            name: 'ops',
            place: TomSecretsNewVaultPlace.github,
            repository: 'al-the-bear/other-vaults',
            folder: '/system/',
          ),
          'file:/demo/primary.kdbx',
        ),
        'github:al-the-bear/other-vaults/system/ops.kdbx',
      );
      expect(
        at(
          const TomSecretsNewVaultSpec(
            name: 'me',
            place: TomSecretsNewVaultPlace.file,
            folder: '/home/demo/vaults/',
          ),
          'file:/demo/primary.kdbx',
        ),
        'file:/home/demo/vaults/me.kdbx',
      );
    });

    test('refused: not a store name, no repository, no folder, a relative '
        'folder', () {
      for (final spec in const [
        TomSecretsNewVaultSpec(name: 'My Vault'),
        TomSecretsNewVaultSpec(
          name: 'ops',
          place: TomSecretsNewVaultPlace.github,
        ),
        TomSecretsNewVaultSpec(
          name: 'ops',
          place: TomSecretsNewVaultPlace.file,
        ),
        TomSecretsNewVaultSpec(
          name: 'ops',
          place: TomSecretsNewVaultPlace.file,
          folder: 'relative',
        ),
      ]) {
        expect(
          () => at(spec, 'file:/demo/primary.kdbx'),
          throwsArgumentError,
          reason: '${spec.name} ${spec.place}',
        );
      }
    });

    test('a system vault is bound in its environment; a personal one is '
        'not', () {
      expect(
        const TomSecretsNewVaultSpec(
          name: 'ops',
          kind: TomSecretsVaultKind.system,
          environment: ' prod ',
        ).binding,
        {'env': 'prod'},
      );
      expect(
        const TomSecretsNewVaultSpec(name: 'me', environment: 'prod').binding,
        isEmpty,
      );
    });
  });

  group('the session', () {
    late FakeService service;
    late TomSecretsServiceConnection connection;
    late TomSecretsSession session;

    setUp(() async {
      service = FakeService(await demoStores());
      connection = TomSecretsServiceConnection(FakeHost(service));
      session = TomSecretsSession(connection, TomSecretsMemoryPreferences())
        ..newVaultFile = _light;
      await connection.connect();
      await connection.unlock(demoPassword);
      await settle();
      while (session.loading) {
        await settle();
      }
    });

    tearDown(() {
      session.dispose();
      connection.dispose();
    });

    Future<TomSecretsPrimaryVaults> listed() async => TomSecretsPrimaryVaults(
      await KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(
          password: demoPassword,
          keyFile: service.store('primary').keyFile,
        ),
      ),
    );

    test('a system vault beside the primary: a generated password and a new '
        'key file, bound in its environment, listed with its keys and due '
        'date, open in the app at once', () async {
      final now = DateTime.utc(2026, 11, 17);
      final created = await session.createVault(
        const TomSecretsNewVaultSpec(
          name: 'ops',
          kind: TomSecretsVaultKind.system,
          environment: 'prod',
          purpose: 'The fleet\'s service keys',
          keyFile: TomSecretsNewKeyFile.generate,
        ),
        now: now,
      );
      expect(created.store, 'ops');
      expect(created.location, 'file:/demo/ops.kdbx');
      expect(created.passwordGenerated, isTrue);
      expect(created.keyFile, isNotNull);
      expect(created.repositoryKey, isNull);

      final sent = service.creations.single;
      final keys = (sent['keys']! as Map).cast<String, Object?>();
      expect((keys['password']! as String).length, 32);
      expect(base64.decode(keys['keyFile']! as String), created.keyFile);
      expect(keys.containsKey('outerKey'), isFalse);
      expect(sent.containsKey('githubToken'), isFalse);
      // Due after vaultKeyAgeMonths (12 by default).
      expect(sent['keysDue'], '2027-11-17T00:00:00.000Z');

      final entry = (await listed()).byName('ops')!;
      expect(entry.locator, 'file:/demo/ops.kdbx');
      expect(entry.password, keys['password']);
      expect(entry.expires, DateTime.utc(2027, 11, 17));

      final vault = session.vault('ops')!;
      final metadata = TomSecretsMetadata.read(vault.file);
      expect(metadata.store, 'ops');
      expect(metadata.kind, TomSecretsVaultKind.system);
      expect(metadata.binding, {'env': 'prod'});
      expect(metadata.purpose, 'The fleet\'s service keys');
      expect(session.kindOf('ops'), TomSecretsVaultKind.system);
    });

    test('a personal vault in another repository: the password given, the '
        'primary\'s key file, outer encrypted under a new repository key, '
        'its token sent', () async {
      // The primary has a key file here.
      final primary = service.store('primary');
      final primaryKeyFile = TomSecretsKeyFile.generate().toBytes();
      final file = await KdbxFormat().read(
        primary.stored,
        tomSecretsVaultCredentials(password: demoPassword),
      );
      file.credentials = tomSecretsVaultCredentials(
        password: demoPassword,
        keyFile: primaryKeyFile,
      );
      primary
        ..keyFile = primaryKeyFile
        ..stored = await file.save()
        ..revision = tomSecretsBlobId(primary.stored);
      await session.load();

      final created = await session.createVault(
        const TomSecretsNewVaultSpec(
          name: 'me',
          place: TomSecretsNewVaultPlace.github,
          repository: 'al-the-bear/personal-vaults',
          outer: true,
          password: 'me-demo-pw',
          keyFile: TomSecretsNewKeyFile.primary,
          githubToken: ' demo-personal-token ',
        ),
      );
      expect(
        created.location,
        'github:al-the-bear/personal-vaults/me.kdbx.tsmx',
      );
      expect(created.passwordGenerated, isFalse);
      expect(created.keyFile, isNull, reason: 'the primary\'s');
      expect(created.repositoryKey, isNotNull);
      final sent = service.creations.single;
      final keys = (sent['keys']! as Map).cast<String, Object?>();
      expect(keys['password'], 'me-demo-pw');
      expect(base64.decode(keys['keyFile']! as String), primaryKeyFile);
      expect(keys['outerKey'], created.repositoryKey);
      expect(sent['githubToken'], 'demo-personal-token');
      expect(session.vault('me'), isNotNull);
      expect((await listed()).byName('me')!.githubToken, 'demo-personal-token');
    });

    test('a key the repository uses is offered and taken; a name in use and '
        'the primary\'s key file it has not are refused before anything is '
        'sent', () async {
      final key = TomSecretsRepositoryKey.generate().toBase64();
      await session.createVault(
        TomSecretsNewVaultSpec(name: 'one', outer: true, repositoryKey: key),
      );
      final known = await session.repositoryKeysAt('file:/demo/two.kdbx');
      expect(known.single.key, key);
      expect(known.single.vaults, ['one']);
      final two = await session.createVault(
        TomSecretsNewVaultSpec(name: 'two', outer: true, repositoryKey: key),
      );
      expect(two.repositoryKey, isNull, reason: 'an existing key');
      expect((service.creations.last['keys']! as Map)['outerKey'], key);

      final before = service.creations.length;
      await expectLater(
        session.createVault(const TomSecretsNewVaultSpec(name: 'team')),
        throwsArgumentError,
      );
      await expectLater(
        session.createVault(
          const TomSecretsNewVaultSpec(
            name: 'three',
            keyFile: TomSecretsNewKeyFile.primary,
          ),
        ),
        throwsArgumentError,
      );
      expect(service.creations, hasLength(before));
    });
  });

  group('the app', () {
    late FakeService service;
    late _Files files;
    late TomSecretsHost host;

    setUp(() async {
      service = FakeService(await demoStores());
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

    Future<void> unlocked(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1700, 1200);
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
      tester
              .element(find.byKey(const Key('tsm-group-tree')))
              .read<TomSecretsSession>()
              .newVaultFile =
          _light;
    }

    Future<void> create(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('tsm-newvault-create')));
      await wait(tester, 8);
    }

    testWidgets('the vault browser: New vault…, a personal vault with a new '
        'key file; its copy saved, the vault in the tree', (tester) async {
      await unlocked(tester);
      await tester.tap(find.byKey(const Key('tsm-new-vault')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('tsm-newvault-create')))
            .onPressed,
        isNull,
        reason: 'no name yet',
      );
      await tester.enterText(find.byKey(const Key('tsm-newvault-name')), 'me');
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tsm-newvault-location')))
            .data,
        'file:/demo/me.kdbx',
      );
      await tester.ensureVisible(
        find.byKey(const Key('tsm-newvault-keyfile-new')),
      );
      await tester.tap(find.byKey(const Key('tsm-newvault-keyfile-new')));
      await tester.pump();
      await create(tester);
      expect(find.byKey(const Key('tsm-newvault-result')), findsOneWidget);
      expect(find.text('me is at file:/demo/me.kdbx.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-newvault-save-keyfile')));
      await wait(tester);
      expect(files.saved.keys, ['me.keyx']);
      await tester.tap(find.byKey(const Key('tsm-newvault-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-vault-me')), findsOneWidget);
      expect(service.creations.single['store'], 'me');
    });

    testWidgets('a system vault in its environment; a name in use is refused '
        'with a message', (tester) async {
      await unlocked(tester);
      await tester.tap(find.byKey(const Key('tsm-new-vault')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tsm-newvault-name')),
        'team',
      );
      await tester.tap(find.byKey(const Key('tsm-newvault-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('System: secrets for the processes').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tsm-newvault-env')), 'prod');
      await tester.pump();
      await create(tester);
      expect(find.byKey(const Key('tsm-newvault-error')), findsOneWidget);
      expect(service.creations, isEmpty);

      await tester.enterText(find.byKey(const Key('tsm-newvault-name')), 'ops');
      await tester.pump();
      await create(tester);
      expect(find.byKey(const Key('tsm-newvault-result')), findsOneWidget);
      final vault = await tester.runAsync(
        () => tomSecretsDecodeStored(
          'file:/demo/ops.kdbx',
          service.store('ops').stored,
          tomSecretsVaultCredentials(password: service.store('ops').password),
        ),
      );
      expect(TomSecretsMetadata.read(vault!).binding, {'env': 'prod'});
    });

    testWidgets('the Environments screen: a configured file the primary '
        'lists no keys for is created as a system vault in its environment; '
        'the header\'s New vault… proposes a system vault', (tester) async {
      // staging is configured but neither served nor listed here.
      service = FakeService((await systemStores()).stores);
      host = TomSecretsHost(
        service: FakeHost(service),
        preferences: TomSecretsMemoryPreferences(),
        clipboard: _Clipboard(),
        files: files,
      );
      await unlocked(tester);
      await tester.tap(find.text('Environments'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-env-new-vault')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-newvault-env')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tsm-env-create-vault-staging')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tsm-newvault-name')))
            .controller!
            .text,
        'staging',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tsm-newvault-env')))
            .controller!
            .text,
        'staging',
      );
      await create(tester);
      await tester.tap(find.byKey(const Key('tsm-newvault-done')));
      await tester.pumpAndSettle();
      expect(service.creations.single['store'], 'staging');
      expect(
        find.byKey(const Key('tsm-env-create-vault-staging')),
        findsNothing,
      );
      expect(find.byKey(const Key('tsm-env-column-staging')), findsOneWidget);
    });

    testWidgets('the Import screen: into a new vault', (tester) async {
      files.disk['/demo/export.csv'] = Uint8List.fromList(utf8.encode(_csv));
      files.next = '/demo/export.csv';
      await unlocked(tester);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-import-pick')));
      await wait(tester);
      await tester.tap(
        find.byKey(const Key('tsm-import-format-onePasswordCsv')),
      );
      await wait(tester);
      final menu = find.byWidgetPredicate(
        (w) =>
            w is DropdownButton<String> &&
            (w.key as ValueKey<String>?)?.value.startsWith(
                  'tsm-import-store-',
                ) ==
                true,
      );
      await tester.tap(menu.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Into a new vault…').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-newvault')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('tsm-newvault-name')),
        'imported',
      );
      await tester.pump();
      await create(tester);
      await tester.tap(find.byKey(const Key('tsm-newvault-done')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButton<String>>(menu.first).value,
        'imported',
      );
      await tester.tap(find.byKey(const Key('tsm-import-preview')));
      await wait(tester);
      await tester.tap(find.byKey(const Key('tsm-import-run')));
      await wait(tester, 5);
      expect(service.saves.single['store'], 'imported');
      final imported = await tester.runAsync(
        () => tomSecretsDecodeStored(
          'file:/demo/imported.kdbx',
          service.store('imported').stored,
          tomSecretsVaultCredentials(
            password: service.store('imported').password,
          ),
        ),
      );
      expect(
        imported!.body.rootGroup.getAllEntries().map((e) => e.label),
        contains('Demo Mail'),
      );
    });
  });
}
