// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The container's health check (`tom_secrets_relay health`): the address it
// asks and its answer for a running relay, a refusing one and none.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

import 'relay_harness.dart';

void main() {
  setUpAll(RelayHarness.initialise);

  test('the health address is the configured host and port, the loopback '
      'when the relay listens on every address', () {
    final c = TomSecretsRelayServerConfiguration(['port=18080'])
      ..host = '127.0.0.1'
      ..port = 18080;
    expect(
      tomSecretsRelayHealthUrl(c).toString(),
      'http://127.0.0.1:18080/health',
    );
    c.host = '';
    expect(tomSecretsRelayHealthUrl(c).host, '127.0.0.1');
    c
      ..host = '10.8.0.1'
      ..listenToAnyIp = true;
    expect(tomSecretsRelayHealthUrl(c).host, '127.0.0.1');
    c.listenToAnyIp = false;
    expect(tomSecretsRelayHealthUrl(c).host, '10.8.0.1');
  });

  test('a running relay is healthy', () async {
    final relay = await RelayHarness.start(const TomSecretsRelayConfig());
    addTearDown(relay.stop);
    final err = StringBuffer();
    expect(
      await tomSecretsRelayHealthCheck(relay.http('/health'), err: err),
      0,
    );
    expect(err.toString(), isEmpty);
  });

  test('an answer other than 200 is unhealthy, said with the status', () async {
    final relay = await RelayHarness.start(const TomSecretsRelayConfig());
    addTearDown(relay.stop);
    final err = StringBuffer();
    expect(await tomSecretsRelayHealthCheck(relay.http('/nope'), err: err), 1);
    expect(err.toString(), contains('answered 404'));
  });

  test('no relay listening is unhealthy, said', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final err = StringBuffer();
    expect(
      await tomSecretsRelayHealthCheck(
        Uri.parse('http://127.0.0.1:$port/health'),
        timeout: const Duration(seconds: 2),
        err: err,
      ),
      1,
    );
    expect(err.toString(), contains('relay health:'));
  });
}
