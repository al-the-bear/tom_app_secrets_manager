// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The pairing rendezvous and the approval links (part-relay): two
/// WebSocket connections joined under a nameplate or a link id, every
/// binary frame of one sent to the other. Held in memory only: a restart
/// drops open pairings and links, and the devices connect again.
///
/// - **Pairing:** `allocate` hands out a nameplate (1–999, unique among the
///   open ones) for 10 minutes. The first two connections to it are
///   joined; a third is refused. The nameplate is released when either
///   side leaves, or at its expiry. 64 KB per frame, 1 MB per channel.
/// - **Link:** two connections to one link id are joined, with no expiry
///   while both stay; a side alone waits up to 24 hours; a third is
///   refused. 10 open links per instance token, 64 KB per frame. When one
///   side leaves, the other is closed too, so both connect again and run
///   the link's handshake afresh.
library;

import 'dart:async';
import 'dart:math';

import 'config.dart';

/// The close codes the relay ends a WebSocket with (4000–4999, the range
/// RFC 6455 leaves to applications).
abstract final class TomSecretsRelayClose {
  /// The other side left.
  static const peerLeft = 4000;

  /// A frame that is not binary.
  static const notBinary = 4400;

  /// No instance token, or an unknown one (a link in token mode).
  static const unauthorized = 4401;

  /// No open nameplate of that number (never allocated, or expired).
  static const unknown = 4404;

  /// The nameplate's or link's time ran out.
  static const expired = 4408;

  /// Two sides are connected already.
  static const taken = 4409;

  /// A frame or the channel is larger than the limits allow.
  static const tooLarge = 4413;

  /// Too many open links for the token.
  static const tooMany = 4429;

  /// The relay stops.
  static const stopping = 4503;
}

/// One side of a joined channel: a WebSocket connection.
abstract interface class TomSecretsRelayPeer {
  /// Sends a binary frame.
  void send(List<int> bytes);

  /// Closes the connection with [code] and [reason].
  Future<void> close(int code, String reason);
}

/// Why a connection was refused, with the close code.
final class TomSecretsRelayRefusal implements Exception {
  /// A refusal with [code] (a [TomSecretsRelayClose] code), the HTTP
  /// [status] the same refusal answers before an upgrade, and [message].
  const TomSecretsRelayRefusal(this.code, this.status, this.message);

  /// The WebSocket close code.
  final int code;

  /// The HTTP status.
  final int status;

  /// For people.
  final String message;

  @override
  String toString() => 'TomSecretsRelayRefusal($code): $message';
}

/// An open nameplate, as `POST /v1/pair` answers it.
typedef TomSecretsRelayNameplate = ({String nameplate, DateTime expires});

/// A channel: up to two peers and what they sent.
final class TomSecretsRelayChannel {
  TomSecretsRelayChannel._(this.key, this.frameLimit, this.channelLimit);

  /// The nameplate or link id.
  final String key;

  /// The largest frame.
  final int frameLimit;

  /// The most bytes the channel carries (null: no limit).
  final int? channelLimit;

  final List<TomSecretsRelayPeer> _peers = [];
  final List<List<int>> _pending = [];
  int _pendingBytes = 0;
  int _bytes = 0;
  bool _ended = false;

  /// How many sides are connected.
  int get sides => _peers.length;

  /// Whether the channel was ended.
  bool get ended => _ended;

  /// Forwards [bytes] from [from] to the other side (kept until it comes
  /// while it is alone, at most [_pendingLimit] bytes); a frame or a
  /// channel over its limit ends the channel.
  void forward(TomSecretsRelayPeer from, List<int> bytes) {
    if (_ended) return;
    if (bytes.length > frameLimit) {
      _endAll(TomSecretsRelayClose.tooLarge, 'a frame is larger than allowed');
      return;
    }
    _bytes += bytes.length;
    final limit = channelLimit;
    if (limit != null && _bytes > limit) {
      _endAll(
        TomSecretsRelayClose.tooLarge,
        'the channel carried more than allowed',
      );
      return;
    }
    if (_peers.length < 2) {
      _pendingBytes += bytes.length;
      if (_pendingBytes > _pendingLimit) {
        _endAll(
          TomSecretsRelayClose.tooLarge,
          'more was sent than waits for the other device',
        );
        return;
      }
      _pending.add(bytes);
      return;
    }
    for (final p in _peers) {
      if (!identical(p, from)) p.send(bytes);
    }
  }

  /// The most bytes kept for a side that has not come yet.
  int get _pendingLimit => channelLimit ?? 16 * frameLimit;

  void _add(TomSecretsRelayPeer peer) {
    _peers.add(peer);
    if (_peers.length == 2 && _pending.isNotEmpty) {
      for (final bytes in _pending) {
        peer.send(bytes);
      }
      _pending.clear();
      _pendingBytes = 0;
    }
  }

  void _endAll(int code, String reason) {
    if (_ended) return;
    _ended = true;
    _pending.clear();
    final peers = [..._peers];
    _peers.clear();
    for (final p in peers) {
      unawaited(p.close(code, reason));
    }
  }
}

/// The nameplates and links of a relay.
final class TomSecretsRelayRendezvous {
  /// The rendezvous under [config], the time read from [clock].
  TomSecretsRelayRendezvous(
    this.config, {
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  /// The settings.
  final TomSecretsRelayConfig config;
  final DateTime Function() _clock;
  final Random _random;

  final Map<String, DateTime> _nameplates = {};
  final Map<String, TomSecretsRelayChannel> _pairs = {};
  final Map<String, TomSecretsRelayChannel> _links = {};
  final Map<String, Timer> _alone = {};

  /// The open links of each token (by name): the link ids it holds a side
  /// of, with how many sides.
  final Map<String, Map<String, int>> _linksOf = {};

  /// How many nameplates are open.
  int get openNameplates => _nameplates.length;

  /// How many links have a side connected.
  int get openLinks => _links.length;

  /// Allocates a nameplate for 10 minutes; throws [StateError] when all
  /// 999 are taken.
  TomSecretsRelayNameplate allocate() {
    _expireNameplates();
    if (_nameplates.length >= 999) {
      throw StateError('every nameplate is taken');
    }
    String n;
    do {
      n = '${1 + _random.nextInt(999)}';
    } while (_nameplates.containsKey(n));
    final expires = _clock().add(config.nameplateLifetime);
    _nameplates[n] = expires;
    return (nameplate: n, expires: expires);
  }

  /// Throws the [TomSecretsRelayRefusal] a connection to the nameplate [n]
  /// would get now (before the upgrade; [joinPair] checks again).
  void checkPair(String n) {
    final expires = _nameplates[n];
    if (expires == null || !expires.isAfter(_clock())) {
      throw TomSecretsRelayRefusal(
        TomSecretsRelayClose.unknown,
        404,
        'no pairing is open under $n',
      );
    }
    if ((_pairs[n]?.sides ?? 0) >= 2 || (_pairs[n]?.ended ?? false)) {
      throw TomSecretsRelayRefusal(
        TomSecretsRelayClose.taken,
        409,
        'two devices are connected to $n already',
      );
    }
  }

  /// Joins [peer] to the pairing under [n]; throws [TomSecretsRelayRefusal].
  TomSecretsRelayChannel joinPair(String n, TomSecretsRelayPeer peer) {
    checkPair(n);
    final channel = _pairs.putIfAbsent(
      n,
      () => TomSecretsRelayChannel._(
        n,
        config.pairingFrameBytes,
        config.pairingChannelBytes,
      ),
    );
    channel._add(peer);
    return channel;
  }

  /// [peer] left the pairing [channel]: the other side is closed and the
  /// nameplate released.
  void leavePair(TomSecretsRelayChannel channel, TomSecretsRelayPeer peer) {
    final wasThere = channel._peers.remove(peer);
    if (wasThere || !channel._ended) {
      channel._endAll(TomSecretsRelayClose.peerLeft, 'the other device left');
    }
    if (identical(_pairs[channel.key], channel)) {
      _pairs.remove(channel.key);
      _nameplates.remove(channel.key);
    }
  }

  /// Throws the [TomSecretsRelayRefusal] a link connection under [linkId]
  /// with the token named [token] (null: open mode) would get now.
  void checkLink(String linkId, String? token) {
    if (config.mode == TomSecretsRelayMode.token && token == null) {
      throw const TomSecretsRelayRefusal(
        TomSecretsRelayClose.unauthorized,
        401,
        'this relay opens approval links only for holders of an instance '
        'token: add the token to the relay in the app\'s relay settings',
      );
    }
    if ((_links[linkId]?.sides ?? 0) >= 2) {
      throw const TomSecretsRelayRefusal(
        TomSecretsRelayClose.taken,
        409,
        'two devices are connected to this link already',
      );
    }
    if (token != null) {
      final held = _linksOf[token] ?? const {};
      if (!held.containsKey(linkId) && held.length >= config.linksPerToken) {
        throw TomSecretsRelayRefusal(
          TomSecretsRelayClose.tooMany,
          429,
          'the token holds ${config.linksPerToken} open links already',
        );
      }
    }
  }

  /// Joins [peer] to the link [linkId], opened with the token named
  /// [token] (null: open mode); throws [TomSecretsRelayRefusal].
  TomSecretsRelayChannel joinLink(
    String linkId,
    String? token,
    TomSecretsRelayPeer peer,
  ) {
    checkLink(linkId, token);
    final channel = _links.putIfAbsent(
      linkId,
      () => TomSecretsRelayChannel._(linkId, config.linkFrameBytes, null),
    );
    channel._add(peer);
    if (token != null) {
      final held = _linksOf.putIfAbsent(token, () => {});
      held[linkId] = (held[linkId] ?? 0) + 1;
    }
    _alone.remove(linkId)?.cancel();
    if (channel.sides == 1) {
      _alone[linkId] = Timer(config.linkAloneTimeout, () {
        _alone.remove(linkId);
        channel._endAll(
          TomSecretsRelayClose.expired,
          'no other device came within the waiting time',
        );
      });
    }
    return channel;
  }

  /// [peer], which joined with the token named [token], left the link
  /// [channel]: the other side is closed too and the link released.
  void leaveLink(
    TomSecretsRelayChannel channel,
    String? token,
    TomSecretsRelayPeer peer,
  ) {
    final wasThere = channel._peers.remove(peer);
    if (token != null) {
      final held = _linksOf[token];
      final n = (held?[channel.key] ?? 0) - 1;
      if (n <= 0) {
        held?.remove(channel.key);
      } else {
        held![channel.key] = n;
      }
      if (held != null && held.isEmpty) _linksOf.remove(token);
    }
    if (wasThere && !channel._ended) {
      channel._endAll(TomSecretsRelayClose.peerLeft, 'the other device left');
    }
    if (identical(_links[channel.key], channel) &&
        (channel._ended || channel._peers.isEmpty)) {
      _links.remove(channel.key);
      _alone.remove(channel.key)?.cancel();
    }
  }

  /// Closes the pairings whose nameplate expired (the expiry job); answers
  /// how many.
  int expire() => _expireNameplates();

  int _expireNameplates() {
    final now = _clock();
    final gone = [
      for (final e in _nameplates.entries)
        if (!e.value.isAfter(now)) e.key,
    ];
    for (final n in gone) {
      _nameplates.remove(n);
      _pairs
          .remove(n)
          ?._endAll(TomSecretsRelayClose.expired, 'the nameplate expired');
    }
    return gone.length;
  }

  /// Closes every channel (the server stops).
  void closeAll() {
    for (final c in [..._pairs.values, ..._links.values]) {
      c._endAll(TomSecretsRelayClose.stopping, 'the relay stops');
    }
    for (final t in _alone.values) {
      t.cancel();
    }
    _alone.clear();
    _pairs.clear();
    _links.clear();
    _nameplates.clear();
    _linksOf.clear();
  }
}
