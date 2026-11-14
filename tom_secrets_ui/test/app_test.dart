// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The app's screens against the fake service: connecting, unlock, the
/// shell with the tree and list views, the entry editor (masked values,
/// reveal, the generator, TOTP, "How clients name it", saving), and the
/// host bridge (tray, notifications, capture, start at login). Demo data
/// only.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

final class _Clipboard implements TomClipboardPort {
  final List<String> placed = [];
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async {
    placed.add(text);
    return TomClipboardReceipt(text);
  }

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

final class _Tray implements TomSecretsTray {
  TomSecretsTrayState? state;
  String tooltip = '';
  List<TomSecretsTrayItem> items = const [];
  @override
  Future<void> update({
    required TomSecretsTrayState state,
    required String tooltip,
    required List<TomSecretsTrayItem> items,
  }) async {
    this.state = state;
    this.tooltip = tooltip;
    this.items = items;
  }

  @override
  Future<void> dispose() async {}
}

final class _Window implements TomSecretsWindowHost {
  bool visible = false;
  int shows = 0;
  bool quitted = false;
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
  Future<void> quit() async => quitted = true;
}

final class _Notifier implements TomSecretsNotifier {
  final List<String> titles = [];
  void Function()? click;
  @override
  Future<void> notify({
    required String title,
    required String body,
    void Function()? onClick,
  }) async {
    titles.add(title);
    click = onClick;
  }
}

final class _Login implements TomSecretsLoginItem {
  bool enabled = false;
  int sets = 0;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<void> setEnabled(bool on) async {
    sets++;
    enabled = on;
  }
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

void main() {
  late FakeService service;
  late _Clipboard clipboard;
  late TomSecretsHost host;

  setUp(() async {
    service = FakeService(await demoStores());
    clipboard = _Clipboard();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: clipboard,
    );
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TomSecretsApp(host: host));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }

  Future<void> unlock(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  Future<void> scrollTo(WidgetTester tester, String key) => tester
      .scrollUntilVisible(
        find.byKey(Key(key)),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('tsm-entry-editor')),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  testWidgets('no service: the app offers to start it', (tester) async {
    host = TomSecretsHost(
      service: FakeHost(service, running: false),
      preferences: TomSecretsMemoryPreferences(),
    );
    await pumpApp(tester);
    expect(find.text('The service is not running'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-start-service')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('Unlock'), findsWidgets);
  });

  testWidgets('unlock: a wrong password is said, the right one opens the '
      'vault browser', (tester) async {
    await pumpApp(tester);
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      'wrong',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Wrong master password or key file.'), findsOneWidget);
    await unlock(tester);
    expect(find.byKey(const Key('tsm-rail')), findsOneWidget);
    expect(find.byKey(const Key('tsm-vault-primary')), findsOneWidget);
    expect(find.byKey(const Key('tsm-group-primary-Db')), findsOneWidget);
    expect(find.textContaining('@host'), findsNothing);
  });

  testWidgets('the tree view, the list view and the search', (tester) async {
    await pumpApp(tester);
    await unlock(tester);
    await tester.tap(find.byKey(const Key('tsm-group-primary-Db')));
    await tester.pump();
    expect(find.text('Main'), findsOneWidget);
    await tester.tap(find.text('List'));
    await tester.pump();
    expect(find.byKey(const Key('tsm-list-filters')), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('tsm-search')), 'bot');
    await tester.pump();
    expect(find.text('Bot'), findsOneWidget);
    expect(find.text('Token'), findsNothing);
  });

  testWidgets('the editor: masked, revealed, copied through the protected '
      'clipboard, generated, saved; how clients name it', (tester) async {
    await pumpApp(tester);
    await unlock(tester);
    await tester.tap(find.byKey(const Key('tsm-group-primary-Db')));
    await tester.pump();
    await tester.tap(find.text('Main'));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const Key('tsm-field-password')),
    );
    expect(field.obscureText, isTrue);
    await tester.tap(find.byKey(const Key('tsm-reveal-password')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('tsm-field-password')),
          )
          .obscureText,
      isFalse,
    );
    // The reveal ends by itself.
    await tester.pump(tomSecretsRevealFor + const Duration(seconds: 1));
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('tsm-field-password')),
          )
          .obscureText,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('tsm-copy-password')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(clipboard.placed, ['demo-db-pw']);
    expect(find.text('primary/Db/Main'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tsm-generate')));
    await tester.pumpAndSettle();
    final generated =
        tester.widget<SelectableText>(find.byKey(const Key('tsm-generated'))).data!;
    expect(generated, hasLength(20));
    await tester.tap(find.byKey(const Key('tsm-use-generated')));
    await tester.pumpAndSettle();
    await scrollTo(tester, 'tsm-field-key');
    await tester.enterText(find.byKey(const Key('tsm-field-key')), 'db.main');
    await tester.pump();
    await scrollTo(tester, 'tsm-save-entry');
    await tester.tap(find.byKey(const Key('tsm-save-entry')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(service.saves, hasLength(1));
    final saved = await tester.runAsync(
      () => KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(password: demoPassword),
      ),
    );
    final main = saved!.body.rootGroup.getAllEntries().firstWhere(
      (e) => e.label == 'Main' && e.parent?.name.get() == 'Db',
    );
    expect(main.getString(KdbxKeyCommon.PASSWORD)?.getText(), generated);
    expect(main.getString(TomSecretsEntryFields.key)?.getText(), 'db.main');
    expect(main.getString(KdbxKeyCommon.USER_NAME)?.getText(), 'demo-user');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('a key another entry of the vault has is refused', (tester) async {
    await pumpApp(tester);
    await unlock(tester);
    await tester.tap(find.byKey(const Key('tsm-group-primary-Db')));
    await tester.pump();
    await tester.tap(find.text('Main'));
    await tester.pump();
    await scrollTo(tester, 'tsm-field-key');
    await tester.enterText(
      find.byKey(const Key('tsm-field-key')),
      'telegram.bot_token',
    );
    await tester.pump();
    await scrollTo(tester, 'tsm-save-entry');
    await tester.tap(find.byKey(const Key('tsm-save-entry')));
    await tester.pump();
    expect(find.text('another entry of this vault has this key'), findsOneWidget);
    expect(service.saves, isEmpty);
  });

  testWidgets('TOTP: the code and its countdown', (tester) async {
    final secret = Uint8List.fromList(
      List<int>.generate(20, (i) => i + 1),
    );
    final totp = TomSecretsTotp(secret);
    final at = DateTime.utc(2026, 11, 14, 12, 0, 10);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TomSecretsTotpView(
            totp: totp,
            clipboard: TomProtectedClipboard(port: clipboard),
            clock: () => at,
          ),
        ),
      ),
    );
    final code = totp.code(at);
    expect(
      find.text('${code.substring(0, 3)} ${code.substring(3)}'),
      findsOneWidget,
    );
    expect(find.text('20s'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-totp-copy')));
    await tester.pump();
    expect(clipboard.placed, [code]);
    // The clipboard's clear runs out.
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the generator dialog: length and classes', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => chosen = await tomSecretsShowGenerator(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('bits'), findsOneWidget);
    for (final cls in ['upper', 'digits', 'symbols']) {
      await tester.tap(find.byKey(Key('tsm-class-$cls')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('tsm-class-lower')));
    await tester.pump();
    final shown =
        tester.widget<SelectableText>(find.byKey(const Key('tsm-generated'))).data!;
    expect(shown, matches(RegExp(r'^[a-z]{20}$')),
        reason: 'the last class cannot be switched off');
    await tester.tap(find.byKey(const Key('tsm-use-generated')));
    await tester.pumpAndSettle();
    expect(chosen, shown);
  });

  group('host bridge', () {
    test('tray, status line, notifications, capture and start at login',
        () async {
      final tray = _Tray();
      final window = _Window();
      final notifier = _Notifier();
      final login = _Login();
      final capture = _Capture();
      final prefs = TomSecretsMemoryPreferences();
      final h = TomSecretsHost(
        service: FakeHost(service),
        tray: tray,
        window: window,
        notifier: notifier,
        loginItem: login,
        captureGuard: capture,
        preferences: prefs,
      );
      final connection = TomSecretsServiceConnection(h.service);
      final bridge = TomSecretsHostBridge(host: h, connection: connection)
        ..start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(capture.calls, [true], reason: 'excluded by default (DP-33)');
      expect(login.enabled, isTrue, reason: 'on at the first start (DP-30)');
      expect(tray.state, TomSecretsTrayState.locked);
      expect(bridge.statusLine(), 'service not running');

      await connection.connect();
      await connection.unlock(demoPassword);
      expect(tray.state, TomSecretsTrayState.unlocked);
      expect(bridge.statusLine(), '2 vaults synced');
      expect(tray.items.map((i) => i.label), contains('Lock'));
      expect(
        tray.items.map((i) => i.label),
        contains('Quit the app (the service keeps running)'),
      );

      service.emit({'op': 'approval_needed', 'approvalId': 'a-9'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tray.state, TomSecretsTrayState.attention);
      expect(tray.items.map((i) => i.label), contains('1 approvals waiting'));

      service.emit({
        'op': 'unlock_needed',
        'identity': {'exe': '/usr/bin/demo'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notifier.titles, ['Unlock the secrets']);
      notifier.click!();
      expect(window.visible, isTrue);
      service.emit({'op': 'unlock_needed'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(notifier.titles, hasLength(1), reason: 'the window is shown');

      tray.items
          .firstWhere((i) => i.label.startsWith('Quit'))
          .onSelected!();
      expect(window.quitted, isTrue);

      // A second start leaves the user's choice alone.
      await login.setEnabled(false);
      final again = TomSecretsHostBridge(host: h, connection: connection)
        ..start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(login.enabled, isFalse);
      // The capture setting switched off is applied as off.
      await prefs.write(TomSecretsHostPreferenceKeys.captureExcluded, 'off');
      expect(await again.applyCaptureSetting(), isTrue);
      expect(capture.calls.last, isFalse);
      bridge.dispose();
      again.dispose();
      connection.dispose();
    });
  });
}
