// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The mobile app's screenshots for its user guide (`doc/images/`): the app
/// over a fake GitHub and demo vaults, at the real fonts. The vaults on a
/// phone (390×844) and a tablet (1024×1366) in the light and the dark
/// theme; every other screen and state in the light theme on a phone (the
/// setup, the unlock and its refusals, the vaults with their banners, the
/// entries, search, the generator, settings, health, shares, proposals,
/// conflicts, the Autofill service's and the passkey provider's unlock),
/// and the two panes of a small tablet (820×1180). Each shot drives the app
/// the way the app tests do (the same keys and fakes). Runs only with
/// `flutter test --tags screenshots --update-goldens`, which writes the
/// files; a normal run skips it. Demo data only: the repository, hosts and
/// people are made up, no request leaves the test.
@Tags(['screenshots'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_kdbx_store/tom_kdbx_store.dart'
    show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/screenshots.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import '../support/demo_vaults.dart';
import '../support/fake_documents.dart';
import '../support/net_switch.dart';

/// Where the mobile guide keeps its images, from this file.
const _images = '../../doc/images';

/// Whether this run leaves the screenshots out.
final bool _skip = tomSecretsScreenshotsSkip(autoUpdateGoldenFiles) != null;

/// A screenshot test: skipped unless the run writes the goldens.
void _shot(String description, WidgetTesterCallback body) =>
    testWidgets(description, body, skip: _skip);

/// The demo repository the screenshots show.
const _owner = 'demo-org';
const _name = 'vaults';
const _repo = '$_owner/$_name';
const _primary = 'github:$_repo/primary.kdbx';
const _team = 'github:$_repo/team.kdbx';
const _fleet = 'github:$_repo/fleet.kdbx';
const _crew = 'github:$_repo/shared/crew.kdbx';
const _crewKeys = 'github:$_repo/shared/crew.keys.age';
const _token = 'demo-phone-token';

/// The demo vaults' own passwords (listed in the primary).
const _teamPassword = 'demo-Team-vault-7#qK2m';
const _fleetPassword = 'demo-Fleet-vault-4!xR8p';
final _teamCredentials = Credentials(ProtectedValue.fromString(_teamPassword));
final _fleetCredentials = Credentials(
  ProtectedValue.fromString(_fleetPassword),
);

/// A new vault [name] (its metadata written), with Argon2id of [memory]
/// bytes (the demo's light 1 MiB by default).
KdbxFile _vault(
  String name,
  Credentials credentials, {
  TomSecretsVaultKind kind = TomSecretsVaultKind.personal,
  int memory = 1 << 20,
}) {
  final file = tomSecretsNewVault(
    credentials,
    name,
    argon2: KdbxArgon2(
      type: KdbxArgon2Type.argon2id,
      memory: memory,
      iterations: 1,
    ),
  );
  TomSecretsMetadata(store: name, kind: kind).writeTo(file);
  return file;
}

/// The password the health report finds in a breach.
const _breached = 'letmein1';

/// A demo TOTP secret (RFC 4648's example).
const _otp =
    'otpauth://totp/Mail:demo%40example.org?secret=JBSWY3DPEHPK3PXP'
    '&issuer=Mail';

/// A breach check that finds [breached] (when given) and nothing else; no
/// request leaves the test.
TomSecretsBreachCheck _breachCheck({String? breached}) => TomSecretsBreachCheck(
  client: MockClient((request) async {
    final prefix = request.url.pathSegments.last;
    final hash = breached == null ? null : tomSecretsPasswordHash(breached);
    return http.Response(
      hash != null && prefix == hash.substring(0, 5)
          ? '${hash.substring(5)}:99\r\n'
                'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0'
          : 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0',
      200,
    );
  }),
);

/// Digital Asset Links that list nothing (no request leaves the test).
TomSecretsAssetLinks _noLinks() => TomSecretsAssetLinks(
  client: MockClient((_) async => http.Response('not found', 404)),
);

/// GitHub refusing every request: the token was revoked.
http.Client _refusingGitHub() => MockClient(
  (_) async => http.Response(
    jsonEncode({'message': 'Bad credentials'}),
    401,
    headers: {'content-type': 'application/json'},
  ),
);

/// Adds a login to [file]'s root group.
KdbxEntry _entry(
  KdbxFile file,
  String title, {
  String user = '',
  required String password,
  String url = '',
  String notes = '',
  Map<String, String> fields = const {},
  ({String name, Uint8List bytes})? attachment,
  DateTime? expires,
}) {
  final entry = KdbxEntry.create(file, file.body.rootGroup)
    ..setString(KdbxKeyCommon.TITLE, PlainValue(title))
    ..setString(KdbxKeyCommon.USER_NAME, PlainValue(user))
    ..setString(KdbxKeyCommon.PASSWORD, ProtectedValue.fromString(password))
    ..setString(KdbxKeyCommon.URL, PlainValue(url))
    ..setString(KdbxKeyCommon.NOTES, PlainValue(notes));
  for (final MapEntry(:key, :value) in fields.entries) {
    entry.setString(KdbxKey(key), PlainValue(value));
  }
  if (attachment != null) {
    entry.createBinary(
      isProtected: false,
      name: attachment.name,
      bytes: attachment.bytes,
    );
  }
  if (expires != null) {
    entry.times.expires.set(true);
    entry.times.expiryTime.set(expires.toUtc());
  }
  file.body.rootGroup.addEntry(entry);
  return entry;
}

/// [stored] (the team vault) with `Shop` changed (Password, Notes) and a
/// conflict record naming the older version, as a merge leaves it.
Future<Uint8List> _withConflict(
  Uint8List stored,
  Credentials credentials,
) async {
  final edited = await KdbxFormat().read(stored, credentials);
  KdbxEntry shop(KdbxFile f) =>
      f.body.rootGroup.getAllEntries().firstWhere((e) => e.label == 'Shop');
  shop(edited)
    ..setString(
      KdbxKeyCommon.PASSWORD,
      ProtectedValue.fromString('Winter2026!'),
    )
    ..setString(KdbxKeyCommon.NOTES, PlainValue('Changed on the tablet.'));
  // Read back, so the record names the history version's stored time.
  final file = await KdbxFormat().read(await edited.save(), credentials);
  final entry = shop(file);
  entry.customData[tomSecretsConflictKey] = jsonEncode([
    TomSecretsEntryConflict(
      entryUuid: entry.uuid.uuid,
      fields: const ['field:Notes', 'field:Password'],
      loserModified: entry.history.last.times.lastModificationTime.get()!,
      at: DateTime.utc(2026, 11, 13),
    ).toJson(),
  ]);
  return file.save();
}

/// The demo vaults on a fake GitHub: a primary (with the key file from the
/// pairing) listing a personal vault `team` of logins and a system vault
/// `fleet`; with [conflict] a merge's conflict in `team`; with [phone] a
/// shared vault `crew` for the phone and Bob, and a share from Bob in the
/// phone's inbox.
Future<void> _seed(
  DemoVaults demo, {
  bool conflict = false,
  int primaryArgon2Memory = 1 << 20,
  TomSecretsMemberKey? phone,
  TomSecretsMemberKey? bob,
}) async {
  demo.server.repo(_repo);
  final primary = _vault(
    'primary',
    demo.primaryCredentials,
    memory: primaryArgon2Memory,
  );
  _entry(
    primary,
    'Router',
    user: 'admin',
    password: 'demo-router-Pw9!',
    url: 'https://192.168.1.1',
  );
  TomSecretsPrimaryVaults(primary, primaryLocator: _primary)
    ..put(
      TomSecretsVaultKeys(
        name: 'team',
        locator: _team,
        password: _teamPassword,
      ),
    )
    ..put(
      TomSecretsVaultKeys(
        name: 'fleet',
        locator: _fleet,
        password: _fleetPassword,
      ),
    );

  final team = _vault('team', _teamCredentials);
  _entry(
    team,
    'Mail',
    user: 'demo@example.org',
    password: 'pX7#vR2!mQ9@kL4z',
    url: 'https://mail.example.org',
    notes: 'The demo mailbox. Recovery codes attached.',
    fields: {'otp': _otp},
    attachment: (
      name: 'recovery-codes.txt',
      bytes: Uint8List.fromList(
        utf8.encode('1. demo-1111-2222\n2. demo-3333-4444\n'),
      ),
    ),
  );
  _entry(
    team,
    'Bank',
    user: 'demo-user',
    password: _breached,
    url: 'https://bank.example.org',
  );
  _entry(
    team,
    'Shop',
    user: 'demo-shopper',
    password: 'Summer2026!',
    url: 'https://shop.example.org',
  );
  _entry(
    team,
    'Forum',
    user: 'demo',
    password: 'Summer2026!',
    url: 'https://forum.example.org',
  );
  _entry(
    team,
    'Cloud API',
    password: 'demo-api-token-0000',
    fields: {'tsm.type': 'api-token'},
    expires: DateTime.now().add(const Duration(days: 10)),
  );
  _entry(team, 'Wi-Fi', password: 'demo-wifi-pass', notes: 'Guest network.');

  final fleet = _vault(
    'fleet',
    _fleetCredentials,
    kind: TomSecretsVaultKind.system,
  );
  _entry(
    fleet,
    'Db',
    user: 'app',
    password: 'demo-db-8\$Lm3#Qz9vT2',
    url: 'postgres://db.example.org',
  );

  if (phone != null && bob != null) {
    final keys = TomSecretsSharedVaultKeys.generate(
      'crew',
      members: [
        (name: 'Me', recipient: phone.recipient),
        (name: 'Bob', recipient: bob.recipient),
      ],
    );
    tomSecretsAddMemberKey(primary, phone);
    TomSecretsPrimaryVaults(primary, primaryLocator: _primary).put(
      TomSecretsVaultKeys(name: 'crew', locator: _crew, keyFile: keys.keyFile),
    );
    final crew = tomSecretsNewSharedVault('crew', keys);
    _entry(crew, 'Office door', password: 'demo-2468');
    await demo.put(_crew, crew);
    await demo.putBytes(_crewKeys, await tomSecretsWriteRecipientsFile(keys));
    final share = await tomSecretsWriteShare(
      TomSecretsShare(
        created: DateTime.utc(2026, 11, 20),
        from: (name: 'Bob', fingerprint: bob.recipient.fingerprint),
        entries: const [
          TomSecretsSharedEntry(
            fields: {
              'Title': (value: 'Door code', protected: false),
              'Password': (value: 'demo-4711', protected: true),
            },
          ),
        ],
      ),
      recipients: [phone.recipient],
    );
    await demo.putBytes(
      'github:$_repo/shared/inbox/${phone.recipient.fingerprint}/'
      '${tomSecretsNewInboxName()}',
      share,
    );
  }

  await demo.put(_primary, primary);
  final teamBytes = await team.save();
  await demo.putBytes(
    _team,
    conflict ? await _withConflict(teamBytes, _teamCredentials) : teamBytes,
  );
  await demo.put(_fleet, fleet);
}

/// The camera, which reads nothing in the shots.
final class _Scanner implements TomSecretsCodeScanner {
  @override
  Future<String?> scan(BuildContext context, {required String title}) async =>
      null;
}

/// mDNS, which finds nothing in the shots.
final class _Discovery implements TomSecretsPairingDiscovery {
  @override
  Future<TomSecretsPairingAdvertising> advertise(
    TomSecretsPairingAdvert advert,
  ) => throw UnsupportedError('a phone does not give');

  @override
  Future<List<TomSecretsPairingAdvert>> browse({
    Duration timeout = const Duration(seconds: 4),
  }) async => const [];
}

/// The Android Autofill service's side of the running app.
final class _Autofill implements TomSecretsAutofillPlatform {
  _Autofill({this.proposal});

  Map<String, Object?>? proposal;

  @override
  void setHandler(
    Future<Object?> Function(String method, Object? arguments)? handler,
  ) {}

  @override
  Future<Map<String, Object?>?> takeProposal() async {
    final p = proposal;
    proposal = null;
    return p;
  }

  /// Whether the service is the device's.
  bool enabled = false;

  @override
  Future<bool?> serviceEnabled() async => enabled;

  @override
  Future<void> openSettings() async => enabled = true;

  @override
  Future<void> setPasskeyIdentities(
    List<Map<String, Object?>> identities,
  ) async {}
}

/// The Autofill service's unlock activity, asking for [asked].
final class _AutofillUnlock implements TomSecretsAutofillUnlockPlatform {
  _AutofillUnlock(this.asked);

  final TomSecretsAutofillRequest asked;

  @override
  Future<TomSecretsAutofillRequest> request() async => asked;

  @override
  Future<void> done(List<TomSecretsAutofillLogin> logins) async {}

  @override
  Future<void> cancel() async {}
}

/// The passkey provider's unlock activity, asking for [asked].
final class _PasskeyUnlock implements TomSecretsPasskeyUnlockPlatform {
  _PasskeyUnlock(this.asked);

  final TomSecretsPasskeyRequest asked;

  @override
  Future<TomSecretsPasskeyRequest> request() async => asked;

  @override
  Future<void> done(Map<String, Object?> answer) async {}

  @override
  Future<void> fail(TomSecretsPasskeyRefusal error) async {}

  @override
  Future<void> cancel() async {}
}

void main() {
  late TomSecretsPairingPeerKeys giverKeys;
  late TomSecretsMemberKey phoneMember;
  late TomSecretsMemberKey bobMember;

  setUpAll(() async {
    await tomSecretsLoadScreenshotFonts();
    // The setup screen's app is not the shared one, which hides the banner.
    WidgetsApp.debugAllowBannerOverride = false;
    final giver = TomSecretsTrust.create('demo-desktop');
    giverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await giver.linkKey()).publicKey,
      approverKey: (await giver.approverKey()).publicKey,
    );
    phoneMember = await TomSecretsMemberKey.generate();
    bobMember = await TomSecretsMemberKey.generate();
  });
  tearDownAll(() {
    phoneMember.dispose();
    bobMember.dispose();
  });

  Future<void> wait(WidgetTester tester, [int rounds = 4]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  /// Until [finder] shows, while a save goes to GitHub: the GitHub client
  /// spaces its writes on a timer, so the fake clock moves too.
  Future<void> writing(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      await wait(tester, 1);
    }
  }

  void size(WidgetTester tester, Size size, [Brightness? theme]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue =
        theme ?? Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  /// A frame without the snack bars still on screen.
  void clearSnackBars(WidgetTester tester) {
    for (final m in tester.stateList<ScaffoldMessengerState>(
      find.byType(ScaffoldMessenger),
    )) {
      m.clearSnackBars();
    }
  }

  /// Settles and writes the light screenshot of [screen] in [state].
  Future<void> snap(WidgetTester tester, String screen, String state) async {
    await wait(tester, 3);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('tsm-screenshot')),
      matchesGoldenFile(
        '$_images/${tomSecretsScreenshotName(screen, state, Brightness.light)}',
      ),
    );
  }

  Future<void> scrollToTop(
    WidgetTester tester,
    Finder finder, {
    Finder? scrollable,
  }) async {
    if (scrollable != null) {
      await tester.scrollUntilVisible(finder, 200, scrollable: scrollable);
    } else {
      await tester.ensureVisible(finder);
    }
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(finder));
    await tester.pumpAndSettle();
  }

  /// The pairing as the desktop answers it: the primary with its key file
  /// and the phone's token for the repository.
  TomSecretsMobileReceive receiveFrom(DemoVaults demo) =>
      ({
        address,
        port,
        relay,
        relayToken,
        required code,
        required device,
      }) async => (
        giver: 'demo-desktop',
        bundle: TomSecretsPairingBundle(
          vaults: [
            TomSecretsPairingVault(
              name: 'primary',
              locator: _primary,
              primary: true,
              keyFile: demo.keyFile.toBytes(),
            ),
          ],
          giverKeys: giverKeys,
          tokens: const [
            TomSecretsPairingToken(repository: _repo, token: _token),
          ],
        ),
        ownTokens: const <String, String>{},
      );

  /// The app over the demo vaults, set up as a pairing leaves it unless
  /// [setUp] is false (the setup screen then).
  Future<
    ({
      DemoVaults demo,
      NetSwitch net,
      TomSecretsMemoryPreferences preferences,
      TomInMemoryGatedSecretStore gated,
      FakeDocuments documents,
    })
  >
  app(
    WidgetTester tester, {
    bool setUp = true,
    bool conflict = false,
    int primaryArgon2Memory = 1 << 20,
    bool shared = false,
    bool breach = false,
    String platform = 'android',
    String biometricLabel = 'Fingerprint',
    DateTime? profileExpiry,
    int kdfMemoryLimit = TomSecretsMobileEngine.defaultKdfMemoryLimit,
    http.Client? httpClient,
    TomSecretsAutofillPlatform? autofill,
    TomSecretsAutofillUnlockPlatform? autofillUnlock,
    TomSecretsPasskeyUnlockPlatform? passkeyUnlock,
    Future<void> Function(TomSecretsMemoryPreferences preferences)? prepare,
  }) async {
    final server = FakeGitHubServer();
    final demo = DemoVaults(server);
    await tester.runAsync(
      () => _seed(
        demo,
        conflict: conflict,
        primaryArgon2Memory: primaryArgon2Memory,
        phone: shared ? phoneMember : null,
        bob: shared ? bobMember : null,
      ),
    );
    final preferences = TomSecretsMemoryPreferences();
    final keychain = TomInMemorySecretStore();
    // The breach check runs at the unlock and says so; only the Health
    // shot wants it.
    if (!breach) {
      await preferences.write(
        TomSecretsHealthPreferenceKeys.breachCheck,
        'off',
      );
    }
    if (setUp) {
      await tester.runAsync(() async {
        await keychain.write(
          tomSecretsGitHubTokenHandle(_owner, _name),
          _token,
        );
        await keychain.write(
          TomSecretsVaultLocator.parse(_primary).keyFileHandle,
          base64.encode(demo.keyFile.toBytes()),
        );
      });
      await preferences.write(TomSecretsMobileKeys.primary, _primary);
      await preferences.write(TomSecretsMobileKeys.device, 'demo-phone');
    }
    await prepare?.call(preferences);
    final net = NetSwitch(server.client);
    final gated = TomInMemoryGatedSecretStore();
    final documents = FakeDocuments();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('tsm-screenshot'),
        child: TomSecretsMobileApp(
          profileExpiry: () async => profileExpiry,
          preferences: preferences,
          keychain: keychain,
          platform: platform,
          gated: gated,
          biometricLabel: biometricLabel,
          httpClient: httpClient ?? net,
          githubBaseUrl: FakeGitHubServer.baseUrl,
          ownAddresses: () async => [InternetAddress('10.8.0.6')],
          receive: receiveFrom(demo),
          scanner: _Scanner(),
          discovery: _Discovery(),
          documents: documents,
          kdfMemoryLimit: kdfMemoryLimit,
          autofill: autofill,
          autofillUnlock: autofillUnlock,
          passkeyUnlock: passkeyUnlock,
          assetLinks: _noLinks(),
          breachCheck: _breachCheck(breached: breach ? _breached : null),
        ),
      ),
    );
    await wait(tester, 2);
    return (
      demo: demo,
      net: net,
      preferences: preferences,
      gated: gated,
      documents: documents,
    );
  }

  Future<void> typePassword(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
  }

  Future<void> unlock(WidgetTester tester) async {
    await typePassword(tester);
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 14);
  }

  /// Pairs on the setup screen (the address typed, over the VPN).
  Future<void> pair(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-device')),
      'demo-phone',
    );
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-address')),
      '10.8.0.2:47900',
    );
    await tester.enterText(
      find.byKey(const Key('tsm-mobile-setup-code')),
      TomSecretsPairingCode.generate().toString(),
    );
    await tester.tap(find.byKey(const Key('tsm-mobile-setup-pair')));
    await wait(tester, 6);
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('tsm-mobile-tabs')),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEntry(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('tsm-mobile-vault-team')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('tsm-mobile-entry-$title')));
    await tester.pumpAndSettle();
    expect(find.byType(TomSecretsEntryEditor), findsOneWidget);
  }

  Finder editorScrollable() => find
      .descendant(
        of: find.byType(TomSecretsEntryEditor),
        matching: find.byType(Scrollable),
      )
      .first;

  // The vaults, in both themes, on a phone and a tablet: set up by a
  // pairing and unlocked.
  for (final (device, screen) in [
    ('phone', TomSecretsScreenshotSizes.phone),
    ('tablet', TomSecretsScreenshotSizes.tablet),
  ]) {
    for (final theme in Brightness.values) {
      _shot('the vaults on a $device (${theme.name})', (tester) async {
        size(tester, screen, theme);
        await app(tester, setUp: false);
        await pair(tester);
        await unlock(tester);
        // The phone lists the vaults; the tablet, wider than 900, shows the
        // desktop's three panes.
        expect(
          device == 'phone'
              ? find.byKey(const Key('tsm-mobile-vault-team'))
              : find.byType(TomSecretsVaultBrowser),
          findsOneWidget,
        );
        await expectLater(
          find.byKey(const Key('tsm-screenshot')),
          matchesGoldenFile(
            '$_images/${tomSecretsScreenshotName('vaults-$device', 'unlocked', theme)}',
          ),
        );
      });
    }
  }

  _shot('a small tablet: the entry list and the entry, a rail', (tester) async {
    size(tester, const Size(820, 1180));
    await app(tester);
    await unlock(tester);
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.byKey(const Key('tsm-mobile-entry-Mail')));
    await tester.pumpAndSettle();
    expect(find.byType(TomSecretsEntryEditor), findsOneWidget);
    await snap(tester, 'vaults-smalltablet', 'unlocked');
  });

  group('the setup', () {
    _shot('pairing with a desktop', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, setUp: false);
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-setup-device')),
        'demo-phone',
      );
      await snap(tester, 'setup', 'pair');
    });

    _shot('pairing through a relay', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, setUp: false);
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-setup-device')),
        'demo-phone',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-setup-code')),
        TomSecretsPairingCode(42, ['guitar', 'orbit']).text,
      );
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-setup-relay')),
        'tsm:https://relay.example.org',
      );
      await scrollToTop(
        tester,
        find.byKey(const Key('tsm-mobile-setup-device')),
      );
      await snap(tester, 'setup', 'relay');
    });

    _shot('set up by hand', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, setUp: false);
      await tester.tap(find.text('By hand'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-setup-device')),
        'demo-phone',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-setup-locator')),
        _primary,
      );
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-setup-token')),
        'github_pat_demo_phone',
      );
      await snap(tester, 'setup', 'hand');
    });
  });

  group('the unlock', () {
    _shot('the first unlock: the master password', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, setUp: false);
      await pair(tester);
      expect(find.byKey(const Key('tsm-unlock-passphrase')), findsOneWidget);
      await typePassword(tester);
      await snap(tester, 'unlock', 'password');
    });

    for (final (platform, label, state) in [
      ('android', 'Fingerprint', 'fingerprint'),
      ('ios', 'Face ID', 'faceid'),
    ]) {
      _shot('a later unlock offers $label', (tester) async {
        size(tester, TomSecretsScreenshotSizes.phone);
        final rig = await app(
          tester,
          platform: platform,
          biometricLabel: label,
        );
        await unlock(tester);
        // Locked, the screen asks at once; the prompt dismissed leaves the
        // button.
        rig.gated.nextFailure = TomGatedSecretErrorKind.cancelled;
        await tester.tap(find.byKey(const Key('tsm-mobile-lock')));
        await wait(tester, 8);
        expect(find.byKey(const Key('tsm-unlock-os')), findsOneWidget);
        await snap(tester, 'unlock', state);
      });
    }

    _shot('no connection', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      final rig = await app(tester);
      rig.net.down = true;
      await unlock(tester);
      expect(
        find.textContaining('tried again by itself when the network is back'),
        findsOneWidget,
      );
      await snap(tester, 'unlock', 'offline');
    });

    _shot('GitHub refused the token', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, httpClient: _refusingGitHub());
      await unlock(tester);
      expect(find.textContaining('GitHub refused'), findsOneWidget);
      await snap(tester, 'unlock', 'token-refused');
    });

    _shot('a vault too heavy for the device', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        primaryArgon2Memory: 32 << 20,
        kdfMemoryLimit: 16 << 20,
      );
      await unlock(tester);
      expect(find.textContaining('MiB of memory'), findsOneWidget);
      await snap(tester, 'unlock', 'memory');
    });
  });

  group('the vaults', () {
    _shot('the iOS build stops starting soon', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        platform: 'ios',
        biometricLabel: 'Face ID',
        profileExpiry: DateTime.now().add(const Duration(hours: 30)),
      );
      await unlock(tester);
      expect(find.byKey(const Key('tsm-mobile-reinstall')), findsOneWidget);
      await snap(tester, 'vaults', 'reinstall');
    });

    _shot('the GitHub token is due', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        prepare: (preferences) =>
            TomSecretsMobileSettings(preferences).setPairedTokenExpiries({
              _repo: DateTime.now().add(const Duration(days: 9)),
            }),
      );
      await unlock(tester);
      expect(find.byKey(const Key('tsm-reminder-banner')), findsOneWidget);
      await snap(tester, 'vaults', 'token-reminder');
    });

    _shot('a change not written to GitHub; the lock asks', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      final rig = await app(tester);
      await unlock(tester);
      await openEntry(tester, 'Wi-Fi');
      rig.net.down = true;
      await tester.enterText(
        find.byKey(const Key('tsm-field-notes')),
        'Guest network, new password from Monday.',
      );
      await tester.pump();
      await scrollToTop(
        tester,
        find.byKey(const Key('tsm-save-entry')),
        scrollable: editorScrollable(),
      );
      await tester.tap(find.byKey(const Key('tsm-save-entry')));
      await wait(tester, 6);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      final pending = find.textContaining('not written to GitHub');
      await writing(tester, pending);
      expect(pending, findsOneWidget);
      clearSnackBars(tester);
      await snap(tester, 'vaults', 'unwritten');

      await tester.tap(find.byKey(const Key('tsm-mobile-lock')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-mobile-lock-write')), findsOneWidget);
      await snap(tester, 'lock', 'unwritten');
    });

    _shot('conflicts to settle', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, conflict: true);
      await unlock(tester);
      expect(find.byKey(const Key('tsm-mobile-conflicts')), findsOneWidget);
      await snap(tester, 'vaults', 'conflicts');
      await tester.tap(find.byKey(const Key('tsm-mobile-conflicts')));
      await tester.pumpAndSettle();
      await snap(tester, 'conflicts', 'list');
    });

    _shot('a share in the inbox; the Shares page; importing a share', (
      tester,
    ) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, shared: true);
      await unlock(tester);
      await wait(tester, 6);
      expect(find.byKey(const Key('tsm-mobile-inbox')), findsOneWidget);
      await snap(tester, 'vaults', 'inbox');
      await tester.tap(find.byKey(const Key('tsm-mobile-inbox-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-mobile-shares-page')), findsOneWidget);
      await snap(tester, 'shares', 'page');
      await tester.tap(find.byKey(const Key('tsm-import-share')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-import-share-dialog')), findsOneWidget);
      await snap(tester, 'shares', 'import');
    });

    _shot('a login the Autofill service saw: the banner, the review', (
      tester,
    ) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        autofill: _Autofill(
          proposal: {
            'url': 'https://news.example.org/login',
            'title': 'news.example.org',
            'userName': 'demo-reader',
            'password': 'demo-news-pw',
          },
        ),
      );
      await unlock(tester);
      await wait(tester);
      expect(find.byKey(const Key('tsm-mobile-proposals')), findsOneWidget);
      await snap(tester, 'vaults', 'proposal');
      await tester.tap(find.byKey(const Key('tsm-mobile-proposals-open')));
      await tester.pumpAndSettle();
      expect(find.byType(TomSecretsProposalsView), findsOneWidget);
      await snap(tester, 'proposals', 'review');
    });
  });

  group('the entries', () {
    _shot('a vault\'s entries; a login; its one-time code; attachments', (
      tester,
    ) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester);
      await unlock(tester);
      await tester.tap(find.byKey(const Key('tsm-mobile-vault-team')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-mobile-entry-Mail')), findsOneWidget);
      await snap(tester, 'entries', 'list');

      await tester.tap(find.byKey(const Key('tsm-mobile-entry-Mail')));
      await tester.pumpAndSettle();
      expect(find.byType(TomSecretsEntryEditor), findsOneWidget);
      await snap(tester, 'entry', 'login');

      await scrollToTop(
        tester,
        find.text('One-time code (TOTP)'),
        scrollable: editorScrollable(),
      );
      expect(find.byType(TomSecretsTotpView), findsOneWidget);
      await snap(tester, 'entry', 'totp');

      await scrollToTop(
        tester,
        find.text('Attachments'),
        scrollable: editorScrollable(),
      );
      expect(find.text('recovery-codes.txt'), findsOneWidget);
      await snap(tester, 'entry', 'attachments');
    });

    _shot('search', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester);
      await unlock(tester);
      await tab(tester, 'Search');
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-search')),
        'example',
      );
      await tester.pumpAndSettle();
      await snap(tester, 'search', 'query');
    });

    _shot('the generator', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester);
      await unlock(tester);
      await tab(tester, 'Generator');
      await tester.tap(find.byKey(const Key('tsm-mobile-generate')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-use-generated')), findsOneWidget);
      await snap(tester, 'generator', 'dialog');
      await tester.tap(find.byKey(const Key('tsm-use-generated')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-mobile-generated')), findsOneWidget);
      await snap(tester, 'generator', 'made');
    });
  });

  group('settings', () {
    _shot('the settings, top and bottom; the Autofill service', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, autofill: _Autofill());
      await unlock(tester);
      await tab(tester, 'Settings');
      expect(find.byKey(const Key('tsm-mobile-settings')), findsOneWidget);
      await snap(tester, 'settings', 'top');

      // The end of the list: the quick unlock's PIN.
      await tester.scrollUntilVisible(
        find.byKey(const Key('tsm-settings-unlock-survives')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await snap(tester, 'settings', 'bottom');

      // The service turned on in the system's settings: the section says
      // what it fills.
      await tester.scrollUntilVisible(
        find.byKey(const Key('tsm-mobile-autofill-on')),
        -200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-mobile-autofill-on')));
      await wait(tester);
      expect(find.byKey(const Key('tsm-mobile-autofill-on')), findsNothing);
      await scrollToTop(
        tester,
        find.byKey(const Key('tsm-mobile-autofill')),
        scrollable: find.byType(Scrollable).last,
      );
      await snap(tester, 'settings', 'autofill');
    });

    _shot('adding a vault from a file', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      final rig = await app(tester);
      rig.documents.nextVault = const TomSecretsPickedDocument(
        id: 'doc-1',
        name: 'Notes.kdbx',
      );
      await unlock(tester);
      await tab(tester, 'Settings');
      await tester.scrollUntilVisible(
        find.byKey(const Key('tsm-mobile-add-file-vault')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('tsm-mobile-add-file-vault')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tsm-mobile-file-vault-password')),
        'notes-pw',
      );
      await snap(tester, 'settings', 'add-file-vault');
    });

    _shot('the health report', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(tester, breach: true);
      await unlock(tester);
      await wait(tester, 6);
      clearSnackBars(tester);
      await tab(tester, 'Settings');
      await tester.tap(find.byKey(const Key('tsm-mobile-health')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-health')), findsOneWidget);
      clearSnackBars(tester);
      await snap(tester, 'health', 'report');
    });
  });

  group('the Autofill service and the passkey provider', () {
    _shot('the service\'s unlock', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        autofillUnlock: _AutofillUnlock(
          const TomSecretsAutofillRequest(
            packageName: 'com.android.chrome',
            webDomain: 'mail.example.org',
          ),
        ),
      );
      expect(
        find.byKey(const Key('tsm-autofill-unlock-cancel')),
        findsOneWidget,
      );
      await typePassword(tester);
      await snap(tester, 'autofill', 'unlock');
    });

    _shot('no login for the site', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        autofillUnlock: _AutofillUnlock(
          const TomSecretsAutofillRequest(
            packageName: 'com.android.chrome',
            webDomain: 'news.example.net',
          ),
        ),
      );
      await unlock(tester);
      await wait(tester, 4);
      expect(find.byKey(const Key('tsm-autofill-message')), findsOneWidget);
      await snap(tester, 'autofill', 'nologin');
    });

    _shot('a phone not set up', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        setUp: false,
        autofillUnlock: _AutofillUnlock(
          const TomSecretsAutofillRequest(packageName: 'com.example.bank'),
        ),
      );
      expect(find.byKey(const Key('tsm-autofill-message')), findsOneWidget);
      await snap(tester, 'autofill', 'notsetup');
    });

    _shot('a passkey refused', (tester) async {
      size(tester, TomSecretsScreenshotSizes.phone);
      await app(
        tester,
        passkeyUnlock: _PasskeyUnlock(
          TomSecretsPasskeyRequest(
            kind: TomSecretsPasskeyRequestKind.get,
            options: {
              'challenge': base64Url
                  .encode(utf8.encode('demo-challenge'))
                  .replaceAll('=', ''),
              'rpId': 'bank.example.org',
            },
            packageName: 'com.example.other',
          ),
        ),
      );
      await unlock(tester);
      await wait(tester, 4);
      expect(find.byKey(const Key('tsm-autofill-message')), findsOneWidget);
      await snap(tester, 'passkey', 'refused');
    });
  });
}
