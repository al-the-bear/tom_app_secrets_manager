// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

void main() {
  group('TomSecretsRelayCidr', () {
    test('IPv4 ranges, single addresses and mapped addresses', () {
      final r = TomSecretsRelayCidr.parse('10.0.0.0/8');
      expect(r.contains(InternetAddress('10.200.1.2')), isTrue);
      expect(r.contains(InternetAddress('11.0.0.1')), isFalse);
      expect(r.contains(InternetAddress('::ffff:10.1.2.3')), isTrue);
      expect(r.contains(InternetAddress('fd00::1')), isFalse);
      final one = TomSecretsRelayCidr.parse('192.168.1.7');
      expect(one.contains(InternetAddress('192.168.1.7')), isTrue);
      expect(one.contains(InternetAddress('192.168.1.8')), isFalse);
      expect(
        TomSecretsRelayCidr.parse(
          '172.16.0.0/12',
        ).contains(InternetAddress('172.31.255.1')),
        isTrue,
      );
      expect(
        TomSecretsRelayCidr.parse(
          '0.0.0.0/0',
        ).contains(InternetAddress('8.8.8.8')),
        isTrue,
      );
    });

    test('IPv6 ranges', () {
      final r = TomSecretsRelayCidr.parse('fd00::/8');
      expect(r.contains(InternetAddress('fd12:3456::1')), isTrue);
      expect(r.contains(InternetAddress('fe80::1')), isFalse);
      expect(r.contains(InternetAddress('10.0.0.1')), isFalse);
      expect(
        TomSecretsRelayCidr.parse(
          '2001:db8::/33',
        ).contains(InternetAddress('2001:db8:7fff::1')),
        isTrue,
      );
      expect(
        TomSecretsRelayCidr.parse(
          '2001:db8::/33',
        ).contains(InternetAddress('2001:db8:8000::1')),
        isFalse,
      );
    });

    test('refuses what is no range', () {
      for (final t in ['10.0.0.0/33', 'fd00::/129', 'nonsense', '10.0.0/8']) {
        expect(() => TomSecretsRelayCidr.parse(t), throwsFormatException);
      }
    });
  });

  group('the address filters', () {
    test('deny refuses, allow serves only its ranges, deny first', () async {
      final g = TomSecretsRelayAddressGuard(
        const TomSecretsRelayConfig(
          deny: ['10.9.0.0/16'],
          allow: ['10.0.0.0/8', 'fd00::/8'],
        ),
      );
      expect(await g.check('10.1.1.1'), TomSecretsRelayVerdict.serve);
      expect(await g.check('fd00::5'), TomSecretsRelayVerdict.serve);
      expect(await g.check('10.9.1.1'), TomSecretsRelayVerdict.refuse);
      expect(await g.check('192.168.1.1'), TomSecretsRelayVerdict.refuse);
      expect(await g.check('unknown'), TomSecretsRelayVerdict.refuse);
    });

    test('without allow ranges every address not denied is served', () async {
      final g = TomSecretsRelayAddressGuard(
        const TomSecretsRelayConfig(deny: ['203.0.113.0/24']),
      );
      expect(await g.check('198.51.100.7'), TomSecretsRelayVerdict.serve);
      expect(await g.check('203.0.113.9'), TomSecretsRelayVerdict.refuse);
    });
  });

  group('the denial-of-service protection', () {
    late DateTime now;
    late Directory dir;
    setUp(() async {
      now = DateTime.utc(2026, 11, 23, 12);
      dir = await Directory.systemTemp.createTemp('relay_guard');
    });
    tearDown(() => dir.delete(recursive: true));

    TomSecretsRelayAddressGuard guard([
      TomSecretsRelayConfig config = const TomSecretsRelayConfig(),
    ]) => TomSecretsRelayAddressGuard(
      config,
      blockFile: File('${dir.path}/blocks.json'),
      clock: () => now,
    );

    test('an eleventh request in one second blocks the address', () async {
      final g = guard();
      for (var i = 0; i < 10; i++) {
        expect(await g.check('198.51.100.1'), TomSecretsRelayVerdict.serve);
      }
      expect(await g.check('198.51.100.1'), TomSecretsRelayVerdict.ignore);
      expect(
        g.blockedUntil('198.51.100.1'),
        now.add(const Duration(hours: 24)),
      );
      // Another address is not affected.
      expect(await g.check('198.51.100.2'), TomSecretsRelayVerdict.serve);
    });

    // The three limits are checked together on sliding windows, so at a
    // steady pace the second's limit trips first; each limit is shown alone
    // with the others raised.
    test('121 requests in a minute block the address', () async {
      final g = guard(const TomSecretsRelayConfig(requestsPerSecond: 1000));
      for (var i = 0; i < 120; i++) {
        expect(await g.check('198.51.100.3'), TomSecretsRelayVerdict.serve);
        now = now.add(const Duration(milliseconds: 100));
      }
      expect(await g.check('198.51.100.3'), TomSecretsRelayVerdict.ignore);
    });

    test('2,001 requests in a day block the address', () async {
      final g = guard(
        const TomSecretsRelayConfig(
          requestsPerSecond: 1000,
          requestsPerMinute: 1000,
        ),
      );
      var verdict = TomSecretsRelayVerdict.serve;
      var n = 0;
      while (verdict == TomSecretsRelayVerdict.serve && n < 2500) {
        verdict = await g.check('198.51.100.4');
        now = now.add(const Duration(seconds: 1));
        n++;
      }
      expect(verdict, TomSecretsRelayVerdict.ignore);
      expect(n, 2001);
    });

    test('blocks escalate: 24 h, 48 h, a week, then doubling', () async {
      final g = guard();
      Future<Duration> blockOnce() async {
        while (await g.check('198.51.100.5') == TomSecretsRelayVerdict.serve) {}
        final until = g.blockedUntil('198.51.100.5')!;
        final length = until.difference(now);
        now = until.add(const Duration(seconds: 2));
        return length;
      }

      expect(await blockOnce(), const Duration(hours: 24));
      expect(await blockOnce(), const Duration(hours: 48));
      expect(await blockOnce(), const Duration(days: 7));
      expect(await blockOnce(), const Duration(days: 14));
      expect(g.blockCount('198.51.100.5'), 4);
    });

    test('a blocked address is ignored until the block ends', () async {
      final g = guard();
      while (await g.check('198.51.100.6') == TomSecretsRelayVerdict.serve) {}
      now = now.add(const Duration(hours: 23));
      expect(await g.check('198.51.100.6'), TomSecretsRelayVerdict.ignore);
      now = now.add(const Duration(hours: 2));
      expect(await g.check('198.51.100.6'), TomSecretsRelayVerdict.serve);
    });

    test('the block list survives a restart', () async {
      final g = guard();
      while (await g.check('198.51.100.7') == TomSecretsRelayVerdict.serve) {}
      final again = guard();
      expect(await again.check('198.51.100.7'), TomSecretsRelayVerdict.ignore);
      expect(again.blockCount('198.51.100.7'), 1);
    });

    test('a block older than the remembered time counts from one', () async {
      final g = guard();
      while (await g.check('198.51.100.8') == TomSecretsRelayVerdict.serve) {}
      now = now.add(const Duration(days: 91));
      g.expire();
      expect(g.blockCount('198.51.100.8'), 0);
      while (await g.check('198.51.100.8') == TomSecretsRelayVerdict.serve) {}
      expect(g.blockCount('198.51.100.8'), 1);
      expect(
        g.blockedUntil('198.51.100.8'),
        now.add(const Duration(hours: 24)),
      );
    });
  });
}
