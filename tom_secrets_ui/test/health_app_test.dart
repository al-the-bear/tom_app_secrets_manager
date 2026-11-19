// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Health screen and the breach check (part-app, part-password-manager,
/// DP-39, DP-179): weak, reused, expiring and breached entries listed, each
/// opening its entry; the breach check on by default, asking with the hash
/// prefix only, each run a notification with "Turn off breach check";
/// changed passwords checked at once, all of them once a week; an entry
/// excluded; the switch in Settings. Demo data only; the range API is a
/// fake.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

final class _Notifier implements TomSecretsNotifier {
  final List<(String, String)> shown = [];
  final List<List<TomSecretsNotificationAction>> actions = [];
  void Function()? click;

  @override
  Future<void> notify({
    required String title,
    required String body,
    void Function()? onClick,
    List<TomSecretsNotificationAction> actions = const [],
  }) async {
    shown.add((title, body));
    this.actions.add(actions);
    click = onClick;
  }
}

/// The demo's breached password: the fake range API counts it.
const _breached = 'letmein1';
const _strong = 'xK9#mQ2!vL7@pR4zW8nB3^jF6tY1';

void main() {
  late FakeService service;
  late List<http.Request> asked;
  late TomSecretsMemoryPreferences preferences;
  late _Notifier notifier;

  setUp(() async {
    final primary = await demoVault('primary', demoPassword, (f) {
      addEntry(f, 'Mail', password: _breached);
      addEntry(f, 'Shop', password: _strong);
      addEntry(f, 'Forum', password: _strong);
      final token = addEntry(
        f,
        'Token',
        password: 'demo-token',
        fields: {'tsm.type': 'api-token'},
      );
      token.times.expires.set(true);
      token.times.expiryTime.set(
        DateTime.now().toUtc().add(const Duration(days: 10)),
      );
    });
    service = FakeService([FakeStore('primary', demoPassword, primary)]);
    asked = [];
    preferences = TomSecretsMemoryPreferences();
    notifier = _Notifier();
  });

  TomSecretsBreachCheck check() => TomSecretsBreachCheck(
    client: MockClient((request) async {
      asked.add(request);
      final hash = tomSecretsPasswordHash(_breached);
      final prefix = request.url.pathSegments.last;
      return http.Response(
        prefix == hash.substring(0, 5)
            ? '${hash.substring(5)}:99\r\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0'
            : 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0',
        200,
      );
    }),
  );

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> unlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TomSecretsApp(
        host: TomSecretsHost(
          service: FakeHost(service),
          preferences: preferences,
          clipboard: _Clipboard(),
          notifier: notifier,
          breachCheck: check(),
        ),
      ),
    );
    await wait(tester, 1);
    // A second start finds the service unlocked already.
    if (find.byKey(const Key('tsm-unlock-passphrase')).evaluate().isEmpty) {
      await wait(tester, 10);
      return;
    }
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
  }

  Key row(String issue, TomSecretsSession session, String title) {
    final view = session.index.firstWhere((v) => v.title == title);
    return Key(
      'tsm-health-$issue-${view.ref.store}-${tomSecretsUuidHex(view.ref.uuid)}',
    );
  }

  testWidgets('on by default: every password checked by its hash prefix at '
      'the unlock, the run notified with "Turn off breach check"; the report '
      'lists weak, reused, expiring and breached entries', (tester) async {
    await unlocked(tester);
    expect(asked, isNotEmpty);
    for (final r in asked) {
      expect(
        r.url.toString(),
        startsWith('https://api.pwnedpasswords.com/range/'),
      );
      expect(r.url.pathSegments.last, hasLength(5));
      expect(r.headers['Add-Padding'], 'true');
    }
    expect(notifier.shown.single, (
      'Breach check: a password was found',
      'All 3 passwords checked: 1 appears in known breaches. Open Health to '
          'change it.',
    ));
    expect(notifier.shown.single.$2, isNot(contains(_breached)));
    expect(notifier.actions.single.map((a) => a.label), [
      'Turn off breach check',
    ]);

    await tester.tap(find.text('Health'));
    await wait(tester);
    final session = tester
        .element(find.byKey(const Key('tsm-health')))
        .read<TomSecretsSession>();
    expect(find.byKey(row('weak', session, 'Mail')), findsOneWidget);
    expect(find.byKey(row('reused', session, 'Shop')), findsOneWidget);
    expect(find.byKey(row('reused', session, 'Forum')), findsOneWidget);
    expect(find.byKey(row('expiring', session, 'Token')), findsOneWidget);
    expect(find.byKey(row('breached', session, 'Mail')), findsOneWidget);
    expect(
      find.text('primary · Seen 99 times in known breaches'),
      findsOneWidget,
    );
    // An API token is no password: neither weak nor breached.
    expect(find.byKey(row('weak', session, 'Token')), findsNothing);

    // A finding opens its entry.
    await tester.tap(find.byKey(row('expiring', session, 'Token')));
    await wait(tester);
    expect(
      session.selectedEntry?.uuid,
      session.index.firstWhere((v) => v.title == 'Token').ref.uuid,
    );
    expect(find.byKey(const Key('tsm-field-title')), findsOneWidget);

    // The notification's action turns the check off; its click shows Health.
    notifier.actions.single.single.onPressed();
    await wait(tester);
    expect(preferences.read(TomSecretsHealthPreferenceKeys.breachCheck), 'off');
    notifier.click!();
    await wait(tester);
    expect(find.byKey(const Key('tsm-health')), findsOneWidget);
    expect(find.byKey(row('breached', session, 'Mail')), findsNothing);
    expect(
      tester
          .widget<Switch>(find.byKey(const Key('tsm-health-breach-switch')))
          .value,
      isFalse,
    );
  });

  testWidgets('a changed password is checked at once, alone; Exclude keeps '
      'an entry out', (tester) async {
    await unlocked(tester);
    final before = asked.length;
    await tester.tap(find.text('Health'));
    await wait(tester);
    final context = tester.element(find.byKey(const Key('tsm-health')));
    final session = context.read<TomSecretsSession>();
    final shop = session.index.firstWhere((v) => v.title == 'Shop').ref;
    await tester.runAsync(
      () => session.updateEntry(
        shop,
        (e) => e.setString(
          KdbxKeyCommon.PASSWORD,
          ProtectedValue.fromString('Another-Demo-Pw-81!zq'),
        ),
      ),
    );
    await wait(tester, 5);
    expect(asked.length, before + 1);
    expect(notifier.shown.last, (
      'Breach check: nothing found',
      'A new or changed password checked: none appears in known breaches.',
    ));
    expect(find.byKey(row('reused', session, 'Shop')), findsNothing);

    final mail = session.index.firstWhere((v) => v.title == 'Mail');
    await tester.tap(
      find.byKey(Key('tsm-health-exclude-${tomSecretsUuidHex(mail.ref.uuid)}')),
    );
    await wait(tester, 5);
    expect(find.byKey(row('breached', session, 'Mail')), findsNothing);
    expect(tomSecretsBreachCheckExcluded(session.entryOf(mail.ref)!), isTrue);
    expect(service.saves.last['store'], 'primary');
  });

  testWidgets('the weekly run checks every password again; between runs only '
      'new ones', (tester) async {
    await preferences.write(
      TomSecretsHealthPreferenceKeys.breachRecord,
      jsonEncode({
        'lastFull': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
        'entries': <String, Object?>{},
      }),
    );
    await unlocked(tester);
    expect(
      notifier.shown.single.$2,
      startsWith('3 new or changed passwords checked'),
    );
    await tester.pumpWidget(const SizedBox());
    await wait(tester);

    notifier.shown.clear();
    final record =
        jsonDecode(
              preferences.read(TomSecretsHealthPreferenceKeys.breachRecord)!,
            )
            as Map<String, Object?>;
    record['lastFull'] = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 8))
        .toIso8601String();
    await preferences.write(
      TomSecretsHealthPreferenceKeys.breachRecord,
      jsonEncode(record),
    );
    await unlocked(tester);
    expect(notifier.shown.single.$2, startsWith('All 3 passwords checked'));
    // The record holds times and counts, never a password or a hash.
    final kept = preferences.read(TomSecretsHealthPreferenceKeys.breachRecord)!;
    expect(kept, isNot(contains(_breached)));
    expect(kept, isNot(contains(tomSecretsPasswordHash(_breached))));
  });

  testWidgets('off: nothing is asked; the Settings switch turns it on and '
      'it runs', (tester) async {
    await preferences.write(TomSecretsHealthPreferenceKeys.breachCheck, 'off');
    await unlocked(tester);
    expect(asked, isEmpty);
    expect(notifier.shown, isEmpty);
    await tester.tap(find.text('Settings'));
    await wait(tester);
    final toggle = find.byKey(const Key('tsm-settings-breach-check'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await wait(tester, 5);
    expect(asked, isNotEmpty);
    expect(notifier.shown.single.$1, 'Breach check: a password was found');
  });
}
