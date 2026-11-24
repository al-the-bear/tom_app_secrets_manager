// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile engine against a fake GitHub (part-mobile): the vaults fetched
/// into memory at the unlock (the key file from the keychain), edited and
/// written to GitHub at once, a branch another device moved merged at the
/// refresh, a system vault refused, the OS unlock's composite key, the lock
/// dropping everything, no network refused with its reason, the refresh
/// interval's floor. Demo data only.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_service/tom_secrets_service.dart'
    show TomSecretsAdminException, TomSecretsUnlockBundle;
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsMemoryPreferences;

import 'support/demo_vaults.dart';
import 'support/net_switch.dart';

final class _Offline extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(http.ClientException('no network', request.url));
}

void main() {
  late FakeGitHubServer server;
  late TomInMemorySecretStore keychain;
  late TomSecretsMobileEngine engine;
  late List<Map<String, Object?>> events;
  late DemoVaults demo;
  Credentials primaryCredentials() => demo.primaryCredentials;
  Credentials teamCredentials() => demo.teamCredentials;

  TomSecretsMobileEngine newEngine({http.Client? client}) =>
      TomSecretsMobileEngine(
        primaryLocator: demoPrimary,
        device: 'demo-phone',
        platform: 'ios',
        keychain: keychain,
        preferences: TomSecretsMemoryPreferences(),
        httpClient: client ?? server.client,
        githubBaseUrl: FakeGitHubServer.baseUrl,
      );

  setUp(() async {
    server = FakeGitHubServer();
    demo = DemoVaults(server);
    await demo.seed();
    keychain = TomInMemorySecretStore();
    await demo.fillKeychain(keychain);
    engine = newEngine();
    events = [];
    engine.events.listen(events.add);
    addTearDown(engine.close);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Matcher refused(String kind, [String? reason]) =>
      isA<TomSecretsAdminException>()
          .having((e) => e.kind, 'kind', kind)
          .having((e) => e.details['reason'], 'reason', reason ?? anything);

  test('locked: nothing is answered; a wrong password is refused; the '
      'password unlocks with the key file from the keychain and every vault '
      'is fetched', () async {
    await expectLater(engine.request('vaultKeys'), throwsA(refused('locked')));
    await expectLater(
      engine.request('unlock', {'password': 'wrong'}),
      throwsA(refused('denied', 'bad_password')),
    );
    expect(engine.isLocked, isTrue);
    await engine.request('unlock', {'password': demoPassword});
    await settle();
    expect(events.map((e) => e['op']), contains('unlocked'));
    final status = await engine.request('status');
    expect(status['locked'], isFalse);
    expect(
      {
        for (final s in (status['stores']! as List).cast<Map>())
          s['name']: s['state'],
      },
      {'primary': 'current', 'team': 'current', 'fleet': 'current'},
    );
  });

  test('an edit is written to GitHub at once; another device\'s change is '
      'merged in at the refresh', () async {
    await engine.request('unlock', {'password': demoPassword});
    final keys = await engine.request('vaultKeys', {
      'stores': ['team'],
    });
    final held = (((keys['stores']! as List).single as Map)['keys']! as Map)
        .cast<String, Object?>();
    expect(held['password'], 'team-pw');
    final file = await engine.request('vaultFile', {'store': 'team'});
    final opened = await KdbxFormat().read(
      base64.decode(file['bytes']! as String),
      teamCredentials(),
    );
    opened.body.rootGroup.addEntry(
      KdbxEntry.create(opened, opened.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('From the phone')),
    );
    await engine.request('save', {
      'store': 'team',
      'bytes': base64.encode(await opened.save()),
      'baseRevision': file['revision'],
    });
    await settle();
    expect(
      events.where((e) => e['op'] == 'store_changed').map((e) => e['store']),
      contains('team'),
    );
    final onGitHub = await demo.fetch(demoTeam, teamCredentials());
    expect(
      onGitHub.body.rootGroup.entries.map(
        (e) => e.getString(KdbxKeyCommon.TITLE)?.getText(),
      ),
      contains('From the phone'),
    );

    // mbp adds an entry; the refresh brings it in.
    onGitHub.body.rootGroup.addEntry(
      KdbxEntry.create(onGitHub, onGitHub.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('From mbp')),
    );
    await demo.put(demoTeam, onGitHub);
    events.clear();
    await engine.request('reload');
    await settle();
    expect(
      events.where((e) => e['op'] == 'store_changed').map((e) => e['store']),
      ['team'],
    );
    final again = await engine.request('vaultFile', {'store': 'team'});
    final merged = await KdbxFormat().read(
      base64.decode(again['bytes']! as String),
      teamCredentials(),
    );
    expect(
      merged.body.rootGroup.entries.map(
        (e) => e.getString(KdbxKeyCommon.TITLE)?.getText(),
      ),
      containsAll(['From the phone', 'From mbp']),
    );
  });

  test('the background refresh (DP-151): another device\'s change comes into '
      'the copy in memory; a save that waits is not written until the '
      'refresh in the foreground', () async {
    final net = NetSwitch(server.client);
    final phone = newEngine(client: net);
    addTearDown(phone.close);
    final changed = <String>[];
    phone.events.listen((e) {
      if (e['op'] == 'store_changed') changed.add(e['store']! as String);
    });
    await phone.request('unlock', {'password': demoPassword});

    Future<List<String?>> held() async {
      final file = await phone.request('vaultFile', {'store': 'team'});
      final opened = await KdbxFormat().read(
        base64.decode(file['bytes']! as String),
        teamCredentials(),
      );
      return [
        for (final e in opened.body.rootGroup.entries)
          e.getString(KdbxKeyCommon.TITLE)?.getText(),
      ];
    }

    Future<List<String?>> onGitHub() async => [
      for (final e in (await demo.fetch(
        demoTeam,
        teamCredentials(),
      )).body.rootGroup.entries)
        e.getString(KdbxKeyCommon.TITLE)?.getText(),
    ];

    Future<void> mbpAdds(String title) async {
      final mbp = await demo.fetch(demoTeam, teamCredentials());
      mbp.body.rootGroup.addEntry(
        KdbxEntry.create(mbp, mbp.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue(title)),
      );
      await demo.put(demoTeam, mbp);
    }

    // mbp writes while the app is in the background: the copy in memory
    // follows.
    await mbpAdds('From mbp');
    await phone.refresh(force: true, background: true);
    await settle();
    expect(changed, contains('team'));
    expect(await held(), contains('From mbp'));

    // A save made without a network waits; a background refresh brings in
    // mbp's next change but does not write the save.
    net.down = true;
    final file = await phone.request('vaultFile', {'store': 'team'});
    final opened = await KdbxFormat().read(
      base64.decode(file['bytes']! as String),
      teamCredentials(),
    );
    opened.body.rootGroup.addEntry(
      KdbxEntry.create(opened, opened.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('Offline')),
    );
    await phone.request('save', {
      'store': 'team',
      'bytes': base64.encode(await opened.save()),
      'baseRevision': file['revision'],
    });
    net.down = false;
    await mbpAdds('Later from mbp');
    await phone.refresh(force: true, background: true);
    expect(await onGitHub(), isNot(contains('Offline')));
    final status = await phone.request('status');
    expect(
      {
        for (final s in (status['stores']! as List).cast<Map>())
          s['name']: s['notPushed'],
      }['team'],
      1,
    );

    // Back in the foreground: written, merged with mbp's changes.
    await phone.refresh();
    expect(
      await onGitHub(),
      containsAll(['Offline', 'From mbp', 'Later from mbp']),
    );
  });

  test('a system vault is read-only on a phone', () async {
    await engine.request('unlock', {'password': demoPassword});
    final file = await engine.request('vaultFile', {'store': 'fleet'});
    await expectLater(
      engine.request('save', {
        'store': 'fleet',
        'bytes': file['bytes'],
        'baseRevision': file['revision'],
      }),
      throwsA(refused('denied', 'read_only')),
    );
  });

  test('the OS unlock: the composite key opens the vaults; the lock drops '
      'every one', () async {
    await engine.unlockWithBundle(
      'primary',
      TomSecretsUnlockBundle(compositeKey: primaryCredentials().getHash()),
    );
    expect(engine.isLocked, isFalse);
    final keys = await engine.request('vaultKeys', {
      'stores': ['primary'],
    });
    final held = ((keys['stores']! as List).single as Map)['keys']! as Map;
    expect(held['compositeKey'], base64.encode(primaryCredentials().getHash()));
    expect(held.containsKey('password'), isFalse);
    await engine.request('lock');
    expect(engine.isLocked, isTrue);
    await expectLater(
      engine.request('vaultFile', {'store': 'team'}),
      throwsA(refused('locked')),
    );
    await expectLater(
      engine.unlockWithBundle(
        'primary',
        TomSecretsUnlockBundle(compositeKey: List.filled(32, 1)),
      ),
      throwsA(refused('denied', 'bad_password')),
    );
  });

  test('no network: the unlock says the vaults are only on GitHub', () async {
    final offline = newEngine(client: _Offline());
    addTearDown(offline.close);
    await expectLater(
      offline.request('unlock', {'password': demoPassword}),
      throwsA(
        isA<TomSecretsAdminException>()
            .having((e) => e.kind, 'kind', 'offline')
            .having((e) => e.message, 'message', contains('only on GitHub')),
      ),
    );
    expect(offline.isLocked, isTrue);
  });

  test('the refresh interval: 15 minutes by default, never below 5; the '
      'requests a phone does not do are unsupported', () async {
    expect(engine.settings.refreshMinutes, 15);
    await engine.request('settings.set', {
      'device': {'refreshMinutes': 1},
    });
    expect(engine.settings.refreshMinutes, 5);
    await expectLater(
      engine.request('approvals.list'),
      throwsA(refused('unsupported')),
    );
  });

  test('a save without a network stays in memory, shown as not written; the '
      'next refresh with the network writes it; the lock drops it', () async {
    final net = NetSwitch(server.client);
    final phone = newEngine(client: net);
    addTearDown(phone.close);
    final states = <Map<String, Object?>>[];
    phone.events.listen((e) {
      if (e['op'] == 'store_state') states.add(e);
    });
    await phone.request('unlock', {'password': demoPassword});

    Future<void> edit(String title) async {
      final file = await phone.request('vaultFile', {'store': 'team'});
      final opened = await KdbxFormat().read(
        base64.decode(file['bytes']! as String),
        teamCredentials(),
      );
      opened.body.rootGroup.addEntry(
        KdbxEntry.create(opened, opened.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue(title)),
      );
      await phone.request('save', {
        'store': 'team',
        'bytes': base64.encode(await opened.save()),
        'baseRevision': file['revision'],
      });
    }

    List<String?> titles(KdbxFile f) => [
      for (final e in f.body.rootGroup.entries)
        e.getString(KdbxKeyCommon.TITLE)?.getText(),
    ];

    net.down = true;
    await edit('Offline one');
    await edit('Offline two');
    await settle();
    int notPushed(Map<String, Object?> status) =>
        {
              for (final s in (status['stores']! as List).cast<Map>())
                s['name']: s['notPushed'],
            }['team']!
            as int;
    expect(notPushed(await phone.request('status')), 1);
    expect(states.last['notPushed'], 1);
    final held = await phone.request('vaultFile', {'store': 'team'});
    expect(
      titles(
        await KdbxFormat().read(
          base64.decode(held['bytes']! as String),
          teamCredentials(),
        ),
      ),
      containsAll(['Offline one', 'Offline two']),
    );
    expect(
      titles(await demo.fetch(demoTeam, teamCredentials())),
      isNot(contains('Offline one')),
    );

    // Still down: the refresh keeps it.
    await expectLater(phone.request('reload'), throwsA(refused('offline')));
    expect(notPushed(await phone.request('status')), 1);

    // mbp writes meanwhile; the network returns: merged and written.
    final mbp = await demo.fetch(demoTeam, teamCredentials());
    mbp.body.rootGroup.addEntry(
      KdbxEntry.create(mbp, mbp.body.rootGroup)
        ..setString(KdbxKeyCommon.TITLE, PlainValue('From mbp')),
    );
    await demo.put(demoTeam, mbp);
    net.down = false;
    await phone.request('reload');
    expect(notPushed(await phone.request('status')), 0);
    expect(
      titles(await demo.fetch(demoTeam, teamCredentials())),
      containsAll(['Offline one', 'Offline two', 'From mbp']),
    );

    // A change not written is dropped by the lock.
    net.down = true;
    await edit('Dropped');
    phone.lock();
    net.down = false;
    await phone.request('unlock', {'password': demoPassword});
    expect(notPushed(await phone.request('status')), 0);
    expect(
      titles(await demo.fetch(demoTeam, teamCredentials())),
      isNot(contains('Dropped')),
    );
  });
}
