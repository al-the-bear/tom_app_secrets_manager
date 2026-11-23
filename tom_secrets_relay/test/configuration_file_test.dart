// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The relay's configuration read as the executable reads it: a YAML file
// installed as the server's configuration resources, `tom_core_server`'s
// keys at the top, the relay's under `relay:`, arguments laid over them.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

import 'relay_harness.dart';

void main() {
  setUpAll(RelayHarness.initialise);

  test('the relay section of a configuration file', () async {
    final dir = await Directory.systemTemp.createTemp('relay_config');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/relay.yaml')
      ..writeAsStringSync('''
port: 47955
relay:
  mode: open
  tokens:
    team-a: team-a-token-0123456789
  allow: [10.0.0.0/8]
  storage: ${dir.path}/data
  dos:
    perSecond: 3
    blockHours: [1, 2]
  mailbox:
    maxExpiryDays: 7
''');
    tomSecretsRelayInstallConfiguration(TomYaml.loadYamlFile(file.path));
    addTearDown(() => tomSecretsRelayInstallConfiguration({}));
    final configuration = TomSecretsRelayServerConfiguration(['port=47956']);
    expect(configuration.port, 47956, reason: 'an argument wins');
    final relay = configuration.relaySettings;
    expect(relay.mode, TomSecretsRelayMode.open);
    expect(relay.tokenName('team-a-token-0123456789'), 'team-a');
    expect(relay.allow, ['10.0.0.0/8']);
    expect(relay.storageDirectory, '${dir.path}/data');
    expect(relay.requestsPerSecond, 3);
    expect(relay.blockDuration(2), const Duration(hours: 2));
    expect(relay.maxExpiry, const Duration(days: 7));
    // The relay section is no surplus key of the server's configuration.
    expect(
      configuration.settingWarnings(
        TomBaseServerConfiguration.getDefaultValues(const []),
        TomServerConfigResourceProvider.getServerConfig().resources,
      ),
      isNot(contains(contains('relay'))),
    );
  });

  test('without a file every relay default holds', () {
    tomSecretsRelayInstallConfiguration({});
    final configuration = TomSecretsRelayServerConfiguration([]);
    expect(configuration.port, tomSecretsRelayDefaultPort);
    expect(configuration.relaySettings.mode, TomSecretsRelayMode.token);
    expect(configuration.noSsl, isTrue);
  });
}
