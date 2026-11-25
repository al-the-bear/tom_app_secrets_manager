// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The app's screens against the fake service: connecting, unlock, the
/// shell with the tree and list views, the entry editor (masked values,
/// reveal, the generator, TOTP, "How clients name it", saving), and the
/// host bridge (tray, notifications, capture, start at login). Demo data
/// only.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_secrets_client/admin.dart' show TomSecretsAdminException;
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';
import 'support/qr_images.dart';

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
    List<TomSecretsNotificationAction> actions = const [],
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
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

  Future<void> scrollTo(WidgetTester tester, String key) =>
      tester.scrollUntilVisible(
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('Unlock'), findsWidgets);
  });

  testWidgets('a service the app has not met: its identity words are shown '
      'to compare, with no password field; trusted, the app attaches', (
    tester,
  ) async {
    const words = 'harbor-violet-cedar-lantern-maple-orbit-pebble-quill';
    final fake = FakeHost(service)
      ..untrusted = TomSecretsAdminException(
        'service_untrusted',
        'this service is not known here yet; its identity is: $words',
        details: const {'reason': 'unpinned', 'words': words},
      );
    host = TomSecretsHost(
      service: fake,
      preferences: TomSecretsMemoryPreferences(),
    );
    await pumpApp(tester);
    expect(find.text('Is this your secrets service?'), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('tsm-service-words')))
          .data,
      words,
    );
    expect(find.textContaining('Nothing was sent to it yet'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('tsm-start-service')), findsNothing);
    await tester.tap(find.byKey(const Key('tsm-trust-service')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(fake.trusted, [words]);
    expect(find.text('Unlock'), findsWidgets);
  });

  testWidgets('the service\'s identity changed: the app says which was '
      'pinned and which answers, offers no password field and no way on '
      'but comparing the new identity', (tester) async {
    final fake = FakeHost(service)
      ..untrusted = TomSecretsAdminException(
        'service_key_changed',
        'the service\'s identity key changed',
        details: const {
          'pinned': 'harbor-violet-cedar-lantern-maple-orbit-pebble-quill',
          'presented':
              'walrus-dahlia-cherry-bronze-ladder-canyon-fountain-mint',
        },
      );
    host = TomSecretsHost(
      service: fake,
      preferences: TomSecretsMemoryPreferences(),
    );
    await pumpApp(tester);
    expect(find.text('The service\'s identity changed'), findsOneWidget);
    final text = tester
        .widget<Text>(find.byKey(const Key('tsm-service-gate-text')))
        .data!;
    expect(text, contains('harbor-violet-cedar'));
    expect(text, contains('walrus-dahlia-cherry'));
    expect(text, contains('do not enter the master password'));
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('tsm-start-service')), findsNothing);
    expect(find.byKey(const Key('tsm-trust-service')), findsNothing);

    // Set up anew: the old pin goes, the new words are compared.
    await tester.tap(find.byKey(const Key('tsm-forget-pin')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(fake.forgotten, 1);
    expect(find.text('Is this your secrets service?'), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('tsm-service-words')))
          .data,
      'walrus-dahlia-cherry-bronze-ladder-canyon-fountain-mint',
    );
  });

  testWidgets('something else answers where the service would: the app '
      'says what is wrong and what to do, and shows no password field', (
    tester,
  ) async {
    final fake = FakeHost(service)
      ..untrusted = TomSecretsAdminException(
        'service_untrusted',
        'the admin endpoint is not this user\'s service: the process '
            'answering (pid 4711) runs as 1001, not as this user',
        details: const {'reason': 'peer_user'},
      );
    host = TomSecretsHost(
      service: fake,
      preferences: TomSecretsMemoryPreferences(),
    );
    await pumpApp(tester);
    expect(find.text('This is not your secrets service'), findsOneWidget);
    final text = tester
        .widget<Text>(find.byKey(const Key('tsm-service-gate-text')))
        .data!;
    expect(text, contains('pid 4711'));
    expect(text, contains('Do not enter the master password'));
    expect(text, contains('Nothing was sent to it.'));
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('tsm-start-service')), findsNothing);
    expect(find.byKey(const Key('tsm-claim-passphrase')), findsNothing);

    // Once it is gone, "Look again" attaches.
    fake.untrusted = null;
    await tester.tap(find.byKey(const Key('tsm-retry')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
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
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
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
          .widget<TextField>(find.byKey(const Key('tsm-field-password')))
          .obscureText,
      isFalse,
    );
    // The reveal ends by itself.
    await tester.pump(tomSecretsRevealFor + const Duration(seconds: 1));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tsm-field-password')))
          .obscureText,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('tsm-copy-password')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(clipboard.placed, ['demo-db-pw']);
    expect(find.text('primary/Db/Main'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tsm-generate')));
    await tester.pumpAndSettle();
    final generated = tester
        .widget<SelectableText>(find.byKey(const Key('tsm-generated')))
        .data!;
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

  testWidgets('TOTP by scanning: the QR code\'s otpauth URI fills the field '
      'and is saved; another QR code is refused', (tester) async {
    final scanner = _FakeScanner();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: clipboard,
      scanner: scanner,
    );
    await pumpApp(tester);
    await unlock(tester);
    await tester.tap(find.byKey(const Key('tsm-group-primary-Db')));
    await tester.pump();
    await tester.tap(find.text('Main'));
    await tester.pump();
    await scrollTo(tester, 'tsm-otp-scan');

    scanner.next = 'tsm-pair:10.8.0.2:47900?code=17-apple-river';
    await tester.tap(find.byKey(const Key('tsm-otp-scan')));
    await tester.pump();
    expect(scanner.titles, ['Scan the one-time code\'s QR code']);
    expect(find.byKey(const Key('tsm-otp-error')), findsOneWidget);

    const uri =
        'otpauth://totp/Demo:demo-user?secret=JBSWY3DPEHPK3PXP&issuer=Demo';
    scanner.next = uri;
    await tester.tap(find.byKey(const Key('tsm-otp-scan')));
    await tester.pump();
    expect(find.byKey(const Key('tsm-otp-error')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tsm-field-otp')))
          .controller!
          .text,
      uri,
    );
    await scrollTo(tester, 'tsm-save-entry');
    await tester.tap(find.byKey(const Key('tsm-save-entry')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    final saved = await tester.runAsync(
      () => KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(password: demoPassword),
      ),
    );
    final main = saved!.body.rootGroup.getAllEntries().firstWhere(
      (e) => e.label == 'Main' && e.parent?.name.get() == 'Db',
    );
    expect(
      TomSecretsTotp.fromEntry(main)?.secret,
      tomSecretsBase32Decode('JBSWY3DPEHPK3PXP'),
    );
  });

  testWidgets('without a camera the editor offers no scan', (tester) async {
    await pumpApp(tester);
    await unlock(tester);
    await tester.tap(find.byKey(const Key('tsm-group-primary-Db')));
    await tester.pump();
    await tester.tap(find.text('Main'));
    await tester.pump();
    expect(find.byKey(const Key('tsm-otp-scan')), findsNothing);
    expect(find.byKey(const Key('tsm-otp-read-qr')), findsNothing);
  });

  group('desktop: "Read a QR code…"', () {
    const uri =
        'otpauth://totp/Demo:demo-user?secret=JBSWY3DPEHPK3PXP&issuer=Demo';
    late _FakeQrSources sources;
    late _Files files;

    Future<void> openMain(WidgetTester tester) async {
      sources = _FakeQrSources();
      files = _Files();
      host = TomSecretsHost(
        service: FakeHost(service),
        preferences: TomSecretsMemoryPreferences(),
        clipboard: clipboard,
        files: files,
        qrSources: sources,
      );
      await pumpApp(tester);
      await unlock(tester);
      await tester.tap(find.byKey(const Key('tsm-group-primary-Db')));
      await tester.pump();
      await tester.tap(find.text('Main'));
      await tester.pump();
      expect(find.byKey(const Key('tsm-otp-scan')), findsNothing);
      await scrollTo(tester, 'tsm-otp-read-qr');
    }

    Future<void> choose(WidgetTester tester, String source) async {
      await tester.tap(find.byKey(const Key('tsm-otp-read-qr')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(source)));
      // The decoding runs on real async work (the codec, zxing2).
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    String field(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const Key('tsm-field-otp')))
        .controller!
        .text;

    Future<KdbxEntry> saveAndRead(WidgetTester tester) async {
      await scrollTo(tester, 'tsm-save-entry');
      await tester.tap(find.byKey(const Key('tsm-save-entry')));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      final saved = await tester.runAsync(
        () => KdbxFormat().read(
          service.store('primary').stored,
          tomSecretsVaultCredentials(password: demoPassword),
        ),
      );
      return saved!.body.rootGroup.getAllEntries().firstWhere(
        (e) => e.label == 'Main' && e.parent?.name.get() == 'Db',
      );
    }

    testWidgets('from an image file: its PNG fills the field and is saved', (
      tester,
    ) async {
      await openMain(tester);
      final png = (await tester.runAsync(() => qrPng(uri)))!;
      files.next = (name: 'setup.png', bytes: png);
      await choose(tester, 'tsm-otp-qr-file');
      expect(find.byKey(const Key('tsm-otp-error')), findsNothing);
      expect(field(tester), uri);
      expect(png.every((b) => b == 0), isTrue, reason: 'the image cleared');
      final main = await saveAndRead(tester);
      expect(
        TomSecretsTotp.fromEntry(main)?.secret,
        tomSecretsBase32Decode('JBSWY3DPEHPK3PXP'),
      );
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets('from the clipboard: a picture with a code is read; none '
        'says so', (tester) async {
      await openMain(tester);
      await choose(tester, 'tsm-otp-qr-clipboard');
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-otp-error'))).data,
        'the clipboard holds no picture',
      );
      final code = qrPixels(uri);
      sources.clipboard = TomSecretsQrImage.rgba(
        code.width,
        code.height,
        code.pixels,
      );
      await choose(tester, 'tsm-otp-qr-clipboard');
      expect(find.byKey(const Key('tsm-otp-error')), findsNothing);
      expect(field(tester), uri);
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets('from the screen: the capture is read; a picture without a '
        'code and a Google Authenticator export of two accounts are named', (
      tester,
    ) async {
      await openMain(tester);
      final blank = Uint8List(100 * 100 * 4)..fillRange(0, 40000, 0xff);
      sources.screen = TomSecretsQrImage.rgba(100, 100, blank);
      await choose(tester, 'tsm-otp-qr-screen');
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-otp-error'))).data,
        'no QR code was found there',
      );

      // An export of two accounts: per account the payload's field 1
      // (6 bytes) holding its secret (field 1, 2 bytes) and its TOTP type
      // (field 6 = 2).
      List<int> account(int s) => [0x0a, 6, 0x0a, 2, s, s, 0x30, 2];
      final payload = <int>[
        for (final s in [1, 2]) ...account(s),
      ];
      final export =
          'otpauth-migration://offline?data='
          '${Uri.encodeQueryComponent(base64.encode(payload))}';
      var screen = qrPixels(export);
      sources.screen = TomSecretsQrImage.rgba(
        screen.width,
        screen.height,
        screen.pixels,
      );
      await choose(tester, 'tsm-otp-qr-screen');
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-otp-error'))).data,
        contains('2 accounts: export them one at a time'),
      );

      screen = qrPixels(
        uri,
        scale: 3,
        canvasWidth: 900,
        canvasHeight: 600,
        left: 400,
        top: 200,
      );
      sources.screen = TomSecretsQrImage.rgba(
        screen.width,
        screen.height,
        screen.pixels,
      );
      await choose(tester, 'tsm-otp-qr-screen');
      expect(find.byKey(const Key('tsm-otp-error')), findsNothing);
      expect(field(tester), uri);
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets('a hex secret typed in the field is saved as base32', (
      tester,
    ) async {
      await openMain(tester);
      // RFC 6238's SHA-1 seed "12345678901234567890" in hex.
      await tester.enterText(
        find.byKey(const Key('tsm-field-otp')),
        'hex:3132333435363738393031323334353637383930',
      );
      final main = await saveAndRead(tester);
      expect(
        main.getString(TomSecretsTotpFields.secretBase32)?.getText(),
        'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
      );
      expect(
        TomSecretsTotp.fromEntry(main)!.code(
          DateTime.fromMillisecondsSinceEpoch(1111111109000, isUtc: true),
        ),
        '081804',
      );
      await tester.pump(const Duration(seconds: 31));
    });
  });

  testWidgets('a key another entry of the vault has is refused', (
    tester,
  ) async {
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
    expect(
      find.text('another entry of this vault has this key'),
      findsOneWidget,
    );
    expect(service.saves, isEmpty);
  });

  testWidgets('TOTP: the code and its countdown', (tester) async {
    final secret = Uint8List.fromList(List<int>.generate(20, (i) => i + 1));
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
            onPressed: () async =>
                chosen = await tomSecretsShowGenerator(context),
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
    final shown = tester
        .widget<SelectableText>(find.byKey(const Key('tsm-generated')))
        .data!;
    expect(
      shown,
      matches(RegExp(r'^[a-z]{20}$')),
      reason: 'the last class cannot be switched off',
    );
    await tester.tap(find.byKey(const Key('tsm-use-generated')));
    await tester.pumpAndSettle();
    expect(chosen, shown);
  });

  group('host bridge', () {
    test(
      'tray, status line, notifications, capture and start at login',
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
        // The prompt above notified too, the window being closed (DP-31).
        expect(notifier.titles, ['Approve a request', 'Unlock the secrets']);
        notifier.click!();
        expect(window.visible, isTrue);
        service.emit({'op': 'unlock_needed'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(notifier.titles, hasLength(2), reason: 'the window is shown');

        tray.items.firstWhere((i) => i.label.startsWith('Quit')).onSelected!();
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
      },
    );
  });

  testWidgets('an entry asked for from outside (the browser host\'s openApp) '
      'is shown once its vault is open; another text is ignored', (
    tester,
  ) async {
    final requests = TomSecretsEntryRequests();
    host = TomSecretsHost(
      service: FakeHost(service),
      preferences: TomSecretsMemoryPreferences(),
      clipboard: clipboard,
      entryRequests: requests,
    );
    final stored = await tester.runAsync(
      () => KdbxFormat().read(
        service.store('primary').stored,
        tomSecretsVaultCredentials(password: demoPassword),
      ),
    );
    final main = stored!.body.rootGroup.getAllEntries().firstWhere(
      (e) => e.label == 'Main' && e.parent?.name.get() == 'Db',
    );
    final hex = [
      for (final b in main.uuid.toBytes()) b.toRadixString(16).padLeft(2, '0'),
    ].join();
    requests.request('not a reference');
    expect(requests.pending, isNull);
    // Asked for while locked: kept until the vault is open.
    requests.request('primary/~$hex');
    await pumpApp(tester);
    await unlock(tester);
    await tester.pumpAndSettle();
    expect(requests.pending, isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('tsm-field-title')))
          .controller!
          .text,
      'Main',
    );
  });
}

final class _FakeScanner implements TomSecretsCodeScanner {
  String? next;
  final List<String> titles = [];

  @override
  Future<String?> scan(BuildContext context, {required String title}) async {
    titles.add(title);
    return next;
  }
}

final class _FakeQrSources implements TomSecretsQrSources {
  TomSecretsQrImage? clipboard;
  TomSecretsQrImage? screen;

  @override
  bool get canCaptureScreen => true;

  @override
  Future<TomSecretsQrImage?> clipboardImage() async => clipboard;

  @override
  Future<TomSecretsQrImage?> captureScreen() async => screen;
}

final class _Files implements TomSecretsFiles {
  ({String name, Uint8List bytes})? next;

  @override
  Future<({String name, Uint8List bytes})?> pick() async => next;

  @override
  Future<bool> save(String name, Uint8List bytes) async => false;

  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => null;

  @override
  Future<Uint8List> read(String path) async => Uint8List(0);

  @override
  Future<bool> delete(String path) async => false;
}
