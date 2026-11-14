// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The First run wizard (part-app, First run) against the fake service and a
/// scratch data directory under `.dart_tool/`: the steps and what blocks
/// them, the setup it writes (the primary, the keys in the keychain, the
/// device settings, `bootstrap.yaml`), the service started and unlocked,
/// the GitHub token prompt's checks, and the last step's offers. Demo data
/// only.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart' show TomInMemorySecretStore;
import 'package:tom_core_storage/tom_core_storage.dart'
    show TomToken, TomTokenRejectedException, TomTokenRequiredException;
import 'package:tom_github_api/testing.dart' show FakeGitHubServer;
import 'package:tom_kdbx_store/tom_kdbx_store.dart'
    show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

const _argon2 = KdbxArgon2(
  type: KdbxArgon2Type.argon2id,
  memory: 1 << 20,
  iterations: 1,
);

Directory _scratch() {
  final root = Directory('.dart_tool/first_run_test')
    ..createSync(recursive: true);
  final dir = root.createTempSync('run');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return Directory(dir.absolute.path);
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
}

void main() {
  late Directory dir;
  late TomInMemorySecretStore keychain;
  late TomSecretsFirstRun firstRun;
  late FakeService service;
  late FakeHost host;
  late TomSecretsServiceConnection connection;

  Future<void> prepare({FakeGitHubServer? server}) async {
    dir = _scratch();
    keychain = TomInMemorySecretStore();
    firstRun = TomSecretsFirstRun(
      dataDirectory: '${dir.path}/data',
      keychain: keychain,
      argon2: _argon2,
      httpClient: server?.client,
      githubBaseUrl: FakeGitHubServer.baseUrl,
    );
    service = FakeService(await demoStores(), locked: true);
    host = FakeHost(service, running: false, setup: firstRun);
    connection = TomSecretsServiceConnection(host);
  }

  group('the model', () {
    test('step 1 blocks until the path and a long enough, repeated password '
        'are there; a new primary with both layers is written, the service '
        'started and unlocked', () async {
      await prepare();
      await connection.connect();
      expect(connection.phase, TomSecretsConnectionPhase.notSetUp);
      expect(connection.firstRunOpen, isTrue);
      final m = TomSecretsFirstRunModel(
        firstRun: firstRun,
        connection: connection,
      );
      expect(m.localPath, '${dir.path}/data/vaults/primary.kdbx');
      m.localPath = '${dir.path}/vaults/primary.kdbx';
      m.password = 'short';
      expect(m.blocker, contains('at least'));
      m.password = demoPassword;
      m.repeat = 'other';
      expect(m.blocker, 'The two passwords differ.');
      m.repeat = demoPassword;
      expect(m.blocker, isNull);
      m.next();
      expect(m.step, TomSecretsFirstRunStep.protection);
      m
        ..useKeyFile = true
        ..useOuter = true
        ..cipher = TomSecretsOuterCipher.aes256Gcm;
      expect(m.fileName, 'primary.kdbx.tsmx');
      expect(m.locator!.text, 'file:${dir.path}/vaults/primary.kdbx.tsmx');
      m.next();
      expect(m.step, TomSecretsFirstRunStep.machine);
      m
        ..host = 'Not Valid'
        ..changed();
      expect(m.blocker, contains('host name'));
      m
        ..host = 'demo-host'
        ..defaultEnvironment = 'prod'
        ..servesPrimaryOnly = true
        ..lock = TomSecretsFirstRunLock.never
        ..deviceKey = TomSecretsDeviceKeyMode.keychain;
      final keyFile = m.newKeyFile!;
      final repositoryKey = m.newRepositoryKey!;
      await m.setUp();
      expect(m.error, isNull);
      expect(m.step, TomSecretsFirstRunStep.done);
      expect(m.result!.created, isTrue);
      expect(m.result!.keysDue, isNotNull);
      expect(m.password, isEmpty, reason: 'not kept after the setup');

      final stored = File(
        '${dir.path}/vaults/primary.kdbx.tsmx',
      ).readAsBytesSync();
      expect(tomSecretsOuterCipherOf(stored), TomSecretsOuterCipher.aes256Gcm);
      await tomSecretsDecodeStored(
        m.locator!.text,
        stored,
        tomSecretsVaultCredentials(password: demoPassword, keyFile: keyFile),
        outerKey: repositoryKey.toBase64(),
      );
      expect(await keychain.read(m.locator!.keyFileHandle), isNotNull);
      expect(await keychain.read(m.locator!.repositoryKeyHandle), isNotNull);
      final bootstrap = File(firstRun.bootstrapPath).readAsStringSync();
      expect(bootstrap, contains('device_key: keychain'));
      expect(bootstrap, contains('host: "demo-host"'));
      final container = await TomSecretsDeviceContainer.open(
        firstRun.deviceContainerPath,
        (await keychain.read('tsm.device-settings.demo-host'))!,
      );
      expect(container.settings.defaultEnvironment, 'prod');
      expect(container.settings.servedStores, ['primary']);
      expect(container.settings.serviceLock.mode, TomSecretsLockMode.never);

      expect(host.starts, 1);
      expect(connection.phase, TomSecretsConnectionPhase.attached);
      expect(connection.locked, isFalse, reason: 'unlocked with the password');
      expect(connection.firstRunOpen, isTrue, reason: 'until the last step');
      connection.endFirstRun();
      expect(connection.firstRunOpen, isFalse);
    });

    test('an existing primary opened with a wrong password: the error, back '
        'on step 1, nothing written', () async {
      await prepare();
      final path = '${dir.path}/there.kdbx';
      File(path).writeAsBytesSync(
        await tomSecretsNewVault(
          tomSecretsVaultCredentials(password: demoPassword),
          'there',
          argon2: _argon2,
        ).save(),
      );
      final m =
          TomSecretsFirstRunModel(firstRun: firstRun, connection: connection)
            ..create = false
            ..localPath = path
            ..password = 'wrong';
      m
        ..next()
        ..next();
      expect(m.step, TomSecretsFirstRunStep.machine);
      await m.setUp();
      expect(m.step, TomSecretsFirstRunStep.primary);
      expect(m.error, contains('does not open'));
      expect(File(firstRun.bootstrapPath).existsSync(), isFalse);
      expect(host.starts, 0);
    });

    test('opening an outer-encrypted primary asks for its repository key on '
        'step 2', () async {
      await prepare();
      final m =
          TomSecretsFirstRunModel(firstRun: firstRun, connection: connection)
            ..create = false
            ..localPath = '${dir.path}/x.kdbx.tsmx'
            ..password = demoPassword;
      m.next();
      expect(m.step, TomSecretsFirstRunStep.protection);
      expect(m.openIsOuter, isTrue);
      expect(m.blocker, contains('repository key'));
      m
        ..openRepositoryKey = TomSecretsRepositoryKey.generate().toBase64()
        ..changed();
      expect(m.blocker, isNull);
    });

    test('GitHub: no token asks for one, the check passes with it and keeps '
        'the expiry entered; a new owner drops the check', () async {
      final server = FakeGitHubServer()..repo('al-the-bear/demo-vaults');
      await prepare(server: server);
      final m =
          TomSecretsFirstRunModel(firstRun: firstRun, connection: connection)
            ..onGitHub = true
            ..owner = 'al-the-bear'
            ..repository = 'demo-vaults'
            ..password = demoPassword
            ..repeat = demoPassword;
      expect(m.blocker, contains('Check the repository'));
      await expectLater(
        m.checkGitHub(),
        throwsA(isA<TomTokenRequiredException>()),
      );
      await m.storeToken(
        const TomToken(host: tomSecretsGitHubHost, secret: ' demo-token '),
      );
      final check = await m.checkGitHub();
      expect(check.defaultBranch, 'main');
      expect(m.blocker, isNull);
      expect(m.locator!.text, 'github:al-the-bear/demo-vaults/primary.kdbx');
      m
        ..owner = 'someone-else'
        ..repositoryChanged();
      expect(m.checked, isNull);
      await expectLater(
        m.checkGitHub(),
        throwsA(
          isA<TomSecretsFirstRunException>().having(
            (e) => e.problem,
            'problem',
            TomSecretsFirstRunProblem.repositoryNotFound,
          ),
        ),
      );
      // A refusal is the token prompt's to answer.
      expect(
        const TomTokenRejectedException('x', tomSecretsGitHubHost, 'refused'),
        isA<TomTokenRejectedException>(),
      );
    });
  });

  group('the wizard', () {
    Future<void> pumpApp(WidgetTester tester, TomSecretsHost appHost) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(TomSecretsApp(host: appHost));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    testWidgets('not set up: the wizard; the three steps, the key file '
        'copy saved, set up, then the vaults', (tester) async {
      await tester.runAsync(prepare);
      final files = _Files();
      await pumpApp(
        tester,
        TomSecretsHost(
          service: host,
          preferences: TomSecretsMemoryPreferences(),
          files: files,
        ),
      );
      expect(find.text('Set up Tom Secrets Manager'), findsOneWidget);
      expect(find.byKey(const Key('tsm-fr-next')), findsOneWidget);
      final next = tester.widget<FilledButton>(
        find.byKey(const Key('tsm-fr-next')),
      );
      expect(next.onPressed, isNull, reason: 'no password yet');

      await tester.enterText(
        find.byKey(const Key('tsm-fr-path')),
        '${dir.path}/primary.kdbx',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-fr-password')),
        demoPassword,
      );
      await tester.enterText(
        find.byKey(const Key('tsm-fr-repeat')),
        demoPassword,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-fr-next')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('tsm-fr-keyfile-switch')));
      await tester.pump();
      expect(
        find.textContaining('Save a copy of the key file'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('tsm-fr-keyfile-save')));
      await settle(tester, rounds: 2);
      expect(files.saved.keys, ['primary.keyx']);
      expect(
        String.fromCharCodes(files.saved['primary.keyx']!),
        contains('<Version>2.0</Version>'),
      );
      expect(
        find.textContaining('A copy of the key file is saved'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('tsm-fr-next')));
      await tester.pump();

      await tester.enterText(find.byKey(const Key('tsm-fr-host')), 'demo-host');
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-fr-setup')));
      await settle(tester, rounds: 30);
      expect(find.byKey(const Key('tsm-fr-error')), findsNothing);
      expect(find.byKey(const Key('tsm-fr-summary')), findsOneWidget);
      expect(find.text('Not available in this version yet.'), findsNWidgets(2));
      expect(File(firstRun.bootstrapPath).existsSync(), isTrue);
      await tester.tap(find.byKey(const Key('tsm-fr-finish')));
      await settle(tester);
      expect(find.byKey(const Key('tsm-rail')), findsOneWidget);
    });

    testWidgets('the last step starts what the host offers', (tester) async {
      await tester.runAsync(prepare);
      final started = <String>[];
      await pumpApp(
        tester,
        TomSecretsHost(
          service: host,
          preferences: TomSecretsMemoryPreferences(),
          firstRunActions: {
            TomSecretsFirstRunActions.import: (_) async =>
                started.add('import'),
          },
        ),
      );
      await tester.enterText(
        find.byKey(const Key('tsm-fr-path')),
        '${dir.path}/primary.kdbx',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-fr-password')),
        demoPassword,
      );
      await tester.enterText(
        find.byKey(const Key('tsm-fr-repeat')),
        demoPassword,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-fr-next')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-fr-next')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-fr-setup')));
      await settle(tester, rounds: 30);
      expect(find.text('Not available in this version yet.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-fr-offer-import')));
      await tester.pump();
      expect(started, ['import']);
    });
  });
}
