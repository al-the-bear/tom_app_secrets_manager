// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The macOS AutoFill snapshot (part-os-integration, DP-50, DP-51): the
/// sealed format (and the test vector the extension's Swift tests open), the
/// document (login entries of personal and shared vaults only, their URLs
/// with host and registrable domain, the TOTP), the QuickType identities,
/// and the app writing it after the unlock and an edit while the provider
/// is on, removing it when turned off. Demo data only.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tom_basics/utilities.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/fake_service.dart';

/// The vector the Swift package's tests open
/// (`tom_secrets_app/macos/TomSecretsAutofillKit/Tests/...`).
const _vectorPath =
    '../tom_secrets_app/macos/TomSecretsAutofillKit/Tests/'
    'TomSecretsAutofillKitTests/Resources/snapshot_vector.json';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

/// An AutoFill port that records what the app does.
final class _Port implements TomSecretsAutofillPort {
  TomSecretsAutofillState current = const TomSecretsAutofillState(
    available: true,
    providerEnabled: true,
  );
  final List<(Uint8List, String)> keys = [];
  final List<Uint8List> snapshots = [];
  final List<List<TomSecretsAutofillIdentity>> identities = [];
  int removed = 0;
  int settingsOpened = 0;

  @override
  Future<TomSecretsAutofillState> state() async => current;

  @override
  Future<void> storeKey(Uint8List key, String keyId) async =>
      keys.add((Uint8List.fromList(key), keyId));

  @override
  Future<void> writeSnapshot(Uint8List sealed) async =>
      snapshots.add(Uint8List.fromList(sealed));

  @override
  Future<void> remove() async => removed++;

  @override
  Future<void> setIdentities(List<TomSecretsAutofillIdentity> list) async =>
      identities.add(list);

  @override
  Future<void> openSettings() async => settingsOpened++;
}

Future<KdbxFile> _vault(void Function(KdbxFile) fill) async {
  final file = tomSecretsNewVault(
    tomSecretsVaultCredentials(password: 'demo-key'),
    'demo',
    argon2: testArgon2,
  );
  fill(file);
  return file;
}

void main() {
  group('the sealed snapshot', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final written = DateTime.utc(2026, 11, 19, 9, 30);
    final document = {
      'formatVersion': 1,
      'written': written.toIso8601String(),
      'entries': [
        {
          'id': 'team/~0123456789abcdef0123456789abcdef',
          'store': 'team',
          'title': 'Mail',
          'userName': 'demo-user',
          'password': 'demo-mail-pw',
          'rule': 'domain',
          'urls': [
            {
              'url': 'https://mail.example.com/login',
              'scheme': 'https',
              'host': 'mail.example.com',
              'path': '/login',
              'site': 'example.com',
            },
          ],
          'totp': {
            'secret': base64.encode(utf8.encode('12345678901234567890')),
            'digits': 6,
            'period': 30,
            'algorithm': 'SHA1',
          },
        },
      ],
    };

    test('opens with its key; a changed header, a changed byte or another '
        'key is refused', () async {
      final sealed = await TomSecretsAutofillSnapshot.seal(
        document,
        key: key,
        keyId: 'demo-key-1',
        written: written,
      );
      expect(ascii.decode(sealed.sublist(0, 12)), 'TSM-AUTOFILL');
      // Nothing readable: no password, no title.
      expect(latin1.decode(sealed), isNot(contains('demo-mail-pw')));
      expect(latin1.decode(sealed), isNot(contains('Mail')));
      final opened = await TomSecretsAutofillSnapshot.open(sealed, key);
      expect(opened.header, {
        'formatVersion': 1,
        'keyId': 'demo-key-1',
        'written': '2026-11-19T09:30:00.000Z',
      });
      expect(opened.document, document);

      final header = Uint8List.fromList(sealed);
      header[30] ^= 1; // inside the header's JSON
      await expectLater(
        TomSecretsAutofillSnapshot.open(header, key),
        throwsA(anything),
      );
      final body = Uint8List.fromList(sealed)..[sealed.length - 20] ^= 1;
      await expectLater(
        TomSecretsAutofillSnapshot.open(body, key),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        TomSecretsAutofillSnapshot.open(sealed, Uint8List(32)),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        TomSecretsAutofillSnapshot.open(Uint8List(40), key),
        throwsA(isA<FormatException>()),
      );
    });

    test('the vector the extension opens is the one this code seals', () async {
      final sealed = await TomSecretsAutofillSnapshot.seal(
        document,
        key: key,
        keyId: 'demo-key-1',
        written: written,
        nonce: List.generate(12, (i) => 0xa0 + i),
      );
      final vector = {
        'key': base64.encode(key),
        'sealed': base64.encode(sealed),
        'document': document,
        'note':
            'Demo data. Written by tom_secrets_ui/test/autofill_test.dart '
            '(TSM_UPDATE_VECTORS=1).',
      };
      final file = File(_vectorPath);
      final text = '${const JsonEncoder.withIndent('  ').convert(vector)}\n';
      if (Platform.environment['TSM_UPDATE_VECTORS'] == '1') {
        file
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }
      expect(file.readAsStringSync(), text);
    });
  });

  test('the document: logins of personal and shared vaults, their web URLs '
      'with host and site, the rule, the TOTP; never a system vault\'s, an '
      'overlay, a note or a login the rule never keeps out', () async {
    final personal = await _vault((f) {
      addEntry(
        f,
        'Web/Mail',
        password: 'demo-mail-pw',
        fields: {
          'UserName': 'demo-user',
          'URL': 'https://mail.example.com/login',
          'KP2A_URL_1': 'androidapp://com.example.mail',
          'KP2A_URL_2': 'http://192.168.1.5:8080/',
          'otp':
              'otpauth://totp/Mail:demo?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
              '&digits=8&period=60&algorithm=SHA256',
        },
      );
      addEntry(
        f,
        'Shop',
        password: 'demo-shop-pw',
        fields: {
          'UserName': 'demo',
          'URL': 'https://shop.example.org',
          'tsm.urlMatch': 'host',
        },
      );
      addEntry(
        f,
        'Hidden',
        password: 'x',
        fields: {'URL': 'https://hidden.example', 'tsm.urlMatch': 'never'},
      );
      addEntry(
        f,
        'Note',
        fields: {'tsm.type': 'note', 'URL': 'https://note.example'},
      );
      addEntry(f, 'No URL', password: 'x');
    });
    final system = await _vault((f) {
      TomSecretsMetadata(kind: TomSecretsVaultKind.system).writeTo(f);
      addEntry(
        f,
        'Fleet',
        password: 'demo-fleet-pw',
        fields: {'URL': 'https://fleet.example.com'},
      );
    });
    final stores = [
      TomSecretsStore.fromFile(personal, name: 'personal'),
      TomSecretsStore.fromFile(system, name: 'fleet'),
    ];
    final document = tomSecretsAutofillDocument(
      stores,
      isSystem: (s) => s == 'fleet',
      written: DateTime.utc(2026, 11, 19),
    );
    final entries = (document['entries']! as List).cast<Map>();
    expect([
      for (final e in entries) e['title'],
    ], unorderedEquals(['Mail', 'Shop']));
    final mail = entries.firstWhere((e) => e['title'] == 'Mail');
    final shop = entries.firstWhere((e) => e['title'] == 'Shop');
    expect(mail['id'], startsWith('personal/~'));
    expect(mail['userName'], 'demo-user');
    expect(mail['password'], 'demo-mail-pw');
    expect(mail['rule'], 'domain');
    expect(mail['urls'], [
      {
        'url': 'https://mail.example.com/login',
        'scheme': 'https',
        'host': 'mail.example.com',
        'path': '/login',
        'site': 'example.com',
      },
      {
        'url': 'http://192.168.1.5:8080/',
        'scheme': 'http',
        'host': '192.168.1.5',
        'port': 8080,
        'path': '/',
        'address': true,
      },
    ]);
    expect(mail['totp'], {
      'secret': base64.encode(utf8.encode('12345678901234567890')),
      'digits': 8,
      'period': 60,
      'algorithm': 'SHA256',
    });
    expect(shop['rule'], 'host');
    expect(jsonEncode(document), isNot(contains('demo-fleet-pw')));

    expect(
      tomSecretsAutofillIdentities(document),
      unorderedEquals([
        TomSecretsAutofillIdentity(
          domain: 'mail.example.com',
          userName: 'demo-user',
          recordIdentifier: mail['id'] as String,
        ),
        TomSecretsAutofillIdentity(
          domain: '192.168.1.5',
          userName: 'demo-user',
          recordIdentifier: mail['id'] as String,
        ),
        TomSecretsAutofillIdentity(
          domain: 'shop.example.org',
          userName: 'demo',
          recordIdentifier: shop['id'] as String,
        ),
      ]),
    );
  });

  group('the app', () {
    late FakeService service;
    late _Port port;

    setUp(() async {
      service = FakeService(await demoStores());
      port = _Port();
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
      await tester.pumpWidget(
        TomSecretsApp(
          host: TomSecretsHost(
            service: FakeHost(service),
            preferences: TomSecretsMemoryPreferences(),
            clipboard: _Clipboard(),
            autofill: port,
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

    Future<Map<String, Object?>> lastDocument(WidgetTester tester) async {
      final (key, _) = port.keys.last;
      final opened = await tester.runAsync(
        () => TomSecretsAutofillSnapshot.open(port.snapshots.last, key),
      );
      return opened!.document;
    }

    testWidgets('the unlock writes a key and the snapshot, an edit writes it '
        'again under the same key; QuickType off clears the identities; off '
        'removes everything', (tester) async {
      await unlocked(tester);
      expect(port.keys, hasLength(1));
      expect(port.keys.single.$1, hasLength(32));
      expect(port.snapshots, hasLength(1));
      final document = await lastDocument(tester);
      final titles = [
        for (final e in (document['entries']! as List).cast<Map>()) e['title'],
      ];
      // The demo primary's one login with a web URL.
      expect(titles, ['Main']);
      expect(port.identities.last.single.domain, 'db.example');

      // An edit through the app's session: the snapshot follows.
      final session = Provider.of<TomSecretsSession>(
        tester.element(find.byType(TomSecretsMainShell)),
        listen: false,
      );
      final main = session.index.firstWhere((e) => e.title == 'Main');
      await tester.runAsync(
        () => session.setField(main.ref, 'Password', 'demo-db-pw-2'),
      );
      await wait(tester, 5);
      expect(port.keys, hasLength(1), reason: 'one key per unlock');
      expect(port.snapshots, hasLength(2));
      final again = await lastDocument(tester);
      expect(
        (again['entries']! as List).cast<Map>().single['password'],
        'demo-db-pw-2',
      );

      await tester.tap(find.text('Settings'));
      await wait(tester);
      await tester.ensureVisible(
        find.byKey(const Key('tsm-autofill-quicktype')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-autofill-quicktype')));
      await wait(tester);
      expect(port.identities.last, isEmpty);
      await tester.tap(find.byKey(const Key('tsm-autofill-enabled')));
      await wait(tester);
      expect(port.removed, 1);
      await tester.tap(find.byKey(const Key('tsm-autofill-open-settings')));
      await wait(tester, 1);
      expect(port.settingsOpened, 1);
    });

    testWidgets('a removed device (its record revoked in the primary) keeps '
        'nothing: the snapshot, its key and the identities are deleted, '
        'nothing written', (tester) async {
      service.pairedDevices.add(
        TomSecretsDeviceRecord(
          device: 'mbp',
          paired: DateTime.utc(2026, 11, 1),
          keyIds: const [],
          revoked: DateTime.utc(2026, 11, 18),
        ),
      );
      await unlocked(tester);
      expect(port.snapshots, isEmpty);
      expect(port.keys, isEmpty);
      expect(port.removed, 1);
      expect(port.identities.last, isEmpty);
    });

    testWidgets('nothing is written while the provider is off in System '
        'Settings or the build has none; Settings says why', (tester) async {
      port.current = const TomSecretsAutofillState(available: true);
      await unlocked(tester);
      expect(port.snapshots, isEmpty);
      expect(port.keys, isEmpty);
      await tester.tap(find.text('Settings'));
      await wait(tester);
      await tester.ensureVisible(find.byKey(const Key('tsm-autofill-system')));
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-autofill-system'))).data,
        contains('Turn on Tom Secrets Manager'),
      );
      port.current = const TomSecretsAutofillState(
        available: false,
        unavailableReason: 'This build has no AutoFill provider.',
      );
      // Leaving and coming back to Settings asks again.
      await tester.tap(find.text('Vaults'));
      await wait(tester);
      await tester.tap(find.text('Settings'));
      await wait(tester);
      await tester.ensureVisible(
        find.byKey(const Key('tsm-autofill-unavailable')),
      );
      expect(port.snapshots, isEmpty);
    });
  });
}
