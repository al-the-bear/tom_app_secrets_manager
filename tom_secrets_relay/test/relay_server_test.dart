// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

// The relay as a running server (part-relay's test list): two in-process
// clients pairing through it, the third connection refused, expiry, a
// mailbox round trip, a proof failure, a link that stays open and
// reconnects, the limits, both sending modes and the token-mode default,
// the address lists, and the escalating blocks of the denial-of-service
// protection. The client address is set with X-Forwarded-For, which the
// relay trusts from the loopback proxy only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_core_server/tom_core_server.dart';
import 'package:tom_secrets_age/tom_secrets_age.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;

import 'relay_harness.dart';

/// Limits high enough that a test's own requests never block it.
const _roomy = TomSecretsRelayConfig(
  requestsPerSecond: 10000,
  requestsPerMinute: 10000,
  requestsPerDay: 100000,
  tokens: {'team': 'team-token-0123456789'},
);

const _token = {'authorization': 'Bearer team-token-0123456789'};

Map<String, String> _from(String address) => {'x-forwarded-for': address};

final class _Captured extends TomLogOutput {
  final List<String> messages = [];
  @override
  void output(
    TomLogLevel loggerLevel,
    TomLogLevel logLevel,
    String level,
    Object message,
    String isolateName,
    DateTime timeStamp, [
    String? origin,
  ]) => messages.add(convertToString(message));
}

void main() {
  late RelayHarness h;
  late DateTime now;

  Future<void> start([
    TomSecretsRelayConfig config = _roomy,
    Directory? storage,
  ]) async {
    h = await RelayHarness.start(config, storage: storage, clock: () => now);
  }

  setUp(() => now = DateTime.now().toUtc());
  tearDown(() => h.stop());

  Future<String> nameplate([String address = '198.51.100.1']) async {
    final r = await h.send('POST', '/v1/pair', headers: _from(address));
    expect(r.status, 200);
    final json = RelayHarness.json(r.body) as Map;
    expect(
      DateTime.parse(json['expires'] as String).difference(now).inMinutes,
      inInclusiveRange(9, 10),
    );
    return json['nameplate'] as String;
  }

  Future<IOWebSocketChannel> socket(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final c = IOWebSocketChannel.connect(h.ws(path), headers: headers);
    await c.ready;
    return c;
  }

  /// The status a refused upgrade answers.
  Future<int> refusedUpgrade(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(h.http(path));
      request.headers
        ..set('connection', 'Upgrade')
        ..set('upgrade', 'websocket')
        ..set('sec-websocket-version', '13')
        ..set('sec-websocket-key', base64.encode(List.filled(16, 1)));
      headers.forEach(request.headers.set);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  group('pairing', () {
    test('two clients pair through the relay', () async {
      await start();
      final n = await nameplate();
      final host = await socket('/v1/pair/$n');
      final joiner = await socket('/v1/pair/$n');
      final atHost = StreamIterator(host.stream);
      final atJoiner = StreamIterator(joiner.stream);
      joiner.sink.add(utf8.encode('spake2 A'));
      expect(await atHost.moveNext(), isTrue);
      expect(utf8.decode(atHost.current as List<int>), 'spake2 A');
      host.sink.add(utf8.encode('spake2 B'));
      expect(await atJoiner.moveNext(), isTrue);
      expect(utf8.decode(atJoiner.current as List<int>), 'spake2 B');
      // The host leaving closes the joiner and releases the nameplate.
      await host.sink.close(status.normalClosure);
      expect(await atJoiner.moveNext(), isFalse);
      expect(joiner.closeCode, TomSecretsRelayClose.peerLeft);
      expect(await refusedUpgrade('/v1/pair/$n'), 404);
    });

    test('a third connection is refused', () async {
      await start();
      final n = await nameplate();
      final a = await socket('/v1/pair/$n');
      final b = await socket('/v1/pair/$n');
      expect(await refusedUpgrade('/v1/pair/$n'), 409);
      await a.sink.close();
      await b.sink.close();
    });

    test('an expired nameplate is refused and closed', () async {
      await start();
      final n = await nameplate();
      final a = await socket('/v1/pair/$n');
      now = now.add(const Duration(minutes: 11));
      await h.app.state.expire();
      await a.stream.drain<void>();
      expect(a.closeCode, TomSecretsRelayClose.expired);
      expect(await refusedUpgrade('/v1/pair/$n'), 404);
    });

    test('10 nameplates per address per hour', () async {
      await start();
      for (var i = 0; i < 10; i++) {
        await nameplate('198.51.100.20');
      }
      final r = await h.send(
        'POST',
        '/v1/pair',
        headers: _from('198.51.100.20'),
      );
      expect(r.status, 429);
      expect(int.parse(r.headers.value('retry-after')!), greaterThan(0));
      // Another address is not limited.
      await nameplate('198.51.100.21');
    });

    test('pairing needs no token in token mode', () async {
      await start(
        const TomSecretsRelayConfig(
          requestsPerSecond: 10000,
          requestsPerMinute: 10000,
          requestsPerDay: 100000,
        ),
      );
      final n = await nameplate();
      final a = await socket('/v1/pair/$n');
      await a.sink.close();
    });
  });

  group('the approval link', () {
    test('stays open, and both sides reconnect after one left', () async {
      await start();
      final a = await socket('/v1/link/link-0001', headers: _token);
      final b = await socket('/v1/link/link-0001', headers: _token);
      final atB = StreamIterator(b.stream);
      // No expiry while both stay: the expiry job a day later leaves it.
      now = now.add(const Duration(days: 1));
      await h.app.state.expire();
      a.sink.add([1, 2]);
      expect(await atB.moveNext(), isTrue);
      expect(atB.current, [1, 2]);
      await a.sink.close();
      expect(await atB.moveNext(), isFalse);
      expect(b.closeCode, TomSecretsRelayClose.peerLeft);

      final a2 = await socket('/v1/link/link-0001', headers: _token);
      final b2 = await socket('/v1/link/link-0001', headers: _token);
      final atA2 = StreamIterator(a2.stream);
      b2.sink.add([3]);
      expect(await atA2.moveNext(), isTrue);
      expect(atA2.current, [3]);
      expect(await refusedUpgrade('/v1/link/link-0001', headers: _token), 409);
      await a2.sink.close();
      await b2.sink.close();
    });

    test('needs the instance token in token mode', () async {
      await start();
      expect(await refusedUpgrade('/v1/link/link-0002'), 401);
      expect(
        await refusedUpgrade(
          '/v1/link/link-0002',
          headers: {'authorization': 'Bearer wrong-token-0123456789'},
        ),
        401,
      );
    });

    test('10 open links per token', () async {
      await start();
      final open = [
        for (var i = 0; i < 10; i++)
          await socket('/v1/link/link-1$i', headers: _token),
      ];
      expect(await refusedUpgrade('/v1/link/link-2', headers: _token), 429);
      for (final s in open) {
        await s.sink.close();
      }
    });
  });

  group('the mailbox', () {
    late TomSecretsMemberKey me;
    setUpAll(() async => me = await TomSecretsMemberKey.generate());
    tearDownAll(() => me.dispose());

    String expiresIn(Duration d) => now.add(d).toIso8601String();

    Future<String> proof() async {
      final id = me.recipient.fingerprint;
      final r = await h.send(
        'POST',
        '/v1/mailbox/$id/challenge',
        body: utf8.encode(me.recipient.encoded),
      );
      expect(r.status, 200);
      return utf8.decode(
        await tomSecretsAgeDecrypt(Uint8List.fromList(r.body), [
          TomSecretsAgeHybridIdentity(me),
        ]),
      );
    }

    test('a round trip: put, list, fetch, delete', () async {
      await start();
      final id = me.recipient.fingerprint;
      final package = await tomSecretsAgeEncrypt(utf8.encode('a share'), [
        me.recipient,
      ]);
      final put = await h.send(
        'PUT',
        '/v1/mailbox/$id/2026-11-23-0123456789abcdef.age',
        body: package,
        headers: {
          ..._token,
          'tsm-expires': expiresIn(const Duration(days: 30)),
        },
      );
      expect(put.status, 201);
      final p = await proof();
      final auth = {'authorization': 'Bearer $p'};
      final list = await h.send('GET', '/v1/mailbox/$id', headers: auth);
      expect(list.status, 200);
      final items = (RelayHarness.json(list.body) as Map)['items'] as List;
      expect(items.single['id'], '2026-11-23-0123456789abcdef.age');
      expect(items.single['size'], package.length);
      final fetched = await h.send(
        'GET',
        '/v1/mailbox/$id/2026-11-23-0123456789abcdef.age',
        headers: auth,
      );
      expect(fetched.status, 200);
      expect(
        utf8.decode(
          await tomSecretsAgeDecrypt(Uint8List.fromList(fetched.body), [
            TomSecretsAgeHybridIdentity(me),
          ]),
        ),
        'a share',
      );
      final deleted = await h.send(
        'DELETE',
        '/v1/mailbox/$id/2026-11-23-0123456789abcdef.age',
        headers: auth,
      );
      expect(deleted.status, 204);
      final again = await h.send('GET', '/v1/mailbox/$id', headers: auth);
      expect((RelayHarness.json(again.body) as Map)['items'], isEmpty);
    });

    test('reads need the proof', () async {
      await start();
      final id = me.recipient.fingerprint;
      expect((await h.send('GET', '/v1/mailbox/$id')).status, 401);
      expect(
        (await h.send(
          'GET',
          '/v1/mailbox/$id',
          headers: {'authorization': 'Bearer made-up'},
        )).status,
        401,
      );
      // A proof is for its own mailbox only.
      final p = await proof();
      expect(
        (await h.send(
          'GET',
          '/v1/mailbox/${'b' * 52}',
          headers: {'authorization': 'Bearer $p'},
        )).status,
        401,
      );
      // A recipient that does not hash to the mailbox gets no challenge.
      final other = await TomSecretsMemberKey.generate();
      addTearDown(other.dispose);
      final wrong = await h.send(
        'POST',
        '/v1/mailbox/$id/challenge',
        body: utf8.encode(other.recipient.encoded),
      );
      expect(wrong.status, 400);
      // The proof runs out after 5 minutes.
      now = now.add(const Duration(minutes: 6));
      expect(
        (await h.send(
          'GET',
          '/v1/mailbox/$id',
          headers: {'authorization': 'Bearer $p'},
        )).status,
        401,
      );
    });

    test('token mode is the default and says what is missing', () async {
      await start(
        const TomSecretsRelayConfig(
          requestsPerSecond: 10000,
          requestsPerMinute: 10000,
          requestsPerDay: 100000,
        ),
      );
      final r = await h.send(
        'PUT',
        '/v1/mailbox/${me.recipient.fingerprint}/x',
        body: [1],
        headers: {'tsm-expires': expiresIn(const Duration(days: 1))},
      );
      expect(r.status, 401);
      expect(
        (RelayHarness.json(r.body) as Map)['error'],
        allOf(contains('instance token'), contains('relay.tokens')),
      );
    });

    test('token mode without tokens says so at start-up, naming the '
        'setting', () async {
      final captured = _Captured();
      final previous = tomLog.logOutput;
      tomLog.logOutput = captured;
      addTearDown(() => tomLog.logOutput = previous);
      await start(const TomSecretsRelayConfig());
      expect(
        captured.messages,
        contains(
          allOf(contains('without instance tokens'), contains('relay.tokens')),
        ),
      );
    });

    test('the relay\'s tokens and proofs are not read as framework JWTs: no '
        'bearer warning per request', () async {
      await start();
      final captured = _Captured();
      final previous = tomLog.logOutput;
      tomLog.logOutput = captured;
      addTearDown(() => tomLog.logOutput = previous);
      final r = await h.send(
        'PUT',
        '/v1/mailbox/${me.recipient.fingerprint}/x',
        body: [1],
        headers: {..._token, 'tsm-expires': expiresIn(const Duration(days: 1))},
      );
      expect(r.status, 201);
      final listed = await h.send(
        'GET',
        '/v1/mailbox/${me.recipient.fingerprint}',
        headers: {'authorization': 'Bearer not-a-proof'},
      );
      expect(listed.status, 401);
      expect(
        captured.messages.where((m) => m.contains('bearer token')),
        isEmpty,
      );
    });

    test('open mode takes puts without a token', () async {
      await start(
        const TomSecretsRelayConfig(
          mode: TomSecretsRelayMode.open,
          requestsPerSecond: 10000,
          requestsPerMinute: 10000,
          requestsPerDay: 100000,
        ),
      );
      final r = await h.send(
        'PUT',
        '/v1/mailbox/${me.recipient.fingerprint}/x',
        body: [1],
        headers: {'tsm-expires': expiresIn(const Duration(days: 1))},
      );
      expect(r.status, 201);
    });

    test('the limits of a put', () async {
      await start(
        const TomSecretsRelayConfig(
          requestsPerSecond: 10000,
          requestsPerMinute: 10000,
          requestsPerDay: 100000,
          tokens: {'team': 'team-token-0123456789'},
          putsPerHour: 3,
        ),
      );
      final id = me.recipient.fingerprint;
      Future<int> put(String item, {String? expires, int size = 1}) async =>
          (await h.send(
            'PUT',
            '/v1/mailbox/$id/$item',
            body: List.filled(size, 1),
            headers: {
              ..._token,
              'tsm-expires': expires ?? expiresIn(const Duration(days: 1)),
            },
          )).status;

      expect(await put('a'), 201);
      expect(await put('a'), 409);
      expect(await put('b', expires: expiresIn(const Duration(days: 31))), 400);
      final last = await h.send(
        'PUT',
        '/v1/mailbox/$id/c',
        body: [1],
        headers: {..._token, 'tsm-expires': expiresIn(const Duration(days: 1))},
      );
      expect(last.status, 429);
      expect(last.headers.value('retry-after'), isNotNull);
    });

    test('1 MB per item', () async {
      await start();
      final r = await h.send(
        'PUT',
        '/v1/mailbox/${me.recipient.fingerprint}/big',
        body: List.filled(1024 * 1024 + 1, 0),
        headers: {..._token, 'tsm-expires': expiresIn(const Duration(days: 1))},
      );
      expect(r.status, 413);
    });

    test('the expiry job deletes expired items', () async {
      await start();
      final id = me.recipient.fingerprint;
      await h.send(
        'PUT',
        '/v1/mailbox/$id/soon',
        body: [1],
        headers: {
          ..._token,
          'tsm-expires': expiresIn(const Duration(hours: 1)),
        },
      );
      now = now.add(const Duration(hours: 2));
      await h.app.state.expire();
      final p = await proof();
      final list = await h.send(
        'GET',
        '/v1/mailbox/$id',
        headers: {'authorization': 'Bearer $p'},
      );
      expect((RelayHarness.json(list.body) as Map)['items'], isEmpty);
    });
  });

  group('the address filters', () {
    test('a denied address is refused, an allowed one served', () async {
      await start(
        const TomSecretsRelayConfig(
          requestsPerSecond: 10000,
          requestsPerMinute: 10000,
          requestsPerDay: 100000,
          deny: ['203.0.113.0/24'],
          allow: ['198.51.100.0/24', '203.0.113.0/24', 'fd00::/8'],
        ),
      );
      expect(
        (await h.send(
          'POST',
          '/v1/pair',
          headers: _from('203.0.113.5'),
        )).status,
        403,
      );
      expect(
        (await h.send('POST', '/v1/pair', headers: _from('192.0.2.1'))).status,
        403,
      );
      expect(
        (await h.send('POST', '/v1/pair', headers: _from('fd00::7'))).status,
        200,
      );
      expect(
        (await h.send(
          'POST',
          '/v1/pair',
          headers: _from('198.51.100.9'),
        )).status,
        200,
      );
    });
  });

  group('the denial-of-service protection', () {
    Future<bool> answered(String address) async {
      try {
        await h.send('POST', '/v1/pair', headers: _from(address));
        return true;
      } on HttpException {
        return false;
      } on SocketException {
        return false;
      }
    }

    test('an eleventh request in a second: closed without an answer', () async {
      await start(const TomSecretsRelayConfig());
      for (var i = 0; i < 10; i++) {
        expect(await answered('198.51.100.30'), isTrue);
      }
      expect(await answered('198.51.100.30'), isFalse);
      // Blocked for 24 hours, not longer.
      now = now.add(const Duration(hours: 23));
      expect(await answered('198.51.100.30'), isFalse);
      now = now.add(const Duration(hours: 2));
      expect(await answered('198.51.100.30'), isTrue);
      // Another address was never blocked.
      expect(await answered('198.51.100.31'), isTrue);
    });

    test('blocks escalate and survive a restart', () async {
      final storage = await Directory.systemTemp.createTemp('relay_blocks');
      addTearDown(() => storage.delete(recursive: true));
      await start(const TomSecretsRelayConfig(), storage);
      while (await answered('198.51.100.40')) {}
      expect(
        h.app.state.guard.blockedUntil('198.51.100.40')!.difference(now),
        const Duration(hours: 24),
      );
      await h.stop(keepStorage: true);

      await start(const TomSecretsRelayConfig(), storage);
      expect(await answered('198.51.100.40'), isFalse);
      now = now.add(const Duration(hours: 25));
      while (await answered('198.51.100.40')) {}
      expect(
        h.app.state.guard.blockedUntil('198.51.100.40')!.difference(now),
        const Duration(hours: 48),
      );
    });

    test('the health endpoints are not counted', () async {
      await start(const TomSecretsRelayConfig());
      for (var i = 0; i < 5; i++) {
        expect((await h.send('GET', '/health')).status, 200);
      }
      expect((await h.send('GET', '/ready')).status, 200);
    });
  });

  test('only the relay\'s routes are served', () async {
    await start();
    for (final path in [
      '/saml/acs',
      '/scim/v2/Users',
      '/.well-known/jwks.json',
    ]) {
      final r = await h.send('GET', path);
      expect(r.status, 404, reason: path);
    }
  });
}
