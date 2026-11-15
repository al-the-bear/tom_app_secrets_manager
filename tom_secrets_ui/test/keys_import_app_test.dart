// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Import screen, the Keys screen with the DP-85 ages, the key
/// reminders (banner, snooze, the daily notification), a key's due date and
/// the stale offline copy, against the fake service. Demo data only.
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
  final Map<String, Uint8List> disk = {};
  final List<String> deleted = [];
  String? next;

  @override
  Future<({String name, Uint8List bytes})?> pick() async => null;

  @override
  Future<bool> save(String name, Uint8List bytes) async => false;

  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => next;

  @override
  Future<Uint8List> read(String path) async => Uint8List.fromList(disk[path]!);

  @override
  Future<bool> delete(String path) async {
    deleted.add(path);
    return disk.remove(path) != null;
  }
}

final class _Notifier implements TomSecretsNotifier {
  final List<(String, String)> shown = [];
  @override
  Future<void> notify({
    required String title,
    required String body,
    void Function()? onClick,
  }) async => shown.add((title, body));
}

/// A 1Password CSV export with demo data: two logins and an archived one.
const _onePasswordCsv =
    '"Title","Url","Username","Password","OTPAuth","Favorite","Archived","Tags","Notes"\n'
    '"Demo Mail","https://mail.example.com","demo.user@example.com","demo-pw-1","","true","false","mail","Demo note"\n'
    '"Demo Shop","https://shop.example.com","shopper","demo-pw-2","","false","false","","" \n'
    '"Demo Old","https://old.example.com","old","demo-old-pw","","false","true","",""\n';

Map<String, Object?> _key(String kind, String key, int days, {String? vault}) {
  final at = DateTime.now().toUtc().add(Duration(days: days, hours: 2));
  return {
    'kind': kind,
    'key': key,
    'vault': ?vault,
    'expiresAt': at.toIso8601String(),
    'daysLeft': days,
    'reminding': days <= 30,
  };
}

void main() {
  late FakeService service;
  late _Files files;
  late _Notifier notifier;
  late TomSecretsMemoryPreferences preferences;
  late TomSecretsHost host;

  setUp(() async {
    service = FakeService(await demoStores());
    files = _Files();
    notifier = _Notifier();
    preferences = TomSecretsMemoryPreferences();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: preferences,
      clipboard: _Clipboard(),
      files: files,
      notifier: notifier,
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
  }

  group('the Import screen', () {
    testWidgets('a CSV: the format chosen, mapped, previewed, imported and '
        'saved; the export deleted; a second import skips what is there', (
      tester,
    ) async {
      files.disk['/demo/export.csv'] = Uint8List.fromList(
        utf8.encode(_onePasswordCsv),
      );
      files.next = '/demo/export.csv';
      await unlocked(tester);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-import-pick')));
      await wait(tester);
      expect(find.text('export.csv'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('tsm-import-format-onePasswordCsv')),
      );
      await wait(tester);
      expect(find.byKey(const Key('tsm-import-run')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('tsm-import-run')))
            .onPressed,
        isNull,
        reason: 'only after a preview',
      );
      await tester.tap(find.byKey(const Key('tsm-import-preview')));
      await wait(tester);
      expect(find.text('3. Preview (nothing written yet)'), findsOneWidget);
      expect(find.text('2 added'), findsOneWidget);
      expect(find.text('1 left out (archived)'), findsOneWidget);
      expect(service.saves, isEmpty);

      await tester.tap(find.byKey(const Key('tsm-import-run')));
      await wait(tester, 5);
      expect(service.saves.single['store'], 'primary');
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-import-summary'))).data,
        contains('2 added'),
      );
      final primary = await tester.runAsync(
        () => KdbxFormat().read(
          service.store('primary').stored,
          tomSecretsVaultCredentials(password: demoPassword),
        ),
      );
      expect(
        primary!.body.rootGroup.getAllEntries().map((e) => e.label),
        containsAll(['Demo Mail', 'Demo Shop']),
      );
      await tester.ensureVisible(find.byKey(const Key('tsm-import-delete')));
      await tester.tap(find.byKey(const Key('tsm-import-delete')));
      await wait(tester);
      expect(files.deleted, ['/demo/export.csv']);
      expect(find.byKey(const Key('tsm-import-gone')), findsOneWidget);

      // Again: what was imported is skipped.
      files.disk['/demo/export.csv'] = Uint8List.fromList(
        utf8.encode(_onePasswordCsv),
      );
      await tester.ensureVisible(find.byKey(const Key('tsm-import-pick')));
      await tester.tap(find.byKey(const Key('tsm-import-pick')));
      await wait(tester);
      await tester.tap(
        find.byKey(const Key('tsm-import-format-onePasswordCsv')),
      );
      await wait(tester);
      await tester.tap(find.byKey(const Key('tsm-import-preview')));
      await wait(tester);
      expect(find.text('2 unchanged, skipped'), findsOneWidget);
    });

    testWidgets('a file that is not the export says so', (tester) async {
      files.disk['/demo/export.json'] = Uint8List.fromList(
        utf8.encode('not json'),
      );
      files.next = '/demo/export.json';
      await unlocked(tester);
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-import-pick')));
      await wait(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-import-error'))).data,
        startsWith('Not a Enpass (JSON) export'),
      );
    });
  });

  group('the Keys screen and the reminders', () {
    testWidgets('the keys soonest first, marked; the DP-85 ages saved', (
      tester,
    ) async {
      service.keys = [
        _key('approver_key', 'approver-key:demo-host', 400),
        _key('github_token', 'github-token:al-the-bear/demo-vault', 5),
        _key('vault_keys', 'vault-keys:team', 200, vault: 'team'),
      ];
      await unlocked(tester);
      await tester.tap(find.text('Keys'));
      await tester.pumpAndSettle();
      await wait(tester);
      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => (t.title as Text?)?.data)
          .where(
            (t) =>
                t != null &&
                (t.startsWith('GitHub') ||
                    t.startsWith('Key file') ||
                    t.startsWith('Approver')),
          )
          .toList();
      expect(titles, [
        'GitHub token for al-the-bear/demo-vault',
        'Key file and repository key of team',
        'Approver key pair of demo-host',
      ]);
      expect(find.textContaining('5 days left · reminding'), findsOneWidget);
      expect(
        find.byKey(const Key('tsm-key-due-vault-keys:team')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('tsm-ages-keyPairAgeMonths-more')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('tsm-ages-save')));
      await tester.tap(find.byKey(const Key('tsm-ages-save')));
      await wait(tester);
      expect(service.device['keyPairAgeMonths'], 25);
      expect(service.device['otherKeyWarningDays'], 30);
    });

    testWidgets('a banner while a key is due; snoozed until its next step; '
        'Open Keys; one notification a day', (tester) async {
      service.keys = [
        _key('github_token', 'github-token:al-the-bear/demo-vault', 5),
      ];
      await unlocked(tester);
      expect(find.byKey(const Key('tsm-reminder-banner')), findsOneWidget);
      expect(
        find.textContaining('the GitHub token for al-the-bear/demo-vault'),
        findsOneWidget,
      );
      expect(notifier.shown.single.$1, 'A key is due');
      expect(notifier.shown.single.$2, contains('in 5 days'));

      await tester.tap(find.byKey(const Key('tsm-reminder-snooze')));
      await wait(tester);
      expect(find.byKey(const Key('tsm-reminder-banner')), findsNothing);
      expect(jsonDecode(preferences.read(TomSecretsReminderKeys.snoozed)!), {
        'github-token:al-the-bear/demo-vault': '7',
      });

      // The key reaches its next step: the banner is back.
      service.keys = [
        _key('github_token', 'github-token:al-the-bear/demo-vault', 1),
      ];
      final c = tester
          .element(find.byKey(const Key('tsm-rail')))
          .read<TomSecretsServiceConnection>();
      await tester.runAsync(c.refreshStatus);
      await tester.pump();
      expect(find.byKey(const Key('tsm-reminder-banner')), findsOneWidget);
      expect(notifier.shown, hasLength(1), reason: 'once a day');
      await tester.tap(find.byKey(const Key('tsm-reminder-open')));
      await tester.pumpAndSettle();
      await wait(tester);
      expect(find.byKey(const Key('tsm-keys')), findsOneWidget);
    });
  });

  group('state', () {
    test('the daily notification: once a day, again the next day', () async {
      final connection = TomSecretsServiceConnection(FakeHost(service));
      addTearDown(connection.dispose);
      service.keys = [_key('vault_keys', 'vault-keys:team', -2, vault: 'team')];
      await connection.connect();
      await connection.unlock(demoPassword);
      final reminders = TomSecretsReminders(connection, preferences);
      final day = DateTime(2026, 11, 15, 9);
      expect(await reminders.notifyDaily(notifier, now: day), isTrue);
      expect(notifier.shown.single.$2, contains('the keys of team (expired)'));
      expect(
        await reminders.notifyDaily(
          notifier,
          now: day.add(const Duration(hours: 5)),
        ),
        isFalse,
      );
      expect(
        await reminders.notifyDaily(
          notifier,
          now: day.add(const Duration(days: 1)),
        ),
        isTrue,
      );
    });

    test('an offline copy older than 7 days is stale', () {
      final now = DateTime.utc(2026, 11, 15, 12);
      TomSecretsStoreState at(String state, Duration age) =>
          TomSecretsStoreState(
            name: 'team',
            state: state,
            source: 'cache',
            fetchedAt: now.subtract(age),
          );
      expect(at('offline', const Duration(days: 8)).isStaleAt(now), isTrue);
      expect(at('offline', const Duration(days: 6)).isStaleAt(now), isFalse);
      expect(
        const TomSecretsStoreState(
          name: 'team',
          state: 'current',
          source: 'github',
        ).isStaleAt(now),
        isFalse,
      );
    });

    test('a vault\'s keys get a due date: the primary\'s tsm.keys-due, '
        'another vault\'s entry Expires', () async {
      // The primary lists team with its keys.
      final primary = await KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(password: demoPassword),
      );
      TomSecretsPrimaryVaults(primary).put(
        TomSecretsVaultKeys(
          name: 'team',
          locator: 'file:/demo/team.kdbx',
          password: 'team-demo-pw',
        ),
      );
      service.store('primary')
        ..stored = await primary.save()
        ..revision = tomSecretsBlobId(service.store('primary').stored);
      final connection = TomSecretsServiceConnection(FakeHost(service));
      final session = TomSecretsSession(connection, preferences);
      addTearDown(() {
        session.dispose();
        connection.dispose();
      });
      await connection.connect();
      await connection.unlock(demoPassword);
      while (session.vaults.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await session.setVaultKeysDue('primary', DateTime.utc(2028, 1, 2));
      await session.setVaultKeysDue('team', DateTime.utc(2027, 3, 4));
      final back = await KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(password: demoPassword),
      );
      expect(TomSecretsMetadata.read(back).keysDue, DateTime.utc(2028, 1, 2));
      final team = TomSecretsPrimaryVaults(back).byName('team')!;
      expect(team.expires, DateTime.utc(2027, 3, 4));
      expect(team.password, 'team-demo-pw', reason: 'the keys stay');
    });
  });
}
