// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The desktop app's screenshots for its user guide
/// (`tom_secrets_app/doc/images/`): each screen and its important states
/// pumped over the fake service and demo vaults, at 1440×900, with the real
/// fonts — the vault browser in the light and the dark theme, every other
/// shot in the light theme. Each shot drives the app the way the app tests
/// do (the same keys, fake service calls and events). Runs only with
/// `flutter test --tags screenshots --update-goldens`, which writes the
/// files; a normal run skips it. Demo data only.
@Tags(['screenshots'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:tom_core_storage/settings.dart'
    show TomInMemoryGatedSecretStore, TomInMemorySecretStore;
import 'package:tom_kdbx_store/tom_kdbx_store.dart'
    show KdbxArgon2, KdbxArgon2Type;
import 'package:tom_secrets_client/admin.dart'
    show TomSecretsBrowser, TomSecretsBrowserHosts;
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_ui/screenshots.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart';

import '../support/fake_service.dart';

/// Where the desktop app's guide keeps its images, from this file.
const _images = '../../../tom_secrets_app/doc/images';

/// Whether this run leaves the screenshots out.
final bool _skip = tomSecretsScreenshotsSkip(autoUpdateGoldenFiles) != null;

/// The path the light screenshot of [screen] in [state] is written to.
String _light(String screen, String state) =>
    '$_images/${tomSecretsScreenshotName(screen, state, Brightness.light)}';

/// A screenshot test: skipped unless the run writes the goldens.
void _shot(String description, WidgetTesterCallback body) =>
    testWidgets(description, body, skip: _skip);

/// The demo user's home, as the screenshots show it.
const _demoHome = '/Users/demo';

/// The demo user's data directory, as the first-run shots show it.
const _demoData = '$_demoHome/Library/Application Support/Tom Secrets';

/// The scratch folders of a shot, under `.dart_tool/`.
Directory _scratch(String name) {
  final root = Directory('.dart_tool/screenshots_$name')
    ..createSync(recursive: true);
  final dir = Directory(root.createTempSync('run').absolute.path);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Maps [_demoHome] onto a scratch folder: the integrations write their
/// files into a demo home whose paths the screen shows as a demo user's.
final class _DemoHome extends IOOverrides {
  _DemoHome(this.scratch);

  final String scratch;

  String _map(String path) =>
      path == _demoHome || path.startsWith('$_demoHome/')
      ? '$scratch${path.substring(_demoHome.length)}'
      : path;

  @override
  File createFile(String path) => super.createFile(_map(path));

  @override
  Directory createDirectory(String path) => super.createDirectory(_map(path));

  @override
  Link createLink(String path) => super.createLink(_map(path));

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      super.fseGetType(_map(path), followLinks);

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      super.fseGetTypeSync(_map(path), followLinks);
}

/// A light Argon2id for the first runs.
const _argon2 = KdbxArgon2(
  type: KdbxArgon2Type.argon2id,
  memory: 1 << 20,
  iterations: 1,
);

/// A breach check that finds nothing (no request leaves the test).
TomSecretsBreachCheck _quietBreachCheck() => TomSecretsBreachCheck(
  client: MockClient(
    (_) async => http.Response('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0', 200),
  ),
);

/// A service host that holds no admin key the running service accepts.
final class _ClaimHost implements TomSecretsServiceHost {
  _ClaimHost(this.service);

  final FakeService service;

  @override
  Future<TomSecretsAttach> attach() async => const TomSecretsClaimNeeded();

  @override
  Future<TomSecretsAttach> start() async => const TomSecretsClaimNeeded();

  @override
  Future<TomSecretsAttach> claim(String password, {Uint8List? keyFile}) async =>
      TomSecretsAttached(service);

  @override
  Future<TomSecretsFirstRun> firstRun() async =>
      throw StateError('set up already');

  @override
  Future<void> serviceStopped() async {}
}

/// Files picked from and saved to a demo disk.
final class _Files implements TomSecretsFiles {
  final Map<String, Uint8List> disk = {};
  String? next;

  @override
  Future<({String name, Uint8List bytes})?> pick() async => null;

  @override
  Future<bool> save(String name, Uint8List bytes) async => true;

  @override
  Future<String?> choosePath({
    required bool save,
    String? suggestedName,
  }) async => next;

  @override
  Future<Uint8List> read(String path) async => Uint8List.fromList(disk[path]!);

  @override
  Future<bool> delete(String path) async => disk.remove(path) != null;
}

/// The window, always shown.
final class _Window implements TomSecretsWindowHost {
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<bool> isVisible() async => true;
  @override
  Future<void> quit() async {}
}

/// A keyboard that types nowhere.
final class _Keyboard implements TomSecretsKeyboard {
  @override
  TomSecretsAutoTypeSupport support() => TomSecretsAutoTypeSupport.ok;
  @override
  Future<bool> requestPermission() async => true;
  @override
  String? activeWindowTitle() => 'Demo Terminal';
  @override
  bool secureInputActive() => false;
  @override
  String? takeRefusal() => null;
  @override
  void typeCharacter(String character) {}
  @override
  void press(TomSecretsAutoTypeKeyPress press) {}
}

/// Global hotkeys pressed by the test.
final class _Hotkeys implements TomSecretsHotkeys {
  final Map<String, void Function()> registered = {};

  @override
  Future<void> register(
    String id,
    TomSecretsHotkey hotkey,
    void Function() onPressed,
  ) async => registered[id] = onPressed;

  @override
  Future<void> unregister(String id) async => registered.remove(id);
}

/// macOS's AutoFill, turned on in System Settings.
final class _Autofill implements TomSecretsAutofillPort {
  @override
  Future<TomSecretsAutofillState> state() async =>
      const TomSecretsAutofillState(available: true, providerEnabled: true);
  @override
  Future<void> storeKey(Uint8List key, String keyId) async {}
  @override
  Future<void> writeSnapshot(Uint8List sealed) async {}
  @override
  Future<void> remove() async {}
  @override
  Future<void> setIdentities(List<TomSecretsAutofillIdentity> list) async {}
  @override
  Future<void> openSettings() async {}
  @override
  Future<List<({String id, TomSecretsPasskey passkey})>>
  pendingPasskeys() async => const [];
  @override
  Future<void> clearPendingPasskeys(List<String> ids) async {}
}

/// The session events of the desktop (screen lock, sleep), never sent.
final class _SessionEvents implements TomSecretsSessionEvents {
  final StreamController<TomSecretsSessionEvent> _controller =
      StreamController.broadcast();

  @override
  Stream<TomSecretsSessionEvent> get events => _controller.stream;
}

/// A capture guard that can keep the window out of screenshots, as macOS
/// and Windows can.
final class _CaptureGuard implements TomSecretsCaptureGuard {
  @override
  bool get supported => true;

  @override
  Future<bool> setExcluded(bool excluded) async => true;
}

/// The Windows passkey plugin, not added to Windows yet.
final class _WindowsPasskeys implements TomSecretsWindowsPasskeysPort {
  @override
  Future<TomSecretsWindowsPasskeysStatus> status() async =>
      TomSecretsWindowsPasskeysStatus.notRegistered;
  @override
  Future<void> register() async {}
  @override
  Future<void> unregister() async {}
  @override
  Future<void> syncCredentials(
    List<TomSecretsWindowsPasskeyName> names,
  ) async {}
}

/// The Windows passkey plugin standing at [current] in Windows.
final class _WindowsPasskeysAt implements TomSecretsWindowsPasskeysPort {
  _WindowsPasskeysAt(this.current);

  final TomSecretsWindowsPasskeysStatus current;

  @override
  Future<TomSecretsWindowsPasskeysStatus> status() async => current;
  @override
  Future<void> register() async {}
  @override
  Future<void> unregister() async {}
  @override
  Future<void> syncCredentials(
    List<TomSecretsWindowsPasskeyName> names,
  ) async {}
}

/// The demo stores with two passkeys in `primary` (demo keys only).
Future<List<FakeStore>> _passkeyStores() async {
  final mail = await tomSecretsCreatePasskey(
    rpId: 'mail.example.com',
    userHandle: Uint8List.fromList([1, 2, 3, 4]),
    userName: 'demo-user@example.com',
  );
  final shop = await tomSecretsCreatePasskey(
    rpId: 'shop.example.com',
    userHandle: Uint8List.fromList([5, 6, 7, 8]),
    userName: 'demo-user',
  );
  final primary = await demoVault('primary', demoPassword, (f) {
    addEntry(
      f,
      'Db/Main',
      password: 'demo-db-pw',
      fields: {'UserName': 'demo-user', 'URL': 'https://db.example'},
    );
    tomSecretsKeepPasskey(f, mail.passkey);
    tomSecretsKeepPasskey(f, shop.passkey);
  });
  final team = await demoVault('team', 'team-demo-pw', (f) {
    addEntry(f, 'Api/Token', password: 'demo-api-token').tags.set('prod;api');
  });
  return [
    FakeStore('primary', demoPassword, primary),
    FakeStore('team', 'team-demo-pw', team),
  ];
}

/// The vault browser's demo: `primary` with logins (one with a one-time
/// code), an SSH key, a certificate, a PGP key, a note, an API token and an
/// overlay; `team` with a tagged login. Demo keys only.
Future<List<FakeStore>> _browserStores() async {
  final ssh = await tomSecretsGenerateSshKey(comment: 'deploy@demo');
  final certificate = tomSecretsGenerateCertificate(
    commonName: 'web.example.com',
  );
  final pgp = tomSecretsGeneratePgpKey(
    userId: 'Release signing <release@example.com>',
    expiresAfter: const Duration(days: 730),
  );
  final primary = await demoVault('primary', demoPassword, (f) {
    addEntry(
      f,
      'Web/Mail',
      password: 'demo-mail-pw-7Qx!',
      fields: {
        'UserName': 'demo-user@example.com',
        'URL': 'https://mail.example.com',
        'otp':
            'otpauth://totp/Mail:demo-user@example.com'
            '?secret=JBSWY3DPEHPK3PXP&issuer=Mail',
      },
    ).tags.set('personal');
    addEntry(
      f,
      'Web/Shop',
      password: 'demo-shop-pw-3k9#',
      fields: {
        'UserName': 'demo-user@example.com',
        'URL': 'https://shop.example.com',
      },
    );
    addEntry(
      f,
      'Db/Main',
      password: 'demo-db-pw',
      fields: {'UserName': 'demo-user', 'URL': 'https://db.example.com'},
    );
    addEntry(f, '@host:bomber/Db/Main', password: 'demo-bomber-pw');
    addEntry(
      f,
      'Bot',
      password: 'demo-bot-token',
      fields: {'tsm.key': 'telegram.bot_token', 'tsm.type': 'api-token'},
    );
    tomSecretsWriteSshKey(
      addEntry(f, 'Servers/Deploy key'),
      attachmentName: 'id_ed25519',
      privateKey: ssh.privateKey,
    );
    tomSecretsWriteCertificate(
      addEntry(f, 'Servers/Web certificate'),
      certificatePem: certificate.certificatePem,
      privateKeyPem: certificate.privateKeyPem,
    );
    tomSecretsWritePgpKey(
      addEntry(
        f,
        'Mail/Release signing',
        fields: {'UserName': 'release@example.com'},
      ),
      privateArmored: pgp.privateArmored,
      passphrase: pgp.passphrase,
    );
    addEntry(f, 'Recovery codes', fields: {'tsm.type': 'note'});
  });
  final team = await demoVault('team', 'team-demo-pw', (f) {
    addEntry(f, 'Api/Token', password: 'demo-api-token').tags.set('prod;api');
  });
  return [
    FakeStore('primary', demoPassword, primary),
    FakeStore('team', 'team-demo-pw', team),
  ];
}

/// The demo stores with `team` in a GitHub repository, listed with its
/// keys in the primary (the Keys screen rotates it).
Future<List<FakeStore>> _listedStores() async {
  const team = 'github:al-the-bear/demo-vaults/team.kdbx';
  final primary = await demoVault('primary', demoPassword, (f) {
    addEntry(f, 'Db/Main', password: 'demo-db-pw');
    TomSecretsPrimaryVaults(f).put(
      TomSecretsVaultKeys(
        name: 'team',
        locator: team,
        password: 'team-demo-pw',
      ),
    );
  });
  final stored = await demoVault('team', 'team-demo-pw', (f) {
    addEntry(f, 'Api/Token', password: 'demo-api-token');
  });
  return [
    FakeStore('primary', demoPassword, primary),
    FakeStore('team', 'team-demo-pw', stored, location: team),
  ];
}

/// A key with a date as the service reports it (`keys`).
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

/// A request waiting for an approval (`approval_needed`).
Map<String, Object?> _prompt(String id) => {
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
};

/// A 1Password CSV export with demo data: two logins and an archived one.
const _onePasswordCsv =
    '"Title","Url","Username","Password","OTPAuth","Favorite","Archived","Tags","Notes"\n'
    '"Demo Mail","https://mail.example.com","demo.user@example.com","demo-pw-1","","true","false","mail","Demo note"\n'
    '"Demo Shop","https://shop.example.com","shopper","demo-pw-2","","false","false","","" \n'
    '"Demo Old","https://old.example.com","old","demo-old-pw","","false","true","",""\n';

void main() {
  setUpAll(tomSecretsLoadScreenshotFonts);

  Future<void> wait(WidgetTester tester, [int rounds = 3]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  /// The window at the desktop size in [theme].
  void desktop(WidgetTester tester, [Brightness theme = Brightness.light]) {
    tester.view.physicalSize = TomSecretsScreenshotSizes.desktop;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = theme;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  /// The app over [host], at the desktop size in [theme].
  Future<void> pumpApp(
    WidgetTester tester,
    TomSecretsHost host, [
    Brightness theme = Brightness.light,
  ]) async {
    desktop(tester, theme);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('tsm-screenshot'),
        child: TomSecretsApp(host: host),
      ),
    );
    await wait(tester, 1);
  }

  /// Types the master password and unlocks.
  Future<void> unlock(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('tsm-unlock-passphrase')),
      demoPassword,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tsm-unlock')));
    await wait(tester, 10);
    await tester.pumpAndSettle();
  }

  /// A host over [service] with a breach check that finds nothing.
  TomSecretsHost hostOf(
    FakeService service, {
    TomSecretsFiles? files,
    Future<bool> Function(Uri url)? openUrl,
    TomSecretsBreachCheck? breachCheck,
  }) => TomSecretsHost(
    service: FakeHost(service),
    preferences: TomSecretsMemoryPreferences(),
    files: files,
    openUrl: openUrl,
    breachCheck: breachCheck ?? _quietBreachCheck(),
  );

  /// The app over [service] (default: the demo vaults) and [host],
  /// unlocked.
  Future<FakeService> unlocked(
    WidgetTester tester, {
    FakeService? service,
    TomSecretsHost Function(FakeService service)? host,
    Brightness theme = Brightness.light,
  }) async {
    final s = service ?? FakeService(await tester.runAsync(demoStores) ?? []);
    await pumpApp(tester, (host ?? hostOf)(s), theme);
    await unlock(tester);
    return s;
  }

  /// A Mac-like host over [service]: Touch ID as the OS unlock (a gated
  /// store in memory), the screen lock's session events and a capture
  /// guard that can keep the window out of screenshots.
  TomSecretsHost macHost(
    FakeService service, {
    TomSecretsAutofillPort? autofill,
  }) => TomSecretsHost(
    service: FakeHost(service),
    preferences: TomSecretsMemoryPreferences(),
    breachCheck: _quietBreachCheck(),
    osUnlock: TomSecretsOsUnlockHost(
      store: TomInMemoryGatedSecretStore(),
      label: 'Touch ID',
    ),
    sessionEvents: _SessionEvents(),
    captureGuard: _CaptureGuard(),
    macOS: true,
    autofill: autofill,
  );

  /// A Windows-like host over [service]: Windows Hello as the OS unlock
  /// (a gated store in memory), the screen lock's session events, a capture
  /// guard and the Windows passkey plugin over [passkeys].
  TomSecretsHost windowsHost(
    FakeService service,
    TomSecretsWindowsPasskeysPort passkeys,
  ) => TomSecretsHost(
    service: FakeHost(service),
    preferences: TomSecretsMemoryPreferences(),
    breachCheck: _quietBreachCheck(),
    osUnlock: TomSecretsOsUnlockHost(
      store: TomInMemoryGatedSecretStore(),
      label: 'Windows Hello',
    ),
    sessionEvents: _SessionEvents(),
    captureGuard: _CaptureGuard(),
    windowsPasskeys: passkeys,
  );

  /// The session of the shell.
  TomSecretsSession session(WidgetTester tester) => tester
      .element(find.byKey(const Key('tsm-rail')))
      .read<TomSecretsSession>();

  /// The rail's destination [label].
  Future<void> go(WidgetTester tester, String label, [int rounds = 3]) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('tsm-rail')),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
    await wait(tester, rounds);
  }

  /// Taps [finder] after scrolling it into view.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
  }

  /// Scrolls [finder] to the top of its scroll view.
  Future<void> scrollToTop(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(finder));
    await tester.pumpAndSettle();
  }

  /// Settles and writes the light screenshot of [screen] in [state].
  Future<void> snap(WidgetTester tester, String screen, String state) async {
    await wait(tester, 3);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const Key('tsm-screenshot')),
      matchesGoldenFile(_light(screen, state)),
    );
  }

  for (final theme in Brightness.values) {
    testWidgets('the vault browser, unlocked (${theme.name})', (tester) async {
      await unlocked(tester, theme: theme);
      expect(find.byType(TomSecretsMainShell), findsOneWidget);
      await expectLater(
        find.byKey(const Key('tsm-screenshot')),
        matchesGoldenFile(
          '$_images/${tomSecretsScreenshotName('vaults', 'unlocked', theme)}',
        ),
      );
    }, skip: _skip);
  }

  group('1 gates', () {
    _shot('no service running', (tester) async {
      final service = FakeService(await tester.runAsync(demoStores) ?? []);
      await pumpApp(
        tester,
        TomSecretsHost(
          service: FakeHost(service, running: false),
          preferences: TomSecretsMemoryPreferences(),
        ),
      );
      expect(find.text('The service is not running'), findsOneWidget);
      await snap(tester, 'connect', 'noservice');
    });

    _shot('a claim is needed', (tester) async {
      final service = FakeService(await tester.runAsync(demoStores) ?? []);
      await pumpApp(
        tester,
        TomSecretsHost(
          service: _ClaimHost(service),
          preferences: TomSecretsMemoryPreferences(),
        ),
      );
      expect(find.byType(TomSecretsClaimScreen), findsOneWidget);
      await snap(tester, 'claim', 'needed');
    });

    _shot('locked', (tester) async {
      final service = FakeService(await tester.runAsync(demoStores) ?? []);
      await pumpApp(tester, hostOf(service));
      expect(find.byKey(const Key('tsm-unlock')), findsOneWidget);
      await snap(tester, 'unlock', 'locked');
    });

    /// A machine that is not set up, its first run writing into [data].
    Future<TomSecretsHost> notSetUp(
      WidgetTester tester,
      Directory data, {
      Map<String, TomSecretsFirstRunAction> actions = const {},
      TomSecretsPairingDiscovery? discovery,
    }) async {
      final firstRun = TomSecretsFirstRun(
        dataDirectory: data.path,
        keychain: TomInMemorySecretStore(),
        argon2: _argon2,
      );
      final service = FakeService(
        await tester.runAsync(demoStores) ?? [],
        locked: true,
      );
      return TomSecretsHost(
        service: FakeHost(service, running: false, setup: firstRun),
        preferences: TomSecretsMemoryPreferences(),
        firstRunActions: actions,
        pairingDiscovery: discovery,
        pairingAddresses: discovery == null
            ? null
            : () async => [InternetAddress.loopbackIPv4],
      );
    }

    TomSecretsFirstRunModel wizard(WidgetTester tester) => tester
        .widget<TomSecretsFirstRunWizard>(find.byType(TomSecretsFirstRunWizard))
        .model;

    _shot('the first run: vault, protection, machine, done', (tester) async {
      final data = _scratch('first_run');
      await pumpApp(
        tester,
        await notSetUp(
          tester,
          data,
          actions: {
            TomSecretsFirstRunActions.import: (_) async {},
            TomSecretsFirstRunActions.pair: (_) async {},
          },
        ),
      );
      await wait(tester, 5);
      // The demo user's path on the screen; the scratch folder underneath.
      const shown = '$_demoData/vaults/primary.kdbx';
      await tester.enterText(find.byKey(const Key('tsm-fr-path')), shown);
      await tester.enterText(
        find.byKey(const Key('tsm-fr-password')),
        demoPassword,
      );
      await tester.enterText(
        find.byKey(const Key('tsm-fr-repeat')),
        demoPassword,
      );
      await tester.pump();
      await snap(tester, 'first-run', 'vault');

      await tester.tap(find.byKey(const Key('tsm-fr-next')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-fr-keyfile-switch')));
      await tester.pump();
      await snap(tester, 'first-run', 'protection');

      await tester.tap(find.byKey(const Key('tsm-fr-next')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('tsm-fr-host')), 'mbp');
      await tester.pump();
      await snap(tester, 'first-run', 'machine');

      final m = wizard(tester)..localPath = '${data.path}/vaults/primary.kdbx';
      await tester.tap(find.byKey(const Key('tsm-fr-setup')));
      await wait(tester, 30);
      expect(find.byKey(const Key('tsm-fr-summary')), findsOneWidget);
      m
        ..localPath = shown
        ..changed();
      await snap(tester, 'first-run', 'done');
    });

    _shot('the first run set up by pairing', (tester) async {
      final data = _scratch('first_run_pairing');
      final lan = FakePairingDiscovery();
      await pumpApp(tester, await notSetUp(tester, data, discovery: lan));
      await wait(tester, 5);
      final code = TomSecretsPairingCode.generate();
      final window = (await tester.runAsync(() async {
        final giver = TomSecretsTrust.create('mbp');
        final w = await TomSecretsPairingWindow.open(
          addresses: [InternetAddress.loopbackIPv4],
          allowLoopback: true,
          code: code,
          device: 'mbp',
          bundleFor: (_) async => TomSecretsPairingBundle(
            vaults: [
              TomSecretsPairingVault(
                name: 'primary',
                locator: 'file:$_demoData/vaults/primary.kdbx',
                primary: true,
                keyFile: TomSecretsKeyFile.generate().toBytes(),
              ),
              TomSecretsPairingVault(
                name: 'team',
                locator: 'github:al-the-bear/demo-vaults/team.kdbx.tsmx',
                primary: false,
                repositoryKey: TomSecretsRepositoryKey.generate().toBase64(),
              ),
            ],
            giverKeys: TomSecretsPairingPeerKeys(
              linkKey: (await giver.linkKey()).publicKey,
              approverKey: (await giver.approverKey()).publicKey,
              linkAddress: '10.8.0.7:47731',
            ),
            tokens: const [
              TomSecretsPairingToken(
                repository: 'al-the-bear/demo-vaults',
                token: 'github_pat_demo_for_this_desktop',
              ),
            ],
          ),
        );
        await lan.advertise(
          TomSecretsPairingAdvert(
            device: 'mbp',
            number: code.number,
            port: w.port,
            addresses: const ['127.0.0.1'],
          ),
        );
        return w;
      }))!;
      addTearDown(() => tester.runAsync(window.close));
      await tester.tap(find.byKey(const Key('tsm-fr-pair')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('tsm-fr-pair-code')),
        code.text,
      );
      await tester.enterText(
        find.byKey(const Key('tsm-fr-pair-host')),
        'newdesk',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('tsm-fr-pair-receive')));
      for (
        var i = 0;
        i < 50 &&
            find.byKey(const Key('tsm-fr-pair-received')).evaluate().isEmpty;
        i++
      ) {
        await wait(tester, 1);
      }
      expect(find.textContaining('Paired with mbp'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('tsm-fr-pair-password')),
        demoPassword,
      );
      await tester.pump();
      await snap(tester, 'first-run', 'pairing');
    });
  });

  group('2 vaults', () {
    Future<FakeService> browser(WidgetTester tester) async => unlocked(
      tester,
      service: FakeService(await tester.runAsync(_browserStores) ?? []),
    );

    Future<void> openEntry(WidgetTester tester, String title) async {
      final ref = session(tester).index.firstWhere((v) => v.title == title).ref;
      await tester.tap(find.byKey(Key('tsm-entry-$ref')));
      await tester.pumpAndSettle();
    }

    Future<void> list(WidgetTester tester) async {
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
    }

    _shot('the tree', (tester) async {
      await browser(tester);
      await tester.tap(find.byKey(const Key('tsm-group-primary-Web')));
      await tester.pumpAndSettle();
      await openEntry(tester, 'Mail');
      await snap(tester, 'vaults', 'tree');
    });

    _shot('the list with a login', (tester) async {
      await browser(tester);
      await list(tester);
      await openEntry(tester, 'Mail');
      await snap(tester, 'vaults', 'list');
    });

    for (final (title, state) in [
      ('Deploy key', 'sshkey'),
      ('Web certificate', 'certificate'),
      ('Release signing', 'pgpkey'),
    ]) {
      _shot('the entry $title', (tester) async {
        await browser(tester);
        await list(tester);
        await openEntry(tester, title);
        await snap(tester, 'entry', state);
      });
    }

    _shot('the generator', (tester) async {
      await browser(tester);
      await list(tester);
      await openEntry(tester, 'Mail');
      await tester.tap(find.byKey(const Key('tsm-generate')));
      await tester.pumpAndSettle();
      await snap(tester, 'generator', 'dialog');
    });

    _shot('new vault', (tester) async {
      await unlocked(tester);
      await tester.tap(find.byKey(const Key('tsm-new-vault')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('tsm-newvault-name')),
        'family',
      );
      await tester.pump();
      await snap(tester, 'newvault', 'dialog');
    });

    _shot('export', (tester) async {
      await unlocked(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('tsm-vault-primary')),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-vault-export-primary')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tsm-export-format-csv')));
      await tester.pump();
      await snap(tester, 'export', 'dialog');
    });
  });

  group('3 overlays and environments', () {
    Future<void> system(WidgetTester tester) async {
      final demo = (await tester.runAsync(systemStores))!;
      await unlocked(
        tester,
        service: FakeService(demo.stores, unserved: [demo.staging]),
      );
    }

    _shot('the overlay editor', (tester) async {
      await system(tester);
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      final stripe = session(tester).index.firstWhere(
        (v) => v.title == 'Stripe' && v.ref.store == 'primary',
      );
      await tester.tap(find.byKey(Key('tsm-entry-${stripe.ref}')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('tsm-open-overlays')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('tsm-entry-editor')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tap(tester, find.byKey(const Key('tsm-open-overlays')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-overlay-matrix')), findsOneWidget);
      await snap(tester, 'overlays', 'editor');
    });

    _shot('the environments', (tester) async {
      await system(tester);
      await go(tester, 'Environments');
      await tester.tap(find.byKey(const Key('tsm-env-open-staging')));
      await wait(tester, 5);
      expect(find.byKey(const Key('tsm-env-column-staging')), findsOneWidget);
      await snap(tester, 'environments', 'keys');
    });
  });

  group('4 clients and approvals', () {
    _shot('the Clients screen with a waiting approval', (tester) async {
      final service = await unlocked(tester);
      service.ask(_prompt('a-1'));
      await wait(tester);
      await tester.tap(find.byKey(const Key('tsm-approval-later')));
      await wait(tester);
      await go(tester, 'Clients');
      expect(find.byKey(const Key('tsm-approval-a-1')), findsOneWidget);
      await snap(tester, 'clients', 'approvals');
    });

    _shot('the approval prompt', (tester) async {
      final service = await unlocked(tester);
      service.ask(_prompt('a-1'));
      await wait(tester);
      expect(find.byKey(const Key('tsm-approval-prompt')), findsOneWidget);
      await snap(tester, 'approval', 'prompt');
    });

    _shot('a new passkey asked for', (tester) async {
      final service = await unlocked(tester);
      service.ask({
        'approvalId': 'a-4',
        'host': 'demo-host',
        'identity': {
          'kind': 'exe',
          'exe': '/opt/tsm/bin/tsm-browser-host',
          'args': const <String>[],
          'cwd': '/',
          'parent': {'exe': '/usr/bin/firefox'},
        },
        'refs': const <String>[],
        'resolved': const <Object>[],
        'confirmOnly': true,
        'url': 'https://shop.example.com/signup',
        'passkeyCreate': {
          'rpId': 'shop.example.com',
          'userName': 'demo-user@example.com',
          'url': 'https://shop.example.com/signup',
        },
      });
      await wait(tester);
      expect(
        find.byKey(const Key('tsm-approval-passkey-create')),
        findsOneWidget,
      );
      await snap(tester, 'approval', 'passkey');
    });

    _shot('an approval code issued', (tester) async {
      await unlocked(tester);
      await go(tester, 'Clients');
      await tester.tap(find.text('Approval code'));
      await tester.pumpAndSettle();
      await wait(tester);
      await tester.enterText(find.byKey(const Key('tsm-code-host')), 'bomber');
      await tester.enterText(
        find.byKey(const Key('tsm-code-code')),
        'abcde fghij',
      );
      await tester.tap(find.byKey(const Key('tsm-code-issue')));
      await wait(tester);
      await snap(tester, 'approval', 'code');
    });
  });

  group('5 import, conflicts, proposals, health', () {
    _shot('the import preview', (tester) async {
      final files = _Files()
        ..disk['/Users/demo/Downloads/1password-export.csv'] =
            Uint8List.fromList(utf8.encode(_onePasswordCsv))
        ..next = '/Users/demo/Downloads/1password-export.csv';
      await unlocked(tester, host: (s) => hostOf(s, files: files));
      await go(tester, 'Import');
      await tester.tap(find.byKey(const Key('tsm-import-pick')));
      await wait(tester);
      await tester.tap(
        find.byKey(const Key('tsm-import-format-onePasswordCsv')),
      );
      await wait(tester);
      await tester.tap(find.byKey(const Key('tsm-import-preview')));
      await wait(tester);
      expect(find.text('3. Preview (nothing written yet)'), findsOneWidget);
      await snap(tester, 'import', 'preview');
    });

    _shot('a conflict', (tester) async {
      final demo = (await tester.runAsync(systemStores))!;
      await unlocked(
        tester,
        service: FakeService(demo.stores, unserved: [demo.staging]),
      );
      await go(tester, 'Conflicts');
      expect(find.byKey(const Key('tsm-conflict-list')), findsOneWidget);
      await snap(tester, 'conflicts', 'list');
    });

    _shot('a proposal', (tester) async {
      final service = await unlocked(tester);
      service.emit({
        'op': 'proposal',
        'url': 'https://db.example/login?next=%2F',
        'title': 'Db sign-in',
        'userName': 'demo-user',
        'password': 'demo-db-pw-2',
      });
      await wait(tester);
      await go(tester, 'Proposals');
      await snap(tester, 'proposals', 'list');
    });

    _shot('the health report', (tester) async {
      const breached = 'letmein1';
      const strong = 'xK9#mQ2!vL7@pR4zW8nB3^jF6tY1';
      final primary = await tester.runAsync(
        () => demoVault('primary', demoPassword, (f) {
          addEntry(f, 'Mail', password: breached);
          addEntry(f, 'Shop', password: strong);
          addEntry(f, 'Forum', password: strong);
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
        }),
      );
      final check = TomSecretsBreachCheck(
        client: MockClient((request) async {
          final hash = tomSecretsPasswordHash(breached);
          final prefix = request.url.pathSegments.last;
          return http.Response(
            prefix == hash.substring(0, 5)
                ? '${hash.substring(5)}:99\r\n'
                      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0'
                : 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:0',
            200,
          );
        }),
      );
      await unlocked(
        tester,
        service: FakeService([FakeStore('primary', demoPassword, primary!)]),
        host: (s) => hostOf(s, breachCheck: check),
      );
      await wait(tester, 5);
      await go(tester, 'Health');
      await snap(tester, 'health', 'report');
    });
  });

  group('6 keys', () {
    _shot('the keys', (tester) async {
      final service = FakeService(await tester.runAsync(demoStores) ?? [])
        ..keys = [
          _key('approver_key', 'approver-key:demo-host', 400),
          _key('github_token', 'github-token:al-the-bear/demo-vaults', 5),
          _key('vault_keys', 'vault-keys:team', 200, vault: 'team'),
        ];
      await unlocked(tester, service: service);
      await go(tester, 'Keys');
      await snap(tester, 'keys', 'list');
    });

    _shot('rotating a vault\'s keys', (tester) async {
      await unlocked(
        tester,
        service: FakeService(await tester.runAsync(_listedStores) ?? []),
      );
      await go(tester, 'Keys', 5);
      await tap(tester, find.byKey(const Key('tsm-rotate-team')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-rotate')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tsm-rotate-password-on')));
      await tester.pump();
      await snap(tester, 'rotate', 'dialog');
    });

    _shot('signing in with GitHub', (tester) async {
      await unlocked(
        tester,
        host: (s) => hostOf(s, openUrl: (_) async => true),
      );
      await go(tester, 'Keys');
      await tap(tester, find.byKey(const Key('tsm-github-client-id')));
      await tester.enterText(
        find.byKey(const Key('tsm-github-client-id')),
        'Iv23demo',
      );
      await tester.tap(find.byKey(const Key('tsm-github-configure')));
      await wait(tester);
      await tap(tester, find.byKey(const Key('tsm-github-sign-in-button')));
      await wait(tester);
      expect(find.byKey(const Key('tsm-github-code')), findsOneWidget);
      await scrollToTop(tester, find.byKey(const Key('tsm-github-sign-in')));
      await snap(tester, 'github', 'signin');
    });

    _shot('renewing a GitHub token', (tester) async {
      final service = FakeService(await tester.runAsync(demoStores) ?? [])
        ..keys = [
          _key('github_token', 'github-token:al-the-bear/demo-vaults', 5),
        ];
      await unlocked(
        tester,
        service: service,
        host: (s) => hostOf(s, openUrl: (_) async => true),
      );
      await go(tester, 'Keys', 5);
      await tester.tap(
        find.byKey(
          const Key('tsm-key-renew-github-token:al-the-bear/demo-vaults'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tsm-renew')), findsOneWidget);
      await snap(tester, 'token', 'renewal');
    });
  });

  group('7 pairing and sharing', () {
    _shot('the pairing window', (tester) async {
      final stores = await tester.runAsync(demoStores) ?? [];
      final giver = TomSecretsTrust.create('mbp');
      final keys = (await tester.runAsync(
        () async => TomSecretsPairingPeerKeys(
          linkKey: (await giver.linkKey()).publicKey,
          approverKey: (await giver.approverKey()).publicKey,
          linkAddress: '10.8.0.7:47731',
        ),
      ))!;
      final service = FakeService(stores)
        ..pairIdentity = {'device': 'mbp', ...keys.toJson()};
      await unlocked(
        tester,
        service: service,
        host: (s) => TomSecretsHost(
          service: FakeHost(s),
          preferences: TomSecretsMemoryPreferences(),
          breachCheck: _quietBreachCheck(),
          pairingAddresses: () async => [InternetAddress.loopbackIPv4],
          pairingAllowsLoopback: true,
          pairingDiscovery: FakePairingDiscovery(),
        ),
      );
      await go(tester, 'Pairing');
      await tester.tap(find.byKey(const Key('tsm-pair-open')));
      await wait(tester, 5);
      expect(find.byKey(const Key('tsm-pair-qr')), findsOneWidget);
      await snap(tester, 'pairing', 'window');
      // Locking closes the window.
      await tester.tap(find.byKey(const Key('tsm-lock')));
      await wait(tester, 5);
    });

    late TomSecretsMemberKey bob;
    late TomSecretsMemberKey carol;

    setUpAll(() async {
      bob = await TomSecretsMemberKey.generate();
      carol = await TomSecretsMemberKey.generate();
    });
    tearDownAll(() {
      bob.dispose();
      carol.dispose();
    });

    /// Unlocked, Sharing open (Alice's member key made), Bob and Carol
    /// in the directory.
    Future<FakeService> sharing(WidgetTester tester) async {
      final primary = await tester.runAsync(
        () => demoVault('primary', demoPassword, (f) {
          addEntry(
            f,
            'Servers/Box',
            password: 'demo-box-pw',
            fields: {'UserName': 'admin', 'URL': 'https://box.example.com'},
          );
        }),
      );
      final service = await unlocked(
        tester,
        service: FakeService([FakeStore('primary', demoPassword, primary!)]),
      );
      await go(tester, 'Sharing', 15);
      final s = session(tester);
      await tester.runAsync(() async {
        await s.setMemberName('Alice');
        await s.addMember('Bob', bob.recipient);
        await s.addMember('Carol', carol.recipient);
      });
      await wait(tester, 5);
      return service;
    }

    /// The shared vault `crew` for Alice and Bob.
    Future<void> crew(WidgetTester tester) async {
      await tap(tester, find.byKey(const Key('tsm-shared-new')));
      await wait(tester, 2);
      await tester.enterText(
        find.byKey(const Key('tsm-shared-new-name')),
        'crew',
      );
      await tap(tester, find.byKey(const Key('tsm-shared-new-place')));
      await wait(tester, 2);
      await tap(tester, find.text('Beside my primary vault').last);
      await wait(tester, 2);
      await tap(
        tester,
        find.byKey(Key('tsm-shared-new-member-${bob.recipient.fingerprint}')),
      );
      await tester.pump();
      await tap(tester, find.byKey(const Key('tsm-shared-new-go')));
      await wait(tester, 15);
    }

    _shot('the member key', (tester) async {
      await sharing(tester);
      await snap(tester, 'sharing', 'memberkey');
    });

    _shot('the shared vaults', (tester) async {
      await sharing(tester);
      await crew(tester);
      await tap(tester, find.byKey(const Key('tsm-shared-crew')));
      await wait(tester, 10);
      await tester.pump(const Duration(seconds: 1));
      await scrollToTop(tester, find.byKey(const Key('tsm-shared-new')));
      await snap(tester, 'sharing', 'sharedvaults');
    });

    _shot('the relays', (tester) async {
      await sharing(tester);
      for (final r in [
        'github:al-the-bear/demo-vaults',
        'tsm:https://relay.example',
      ]) {
        await tap(tester, find.byKey(const Key('tsm-relay-add-text')));
        await tester.enterText(find.byKey(const Key('tsm-relay-add-text')), r);
        await tap(tester, find.byKey(const Key('tsm-relay-add')));
        await wait(tester, 2);
      }
      await scrollToTop(
        tester,
        find.byKey(const Key('tsm-relay-github:al-the-bear/demo-vaults')),
      );
      await snap(tester, 'relays', 'section');
    });

    _shot('sharing an entry', (tester) async {
      await sharing(tester);
      await crew(tester);
      await go(tester, 'Vaults', 5);
      final s = session(tester);
      s.toggleMarked(s.index.firstWhere((v) => v.title == 'Box').ref);
      await tester.pump();
      await tap(tester, find.byKey(const Key('tsm-share-marked')));
      await wait(tester, 2);
      expect(find.byKey(const Key('tsm-share-dialog')), findsOneWidget);
      await tap(
        tester,
        find.byKey(Key('tsm-share-member-${bob.recipient.fingerprint}')),
      );
      await tester.pump();
      await tap(tester, find.byKey(const Key('tsm-share-make')));
      await wait(tester, 15);
      expect(find.byKey(const Key('tsm-share-qr')), findsOneWidget);
      await snap(tester, 'share', 'dialog');
    });
  });

  group('8 quick access, settings, status', () {
    _shot('quick access', (tester) async {
      final hotkeys = _Hotkeys();
      await unlocked(
        tester,
        service: FakeService(await tester.runAsync(_browserStores) ?? []),
        host: (s) => TomSecretsHost(
          service: FakeHost(s),
          preferences: TomSecretsMemoryPreferences(),
          breachCheck: _quietBreachCheck(),
          keyboard: _Keyboard(),
          hotkeys: hotkeys,
          window: _Window(),
          macOS: true,
        ),
      );
      hotkeys.registered['quick-access']!();
      await wait(tester, 4);
      expect(find.byKey(const Key('tsm-quick-access')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('tsm-quick-access-search')),
        'ma',
      );
      await tester.pump();
      await snap(tester, 'quickaccess', 'dialog');
    });

    _shot('the settings', (tester) async {
      await unlocked(tester, host: macHost);
      await go(tester, 'Settings');
      await snap(tester, 'settings', 'top');
    });

    _shot('the integrations', (tester) async {
      final home = _scratch('integrations');
      final before = IOOverrides.current;
      IOOverrides.global = _DemoHome(home.path);
      addTearDown(() => IOOverrides.global = before);
      const tsm = '$_demoHome/Applications/Tom Secrets/bin/tsm';
      const browserHost =
          '$_demoHome/Applications/Tom Secrets/bin/tsm-browser-host';
      File(tsm)
        ..createSync(recursive: true)
        ..writeAsStringSync('demo');
      File(browserHost).writeAsStringSync('demo');
      Directory(
        TomSecretsBrowserHosts(
          home: _demoHome,
          hostExecutable: browserHost,
        ).profileFolder(TomSecretsBrowser.firefox),
      ).createSync(recursive: true);
      final service = FakeService(await tester.runAsync(demoStores) ?? [])
        ..agent = {'socket': '$_demoHome/.tsm/agent.sock'};
      await unlocked(
        tester,
        service: service,
        host: (s) => TomSecretsHost(
          service: FakeHost(s),
          preferences: TomSecretsMemoryPreferences(),
          breachCheck: _quietBreachCheck(),
          window: _Window(),
          integrationPaths: (
            home: _demoHome,
            tsmExecutable: tsm,
            browserHostExecutable: browserHost,
          ),
          windowsPasskeys: _WindowsPasskeys(),
        ),
      );
      await go(tester, 'Settings');
      await tap(tester, find.byKey(const Key('tsm-integration-ssh')));
      await wait(tester);
      await tap(tester, find.byKey(const Key('tsm-integration-aws')));
      await wait(tester);
      await tester.enterText(
        find.byKey(const Key('tsm-integration-aws-name')),
        'ci',
      );
      await tester.enterText(
        find.byKey(const Key('tsm-integration-aws-ref')),
        'team/Cloud/AWS ci',
      );
      await tester.tap(find.byKey(const Key('tsm-integration-aws-add')));
      await wait(tester);
      expect(
        find.byKey(const Key('tsm-integration-aws-profile-ci')),
        findsOneWidget,
      );
      await scrollToTop(
        tester,
        find.byKey(const Key('tsm-settings-integrations')),
      );
      await snap(tester, 'settings', 'integrations');
    });

    _shot('Password AutoFill', (tester) async {
      await unlocked(tester, host: (s) => macHost(s, autofill: _Autofill()));
      await go(tester, 'Settings');
      await scrollToTop(tester, find.byKey(const Key('tsm-settings-autofill')));
      await snap(tester, 'settings', 'autofill');
    });

    for (final (state, status) in [
      ('notadded', TomSecretsWindowsPasskeysStatus.notRegistered),
      ('off', TomSecretsWindowsPasskeysStatus.disabled),
      ('on', TomSecretsWindowsPasskeysStatus.enabled),
    ]) {
      _shot('Windows passkeys ($state)', (tester) async {
        await unlocked(
          tester,
          service: FakeService(await tester.runAsync(_passkeyStores) ?? []),
          host: (s) => windowsHost(s, _WindowsPasskeysAt(status)),
        );
        await go(tester, 'Settings');
        await scrollToTop(
          tester,
          find.byKey(const Key('tsm-settings-windows-passkeys')),
        );
        expect(
          find.byKey(
            Key(
              status == TomSecretsWindowsPasskeysStatus.notRegistered
                  ? 'tsm-windows-passkeys-register'
                  : 'tsm-windows-passkeys-unregister',
            ),
          ),
          findsOneWidget,
        );
        await snap(tester, 'settings', 'winpasskeys-$state');
      });
    }

    _shot('the status report', (tester) async {
      final service = FakeService(await tester.runAsync(demoStores) ?? [])
        ..links = [
          {
            'device': 'bigbeast',
            'role': 'host',
            'state': 'connected',
            'via': 'address',
          },
          {
            'device': 'server1',
            'role': 'approver',
            'state': 'connected',
            'via': 'relay',
          },
        ];
      await unlocked(tester, service: service);
      await go(tester, 'Status');
      await snap(tester, 'status', 'report');
    });
  });
}
