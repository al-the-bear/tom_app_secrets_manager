// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The Android Autofill service's Dart side (part-os-integration, DP-175):
/// which logins answer a request (a browser's web domain by the browser's
/// rules, an app by `androidapp://<package>`, never a system vault's),
/// Digital Asset Links verifying a package match, the running app answering
/// the service from its memory (locked: nothing), a login the service saw
/// submitted becoming a proposal after the unlock, and the app as the
/// service's own unlock: the vaults fetched and opened, the logins handed
/// back, none said so, a phone not set up told. Demo data only.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_basics/utilities.dart'
    show TomClipboardPort, TomClipboardReceipt;
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import 'support/demo_vaults.dart';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

/// The running app's side of the service, recorded.
final class _Platform implements TomSecretsAutofillPlatform {
  Future<Object?> Function(String method, Object? arguments)? handler;
  Map<String, Object?>? proposal;
  bool? enabled = false;
  int settingsOpened = 0;

  @override
  void setHandler(
    Future<Object?> Function(String method, Object? arguments)? h,
  ) => handler = h;

  @override
  Future<Map<String, Object?>?> takeProposal() async {
    final p = proposal;
    proposal = null;
    return p;
  }

  @override
  Future<bool?> serviceEnabled() async => enabled;

  @override
  Future<void> openSettings() async {
    settingsOpened++;
    enabled = true;
  }

  @override
  Future<void> setPasskeyIdentities(
    List<Map<String, Object?>> identities,
  ) async {}
}

/// The unlock activity's side, recorded.
final class _Unlock implements TomSecretsAutofillUnlockPlatform {
  _Unlock(this.asked);

  final TomSecretsAutofillRequest asked;
  List<TomSecretsAutofillLogin>? handed;
  int cancelled = 0;

  @override
  Future<TomSecretsAutofillRequest> request() async => asked;

  @override
  Future<void> done(List<TomSecretsAutofillLogin> logins) async =>
      handed = logins;

  @override
  Future<void> cancel() async => cancelled++;
}

KdbxEntry _login(
  KdbxFile file,
  String title,
  Map<String, String> fields, {
  String password = 'demo-pw',
}) {
  final entry = KdbxEntry.create(file, file.body.rootGroup)
    ..setString(KdbxKeyCommon.TITLE, PlainValue(title))
    ..setString(KdbxKeyCommon.USER_NAME, PlainValue('demo-user'))
    ..setString(KdbxKeyCommon.PASSWORD, ProtectedValue.fromString(password));
  for (final MapEntry(:key, :value) in fields.entries) {
    entry.setString(KdbxKey(key), PlainValue(value));
  }
  file.body.rootGroup.addEntry(entry);
  return entry;
}

/// The team vault with web and app logins, the system vault with one of the
/// same site (never offered).
(KdbxFile, KdbxFile) _vaults(DemoVaults demo) {
  final team = DemoVaults.vault('team', demo.teamCredentials, const {});
  _login(team, 'Mail', {
    'URL': 'https://mail.example.com/login',
  }, password: 'demo-mail-pw');
  _login(team, 'Bank', {
    'URL': 'https://bank.example',
    'KP2A_URL_1': 'androidapp://com.example.bank',
  }, password: 'demo-bank-pw');
  _login(team, 'Chat', {
    'KP2A_URL_1': 'androidapp://com.example.chat',
  }, password: 'demo-chat-pw');
  _login(team, 'Hidden', {
    'URL': 'https://mail.example.com',
    'tsm.urlMatch': 'never',
  });
  final fleet = DemoVaults.vault(
    'fleet',
    demo.systemCredentials,
    const {},
    kind: TomSecretsVaultKind.system,
  );
  _login(fleet, 'Fleet mail', {
    'URL': 'https://mail.example.com',
    'KP2A_URL_1': 'androidapp://com.example.bank',
  }, password: 'demo-fleet-pw');
  return (team, fleet);
}

/// The bank's site lists the bank app with the demo certificate.
const _bankCert =
    '14:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:'
    '8A:04:96:B2:3F:CF:44:E5';

http.Client _assetLinks() => MockClient((request) async {
  if (request.url.host == 'bank.example' &&
      request.url.path == '/.well-known/assetlinks.json') {
    return http.Response(
      jsonEncode([
        {
          'relation': ['delegate_permission/common.get_login_creds'],
          'target': {
            'namespace': 'android_app',
            'package_name': 'com.example.bank',
            'sha256_cert_fingerprints': [_bankCert],
          },
        },
      ]),
      200,
    );
  }
  return http.Response('not found', 404);
});

void main() {
  group('matching', () {
    late List<TomSecretsStore> stores;

    setUp(() {
      final demo = DemoVaults(FakeGitHubServer());
      final (team, fleet) = _vaults(demo);
      stores = [
        TomSecretsStore.fromFile(team, name: 'team'),
        TomSecretsStore.fromFile(fleet, name: 'fleet'),
      ];
    });

    test('a browser\'s page by the browser\'s rules, an app by its package; '
        'never a system vault\'s, never the rule never', () {
      final web = tomSecretsAutofillLogins(
        stores,
        const TomSecretsAutofillRequest(
          packageName: 'com.android.chrome',
          webDomain: 'www.example.com',
        ),
      );
      // mail.example.com's login matches example.com's subdomain www by
      // the registrable domain.
      expect([for (final l in web) l.title], ['Mail']);
      expect(web.single.byPackage, isFalse);
      expect(web.single.password, 'demo-mail-pw');
      expect(web.single.entryId, startsWith('team/~'));

      final app = tomSecretsAutofillLogins(
        stores,
        const TomSecretsAutofillRequest(packageName: 'com.example.bank'),
      );
      expect([for (final l in app) l.title], ['Bank']);
      expect(app.single.byPackage, isTrue);
      expect(app.single.webHost, 'bank.example');
      expect(app.single.label, 'Bank (demo-user) · unverified app');

      expect(
        tomSecretsAutofillLogins(
          stores,
          const TomSecretsAutofillRequest(packageName: 'com.example.other'),
        ),
        isEmpty,
      );
    });

    test('Digital Asset Links verify a package match by the app\'s '
        'certificate; another certificate, no links or an entry without a '
        'web URL stay unverified', () async {
      final links = TomSecretsAssetLinks(client: _assetLinks());
      Future<List<TomSecretsAutofillLogin>> check(
        String package,
        List<String> certificates,
      ) {
        final request = TomSecretsAutofillRequest(
          packageName: package,
          certificates: certificates,
        );
        return links.check(tomSecretsAutofillLogins(stores, request), request);
      }

      final verified = await check('com.example.bank', [
        _bankCert.toLowerCase(),
      ]);
      expect(verified.single.verified, isTrue);
      expect(verified.single.label, 'Bank (demo-user)');
      final other = await check('com.example.bank', ['AA:BB']);
      expect(other.single.verified, isFalse);
      final chat = await check('com.example.chat', [_bankCert]);
      expect(chat.single.webHost, isNull);
      expect(chat.single.label, endsWith('unverified app'));
    });

    test('the running app answers state and logins; locked, nothing', () async {
      var open = true;
      final responder = TomSecretsAutofillResponder(
        stores: () => open ? stores : null,
        links: TomSecretsAssetLinks(client: _assetLinks()),
      );
      expect(await responder.handle('state', null), {'unlocked': true});
      final logins = await responder.handle('logins', {
        'packageName': 'com.android.chrome',
        'webDomain': 'mail.example.com',
        'webScheme': 'https',
        'certificates': <String>[],
      });
      expect(logins, [
        {
          'entryId': (logins! as List).cast<Map>().single['entryId'],
          'label': 'Mail (demo-user)',
          'userName': 'demo-user',
          'password': 'demo-mail-pw',
        },
      ]);
      open = false;
      expect(await responder.handle('state', null), {'unlocked': false});
      expect(
        await responder.handle('logins', {'packageName': 'com.example.bank'}),
        isEmpty,
      );
    });
  });

  group('the app', () {
    late FakeGitHubServer server;
    late DemoVaults demo;
    late TomInMemorySecretStore keychain;
    late TomSecretsMemoryPreferences preferences;

    setUp(() async {
      server = FakeGitHubServer();
      demo = DemoVaults(server);
      await demo.seed();
      final (team, fleet) = _vaults(demo);
      await demo.put(demoTeam, team);
      await demo.put(demoSystem, fleet);
      keychain = TomInMemorySecretStore();
      await demo.fillKeychain(keychain);
      preferences = TomSecretsMemoryPreferences();
      // Set up as a pairing leaves it.
      await preferences.write(TomSecretsMobileKeys.primary, demoPrimary);
      await preferences.write(TomSecretsMobileKeys.device, 'pixel');
    });

    Widget app({
      TomSecretsAutofillPlatform? autofill,
      TomSecretsAutofillUnlockPlatform? unlock,
    }) => TomSecretsMobileApp(
      profileExpiry: () async => null,
      preferences: preferences,
      keychain: keychain,
      platform: 'android',
      clipboard: _Clipboard(),
      httpClient: server.client,
      githubBaseUrl: FakeGitHubServer.baseUrl,
      autofill: autofill,
      autofillUnlock: unlock,
      assetLinks: TomSecretsAssetLinks(client: _assetLinks()),
    );

    Future<void> wait(WidgetTester tester, [int rounds = 4]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
    }

    Future<void> unlock(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('tsm-unlock-passphrase')),
        demoPassword,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-unlock')));
      await wait(tester, 14);
    }

    testWidgets('the running app answers the service from its memory once '
        'unlocked; a login the service saw submitted waits for the unlock '
        'and becomes a proposal; Settings turns the service on', (
      tester,
    ) async {
      final platform = _Platform()
        ..proposal = {
          'url': 'androidapp://com.example.shop',
          'title': 'Shop',
          'userName': 'demo-shopper',
          'password': 'demo-shop-pw',
        };
      await tester.pumpWidget(app(autofill: platform));
      await wait(tester, 2);
      final handler = platform.handler!;
      expect(await handler('state', null), {'unlocked': false});
      expect(find.byKey(const Key('tsm-mobile-proposals')), findsNothing);

      await unlock(tester);
      expect(await handler('state', null), {'unlocked': true});
      final logins = await tester.runAsync(
        () => handler('logins', {
          'packageName': 'com.android.chrome',
          'webDomain': 'mail.example.com',
        }),
      );
      expect(
        [for (final l in (logins! as List).cast<Map>()) l['label']],
        ['Mail (demo-user)'],
      );
      // The system vault's login of the same site is not offered.
      expect(jsonEncode(logins), isNot(contains('demo-fleet-pw')));

      await wait(tester);
      expect(find.byKey(const Key('tsm-mobile-proposals')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-mobile-proposals-open')));
      await wait(tester);
      expect(find.byType(TomSecretsProposalsView), findsOneWidget);
      expect(find.text('User name: demo-shopper'), findsOneWidget);
      await tester.pageBack();
      await wait(tester);

      // A later one, pushed while the app runs.
      await handler('proposal', {
        'url': 'https://news.example/',
        'title': 'news.example',
        'userName': 'demo-reader',
        'password': 'demo-news-pw',
      });
      await wait(tester);
      expect(find.text('2 logins to save'), findsOneWidget);

      await tester.tap(find.text('Settings'));
      await wait(tester);
      expect(find.byKey(const Key('tsm-mobile-autofill')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-mobile-autofill-on')));
      await wait(tester);
      expect(platform.settingsOpened, 1);
      expect(find.byKey(const Key('tsm-mobile-autofill-on')), findsNothing);
    });

    testWidgets('as the service\'s own unlock: the vaults fetched and '
        'opened, the app\'s logins checked and handed back', (tester) async {
      final asked = _Unlock(
        const TomSecretsAutofillRequest(
          packageName: 'com.example.bank',
          certificates: [_bankCert],
        ),
      );
      await tester.pumpWidget(app(unlock: asked));
      await wait(tester, 2);
      expect(find.byKey(const Key('tsm-autofill-unlock-cancel')), findsOne);
      await unlock(tester);
      await wait(tester, 4);
      expect(asked.handed, isNotNull);
      expect(asked.handed!.single.title, 'Bank');
      expect(asked.handed!.single.verified, isTrue);
      expect(asked.handed!.single.password, 'demo-bank-pw');
    });

    testWidgets('no login for the request is said, Close ends it; a phone '
        'not set up is told so; Cancel at the unlock', (tester) async {
      final none = _Unlock(
        const TomSecretsAutofillRequest(packageName: 'com.example.other'),
      );
      await tester.pumpWidget(app(unlock: none));
      await wait(tester, 2);
      await unlock(tester);
      await wait(tester, 4);
      expect(none.handed, isNull);
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-autofill-message'))).data,
        contains('No login for com.example.other'),
      );
      await tester.tap(find.byKey(const Key('tsm-autofill-close')));
      await wait(tester, 1);
      expect(none.cancelled, 1);
    });

    testWidgets('a phone not set up; Cancel at the unlock', (tester) async {
      await preferences.write(TomSecretsMobileKeys.primary, null);
      final notSetUp = _Unlock(
        const TomSecretsAutofillRequest(packageName: 'com.example.bank'),
      );
      await tester.pumpWidget(app(unlock: notSetUp));
      await wait(tester, 2);
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-autofill-message'))).data,
        contains('Set Tom Secrets Manager up first'),
      );
      await tester.tap(find.byKey(const Key('tsm-autofill-close')));
      await wait(tester, 1);
      expect(notSetUp.cancelled, 1);

      await preferences.write(TomSecretsMobileKeys.primary, demoPrimary);
      final cancelled = _Unlock(
        const TomSecretsAutofillRequest(packageName: 'com.example.bank'),
      );
      // A new app (its State reads the setup again).
      await tester.pumpWidget(
        KeyedSubtree(
          key: UniqueKey(),
          child: app(unlock: cancelled),
        ),
      );
      await wait(tester, 2);
      await tester.tap(find.byKey(const Key('tsm-autofill-unlock-cancel')));
      await wait(tester, 1);
      expect(cancelled.cancelled, 1);
    });
  });
}
