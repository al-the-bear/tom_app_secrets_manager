// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

final class _Peer implements TomSecretsRelayPeer {
  final List<List<int>> got = [];
  int? closedWith;

  @override
  void send(List<int> bytes) => got.add(bytes);

  @override
  Future<void> close(int code, String reason) async => closedWith ??= code;
}

Matcher _refused(int code, int status) => throwsA(
  isA<TomSecretsRelayRefusal>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.status, 'status', status),
);

void main() {
  late DateTime now;
  setUp(() => now = DateTime.utc(2026, 11, 23, 12));

  TomSecretsRelayRendezvous rendezvous([
    TomSecretsRelayConfig config = const TomSecretsRelayConfig(),
  ]) => TomSecretsRelayRendezvous(config, clock: () => now);

  group('pairing', () {
    test('nameplates are 1-999, unique among the open ones', () {
      final r = rendezvous();
      final seen = <String>{};
      for (var i = 0; i < 999; i++) {
        final n = r.allocate();
        final value = int.parse(n.nameplate);
        expect(value, inInclusiveRange(1, 999));
        expect(seen.add(n.nameplate), isTrue);
        expect(n.expires, now.add(const Duration(minutes: 10)));
      }
      expect(r.allocate, throwsStateError);
    });

    test('the first two are joined, a third is refused', () {
      final r = rendezvous();
      final n = r.allocate().nameplate;
      final a = _Peer(), b = _Peer();
      final channel = r.joinPair(n, a);
      expect(r.joinPair(n, b), same(channel));
      channel.forward(a, [1, 2]);
      channel.forward(b, [3]);
      expect(b.got, [
        [1, 2],
      ]);
      expect(a.got, [
        [3],
      ]);
      expect(
        () => r.joinPair(n, _Peer()),
        _refused(TomSecretsRelayClose.taken, 409),
      );
    });

    test('what a side sends alone waits for the other', () {
      final r = rendezvous();
      final n = r.allocate().nameplate;
      final a = _Peer(), b = _Peer();
      final channel = r.joinPair(n, a);
      channel.forward(a, [9]);
      r.joinPair(n, b);
      expect(b.got, [
        [9],
      ]);
    });

    test('an unknown or expired nameplate is refused', () {
      final r = rendezvous();
      expect(
        () => r.joinPair('5', _Peer()),
        _refused(TomSecretsRelayClose.unknown, 404),
      );
      final n = r.allocate().nameplate;
      now = now.add(const Duration(minutes: 11));
      expect(
        () => r.joinPair(n, _Peer()),
        _refused(TomSecretsRelayClose.unknown, 404),
      );
    });

    test('expiry closes an open pairing and frees its nameplate', () {
      final r = rendezvous();
      final n = r.allocate().nameplate;
      final a = _Peer();
      r.joinPair(n, a);
      now = now.add(const Duration(minutes: 10, seconds: 1));
      expect(r.expire(), 1);
      expect(a.closedWith, TomSecretsRelayClose.expired);
      expect(r.openNameplates, 0);
    });

    test('a side leaving closes the other and releases the nameplate', () {
      final r = rendezvous();
      final n = r.allocate().nameplate;
      final a = _Peer(), b = _Peer();
      final channel = r.joinPair(n, a);
      r.joinPair(n, b);
      r.leavePair(channel, a);
      expect(b.closedWith, TomSecretsRelayClose.peerLeft);
      expect(r.openNameplates, 0);
      expect(
        () => r.joinPair(n, _Peer()),
        _refused(TomSecretsRelayClose.unknown, 404),
      );
    });

    test('64 KB per frame, 1 MB per channel', () {
      final r = rendezvous();
      final n = r.allocate().nameplate;
      final a = _Peer(), b = _Peer();
      final channel = r.joinPair(n, a);
      r.joinPair(n, b);
      channel.forward(a, List.filled(64 * 1024, 1));
      expect(b.got, hasLength(1));
      channel.forward(a, List.filled(64 * 1024 + 1, 1));
      expect(a.closedWith, TomSecretsRelayClose.tooLarge);
      expect(b.closedWith, TomSecretsRelayClose.tooLarge);

      final n2 = r.allocate().nameplate;
      final c = _Peer(), d = _Peer();
      final second = r.joinPair(n2, c);
      r.joinPair(n2, d);
      for (var i = 0; i < 16; i++) {
        second.forward(c, List.filled(64 * 1024, 1));
      }
      expect(c.closedWith, isNull);
      second.forward(c, [1]);
      expect(c.closedWith, TomSecretsRelayClose.tooLarge);
    });
  });

  group('the approval link', () {
    const tokenMode = TomSecretsRelayConfig(
      tokens: {'team': 'tttttttttttttttttttt'},
    );

    test('needs a token in token mode, none in open mode', () {
      expect(
        () => rendezvous(tokenMode).joinLink('L1', null, _Peer()),
        _refused(TomSecretsRelayClose.unauthorized, 401),
      );
      rendezvous(
        const TomSecretsRelayConfig(mode: TomSecretsRelayMode.open),
      ).joinLink('L1', null, _Peer());
    });

    test('two sides are joined, a third refused, no expiry', () {
      final r = rendezvous(tokenMode);
      final a = _Peer(), b = _Peer();
      final channel = r.joinLink('L1', 'team', a);
      r.joinLink('L1', 'team', b);
      expect(
        () => r.joinLink('L1', 'team', _Peer()),
        _refused(TomSecretsRelayClose.taken, 409),
      );
      now = now.add(const Duration(days: 3));
      r.expire();
      channel.forward(a, [7]);
      expect(b.got, [
        [7],
      ]);
      expect(a.closedWith, isNull);
    });

    test('a side leaving closes the other; both connect again', () {
      final r = rendezvous(tokenMode);
      final a = _Peer(), b = _Peer();
      final channel = r.joinLink('L1', 'team', a);
      r.joinLink('L1', 'team', b);
      r.leaveLink(channel, 'team', a);
      expect(b.closedWith, TomSecretsRelayClose.peerLeft);
      r.leaveLink(channel, 'team', b);
      expect(r.openLinks, 0);
      final c = _Peer(), d = _Peer();
      final again = r.joinLink('L1', 'team', c);
      r.joinLink('L1', 'team', d);
      again.forward(d, [1]);
      expect(c.got, [
        [1],
      ]);
    });

    test('a side alone waits up to its timeout', () async {
      final r = rendezvous(
        const TomSecretsRelayConfig(
          mode: TomSecretsRelayMode.open,
          linkAloneTimeout: Duration(milliseconds: 50),
        ),
      );
      final a = _Peer();
      r.joinLink('L2', null, a);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(a.closedWith, TomSecretsRelayClose.expired);
    });

    test('10 open links per token', () {
      final r = rendezvous(tokenMode);
      for (var i = 0; i < 10; i++) {
        r.joinLink('L$i', 'team', _Peer());
      }
      // The other side of a held link still joins.
      r.joinLink('L3', 'team', _Peer());
      expect(
        () => r.joinLink('L10', 'team', _Peer()),
        _refused(TomSecretsRelayClose.tooMany, 429),
      );
    });

    test('64 KB per frame', () {
      final r = rendezvous(tokenMode);
      final a = _Peer(), b = _Peer();
      final channel = r.joinLink('L1', 'team', a);
      r.joinLink('L1', 'team', b);
      channel.forward(a, List.filled(64 * 1024 + 1, 0));
      expect(b.closedWith, TomSecretsRelayClose.tooLarge);
    });
  });
}
