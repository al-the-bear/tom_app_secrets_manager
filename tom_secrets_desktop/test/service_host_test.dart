// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop's service host against the real service, run in this process
/// on demo vaults: no service; attached with the admin key the keychain
/// keeps under tsm's handle; a key the keychain lacks needs a claim, which
/// keeps the new key; the editing path over the attached channel
/// (`vaultKeys`, `vaultFile`); a vault far over the admin frame limits
/// saved and opened again through the app's session. Demo data only.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

const _tenSeconds = Duration(seconds: 10);

/// How many times slower this machine is right now than an idle mbp, at
/// least 1: a fixed piece of the work a save does (hashing 16 MiB, 280 ms
/// there) timed here.
double _slowdown() {
  final data = Uint8List(16 * 1024 * 1024);
  final watch = Stopwatch()..start();
  tomSecretsBlobId(data);
  return max(1, watch.elapsedMicroseconds / 280000);
}

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

  test('a vault with 40 MB of attachments: saved and opened again through '
      'the session in under 10 seconds each; the save reports how far it '
      'was sent, and the copy held takes the written file\'s revision', () async {
    final key = tomSecretsRandomBytes();
    final service = await launch(key);
    await keychain.write(
      tomSecretsAdminKeyHandle(service.startedAt),
      base64.encode(key),
    );
    Future<TomSecretsSession> open(TomSecretsServiceConnection c) async {
      final session = TomSecretsSession(c, TomSecretsMemoryPreferences());
      addTearDown(session.dispose);
      await c.connect();
      if (c.locked) await c.unlock(_password);
      for (
        var i = 0;
        i < 1200 && (session.loading || session.vaults.isEmpty);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return session;
    }

    final connection = TomSecretsServiceConnection(host);
    addTearDown(connection.dispose);
    final session = await open(connection);
    final file = session.vault('primary')!.file;
    final group = file.body.rootGroup;
    final random = Random(1);
    for (var i = 0; i < 1000; i++) {
      final entry = KdbxEntry.create(file, group)..label = 'Demo $i';
      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('demo-password-$i'),
      );
      if (i % 25 == 0) {
        // Forty demo attachments of 1 MB.
        entry.createBinary(
          isProtected: false,
          name: 'scan$i.pdf',
          bytes: Uint8List.fromList(
            List.generate(1000 * 1000, (_) => random.nextInt(256)),
          ),
        );
      }
      group.addEntry(entry);
    }

    final progress = <TomSecretsSaveProgress>[];
    void watchProgress() {
      final p = session.saveProgress;
      if (p != null && (progress.isEmpty || progress.last.sent != p.sent)) {
        progress.add(p);
      }
    }

    session.addListener(watchProgress);
    final slowBefore = _slowdown();
    final watch = Stopwatch()..start();
    await session.save('primary');
    final saved = watch.elapsed;
    final slowBetween = _slowdown();
    session.removeListener(watchProgress);

    // Sent in steps, over 40 MB in all (the file as base64), to the end.
    expect(progress.length, greaterThan(20));
    expect(progress.first.store, 'primary');
    expect(progress.last.total, greaterThan(40 * 1000 * 1000));
    expect(progress.last.isSent, isTrue);
    expect(session.saveProgress, isNull);
    // The copy held is the file written: its revision is the service's.
    final written = File('${dir.path}/primary.kdbx').readAsBytesSync();
    expect(session.vault('primary')!.revision, tomSecretsBlobId(written));
    expect(written.length, greaterThan(40 * 1000 * 1000));

    final other = TomSecretsServiceConnection(host);
    addTearDown(other.dispose);
    watch.reset();
    final again = await open(other);
    final opened = watch.elapsed;
    final entries = again.vault('primary')!.file.body.rootGroup.entries;
    expect(entries, hasLength(1001));
    expect(entries.where((e) => e.binaryEntries.isNotEmpty).length, 40);
    final slowAfter = _slowdown();
    // Under 10 seconds each on an idle mbp. Other sessions build and test
    // on this machine too, so the limit follows how slow it is while the
    // test runs (1.0 when idle).
    final saveLimit = _tenSeconds * max(slowBefore, slowBetween);
    final openLimit = _tenSeconds * max(slowBetween, slowAfter);
    // ignore: avoid_print
    print(
      '40 MB: saved in $saved (limit $saveLimit), opened in $opened '
      '(limit $openLimit); the machine is '
      '${[slowBefore, slowBetween, slowAfter].map((x) => x.toStringAsFixed(1)).join(' / ')} '
      'times an idle mbp',
    );
    expect(saved, lessThan(saveLimit), reason: '$saved');
    expect(opened, lessThan(openLimit), reason: '$opened');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('what answers is not this user\'s service: no claim is offered and '
      'none is sent (the socket opened to others; another user\'s process); '
      'closed again, the claim is offered', () async {
    await launch(tomSecretsRandomBytes());
    final socket = TomSecretsRuntime.current(environment: env).adminSocket;
    Process.runSync('chmod', ['666', socket]);
    final loose = await host.attach();
    expect(loose, isA<TomSecretsServiceUntrusted>());
    expect((loose as TomSecretsServiceUntrusted).reason, 'mode');
    expect(loose.message, contains('admin socket is open to others'));
    await expectLater(
      host.claim(_password),
      throwsA(
        isA<TomSecretsAdminException>()
            .having((e) => e.kind, 'kind', tomSecretsServiceUntrusted)
            .having((e) => e.details['reason'], 'reason', 'mode'),
      ),
    );
    // With the key in the keychain too: no proof is sent.
    Process.runSync('chmod', ['600', socket]);
    final other = TomSecretsDesktopServiceHost(
      environment: env,
      keychain: keychain,
      endpointInspector: const _OtherUsersPeer(),
    );
    final refused = await other.attach();
    expect(refused, isA<TomSecretsServiceUntrusted>());
    expect((refused as TomSecretsServiceUntrusted).reason, 'peer_user');

    expect(await host.attach(), isA<TomSecretsClaimNeeded>());
  }, testOn: '!windows');

  test('attaching prunes the keys of services that are gone; a stopped '
      'service\'s key leaves the keychain', () async {
    final keyring = TomSecretsAdminKeyring(
      read: keychain.read,
      write: keychain.write,
      delete: keychain.delete,
    );
    await keyring.keep(111, tomSecretsRandomBytes());
    await keyring.keep(222, tomSecretsRandomBytes());
    final key = tomSecretsRandomBytes();
    final service = await launch(key);
    await keyring.keep(service.startedAt, key);
    final attached = await host.attach();
    expect(attached, isA<TomSecretsAttached>());
    expect(await keyring.recorded(), {service.startedAt});
    expect(await keychain.read(tomSecretsAdminKeyHandle(111)), isNull);

    final connection = TomSecretsServiceConnection(host);
    await connection.connect();
    expect(connection.phase, TomSecretsConnectionPhase.attached);
    await connection.stopService();
    await service.done;
    expect(
      await keychain.read(tomSecretsAdminKeyHandle(service.startedAt)),
      isNull,
    );
    expect(await keyring.recorded(), isEmpty);
    await (attached as TomSecretsAttached).channel.close();
  });

  test('a vault of 1,000 entries and 2 MB of attachments: saved and opened '
      'again through the session in a few seconds', () async {
    final key = tomSecretsRandomBytes();
    final service = await launch(key);
    await keychain.write(
      tomSecretsAdminKeyHandle(service.startedAt),
      base64.encode(key),
    );
    Future<TomSecretsSession> open(TomSecretsServiceConnection c) async {
      final session = TomSecretsSession(c, TomSecretsMemoryPreferences());
      addTearDown(session.dispose);
      await c.connect();
      if (c.locked) await c.unlock(_password);
      for (
        var i = 0;
        i < 600 && (session.loading || session.vaults.isEmpty);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return session;
    }

    final connection = TomSecretsServiceConnection(host);
    addTearDown(connection.dispose);
    final session = await open(connection);
    final file = session.vault('primary')!.file;
    final group = file.body.rootGroup;
    final random = Random(1);
    for (var i = 0; i < 1000; i++) {
      final entry = KdbxEntry.create(file, group)..label = 'Demo $i';
      entry.setString(
        KdbxKeyCommon.PASSWORD,
        ProtectedValue.fromString('demo-password-$i'),
      );
      if (i % 200 == 0) {
        // Five demo images of 400 KB, as an export carries them.
        entry.createBinary(
          isProtected: false,
          name: 'image$i.png',
          bytes: Uint8List.fromList(
            List.generate(400 * 1000, (_) => random.nextInt(256)),
          ),
        );
      }
      group.addEntry(entry);
    }

    final watch = Stopwatch()..start();
    await session.save('primary');
    final saved = watch.elapsed;

    final other = TomSecretsServiceConnection(host);
    addTearDown(other.dispose);
    watch.reset();
    final again = await open(other);
    final opened = watch.elapsed;
    final entries = again.vault('primary')!.file.body.rootGroup.entries;
    expect(entries, hasLength(1001));
    expect(entries.where((e) => e.binaryEntries.isNotEmpty).length, 5);
    // A few seconds each (the debug VM, Argon2 at 1 MiB here).
    expect(saved, lessThan(const Duration(seconds: 15)), reason: '$saved');
    expect(opened, lessThan(const Duration(seconds: 15)), reason: '$opened');
    printOnFailure('saved in $saved, opened in $opened');
  });
}

/// The endpoint as it is, but the process answering runs as another user.
final class _OtherUsersPeer implements TomSecretsEndpointInspector {
  const _OtherUsersPeer();

  static const _system = TomSecretsSystemEndpointInspector();

  @override
  TomSecretsEndpointFacts files(TomSecretsRuntime runtime) =>
      _system.files(runtime);

  @override
  TomSecretsEndpointFacts withPeer(TomSecretsEndpointFacts f, Socket s) =>
      TomSecretsEndpointFacts(
        operatingSystem: f.operatingSystem,
        ownUser: f.ownUser,
        ownPid: f.ownPid,
        directory: f.directory,
        socket: f.socket,
        directoryGrantees: f.directoryGrantees,
        peer: const TomSecretsServicePeer(
          pid: 4711,
          user: 'another-user',
          executable: '/opt/demo/tom_secrets_service',
        ),
      );
}
