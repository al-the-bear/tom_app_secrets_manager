// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import 'package:test/test.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

void main() {
  group('TomSecretsRelayConfig', () {
    test('the defaults are part-relay\'s numbers, token mode first', () {
      final c = TomSecretsRelayConfig.fromMap(null);
      expect(c.mode, TomSecretsRelayMode.token);
      expect(c.tokens, isEmpty);
      expect(
        [c.requestsPerSecond, c.requestsPerMinute, c.requestsPerDay],
        [10, 120, 2000],
      );
      expect(c.nameplatesPerHour, 10);
      expect(c.nameplateLifetime, const Duration(minutes: 10));
      expect(c.pairingFrameBytes, 64 * 1024);
      expect(c.pairingChannelBytes, 1024 * 1024);
      expect(c.linksPerToken, 10);
      expect(c.linkFrameBytes, 64 * 1024);
      expect(c.linkAloneTimeout, const Duration(hours: 24));
      expect(c.putsPerHour, 30);
      expect(c.itemBytes, 1024 * 1024);
      expect(c.itemsPerRecipient, 200);
      expect(c.bytesPerRecipient, 50 * 1024 * 1024);
      expect(c.maxExpiry, const Duration(days: 30));
      expect(c.challengesPerHour, 20);
      expect(c.proofLifetime, const Duration(minutes: 5));
      expect(c.expiryInterval, const Duration(minutes: 10));
      expect(c.trustedProxies, ['127.0.0.1', '::1']);
    });

    test('blocks last 24 h, 48 h, a week, then twice the one before', () {
      const c = TomSecretsRelayConfig();
      expect(c.blockDuration(1), const Duration(hours: 24));
      expect(c.blockDuration(2), const Duration(hours: 48));
      expect(c.blockDuration(3), const Duration(days: 7));
      expect(c.blockDuration(4), const Duration(days: 14));
      expect(c.blockDuration(5), const Duration(days: 28));
    });

    test('reads every section of the configuration', () {
      final c = TomSecretsRelayConfig.fromMap({
        'mode': 'open',
        'tokens': {'team-a': 'aaaaaaaaaaaaaaaaaaaa'},
        'deny': ['10.0.0.0/8'],
        'allow': '192.168.0.0/16, fd00::/8',
        'trustedProxies': ['10.1.1.1'],
        'storage': '/data',
        'dos': {
          'perSecond': 3,
          'perMinute': 60,
          'perDay': 1000,
          'blockHours': [1, 2],
          'rememberDays': 7,
        },
        'pairing': {'nameplatesPerHour': 4, 'minutes': 5},
        'link': {'perToken': 2, 'aloneHours': 1},
        'mailbox': {'putsPerHour': 5, 'itemBytes': 100, 'maxExpiryDays': 7},
        'proof': {'challengesPerHour': 3, 'minutes': 2},
        'expiryMinutes': 1,
      });
      expect(c.mode, TomSecretsRelayMode.open);
      expect(c.tokenName('aaaaaaaaaaaaaaaaaaaa'), 'team-a');
      expect(c.tokenName('bbbbbbbbbbbbbbbbbbbb'), isNull);
      expect(c.allow, ['192.168.0.0/16', 'fd00::/8']);
      expect(c.trustedProxies, ['10.1.1.1']);
      expect(c.storageDirectory, '/data');
      expect(c.requestsPerSecond, 3);
      expect(c.blockDuration(3), const Duration(hours: 4));
      expect(c.blockMemory, const Duration(days: 7));
      expect(c.nameplateLifetime, const Duration(minutes: 5));
      expect(c.linksPerToken, 2);
      expect(c.linkAloneTimeout, const Duration(hours: 1));
      expect(c.itemBytes, 100);
      expect(c.maxExpiry, const Duration(days: 7));
      expect(c.proofLifetime, const Duration(minutes: 2));
      expect(c.expiryInterval, const Duration(minutes: 1));
    });

    test('refuses what it cannot read, naming the setting', () {
      Matcher names(String key) => throwsA(
        isA<TomSecretsRelayConfigException>().having((e) => e.key, 'key', key),
      );
      expect(
        () => TomSecretsRelayConfig.fromMap({'mode': 'closed'}),
        names('mode'),
      );
      expect(
        () => TomSecretsRelayConfig.fromMap({
          'tokens': {'a': 'short'},
        }),
        names('tokens.a'),
      );
      expect(
        () => TomSecretsRelayConfig.fromMap({
          'dos': {'perSecond': 0},
        }),
        names('dos.perSecond'),
      );
      expect(
        () => TomSecretsRelayConfig.fromMap({
          'tokens': ['x'],
        }),
        names('tokens'),
      );
    });

    test('refuses a secret reference as a token: the relay resolves none, '
        'and taking the reference itself as the token would admit whoever '
        'reads the file and refuse the token\'s real holders', () {
      expect(
        () => TomSecretsRelayConfig.fromMap({
          'tokens': {'team-a': 'secret:local:relay/team-a#Password'},
        }),
        throwsA(
          isA<TomSecretsRelayConfigException>()
              .having((e) => e.key, 'key', 'tokens.team-a')
              .having((e) => e.message, 'message', contains('not resolved')),
        ),
      );
    });
  });
}
