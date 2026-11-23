// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** Android's Credential Manager provider, the Dart side
/// (part-os-integration, DP-120): the caller checked (a browser's origin
/// within the relying party, an app by the site's Digital Asset Links), the
/// client data an app gets, a sign-in signed with the passkey picked, a new
/// passkey made with the site's algorithm and refused when the site
/// excludes one held, never a system vault's passkey; the running app
/// answering and keeping a new passkey in the vault of the site's login on
/// GitHub, the identities handed to the provider; the app as the
/// provider's own unlock, a refusal said. Demo keys only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
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
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsMemoryPreferences;

import 'support/demo_vaults.dart';

final class _Clipboard implements TomClipboardPort {
  @override
  Future<TomClipboardReceipt?> placeConcealed(String text) async =>
      TomClipboardReceipt(text);

  @override
  Future<bool> clearIfHolding(TomClipboardReceipt receipt) async => true;
}

/// The running app's side of the services, recorded.
final class _Platform implements TomSecretsAutofillPlatform {
  Future<Object?> Function(String method, Object? arguments)? handler;
  final identities = <List<Map<String, Object?>>>[];

  @override
  void setHandler(
    Future<Object?> Function(String method, Object? arguments)? h,
  ) => handler = h;

  @override
  Future<Map<String, Object?>?> takeProposal() async => null;

  @override
  Future<bool?> serviceEnabled() async => true;

  @override
  Future<void> openSettings() async {}

  @override
  Future<void> setPasskeyIdentities(
    List<Map<String, Object?>> identities,
  ) async => this.identities.add(identities);
}

/// The passkey unlock activity's side, recorded.
final class _Unlock implements TomSecretsPasskeyUnlockPlatform {
  _Unlock(this.asked);

  final TomSecretsPasskeyRequest asked;
  Map<String, Object?>? answer;
  TomSecretsPasskeyRefusal? failed;

  @override
  Future<TomSecretsPasskeyRequest> request() async => asked;

  @override
  Future<void> done(Map<String, Object?> a) async => answer = a;

  @override
  Future<void> fail(TomSecretsPasskeyRefusal error) async => failed = error;

  @override
  Future<void> cancel() async {}
}

/// The bank app's demo signing certificate, which bank.example lists.
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

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

final _challenge = _b64(utf8.encode('demo-challenge'));

/// A creation for bank.example by [origin] (a browser) or the bank app.
TomSecretsPasskeyRequest _create({
  String? origin,
  List<int> algorithms = const [-7],
  List<String> exclude = const [],
}) => TomSecretsPasskeyRequest(
  kind: TomSecretsPasskeyRequestKind.create,
  options: {
    'challenge': _challenge,
    'rp': {'id': 'bank.example', 'name': 'Bank'},
    'user': {'id': _b64(utf8.encode('demo-user-handle')), 'name': 'demo-user'},
    'pubKeyCredParams': [
      for (final a in algorithms) {'type': 'public-key', 'alg': a},
    ],
    'excludeCredentials': [
      for (final id in exclude) {'type': 'public-key', 'id': id},
    ],
  },
  packageName: origin == null ? 'com.example.bank' : 'com.android.chrome',
  origin: origin,
  clientDataHash: origin == null
      ? null
      : Uint8List.fromList(List.filled(32, 7)),
  certificates: origin == null ? const [_bankCert] : const [],
);

/// A sign-in at [rpId] with [credentialId] picked.
TomSecretsPasskeyRequest _get(
  String rpId, {
  String? credentialId,
  String? origin,
  String packageName = 'com.example.bank',
  List<String> certificates = const [_bankCert],
  TomSecretsPasskeyRequestKind kind = TomSecretsPasskeyRequestKind.get,
}) => TomSecretsPasskeyRequest(
  kind: kind,
  options: {'challenge': _challenge, 'rpId': rpId},
  packageName: packageName,
  origin: origin,
  clientDataHash: origin == null
      ? null
      : Uint8List.fromList(List.filled(32, 9)),
  certificates: origin == null ? certificates : const [],
  credentialId: credentialId,
);

void main() {
  group('the answerer', () {
    final answerer = TomSecretsPasskeyAnswerer(
      links: TomSecretsAssetLinks(client: _assetLinks()),
    );
    late List<TomSecretsStore> stores;
    late TomSecretsPasskey teamKey;

    setUp(() async {
      final team = DemoVaults.vault(
        'team',
        Credentials(ProtectedValue.fromString('team-pw')),
        const {},
      );
      final fleet = DemoVaults.vault(
        'fleet',
        Credentials(ProtectedValue.fromString('sys-pw')),
        const {},
        kind: TomSecretsVaultKind.system,
      );
      teamKey = (await tomSecretsCreatePasskey(
        rpId: 'bank.example',
        userHandle: Uint8List.fromList(utf8.encode('demo-user-handle')),
        userName: 'demo-user',
      )).passkey;
      tomSecretsKeepPasskey(team, teamKey);
      tomSecretsKeepPasskey(
        fleet,
        (await tomSecretsCreatePasskey(
          rpId: 'bank.example',
          userHandle: Uint8List.fromList(utf8.encode('fleet')),
          userName: 'fleet-user',
        )).passkey,
      );
      stores = [
        TomSecretsStore.fromFile(team, name: 'team'),
        TomSecretsStore.fromFile(fleet, name: 'fleet'),
      ];
    });

    test('the caller: a browser within the relying party over https, an app '
        'by the Digital Asset Links, with the client data naming it', () async {
      expect(
        await answerer.callerOrigin(
          _get('bank.example', origin: 'https://login.bank.example'),
        ),
        'https://login.bank.example',
      );
      for (final origin in [
        'https://evil.example',
        'http://bank.example',
        'https://notbank.example',
      ]) {
        await expectLater(
          answerer.callerOrigin(_get('bank.example', origin: origin)),
          throwsA(
            isA<TomSecretsPasskeyRefusal>().having(
              (e) => e.error,
              'error',
              TomSecretsPasskeyError.notAllowed,
            ),
          ),
        );
      }
      final certificate = [
        for (final h in _bankCert.split(':')) int.parse(h, radix: 16),
      ];
      expect(
        await answerer.callerOrigin(_get('bank.example')),
        'android:apk-key-hash:${_b64(certificate)}',
      );
      await expectLater(
        answerer.callerOrigin(
          _get('bank.example', packageName: 'com.example.other'),
        ),
        throwsA(isA<TomSecretsPasskeyRefusal>()),
      );
      await expectLater(
        answerer.callerOrigin(_get('bank.example', certificates: const [])),
        throwsA(isA<TomSecretsPasskeyRefusal>()),
      );

      // An app gets the client data the provider made, its hash signed.
      final data = await answerer.clientData(
        _get('bank.example'),
        'webauthn.get',
      );
      final json = jsonDecode(utf8.decode(data.json!)) as Map;
      expect(json['type'], 'webauthn.get');
      expect(json['challenge'], _challenge);
      expect(json['androidPackageName'], 'com.example.bank');
      expect(data.hash, crypto.sha256.convert(data.json!).bytes);
      // A browser's hash is taken as it came.
      final browser = await answerer.clientData(
        _get('bank.example', origin: 'https://bank.example'),
        'webauthn.get',
      );
      expect(browser.json, isNull);
      expect(browser.hash, List.filled(32, 9));
    });

    test('a sign-in with the passkey picked; never a system vault\'s; the '
        'entries and the identities', () async {
      final answer = await answerer.answer(
        _get('bank.example', credentialId: teamKey.credentialId),
        stores,
        (_) async => fail('nothing is kept'),
      );
      final response =
          (jsonDecode(answer['json']! as String) as Map)['response'];
      final data = tomSecretsDecodeBase64(
        (response as Map)['authenticatorData'] as String,
      );
      expect(data.sublist(0, 32), tomSecretsRpIdHash('bank.example'));
      expect(
        jsonDecode(
          utf8.decode(
            tomSecretsDecodeBase64(response['clientDataJSON'] as String),
          ),
        )['origin'],
        startsWith('android:apk-key-hash:'),
      );
      expect(response['userHandle'], _b64(utf8.encode('demo-user-handle')));
      final identities = (answer['identities']! as List).cast<Map>();
      expect([for (final i in identities) i['userName']], ['demo-user']);
      expect(jsonEncode(identities), isNot(contains('PRIVATE KEY')));

      final entries = await answerer.answer(
        _get('bank.example', kind: TomSecretsPasskeyRequestKind.entries),
        stores,
        (_) async {},
      );
      expect(
        [
          for (final e in (entries['entries']! as List).cast<Map>())
            e['entryId'],
        ],
        [startsWith('team/~')],
      );

      // Nothing for another site, nor through a credential not held.
      expect(
        (await answerer.answer(
          _get('bank.example', credentialId: 'bm90LWhlbGQ'),
          stores,
          (_) async {},
        ))['error'],
        'notAllowed',
      );
      expect(
        (await answerer.answer(_get('bank.example'), null, (_) async {})),
        {'locked': true},
      );
    });

    test('a new passkey with the site\'s algorithm, kept; refused when the '
        'site excludes one held or offers nothing made here', () async {
      TomSecretsPasskey? kept;
      final made = await answerer.answer(
        _create(origin: 'https://bank.example', algorithms: const [-257, -8]),
        stores,
        (p) async => kept = p,
      );
      expect(kept!.relyingParty, 'bank.example');
      expect(kept!.userName, 'demo-user');
      final response = (jsonDecode(made['json']! as String) as Map)['response'];
      expect((response as Map)['publicKeyAlgorithm'], -8);
      expect([
        for (final i in (made['identities']! as List).cast<Map>())
          i['credentialId'],
      ], contains(tomSecretsBase64Url(kept!.credentialId)));

      expect(
        (await answerer.answer(
          _create(exclude: [teamKey.credentialId]),
          stores,
          (_) async => fail('nothing is kept'),
        ))['error'],
        'invalidState',
      );
      expect(
        (await answerer.answer(
          _create(algorithms: const [-257]),
          stores,
          (_) async => fail('nothing is kept'),
        ))['error'],
        'notSupported',
      );
      expect(
        (await answerer.answer(
          _create(),
          stores,
          (_) async => throw StateError('demo: not writable'),
        ))['error'],
        'unknown',
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
      final team = DemoVaults.vault('team', demo.teamCredentials, const {});
      team.body.rootGroup.addEntry(
        KdbxEntry.create(team, team.body.rootGroup)
          ..setString(KdbxKeyCommon.TITLE, PlainValue('Bank'))
          ..setString(KdbxKeyCommon.URL, PlainValue('https://bank.example'))
          ..setString(KdbxKeyCommon.USER_NAME, PlainValue('demo-user')),
      );
      await demo.put(demoTeam, team);
      keychain = TomInMemorySecretStore();
      await demo.fillKeychain(keychain);
      preferences = TomSecretsMemoryPreferences();
      await preferences.write(TomSecretsMobileKeys.primary, demoPrimary);
      await preferences.write(TomSecretsMobileKeys.device, 'pixel');
    });

    Widget app({
      TomSecretsAutofillPlatform? autofill,
      TomSecretsPasskeyUnlockPlatform? unlock,
    }) => TomSecretsMobileApp(
      profileExpiry: () async => null,
      preferences: preferences,
      keychain: keychain,
      platform: 'android',
      clipboard: _Clipboard(),
      httpClient: server.client,
      githubBaseUrl: FakeGitHubServer.baseUrl,
      autofill: autofill,
      passkeyUnlock: unlock,
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

    testWidgets('the running app makes a passkey, keeps it in the bank '
        'login\'s vault on GitHub, signs in with it, and hands the '
        'identities to the provider', (tester) async {
      final platform = _Platform();
      await tester.pumpWidget(app(autofill: platform));
      await wait(tester, 2);
      final handler = platform.handler!;
      expect(
        await handler('passkey', {
          'kind': 'get',
          'requestJson': jsonEncode({'rpId': 'bank.example'}),
          'packageName': 'com.example.bank',
        }),
        {'locked': true},
      );
      await unlock(tester);

      // Answered while the test pumps: the save runs on the engine's queue.
      Future<Map> answer(Map<String, Object?> request) async {
        Map? got;
        unawaited(handler('passkey', request).then((a) => got = a! as Map));
        // The GitHub client spaces its writes on timers.
        for (var i = 0; i < 200 && got == null; i++) {
          await wait(tester, 1);
          await tester.pump(const Duration(milliseconds: 500));
        }
        return got!;
      }

      final made = await answer({
        'kind': 'create',
        'requestJson': jsonEncode(_create().options),
        'packageName': 'com.example.bank',
        'certificates': [_bankCert],
      });
      expect(made['error'], isNull, reason: '$made');
      await wait(tester, 6);
      final onGitHub = await tester.runAsync(
        () => demo.fetch(demoTeam, demo.teamCredentials),
      );
      final kept = tomSecretsPasskeysIn(onGitHub!).single;
      expect(kept.entry.label, 'Bank');
      expect(kept.passkey.userName, 'demo-user');
      expect(
        platform.identities.last.map((i) => i['credentialId']),
        contains(kept.passkey.credentialId),
      );

      final signed = await answer({
        'kind': 'get',
        'requestJson': jsonEncode({
          'challenge': _challenge,
          'rpId': 'bank.example',
        }),
        'packageName': 'com.example.bank',
        'certificates': [_bankCert],
        'credentialId': kept.passkey.credentialId,
      });
      expect(
        jsonDecode(signed['json']! as String)['id'],
        kept.passkey.credentialId,
      );
    });

    testWidgets('as the provider\'s own unlock: the vaults fetched, the new '
        'passkey kept on GitHub and answered', (tester) async {
      final asked = _Unlock(_create());
      await tester.pumpWidget(app(unlock: asked));
      await wait(tester, 2);
      expect(find.byKey(const Key('tsm-autofill-unlock-cancel')), findsOne);
      await unlock(tester);
      for (var i = 0; i < 200 && asked.answer == null; i++) {
        await wait(tester, 1);
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(asked.answer?['json'], isA<String>(), reason: '${asked.answer}');
      final onGitHub = await tester.runAsync(
        () => demo.fetch(demoTeam, demo.teamCredentials),
      );
      expect(tomSecretsPasskeysIn(onGitHub!), hasLength(1));
    });

    testWidgets('a refusal is said; Close ends it', (tester) async {
      final asked = _Unlock(
        _get('bank.example', packageName: 'com.example.other'),
      );
      await tester.pumpWidget(app(unlock: asked));
      await wait(tester, 2);
      await unlock(tester);
      await wait(tester, 4);
      expect(asked.answer, isNull);
      expect(
        tester.widget<Text>(find.byKey(const Key('tsm-autofill-message'))).data,
        contains('com.example.other'),
      );
      await tester.tap(find.byKey(const Key('tsm-autofill-close')));
      await wait(tester, 1);
      expect(asked.failed?.error, TomSecretsPasskeyError.notAllowed);
    });
  });
}
