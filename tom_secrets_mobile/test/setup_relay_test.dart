// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The phone set up through a GitHub relay (part-relay), with the real
/// receiving side (`tomSecretsMobileReceive`) against the fake GitHub
/// server: the desktop's pairing hosted on the repository, the phone
/// joining with its own token — alone, and after an address that does not
/// answer (the network first); the setup keeping that token for the
/// repository. Demo data only.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_core_storage/settings.dart';
import 'package:tom_github_api/testing.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart';
import 'package:tom_secrets_mobile/tom_secrets_mobile.dart';
import 'package:tom_secrets_ui/tom_secrets_ui.dart'
    show TomSecretsMemoryPreferences;

const _slug = 'demo-owner/demo-vaults';

void main() {
  late FakeGitHubServer github;
  late TomSecretsPairingPeerKeys giverKeys;
  final id = TomSecretsRelayId.parse('github:$_slug');

  setUpAll(() async {
    final giver = TomSecretsTrust.create('mbp');
    giverKeys = TomSecretsPairingPeerKeys(
      linkKey: (await giver.linkKey()).publicKey,
    );
  });

  setUp(() {
    github = FakeGitHubServer()..commitFiles(_slug, {'README.md': 'demo'});
  });

  TomSecretsRelay relay(TomSecretsRelayId id, String token, String device) =>
      TomSecretsGitHubRelay.withToken(
        id,
        token,
        device: device,
        httpClient: github.client,
        baseUrl: FakeGitHubServer.baseUrl,
        pollInterval: const Duration(milliseconds: 20),
      );

  /// The desktop's pairing on the repository alone.
  Future<(TomSecretsPairingWindow, TomSecretsPairingCode)> desktop() async {
    final channel = await relay(id, 'demo-desktop-token', 'mbp').host();
    final code = TomSecretsPairingCode(int.parse(channel.nameplate), [
      'guitar',
      'orbit',
    ]);
    final window = await TomSecretsPairingWindow.open(
      addresses: const [],
      relayChannel: channel,
      code: code,
      device: 'mbp',
      bundleFor: (_) async => TomSecretsPairingBundle(
        vaults: const [
          TomSecretsPairingVault(
            name: 'primary',
            locator: 'github:$_slug/primary.kdbx',
            primary: true,
          ),
        ],
        giverKeys: giverKeys,
      ),
    );
    return (window, code);
  }

  test(
    'through the relay alone; the setup keeps the phone\'s own token',
    () async {
      final (window, code) = await desktop();
      final received = await tomSecretsMobileReceive(
        relay: id,
        relayToken: 'github_pat_demo_phone',
        code: code,
        device: 'iphone',
        relayFor: relay,
      );
      expect(received.giver, 'mbp');
      expect(received.bundle.tokens, isEmpty);
      expect(received.ownTokens, {_slug: 'github_pat_demo_phone'});
      expect((await window.result).receiver, 'iphone');

      final keychain = TomInMemorySecretStore();
      final setup = TomSecretsMobileSetup(
        preferences: TomSecretsMemoryPreferences(),
        keychain: keychain,
      );
      await setup.applyPairing(
        received.bundle,
        device: 'iphone',
        ownTokens: received.ownTokens,
      );
      expect(setup.isSetUp, isTrue);
      expect(
        await keychain.read(
          tomSecretsGitHubTokenHandle('demo-owner', 'demo-vaults'),
        ),
        'github_pat_demo_phone',
      );
    },
  );

  test('the address first: nothing answers there, then the relay', () async {
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();
    final (window, code) = await desktop();
    final received = await tomSecretsMobileReceive(
      address: '127.0.0.1',
      port: port,
      relay: id,
      relayToken: 'github_pat_demo_phone',
      code: code,
      device: 'iphone',
      relayFor: relay,
    );
    expect(received.giver, 'mbp');
    expect((await window.result).receiver, 'iphone');
  });

  test('no pairing waits on the relay: the error names it', () async {
    await expectLater(
      tomSecretsMobileReceive(
        relay: id,
        relayToken: 'github_pat_demo_phone',
        code: TomSecretsPairingCode(77, ['guitar', 'orbit']),
        device: 'iphone',
        relayFor: relay,
      ),
      throwsA(
        isA<TomSecretsRelayException>().having(
          (e) => e.relay,
          'relay',
          'github:$_slug',
        ),
      ),
    );
  });
}
