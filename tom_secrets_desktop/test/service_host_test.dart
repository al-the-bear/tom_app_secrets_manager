// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop's service host against the real service, run in this process
/// on demo vaults: no service; attached with the admin key the keychain
/// keeps under tsm's handle; a key the keychain lacks needs a claim, which
/// keeps the new key; the editing path over the attached channel
/// (`vaultKeys`, `vaultFile`). Demo data only.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart' show TomInMemorySecretStore;
import 'package:tom_kdbx_store/tom_kdbx_store.dart'
    show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_client/admin.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_desktop/tom_secrets_desktop.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart'
    show TomSecretsBootstrap, TomSecretsService, TomSecretsServiceConfig;
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

const _password = 'primary-demo-pw';

const _argon2 = KdbxArgon2(
  type: KdbxArgon2Type.argon2id,
  memory: 1 << 20,
  iterations: 1,
);

void main() {
  late Directory dir;
  late Map<String, String> env;
  late TomInMemorySecretStore keychain;
  late TomSecretsDesktopServiceHost host;

  final transport = Platform.isWindows
      ? TomSecretsTransport.tcp
      : TomSecretsTransport.unix;

  setUp(() async {
    // The system's temporary directory: a Unix socket path is short.
    dir = Directory.systemTemp.createTempSync('tsmd');
    final primary = tomSecretsNewVault(
      tomSecretsVaultCredentials(password: _password),
      'primary',
      argon2: _argon2,
    );
    final entry = KdbxEntry.create(primary, primary.body.rootGroup)
      ..label = 'Main';
    entry.setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString('demo-db-pw'),
    );
    primary.body.rootGroup.addEntry(entry);
    File('${dir.path}/primary.kdbx').writeAsBytesSync(await primary.save());
    Directory('${dir.path}/data').createSync();
    File('${dir.path}/data/bootstrap.yaml').writeAsStringSync(
      'primary: file:${dir.path}/primary.kdbx\n'
      'device_key: keyfile\n'
      'runtime_dir: ${dir.path}/run\n'
      'host: demo-host\n',
    );
    env = {
      ...Platform.environment,
      'TSM_RUNTIME_DIR': '${dir.path}/run',
      'TSM_DATA_DIR': '${dir.path}/data',
      'TSM_SERVICE': '${dir.path}/no-such-service',
    };
    keychain = TomInMemorySecretStore();
    host = TomSecretsDesktopServiceHost(environment: env, keychain: keychain);
  });

  tearDown(() async {
    for (var i = 0; i < 50; i++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Future<TomSecretsService> launch(List<int> adminKey) async {
    final service = await TomSecretsService.launch(
      TomSecretsServiceConfig(
        runtime: TomSecretsRuntime('${dir.path}/run', transport: transport),
        bootstrap: await TomSecretsBootstrap.read(
          '${dir.path}/data/bootstrap.yaml',
        ),
        adminKey: adminKey is Uint8List
            ? adminKey
            : Uint8List.fromList(adminKey),
        host: 'demo-host',
        authDelay: (n) => Duration(milliseconds: 10 * n),
      ),
    );
    addTearDown(service.stop);
    return service;
  }

  test('the service: TSM_SERVICE, else beside the app, else in the app\'s '
      'distribution (tsm/bin)', () {
    final appDir = Platform.isMacOS
        ? '${dir.path}/X.app/Contents/MacOS'
        : '${dir.path}/app';
    Directory(appDir).createSync(recursive: true);
    final ext = Platform.isWindows ? '.exe' : '';
    final plain = {...env}..remove('TSM_SERVICE');
    TomSecretsDesktopServiceHost at() => TomSecretsDesktopServiceHost(
      environment: plain,
      executableDirectory: appDir,
      keychain: keychain,
    );
    final beside = '$appDir${Platform.pathSeparator}tom_secrets_service$ext';
    expect(at().serviceExecutable, beside, reason: 'none there: the default');
    final bundled = File(
      tomSecretsServiceCandidates(
        appDir,
        operatingSystem: Platform.operatingSystem,
      ).last,
    )..createSync(recursive: true);
    expect(at().serviceExecutable, bundled.path);
    File(beside).createSync();
    expect(at().serviceExecutable, beside, reason: 'beside the app first');
    expect(host.serviceExecutable, '${dir.path}/no-such-service');
  });

  test(
    'no service: NoService; starting without an executable says so',
    () async {
      expect(await host.attach(), isA<TomSecretsNoService>());
      final started = await host.start();
      expect(started, isA<TomSecretsCannotStart>());
      expect(
        (started as TomSecretsCannotStart).message,
        contains('no-such-service'),
      );
    },
  );

  test(
    'no bootstrap: the machine is not set up, attached or started; the '
    'first run writes into TSM_DATA_DIR and the keychain, and the real '
    'service unlocks the new primary with the master password alone',
    () async {
      File('${dir.path}/data/bootstrap.yaml').deleteSync();
      expect(await host.attach(), isA<TomSecretsNotSetUp>());
      expect(await host.start(), isA<TomSecretsNotSetUp>());

      final firstRun = await host.firstRun();
      expect(firstRun.dataDirectory, '${dir.path}/data');
      expect(firstRun.keychain, same(keychain));
      final locator = TomSecretsVaultLocator.parse(
        'file:${dir.path}/vaults/new.kdbx.tsmx',
      );
      await TomSecretsFirstRun(
        dataDirectory: firstRun.dataDirectory,
        keychain: keychain,
        argon2: _argon2,
      ).run(
        TomSecretsFirstRunSetup(
          primary: locator,
          create: true,
          masterPassword: _password,
          keyFile: TomSecretsKeyFile.generate().toBytes(),
          repositoryKey: TomSecretsRepositoryKey.generate(),
          deviceKey: TomSecretsDeviceKeyMode.keyfile,
          host: 'demo-host',
        ),
      );
      expect(await host.attach(), isA<TomSecretsNoService>());

      final adminKey = tomSecretsRandomBytes();
      final service = await TomSecretsService.launch(
        TomSecretsServiceConfig(
          runtime: TomSecretsRuntime('${dir.path}/run', transport: transport),
          bootstrap: await TomSecretsBootstrap.read(firstRun.bootstrapPath),
          adminKey: adminKey,
          keychain: keychain,
          authDelay: (n) => Duration(milliseconds: 10 * n),
        ),
      );
      addTearDown(service.stop);
      expect(service.host, 'demo-host', reason: 'from the bootstrap');
      final admin = await TomSecretsAdminClient.connect(
        TomSecretsRuntime('${dir.path}/run', transport: transport),
        adminKey,
      );
      addTearDown(admin.close);
      await admin.unlock(_password);
      final status = await admin.request('status');
      expect(status['locked'], isFalse);
      expect((status['stores'] as List).map((s) => (s as Map)['name']), [
        'new',
      ]);
    },
  );

  test(
    'attached with the key tsm keeps; the editing path works over it',
    () async {
      final key = tomSecretsRandomBytes();
      final service = await launch(key);
      await keychain.write(
        tomSecretsAdminKeyHandle(service.startedAt),
        base64.encode(key),
      );
      final attached = await host.attach();
      expect(attached, isA<TomSecretsAttached>());
      final channel = (attached as TomSecretsAttached).channel;
      await channel.request('unlock', {'password': _password});
      final keys = await channel.request('vaultKeys');
      final store = (keys['stores'] as List).cast<Map>().single;
      final file = await channel.request('vaultFile', {
        'store': store['store'],
      });
      final opened = await tomSecretsDecodeStored(
        file['location']! as String,
        base64.decode(file['bytes']! as String),
        tomSecretsVaultCredentials(
          password: (store['keys'] as Map)['password'] as String?,
        ),
      );
      expect(
        opened.body.rootGroup.entries.single
            .getString(KdbxKeyCommon.PASSWORD)
            ?.getText(),
        'demo-db-pw',
      );
      await channel.close();
    },
  );

  test(
    'without the key a claim is needed; the claim keeps the new key',
    () async {
      final service = await launch(tomSecretsRandomBytes());
      expect(await host.attach(), isA<TomSecretsClaimNeeded>());
      await expectLater(
        host.claim('wrong'),
        throwsA(isA<TomSecretsAdminException>()),
      );
      final claimed = await host.claim(_password);
      expect(claimed, isA<TomSecretsAttached>());
      await (claimed as TomSecretsAttached).channel.close();
      expect(
        await keychain.read(tomSecretsAdminKeyHandle(service.startedAt)),
        isNotNull,
      );
      final again = await host.attach();
      expect(again, isA<TomSecretsAttached>(), reason: 'the kept key');
      await (again as TomSecretsAttached).channel.close();
    },
  );
}
