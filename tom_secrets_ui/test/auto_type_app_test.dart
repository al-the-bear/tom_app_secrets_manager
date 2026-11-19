// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Auto-type and quick access in the app (part-app, part-password-manager,
/// DP-41): the typer types a sequence and stops when the window changes,
/// on secure input and when the system refuses keys; the hotkeys are
/// registered with their defaults; the quick-access popup copies the
/// password and the user name and types into the window it was opened for;
/// the global auto-type hotkey types for the entry associated with the
/// active window; the entry editor keeps the window associations; Settings
/// sets a hotkey. A fake keyboard and fake hotkeys; demo data only.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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

/// Records what is typed into [title], the active window.
final class _Keyboard implements TomSecretsKeyboard {
  String? title = 'Demo Terminal';
  bool trusted = true;
  bool secure = false;
  String? refusal;
  int? changeTitleAfter;
  final StringBuffer typed = StringBuffer();
  final List<TomSecretsAutoTypeKeyPress> keys = [];
  int permissionAsked = 0;

  @override
  TomSecretsAutoTypeSupport support() => trusted
      ? TomSecretsAutoTypeSupport.ok
      : const TomSecretsAutoTypeSupport(
          available: false,
          permissionNeeded: true,
          reason: 'The Accessibility permission is missing.',
        );

  @override
  Future<bool> requestPermission() async {
    permissionAsked++;
    return trusted = true;
  }

  @override
  String? activeWindowTitle() => title;

  @override
  bool secureInputActive() => secure;

  @override
  String? takeRefusal() {
    final why = refusal;
    refusal = null;
    return why;
  }

  void _count() {
    final after = changeTitleAfter;
    if (after != null && typed.length >= after) title = 'Another window';
  }

  @override
  void typeCharacter(String character) {
    typed.write(character);
    _count();
  }

  @override
  void press(TomSecretsAutoTypeKeyPress press) {
    keys.add(press);
    typed.write(switch (press.key) {
      TomSecretsAutoTypeKey.tab => '<TAB>',
      TomSecretsAutoTypeKey.enter => '<ENTER>',
      _ => '<${press.key?.name ?? press.character}>',
    });
    _count();
  }
}

final class _Hotkeys implements TomSecretsHotkeys {
  final Map<String, (TomSecretsHotkey, void Function())> registered = {};
  final Set<TomSecretsHotkey> taken = {};

  @override
  Future<void> register(
    String id,
    TomSecretsHotkey hotkey,
    void Function() onPressed,
  ) async {
    if (taken.contains(hotkey)) throw StateError('held by another program');
    registered[id] = (hotkey, onPressed);
  }

  @override
  Future<void> unregister(String id) async => registered.remove(id);
}

final class _Window implements TomSecretsWindowHost {
  bool visible = false;

  @override
  Future<void> show() async => visible = true;

  @override
  Future<void> hide() async => visible = false;

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<void> quit() async {}
}

Future<void> _noPause(Duration _) async {}

void main() {
  group('the typer', () {
    late _Keyboard keyboard;
    late KdbxEntry entry;

    setUp(() {
      keyboard = _Keyboard();
      final file = tomSecretsNewVault(
        tomSecretsVaultCredentials(password: 'x'),
        'demo',
        argon2: testArgon2,
      );
      entry = KdbxEntry.create(file, file.body.rootGroup)..label = 'Db';
      file.body.rootGroup.addEntry(entry);
      entry
        ..setString(KdbxKeyCommon.USER_NAME, PlainValue('demo-user'))
        ..setString(KdbxKeyCommon.PASSWORD, ProtectedValue.fromString('pw+1'));
    });

    test('the default sequence: characters as Unicode, Tab and Enter as '
        'keys', () async {
      final outcome = await TomSecretsAutoTyper(
        keyboard,
        pause: _noPause,
      ).typeEntry(entry);
      expect(outcome.result, TomSecretsAutoTypeResult.typed);
      expect(keyboard.typed.toString(), 'demo-user<TAB>pw+1<ENTER>');
    });

    test('stops when the window changes, on secure input and when the '
        'system refuses the keys', () async {
      keyboard.changeTitleAfter = 3;
      var outcome = await TomSecretsAutoTyper(
        keyboard,
        pause: _noPause,
      ).typeEntry(entry);
      expect(outcome.result, TomSecretsAutoTypeResult.stopped);
      expect(outcome.message, contains('window changed'));
      expect(keyboard.typed.toString(), 'dem');

      keyboard
        ..title = 'Demo Terminal'
        ..changeTitleAfter = null
        ..secure = true;
      outcome = await TomSecretsAutoTyper(
        keyboard,
        pause: _noPause,
      ).typeEntry(entry);
      expect(outcome.result, TomSecretsAutoTypeResult.stopped);
      expect(outcome.message, contains('secure input'));

      keyboard
        ..secure = false
        ..refusal = 'Windows refused the keys.';
      outcome = await TomSecretsAutoTyper(
        keyboard,
        pause: _noPause,
      ).typeEntry(entry);
      expect(outcome.message, 'Windows refused the keys.');
    });

    test('refused: no permission, auto-type off, a bad sequence', () async {
      keyboard.trusted = false;
      var outcome = await TomSecretsAutoTyper(
        keyboard,
        pause: _noPause,
      ).typeEntry(entry);
      expect(outcome.result, TomSecretsAutoTypeResult.refused);
      keyboard.trusted = true;
      entry.autoType = const KdbxAutoTypeSettings(enabled: false);
      outcome = await TomSecretsAutoTyper(
        keyboard,
        pause: _noPause,
      ).typeEntry(entry);
      expect(outcome.message, 'Auto-type is off for this entry.');
      entry.autoType = const KdbxAutoTypeSettings(defaultSequence: '{NOPE}');
      outcome = await TomSecretsAutoTyper(
        keyboard,
        pause: _noPause,
      ).typeEntry(entry);
      expect(outcome.message, contains('unknown placeholder {NOPE}'));
      expect(keyboard.typed.toString(), isEmpty);
    });

    test('hotkeys are written and read back', () {
      final h = TomSecretsHotkey.parse('ctrl + shift + space')!;
      expect(h.toString(), 'Ctrl+Shift+Space');
      expect(TomSecretsHotkey.parse('Cmd+Alt+a').toString(), 'Alt+Cmd+A');
      expect(TomSecretsHotkey.parse('Space'), isNull);
      expect(TomSecretsHotkey.parse('Ctrl+Hyper+X'), isNull);
      expect(TomSecretsHotkey.parse('Ctrl+F13'), isNull);
    });
  });

  group('the app', () {
    late FakeService service;
    late _Keyboard keyboard;
    late _Hotkeys hotkeys;
    late _Window window;
    late _Clipboard clipboard;

    setUp(() async {
      service = FakeService(await demoStores());
      keyboard = _Keyboard();
      hotkeys = _Hotkeys();
      window = _Window();
      clipboard = _Clipboard();
    });

    Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        // Typing pauses between keys on the test's clock.
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> unlocked(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1700, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TomSecretsApp(
          host: TomSecretsHost(
            service: FakeHost(service),
            preferences: TomSecretsMemoryPreferences(),
            clipboard: clipboard,
            keyboard: keyboard,
            hotkeys: hotkeys,
            window: window,
            breachCheck: TomSecretsBreachCheck(
              endpoint: Uri.parse('http://127.0.0.1:9/'),
            ),
          ),
        ),
      );
      await wait(tester, 1);
      await tester.enterText(
        find.byKey(const Key('tsm-unlock-passphrase')),
        demoPassword,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-unlock')));
      await wait(tester, 10);
    }

    Future<void> pressHotkey(WidgetTester tester, String id) async {
      hotkeys.registered[id]!.$2();
      await wait(tester, 4);
    }

    testWidgets('the default hotkeys are registered; quick access: Enter '
        'copies the password, Shift+Enter the user name, the window hides '
        'again', (tester) async {
      await unlocked(tester);
      expect(
        hotkeys.registered['quick-access']!.$1.toString(),
        'Ctrl+Shift+Space',
      );
      expect(hotkeys.registered['auto-type']!.$1.toString(), 'Ctrl+Alt+A');

      await pressHotkey(tester, 'quick-access');
      expect(find.byKey(const Key('tsm-quick-access')), findsOneWidget);
      expect(window.visible, isTrue);
      await tester.enterText(
        find.byKey(const Key('tsm-quick-access-search')),
        'main',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await wait(tester);
      expect(clipboard.placed.last, 'demo-db-pw');
      expect(find.byKey(const Key('tsm-quick-access')), findsNothing);
      expect(window.visible, isFalse);

      await pressHotkey(tester, 'quick-access');
      await tester.enterText(
        find.byKey(const Key('tsm-quick-access-search')),
        'main',
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await wait(tester);
      expect(clipboard.placed.last, 'demo-user');
      // The protected clipboard's clearing runs out.
      await tester.pump(const Duration(minutes: 2));
    });

    testWidgets('quick access types into the window it was opened for '
        '(Alt+Enter); the global auto-type hotkey types for the entry '
        'associated with the active window', (tester) async {
      await unlocked(tester);
      await pressHotkey(tester, 'quick-access');
      await tester.enterText(
        find.byKey(const Key('tsm-quick-access-search')),
        'main',
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await wait(tester, 6);
      expect(keyboard.typed.toString(), 'demo-user<TAB>demo-db-pw<ENTER>');
      expect(window.visible, isFalse);

      // No entry fits "Demo Terminal": the popup says so.
      keyboard.typed.clear();
      await pressHotkey(tester, 'auto-type');
      expect(
        find.text('No entry is associated with "Demo Terminal".'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wait(tester);

      // An association makes Main the one for it: typed at once.
      final session = tester
          .element(find.byKey(const Key('tsm-rail')))
          .read<TomSecretsSession>();
      final main = session.index.firstWhere((v) => v.title == 'Main').ref;
      await tester.runAsync(
        () => session.updateEntry(
          main,
          (e) => e.autoType = const KdbxAutoTypeSettings(
            associations: [
              KdbxAutoTypeAssociation('Demo Term*', '{PASSWORD}{ENTER}'),
            ],
          ),
        ),
      );
      await wait(tester, 4);
      await pressHotkey(tester, 'auto-type');
      expect(keyboard.typed.toString(), 'demo-db-pw<ENTER>');
      expect(find.byKey(const Key('tsm-quick-access')), findsNothing);
    });

    testWidgets('the entry editor keeps auto-type\'s sequence and window '
        'associations', (tester) async {
      await unlocked(tester);
      await tester.tap(find.byKey(const Key('tsm-group-primary-Db')));
      await tester.pump();
      await tester.tap(find.text('Main'));
      await wait(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('tsm-auto-type-sequence')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('tsm-entry-editor')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tsm-auto-type-sequence')),
        '{USERNAME}{ENTER}',
      );
      await tester.tap(find.byKey(const Key('tsm-auto-type-window-add')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('tsm-auto-type-window-0')),
        'psql*',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-auto-type-window-sequence-0')),
        '{PASSWORD}{ENTER}',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await wait(tester, 5);
      final stored = (await tester.runAsync(
        () => KdbxFormat().read(
          service.store('primary').stored,
          tomSecretsVaultCredentials(password: demoPassword),
        ),
      ))!;
      final entry = stored.body.rootGroup.getAllEntries().firstWhere(
        (e) => e.label == 'Main',
      );
      expect(
        entry.autoType,
        const KdbxAutoTypeSettings(
          defaultSequence: '{USERNAME}{ENTER}',
          associations: [KdbxAutoTypeAssociation('psql*', '{PASSWORD}{ENTER}')],
        ),
      );
    });

    testWidgets('Settings: auto-type\'s state with Grant…, a hotkey changed, '
        'a wrong one and a taken one said so', (tester) async {
      keyboard.trusted = false;
      await unlocked(tester);
      await tester.tap(find.text('Settings'));
      await wait(tester);
      final section = find.byKey(const Key('tsm-settings-auto-type'));
      await tester.ensureVisible(section);
      await tester.pumpAndSettle();
      expect(
        find.text('The Accessibility permission is missing.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('tsm-settings-auto-type-grant')));
      await wait(tester);
      expect(keyboard.permissionAsked, 1);
      expect(find.text('Auto-type works on this machine.'), findsOneWidget);

      const field = Key('tsm-settings-hotkey-quickAccess.hotkey');
      await tester.enterText(find.byKey(field), 'Ctrl+Alt+K');
      await tester.tap(
        find.byKey(const Key('tsm-settings-hotkey-quickAccess.hotkey-set')),
      );
      await wait(tester);
      expect(hotkeys.registered['quick-access']!.$1.toString(), 'Ctrl+Alt+K');
      await tester.enterText(find.byKey(field), 'K');
      await tester.tap(
        find.byKey(const Key('tsm-settings-hotkey-quickAccess.hotkey-set')),
      );
      await wait(tester);
      expect(
        find.byKey(const Key('tsm-settings-hotkey-error')),
        findsOneWidget,
      );
      hotkeys.taken.add(TomSecretsHotkey.parse('Ctrl+Alt+J')!);
      await tester.enterText(find.byKey(field), 'Ctrl+Alt+J');
      await tester.tap(
        find.byKey(const Key('tsm-settings-hotkey-quickAccess.hotkey-set')),
      );
      await wait(tester);
      expect(find.textContaining('cannot be used'), findsOneWidget);
    });
  });
}
