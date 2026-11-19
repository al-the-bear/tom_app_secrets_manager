// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The approval prompt, its notification, the Clients screen (approvals,
/// allow list, pre-approval, approval code, audit log) and the Settings
/// screen against the fake service. Demo data only.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

final class _Window implements TomSecretsWindowHost {
  bool visible = true;
  int shows = 0;
  @override
  Future<void> show() async {
    shows++;
    visible = true;
  }

  @override
  Future<void> hide() async => visible = false;
  @override
  Future<bool> isVisible() async => visible;
  @override
  Future<void> quit() async {}
}

final class _Notifier implements TomSecretsNotifier {
  final List<(String, String)> shown = [];
  void Function()? click;
  @override
  Future<void> notify({
    required String title,
    required String body,
    void Function()? onClick,
    List<TomSecretsNotificationAction> actions = const [],
  }) async {
    shown.add((title, body));
    click = onClick;
  }
}

final class _Login implements TomSecretsLoginItem {
  bool enabled = true;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<void> setEnabled(bool on) async => enabled = on;
}

final class _Capture implements TomSecretsCaptureGuard {
  final List<bool> calls = [];
  @override
  bool get supported => true;
  @override
  Future<bool> setExcluded(bool excluded) async {
    calls.add(excluded);
    return true;
  }
}

Map<String, Object?> _prompt(String id, {bool wantToken = false}) => {
  'approvalId': id,
  'host': 'demo-host',
  'identity': {
    'kind': 'exe',
    'exe': '/usr/local/bin/demo-tool',
    'args': ['--sync'],
    'cwd': '/home/demo/work',
    'parent': {'exe': '/bin/zsh'},
  },
  'refs': ['telegram.bot_token'],
  'resolved': [
    {'store': 'primary', 'path': 'Bot', 'kind': 'api-token'},
  ],
  if (wantToken) 'wantClientToken': true,
};

void main() {
  late FakeService service;
  late _Window window;
  late _Notifier notifier;
  late _Login login;
  late _Capture capture;
  late TomSecretsMemoryPreferences preferences;
  late TomSecretsHost host;

  setUp(() async {
    service = FakeService(await demoStores());
    window = _Window();
    notifier = _Notifier();
    login = _Login();
    capture = _Capture();
    preferences = TomSecretsMemoryPreferences();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: preferences,
      clipboard: _Clipboard(),
      window: window,
      notifier: notifier,
      loginItem: login,
      captureGuard: capture,
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
    tester.view.physicalSize = const Size(1700, 1100);
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

  group('the approval prompt', () {
    testWidgets('shown on top when it comes; always with a client token: '
        'the app makes the token and answers', (tester) async {
      await unlocked(tester);
      service.ask(_prompt('a-1', wantToken: true));
      await wait(tester);
      expect(find.byKey(const Key('tsm-approval-prompt')), findsOneWidget);
      expect(find.text('/usr/local/bin/demo-tool'), findsOneWidget);
      final prompt = find.byKey(const Key('tsm-approval-prompt'));
      expect(
        find.descendant(of: prompt, matching: find.text('telegram.bot_token')),
        findsOneWidget,
      );
      expect(find.text('primary/Bot (api-token)'), findsOneWidget);
      expect(find.text('/bin/zsh'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-approval-decision-always')));
      await tester.pump();
      expect(find.textContaining('client token'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-approval-answer')));
      await wait(tester);
      expect(find.byKey(const Key('tsm-approval-prompt')), findsNothing);
      final answer = service.approvals.single;
      expect(answer['approvalId'], 'a-1');
      expect(answer['decision'], 'always');
      expect(answer['secret'], 'ref');
      expect(answer['pin'], 'hash');
      expect(base64.decode(answer['clientToken']! as String), hasLength(32));
    });

    testWidgets('once sends no pin or token; a folder decision names the '
        'folder; a prompt ended elsewhere closes its dialog', (tester) async {
      await unlocked(tester);
      service.ask(_prompt('a-1'));
      await wait(tester);
      await tester.tap(find.byKey(const Key('tsm-approval-answer')));
      await wait(tester);
      expect(service.approvals.single, {
        'approvalId': 'a-1',
        'decision': 'once',
        'secret': 'ref',
      });

      service.ask(_prompt('a-2'));
      await wait(tester);
      await tester.tap(find.byKey(const Key('tsm-approval-decision-folder')));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('tsm-approval-folder')))
            .controller!
            .text,
        '/usr/local/bin',
      );
      await tester.tap(find.byKey(const Key('tsm-approval-answer')));
      await wait(tester);
      expect(service.approvals.last['folder'], '/usr/local/bin');
      expect(service.approvals.last['decision'], 'folder');

      service.ask(_prompt('a-3'));
      await wait(tester);
      expect(find.byKey(const Key('tsm-approval-prompt')), findsOneWidget);
      service.endPrompt('a-3', 'approved');
      await wait(tester);
      expect(find.byKey(const Key('tsm-approval-prompt')), findsNothing);
    });

    testWidgets('Later keeps it under Clients, answered from there; with the '
        'window closed a notification opens it', (tester) async {
      await unlocked(tester);
      window.visible = false;
      service.ask(_prompt('a-1'));
      await wait(tester);
      expect(notifier.shown.single.$1, 'Approve a request');
      expect(notifier.shown.single.$2, contains('demo-tool on demo-host'));
      expect(notifier.shown.single.$2, isNot(contains('telegram')));
      notifier.click!();
      expect(window.shows, 1);
      await tester.tap(find.byKey(const Key('tsm-approval-later')));
      await wait(tester);
      expect(service.approvals, isEmpty);
      await tester.tap(find.text('Clients'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-approval-a-1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-approval-open-a-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-approval-decision-never')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-approval-answer')));
      await wait(tester);
      expect(service.approvals.single['decision'], 'never');
      expect(find.byKey(const Key('tsm-approval-a-1')), findsNothing);
    });
  });

  group('the Clients screen', () {
    Future<void> openTab(WidgetTester tester, String tab) async {
      await tester.tap(find.text('Clients'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      await wait(tester);
    }

    testWidgets('the allow list: grouped, filtered by host, revoked', (
      tester,
    ) async {
      await unlocked(tester);
      await openTab(tester, 'Allow list');
      expect(find.text('Executable /usr/bin/demo-app'), findsOneWidget);
      expect(
        find.text('Script /usr/bin/python3 /srv/demo/job.py'),
        findsOneWidget,
      );
      expect(find.text('2 grants'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-grants-host')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('bomber').last);
      await tester.pumpAndSettle();
      expect(find.text('1 grants'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-grant-revoke-g-2')));
      await wait(tester);
      expect(service.grants.map((g) => g['id']), ['g-1']);
      expect(find.text('No grants.'), findsOneWidget);
    });

    testWidgets('pre-approve: a grant for another host', (tester) async {
      await unlocked(tester);
      await openTab(tester, 'Pre-approve');
      await tester.enterText(find.byKey(const Key('tsm-grant-host')), 'bomber');
      await tester.enterText(
        find.byKey(const Key('tsm-grant-path')),
        '/usr/bin/demo-agent',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-grant-secret')),
        'store team',
      );
      await tester.tap(find.byKey(const Key('tsm-grant-add')));
      await wait(tester);
      final added = service.requests.lastWhere((r) => r['op'] == 'grants.add');
      expect(added['grant'], {
        'host': 'bomber',
        'subject': 'exe /usr/bin/demo-agent',
        'secret': 'store team',
        'decision': 'allow',
        'pin': 'hash',
      });
      expect(find.text('Added for bomber.'), findsOneWidget);
    });

    testWidgets('the approval code: a token; a lasting answer also writes the '
        'grant; an unpaired host is said', (tester) async {
      await unlocked(tester);
      await openTab(tester, 'Approval code');
      await tester.enterText(find.byKey(const Key('tsm-code-host')), 'bomber');
      await tester.enterText(
        find.byKey(const Key('tsm-code-code')),
        'abcde fghij',
      );
      await tester.tap(find.byKey(const Key('tsm-code-issue')));
      await wait(tester);
      final issued = service.requests.lastWhere(
        (r) => r['op'] == 'approval.issue',
      );
      expect(issued['code'], 'ABCDEFGHIJ');
      expect(issued['decision'], 'once');
      expect(find.text('ABCDEFGHIJKLMNOPQRSTUVWXYZ'), findsOneWidget);
      expect(service.requests.where((r) => r['op'] == 'grants.add'), isEmpty);

      await tester.tap(find.byKey(const Key('tsm-code-decision-always')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-code-issue')));
      await wait(tester);
      expect(find.byKey(const Key('tsm-code-message')), findsOneWidget);
      expect(service.requests.where((r) => r['op'] == 'grants.add'), isEmpty);
      await tester.enterText(
        find.byKey(const Key('tsm-grant-path')),
        '/usr/bin/demo-agent',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-grant-secret')),
        'telegram.bot_token',
      );
      await tester.tap(find.byKey(const Key('tsm-code-issue')));
      await wait(tester);
      final grant =
          service.requests.lastWhere((r) => r['op'] == 'grants.add')['grant']
              as Map;
      expect(grant['subject'], 'exe /usr/bin/demo-agent');
      expect(grant['decision'], 'allow');
      expect(grant['host'], 'bomber');

      await tester.enterText(find.byKey(const Key('tsm-code-host')), 'nowhere');
      await tester.tap(find.byKey(const Key('tsm-code-issue')));
      await wait(tester);
      expect(
        find.text('This device is not paired with nowhere.'),
        findsOneWidget,
      );
    });

    testWidgets('the audit log, filtered by outcome', (tester) async {
      await unlocked(tester);
      await openTab(tester, 'Audit log');
      expect(find.text('/usr/bin/demo-app'), findsOneWidget);
      expect(find.text('/usr/bin/python3 /srv/demo/job.py'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-audit-outcome')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('denied').last);
      await tester.pumpAndSettle();
      expect(find.text('/usr/bin/demo-app'), findsNothing);
      expect(find.text('/usr/bin/python3 /srv/demo/job.py'), findsOneWidget);
    });
  });

  group('the Settings screen', () {
    testWidgets('the device settings: changed and saved, what applies later '
        'said; command-line approvals; capture and login', (tester) async {
      await unlocked(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await wait(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-settings-refresh'))).data,
        '5',
      );
      await tester.tap(find.byKey(const Key('tsm-settings-refresh-more')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-settings-serve-all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-settings-serve-team')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-settings-save')));
      await wait(tester);
      expect(service.device['refreshMinutes'], 6);
      expect(service.device['servedStores'], isEmpty);
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-settings-message'))).data,
        'Saved. The files served applies at the next unlock.',
      );

      await tester.tap(find.byKey(const Key('tsm-settings-cli')));
      await wait(tester);
      expect(service.cliApprovals, isTrue);

      await tester.tap(find.byKey(const Key('tsm-settings-capture')));
      await wait(tester);
      expect(
        preferences.read(TomSecretsHostPreferenceKeys.captureExcluded),
        'off',
      );
      expect(capture.calls.last, isFalse);
      await tester.tap(find.byKey(const Key('tsm-settings-login')));
      await wait(tester);
      expect(login.enabled, isFalse);
    });

    testWidgets('the shared configuration: refused when it does not read, '
        'else saved in the primary vault', (tester) async {
      await unlocked(tester);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await wait(tester);
      await tester.ensureVisible(find.byKey(const Key('tsm-settings-config')));
      await tester.enterText(
        find.byKey(const Key('tsm-settings-config')),
        'dimensions: [ nope',
      );
      await tester.tap(find.byKey(const Key('tsm-settings-config-save')));
      await wait(tester);
      expect(service.saves, isEmpty);
      await tester.enterText(
        find.byKey(const Key('tsm-settings-config')),
        'dimensions:\n  - name: host\n  - name: env\n    default: dev\n',
      );
      await tester.tap(find.byKey(const Key('tsm-settings-config-save')));
      await wait(tester);
      expect(service.saves.single['store'], 'primary');
      final primary = await tester.runAsync(
        () => KdbxFormat().read(
          service.store('primary').stored,
          tomSecretsVaultCredentials(password: demoPassword),
        ),
      );
      final config = TomSecretsMetadata.read(primary!).config!;
      expect(config.dimension('env')!.defaultValue, 'dev');
    });
  });
}
