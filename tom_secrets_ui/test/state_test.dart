// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The app's state (part-app, State): the connection's phases and events,
/// and the session's vaults (opened from the copies the service holds,
/// protocol.md 6.4), index, search, filters, edits saved against the
/// revision read, a change from elsewhere, and the lock clearing it all.
/// Demo data only.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late FakeService service;
  late FakeHost host;
  late TomSecretsServiceConnection connection;
  late TomSecretsSession session;
  late TomSecretsMemoryPreferences prefs;

  setUp(() async {
    service = FakeService(await demoStores());
    host = FakeHost(service);
    connection = TomSecretsServiceConnection(host);
    prefs = TomSecretsMemoryPreferences();
    session = TomSecretsSession(connection, prefs);
  });

  tearDown(() {
    session.dispose();
    connection.dispose();
  });

  Future<void> unlocked() async {
    await connection.connect();
    await connection.unlock(demoPassword);
    await settle();
    while (session.loading) {
      await settle();
    }
  }

  group('connection', () {
    test('attach subscribes and reads the status; locked at first', () async {
      await connection.connect();
      expect(connection.phase, TomSecretsConnectionPhase.attached);
      expect(service.requests.map((r) => r['op']), ['subscribe', 'status']);
      expect(connection.locked, isTrue);
    });

    test('no service, then started; a claim attaches', () async {
      host.running = false;
      await connection.connect();
      expect(connection.phase, TomSecretsConnectionPhase.noService);
      await connection.startService();
      expect(host.starts, 1);
      expect(connection.phase, TomSecretsConnectionPhase.attached);
    });

    test('what answers is not this user\'s service: the phase says so, at '
        'the attach and at a claim, and no claim is made', () async {
      final why = TomSecretsAdminException(
        'service_untrusted',
        'the admin endpoint is not this user\'s service: the runtime '
            'directory belongs to user 1001, not to this user (1000)',
        details: const {'reason': 'owner'},
      );
      host.untrusted = why;
      await connection.connect();
      expect(connection.phase, TomSecretsConnectionPhase.untrusted);
      expect(connection.untrustedReason, 'owner');
      expect(connection.message, contains('belongs to user 1001'));

      // The endpoint changed between the attach and the claim.
      host
        ..untrusted = null
        ..claimNeeded = true;
      await connection.connect();
      expect(connection.phase, TomSecretsConnectionPhase.claimNeeded);
      host.untrusted = why;
      await connection.claim('demo-password');
      expect(connection.phase, TomSecretsConnectionPhase.untrusted);
      expect(host.claims, isEmpty);

      host.untrusted = null;
      await connection.claim('demo-password');
      expect(connection.phase, TomSecretsConnectionPhase.attached);
      expect(host.claims, ['demo-password']);
    });

    test('stopping the service shuts it down and tells the host, which drops '
        'its admin key', () async {
      await connection.connect();
      await connection.stopService();
      expect(service.requests.last['op'], 'shutdown');
      expect(host.stoppedReports, 1);
    });

    test('a wrong password is denied; the right one unlocks and reads the '
        'stores', () async {
      await connection.connect();
      await expectLater(
        connection.unlock('wrong'),
        throwsA(isA<TomSecretsAdminException>()),
      );
      await connection.unlock(demoPassword);
      expect(connection.locked, isFalse);
      expect(connection.stores.keys, ['primary', 'team']);
    });

    test(
      'events: approvals counted, store states, a dropped connection',
      () async {
        await connection.connect();
        service.emit({'op': 'approval_needed', 'approvalId': 'a-1'});
        service.emit({'op': 'unlock_needed'});
        await settle();
        expect(connection.pendingApprovals, 1);
        expect(connection.unlockNeeded, isTrue);
        expect(connection.needsAttention, isTrue);
        service.emit({'op': 'approval_closed', 'approvalId': 'a-1'});
        service.emit({
          'op': 'store_state',
          'store': 'team',
          'state': 'offline',
          'source': 'cache',
          'notPushed': 0,
        });
        await settle();
        expect(connection.pendingApprovals, 0);
        expect(connection.stores['team']!.isOffline, isTrue);
        expect(
          connection.stores['team']!.offlineReason,
          'GitHub is not reachable',
        );
        await service.die();
        await settle();
        expect(connection.phase, TomSecretsConnectionPhase.dropped);
        expect(connection.locked, isTrue);
      },
    );
  });

  test('a paired host\'s prompt beside this host\'s with the same id: both '
      'kept, the paired one answered by its qualified id and its token made '
      'by the app', () async {
    await connection.connect();
    await connection.unlock(demoPassword);
    service.ask({'approvalId': 'a-1', 'host': 'demo-host'});
    service.ask({
      'approvalId': 'bigbeast/a-1',
      'host': 'bigbeast',
      'wantClientToken': true,
    });
    await settle();
    expect(connection.pendingApprovals, 2);
    expect(connection.prompt('bigbeast/a-1')!.host, 'bigbeast');
    await connection.approve('bigbeast/a-1', decision: 'always');
    final sent = service.requests.lastWhere((r) => r['op'] == 'approve');
    expect(sent['approvalId'], 'bigbeast/a-1');
    expect(base64.decode(sent['clientToken']! as String), hasLength(32));
    expect(connection.prompts.single.approvalId, 'a-1');
    service.emit({
      'op': 'approval_closed',
      'approvalId': 'a-1',
      'host': 'demo-host',
    });
    await settle();
    expect(connection.pendingApprovals, 0);
  });

  group('session', () {
    test('after the unlock every vault is opened from the service\'s copy; '
        'overlays are counted, not listed', () async {
      await unlocked();
      expect(session.vaults.map((v) => v.store), ['primary', 'team']);
      expect(
        service.requests
            .where((r) => r['op'] == 'vaultFile')
            .map((r) => r['store']),
        ['primary', 'team'],
      );
      final titles = session.index.map((e) => e.title).toList();
      expect(titles, containsAll(['Main', 'Bot', 'Recovery codes', 'Token']));
      expect(titles.where((t) => t == 'Main'), hasLength(1));
      final main = session.index.firstWhere((e) => e.title == 'Main');
      expect(main.overlays, 1);
      expect(main.groups, ['Db']);
      final bot = session.index.firstWhere((e) => e.title == 'Bot');
      expect(bot.key, 'telegram.bot_token');
      expect(bot.type, TomSecretsEntryType.apiToken);
    });

    test('search over every vault, never a protected value; filters', () async {
      await unlocked();
      session.query = 'token';
      expect(
        session.listResults.map((e) => e.title),
        unorderedEquals(['Bot', 'Token']),
      );
      session.query = 'demo-db-pw';
      expect(session.listResults, isEmpty);
      session.query = '';
      session.filterTag = 'prod';
      expect(session.listResults.map((e) => e.title), ['Token']);
      session.filterTag = null;
      session.filterType = TomSecretsEntryType.note;
      expect(session.listResults.map((e) => e.title), ['Recovery codes']);
      session.filterType = null;
      session.filterStore = 'team';
      expect(session.listResults.map((e) => e.ref.store).toSet(), {'team'});
    });

    test('the view switch is kept per device', () async {
      session.listView = true;
      await settle();
      expect(prefs.read(TomSecretsPreferenceKeys.view), 'list');
      final again = TomSecretsSession(connection, prefs);
      expect(again.listView, isTrue);
      again.dispose();
    });

    test(
      'a save the service wrote as it was sent reads nothing back; a '
      'merged one, and a service that names no revision, are read back',
      () async {
        await unlocked();
        final main = session.index.firstWhere((e) => e.title == 'Main');
        Future<int> readsOfASave() async {
          final before = service.requests.length;
          await session.updateEntry(
            main.ref,
            (e) =>
                e.setString(KdbxKeyCommon.URL, PlainValue('https://a.example')),
          );
          expect(
            session.vault('primary')!.revision,
            service.store('primary').revision,
          );
          return service.requests
              .skip(before)
              .where((r) => r['op'] == 'vaultFile')
              .length;
        }

        expect(await readsOfASave(), 0);
        service.mergeNextSave = true;
        expect(await readsOfASave(), 1);
        service
          ..mergeNextSave = false
          ..saveAnswersRevision = false;
        expect(await readsOfASave(), 1);
      },
    );

    test('a large save reports how far it was sent, from 1 MiB on; it is '
        'gone once the save ended', () async {
      await unlocked();
      final main = session.index.firstWhere((e) => e.title == 'Main');
      final seen = <String>[];
      void watch() {
        final p = session.saveProgress;
        if (p != null) seen.add('${p.store} ${p.sent}/${p.total} ${p.isSent}');
      }

      session.addListener(watch);
      addTearDown(() => session.removeListener(watch));
      const mib = 1024 * 1024;
      service.progressSteps = const [(mib, 4 * mib), (4 * mib, 4 * mib)];
      await session.updateEntry(
        main.ref,
        (e) => e.setString(KdbxKeyCommon.URL, PlainValue('https://b.example')),
      );
      expect(seen.toSet(), {
        'primary $mib/${4 * mib} false',
        'primary ${4 * mib}/${4 * mib} true',
      });
      expect(session.saveProgress, isNull);
      expect(
        tomSecretsSaveProgressText(
          const TomSecretsSaveProgress('primary', mib, 4 * mib),
        ),
        'Saving primary: 1.0 of 4.0 MB sent',
      );
      expect(
        tomSecretsSaveProgressText(
          const TomSecretsSaveProgress('primary', 4 * mib, 4 * mib),
        ),
        'Sent 4.0 MB; the service is writing primary…',
      );

      // A save of 1 MiB or less shows none.
      seen.clear();
      service.progressSteps = const [(1000, mib), (mib, mib)];
      await session.updateEntry(
        main.ref,
        (e) => e.setString(KdbxKeyCommon.URL, PlainValue('https://c.example')),
      );
      expect(seen, isEmpty);
    });

    test('an edit is saved against the revision read', () async {
      await unlocked();
      final main = session.index.firstWhere((e) => e.title == 'Main');
      final before = service.store('primary').revision;
      await session.updateEntry(
        main.ref,
        (e) => e.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('demo-new-pw'),
        ),
      );
      expect(service.saves.single['baseRevision'], before);
      expect(
        session.vault('primary')!.revision,
        service.store('primary').revision,
      );
      final saved = await KdbxFormat().read(
        base64.decode(service.saves.single['bytes']! as String),
        tomSecretsVaultCredentials(password: demoPassword),
      );
      final entry = saved.body.rootGroup.getAllEntries().firstWhere(
        (e) => e.uuid == main.ref.uuid,
      );
      expect(entry.getString(KdbxKeyCommon.PASSWORD)?.getText(), 'demo-new-pw');
      expect(entry.history, hasLength(1));
      expect(session.changedElsewhere, isNull);
    });

    test(
      'entries and groups: create, tag, move, delete to the recycle bin',
      () async {
        await unlocked();
        final ref = await session.createEntry(
          'team',
          title: 'Webhook',
          type: TomSecretsEntryType.apiToken,
        );
        expect(session.view(ref)!.type, TomSecretsEntryType.apiToken);
        await session.createGroup('team', null, 'Hooks');
        final hooks = session
            .vault('team')!
            .file
            .body
            .rootGroup
            .groups
            .firstWhere((g) => g.name.get() == 'Hooks');
        await session.moveEntries([ref], 'team', hooks.uuid);
        expect(session.view(ref)!.groups, ['Hooks']);
        await session.tagEntries([ref], 'ci');
        expect(session.view(ref)!.tags, ['ci']);
        await session.renameGroup('team', hooks.uuid, 'Webhooks');
        expect(session.view(ref)!.groups, ['Webhooks']);
        await session.deleteEntries([ref]);
        expect(session.index.map((e) => e.ref), isNot(contains(ref)));
        expect(session.view(ref)!.inRecycleBin, isTrue);
      },
    );

    test('a change from elsewhere reloads the vault and flags the entry '
        'open in the editor', () async {
      await unlocked();
      final token = session.index.firstWhere((e) => e.title == 'Token');
      session.selectedEntry = token.ref;
      await service.changeElsewhere('team', (f) {
        f.body.rootGroup.getAllEntries().first.setString(
          KdbxKeyCommon.USER_NAME,
          PlainValue('changed-elsewhere'),
        );
      });
      await settle();
      await settle();
      expect(session.changedElsewhere, token.ref);
      expect(session.view(token.ref)!.userName, 'changed-elsewhere');
    });

    test(
      'a stale base: the vault is read again and the error says so',
      () async {
        await unlocked();
        final main = session.index.firstWhere((e) => e.title == 'Main');
        service.store('primary').revision = 'moved';
        await expectLater(
          session.updateEntry(main.ref, (e) => e.label = 'Changed'),
          throwsA(
            isA<TomSecretsAdminException>().having(
              (e) => e.details['reason'],
              'reason',
              'stale_base',
            ),
          ),
        );
        expect(session.vault('primary')!.revision, 'moved');
      },
    );

    test('a store served from its offline copy is read-only', () async {
      service.store('team').state = 'offline';
      await unlocked();
      expect(session.readOnlyReason('team'), contains('read-only'));
      expect(session.readOnlyReason('primary'), isNull);
    });

    test('an offline store is edited when the service keeps a save GitHub '
        'cannot take in memory (the offline cache off)', () async {
      service.store('team').state = 'offline';
      service.keepsUnwritten = true;
      await unlocked();
      expect(connection.keepsUnwritten, isTrue);
      expect(session.readOnlyReason('team'), isNull);
    });

    test('locking drops every vault, the index and the selection', () async {
      await unlocked();
      session.selectedEntry = session.index.first.ref;
      await connection.lock();
      await settle();
      expect(session.vaults, isEmpty);
      expect(session.index, isEmpty);
      expect(session.selectedEntry, isNull);
    });
  });
}
