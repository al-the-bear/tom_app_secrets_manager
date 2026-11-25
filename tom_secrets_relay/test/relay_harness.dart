// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// Starts a relay in the test's process on a free loopback port, with its
// storage in a temporary directory, and helpers to reach it.

import 'dart:convert';
import 'dart:io';

import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

import '../bin/tom_secrets_relay.reflection.dart';
import 'package:tom_secrets_client/admin.dart';
import 'package:tom_secrets_core/tom_secrets_core.dart'
    show TomSecretsPqcIdentityCrypto;

bool _initialised = false;

/// A relay started for one test.
final class RelayHarness {
  RelayHarness._(this.app, this.storage);

  /// Starts a relay with [config] (its storage directory replaced by a
  /// fresh one unless [storage] is given), the time read from [clock].
  static Future<RelayHarness> start(
    TomSecretsRelayConfig config, {
    Directory? storage,
    DateTime Function()? clock,
  }) async {
    initialise();
    TomBean.resetBeanContext();
    final dir =
        storage ??
        await Directory.systemTemp.createTemp('tom_secrets_relay_test');
    final configuration = TomSecretsRelayServerConfiguration([
      'port=0',
      'host=127.0.0.1',
    ]);
    configuration
      ..port = 0
      ..host = '127.0.0.1'
      ..listenToAnyIp = false
      ..exitOnShutdownSignal = false
      ..relaySettings = config.withStorage(dir.path);
    final app = await TomSecretsRelayApp.start(configuration, clock: clock);
    return RelayHarness._(app, dir);
  }

  /// Reflection and the runtime, once per test process.
  static void initialise() {
    if (_initialised) return;
    initializeReflection();
    tomSecretsRelayInitialize();
    _initialised = true;
  }

  final TomSecretsRelayApp app;
  final Directory storage;

  int get port => app.port;

  Uri http(String path) => Uri.parse('http://127.0.0.1:$port$path');
  Uri ws(String path) => Uri.parse('ws://127.0.0.1:$port$path');

  /// A request: [method] on [path], [body], [headers]; answers the status,
  /// the headers and the body.
  Future<({int status, HttpHeaders headers, List<int> body})> send(
    String method,
    String path, {
    List<int>? body,
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, http(path));
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.binary;
        request.add(body);
      }
      final response = await request.close();
      final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      return (
        status: response.statusCode,
        headers: response.headers,
        body: bytes,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// The JSON of a body.
  static Object? json(List<int> body) => jsonDecode(utf8.decode(body));

  Future<void> stop({bool keepStorage = false}) async {
    await app.stop();
    if (!keepStorage && storage.existsSync()) {
      await storage.delete(recursive: true);
    }
  }
}

/// The tests' admin connections check the identity key of the service they
/// started themselves (protocol.md 6.1), and pin it as it presents itself.
void trustTestServices() =>
    TomSecretsServiceTrust.fallbackIdentity ??= TomSecretsIdentityTrust(
      pins: TomSecretsMemoryPins(),
      crypto: const TomSecretsPqcIdentityCrypto(),
      pinOnFirstUse: true,
    );
