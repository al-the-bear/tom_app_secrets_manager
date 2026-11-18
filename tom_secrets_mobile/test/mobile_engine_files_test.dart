// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile engine's `file:` vaults, reminders and edge cases against a
/// fake GitHub and documents in memory (part-mobile): a picked KDBX file
/// listed in the primary under this device's locator, opened, written back,
/// merged when it changed there; another device cannot reach it; a vault
/// whose Argon2 is too heavy refused at the unlock; the GitHub token's
/// reminder; the unlock tried again when the network returns; the size of
/// each fetch. Demo data only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart'
    show TomSecretsAdminException;
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsMemoryPreferences;

import 'support/demo_vaults.dart';
import 'support/net_switch.dart';
import 'support/fake_documents.dart';


List<String?> _titles(KdbxFile f) => [
  for (final e in f.body.rootGroup.entries)
    e.getString(KdbxKeyCommon.TITLE)?.getText(),
];

void main() {
  late FakeGitHubServer server;
  late DemoVaults demo;
  late TomInMemorySecretStore keychain;
  late TomSecretsMemoryPreferences preferences;
  late FakeDocuments documents;
  late List<Map<String, Object?>> events;
  final notesCredentials = Credentials(ProtectedValue.fromString('notes-pw'));

  setUp(() async {
    server = FakeGitHubServer();
    demo = DemoVaults(server);
    await demo.seed();
    keychain = TomInMemorySecretStore();
    await demo.fillKeychain(keychain);
    preferences = TomSecretsMemoryPreferences();
    documents = FakeDocuments()
      ..files['doc-1'] = await DemoVaults.vault('notes', notesCredentials, {
        'Wifi': 'demo-wifi',
      }).save();
    events = [];
  });

  TomSecretsMobileEngine newEngine({
    http.Client? client,
    TomSecretsMemoryPreferences? prefs,
    int kdfMemoryLimit = TomSecretsMobileEngine.defaultKdfMemoryLimit,
    Duration retryEvery = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) {
    final engine = TomSecretsMobileEngine(
      primaryLocator: demoPrimary,
      device: 'demo-phone',
      platform: 'ios',
      keychain: keychain,
      preferences: prefs ?? preferences,
      httpClient: client ?? server.client,
      githubBaseUrl: FakeGitHubServer.baseUrl,
      documents: documents,
      kdfMemoryLimit: kdfMemoryLimit,
      unlockRetryEvery: retryEvery,
      clock: clock,
    );
    engine.events.listen(events.add);
    addTearDown(engine.close);
    return engine;
  }

  Future<Map<String, Map>> stores(TomSecretsMobileEngine engine) async => {
    for (final s
        in ((await engine.request('status'))['stores']! as List).cast<Map>())
      s['name'] as String: s,
  };

  test('a picked file becomes a vault: listed in the primary under this '
      'device\'s locator, opened, written back; a change made there '
      'meanwhile is merged', () async {
    final engine = newEngine();
    await engine.request('unlock', {'password': demoPassword});
    final locator = await engine.addDocumentVault(
      name: 'notes',
      document: const TomSecretsPickedDocument(id: 'doc-1', name: 'Notes.kdbx'),
      password: 'notes-pw',
    );
    expect(locator, 'file:/tsm-document/demo-phone/Notes.kdbx');
    expect((await stores(engine))['notes']?['state'], 'current');

    // Its keys are in the primary, as every vault's.
    final primary = await demo.fetch(demoPrimary, demo.primaryCredentials);
    final listed = {
      for (final k in TomSecretsPrimaryVaults(primary).list())
        k.name: k.locator,
    };
    expect(listed['notes'], locator);

    // An edit is written back into the document.
    Future<void> edit(String title) async {
      final file = await engine.request('vaultFile', {'store': 'notes'});
      final opened = await KdbxFormat().read(
        base64.decode(file['bytes']! as String),
        notesCredentials,
      );
      opened.body.rootGroup.addEntry(
        KdbxEntry.create(opened, opened.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue(title)),
      );
      await engine.request('save', {
        'store': 'notes',
        'bytes': base64.encode(await opened.save()),
        'baseRevision': file['revision'],
      });
    }

    Future<KdbxFile> onDisk() =>
        KdbxFormat().read(documents.files['doc-1']!, notesCredentials);

    await edit('From the phone');
    expect(_titles(await onDisk()), containsAll(['Wifi', 'From the phone']));

    // Another app changes the file (iCloud Drive from the Mac); the phone's
    // next save, made on the copy it holds, is merged with it.
    final there = await onDisk();
    there.body.rootGroup.addEntry(
      KdbxEntry.create(there, there.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('From the Mac')),
    );
    documents.files['doc-1'] = await there.save();
    await edit('Second from the phone');
    expect(
      _titles(await onDisk()),
      containsAll(['From the phone', 'From the Mac', 'Second from the phone']),
    );
  });

  test('a wrong password or a taken name is refused and nothing is listed; '
      'another device has no such file', () async {
    final engine = newEngine();
    await engine.request('unlock', {'password': demoPassword});
    const doc = TomSecretsPickedDocument(id: 'doc-1', name: 'Notes.kdbx');
    await expectLater(
      engine.addDocumentVault(name: 'notes', document: doc, password: 'nope'),
      throwsA(
        isA<TomSecretsAdminException>().having(
          (e) => e.details['reason'],
          'reason',
          'bad_password',
        ),
      ),
    );
    await expectLater(
      engine.addDocumentVault(
        name: 'team',
        document: doc,
        password: 'notes-pw',
      ),
      throwsA(
        isA<TomSecretsAdminException>().having(
          (e) => e.details['reason'],
          'reason',
          'exists',
        ),
      ),
    );
    expect(
      engine.documentRegistry.idOf('file:/tsm-document/demo-phone/Notes.kdbx'),
      isNull,
    );
    await engine.addDocumentVault(
      name: 'notes',
      document: doc,
      password: 'notes-pw',
    );

    // A second phone (its own preferences): the vault is listed but not
    // reachable; every other vault opens.
    final other = newEngine(prefs: TomSecretsMemoryPreferences());
    await other.request('unlock', {'password': demoPassword});
    final seen = await stores(other);
    expect(seen['notes']?['state'], 'unavailable');
    expect(seen['team']?['state'], 'current');
  });

  test('a vault whose Argon2 needs more memory than the device can spare is '
      'refused at the unlock with a message', () async {
    expect(
      tomSecretsArgon2MemoryOf(await demo.fetchStored(demoPrimary)),
      1 << 20,
    );
    final engine = newEngine(kdfMemoryLimit: 512 << 10);
    await expectLater(
      engine.request('unlock', {'password': demoPassword}),
      throwsA(
        isA<TomSecretsAdminException>()
            .having((e) => e.kind, 'kind', 'unavailable')
            .having((e) => e.details['reason'], 'reason', 'kdf_memory')
            .having((e) => e.message, 'message', contains('1 MiB of memory')),
      ),
    );
    expect(engine.isLocked, isTrue);
    expect(tomSecretsArgon2MemoryOf(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test(
    'the GitHub token\'s reminder from two weeks before it expires',
    () async {
      final now = DateTime.utc(2026, 11, 18, 12);
      final settings = TomSecretsMobileSettings(preferences);
      await settings.setPairedTokenExpiries({
        'al-the-bear/demo-vaults': now.add(const Duration(days: 20)),
      });
      final engine = newEngine(clock: () => now);
      await engine.request('unlock', {'password': demoPassword});
      expect((await engine.request('status'))['expiring'], isEmpty);

      await settings.setPairedTokenExpiries({
        'al-the-bear/demo-vaults': now.add(const Duration(days: 10, hours: 1)),
      });
      final expiring = ((await engine.request('status'))['expiring']! as List)
          .cast<Map>();
      expect(expiring.single['key'], 'github-token:al-the-bear/demo-vaults');
      expect(expiring.single['daysLeft'], 10);
    },
  );

  test('no network at the unlock: refused with what happens next, then '
      'opened by itself once the network is back', () async {
    final net = NetSwitch(server.client)..down = true;
    final engine = newEngine(
      client: net,
      retryEvery: const Duration(milliseconds: 50),
    );
    await expectLater(
      engine.request('unlock', {'password': demoPassword}),
      throwsA(
        isA<TomSecretsAdminException>()
            .having((e) => e.kind, 'kind', 'offline')
            .having((e) => e.details['reason'], 'reason', 'no_copy')
            .having((e) => e.message, 'message', contains('tried again')),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(engine.isLocked, isTrue);
    net.down = false;
    for (var i = 0; i < 60 && engine.isLocked; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(engine.isLocked, isFalse);
    expect(events.map((e) => e['op']), contains('unlocked'));
  });

  test('a lock ends the retries', () async {
    final net = NetSwitch(server.client)..down = true;
    final engine = newEngine(
      client: net,
      retryEvery: const Duration(milliseconds: 50),
    );
    await expectLater(
      engine.request('unlock', {'password': demoPassword}),
      throwsA(isA<TomSecretsAdminException>()),
    );
    engine.lock();
    net.down = false;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.isLocked, isTrue);
  });

  test('every vault reports the size of its last fetch', () async {
    final engine = newEngine();
    await engine.request('unlock', {'password': demoPassword});
    final seen = await stores(engine);
    for (final name in ['primary', 'team', 'fleet']) {
      expect(
        seen[name]?['fetchedBytes'],
        (await engine.heldBytesForTest(name)).length,
        reason: name,
      );
    }
  });
}
