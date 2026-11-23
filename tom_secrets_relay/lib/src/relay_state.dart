// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** What a running relay holds: its settings, the address guard, the
/// rendezvous, the mailboxes and the proofs, the per-token limits, and the
/// guard that runs before every route (the server's authentication
/// middleware, `tom_core_server`'s own inside it).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:tom_core_server/tom_core_server.dart';

import 'address_guard.dart';
import 'config.dart';
import 'mailbox.dart';
import 'rendezvous.dart';

/// A running relay's state.
final class TomSecretsRelayState {
  /// The state of a relay with [config], the time read from [clock].
  TomSecretsRelayState(this.config, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now {
    final dir = Directory(config.storageDirectory);
    guard = TomSecretsRelayAddressGuard(
      config,
      blockFile: File(p.join(dir.path, 'blocks.json')),
      clock: this.clock,
    );
    rendezvous = TomSecretsRelayRendezvous(config, clock: this.clock);
    mailbox = TomSecretsRelayMailbox(
      TomDirectoryBlobStore(Directory(p.join(dir.path, 'mailbox'))),
      config,
      clock: this.clock,
    );
    proofs = TomSecretsRelayProofs(config, clock: this.clock);
    _limiter = TomMemoryRateLimiter(clock: this.clock);
  }

  /// The settings.
  final TomSecretsRelayConfig config;

  /// The time.
  final DateTime Function() clock;

  /// The filters and the block list.
  late final TomSecretsRelayAddressGuard guard;

  /// The nameplates and links.
  late final TomSecretsRelayRendezvous rendezvous;

  /// The mailboxes.
  late final TomSecretsRelayMailbox mailbox;

  /// The recipients' proofs.
  late final TomSecretsRelayProofs proofs;

  late final TomMemoryRateLimiter _limiter;

  /// The client address of [request] (the trusted proxy's
  /// `X-Forwarded-For` read), or `unknown`.
  String addressOf(Request request) =>
      TomClientAddress.of(
        request,
        trustedProxies: config.trustedProxies.toSet(),
      ) ??
      'unknown';

  /// The name of the instance token [request] carries
  /// (`Authorization: Bearer <token>`), or null.
  String? tokenOf(Request request) => config.tokenName(bearerOf(request));

  /// The bearer credential of [request], or null.
  static String? bearerOf(Request request) {
    final h = request.headers['authorization'];
    if (h == null) return null;
    final m = RegExp(
      r'^\s*Bearer\s+(\S+)\s*$',
      caseSensitive: false,
    ).firstMatch(h);
    return m?.group(1);
  }

  /// Counts one use of [bucket] against at most [limit] per [window];
  /// throws [TomSecretsRelayRefused] (429) past it.
  Future<void> limit(
    String rule,
    String bucket,
    int limit,
    Duration window,
    String what,
  ) async {
    final d = await _limiter.hit(
      '$rule|$bucket',
      TomRateLimitRule(
        name: rule,
        scope: TomRateLimitScope.address,
        limit: limit,
        window: window,
      ),
    );
    if (!d.allowed) {
      throw TomSecretsRelayRefused(
        429,
        'at most $limit $what',
        retryAfter: d.retryAfter,
      );
    }
  }

  /// Whether [segments] (a request's path) is one of the relay's routes:
  /// `/health`, `/ready` and the `/v1` endpoints. Everything else the
  /// framework would mount (its own services) is answered 404.
  static bool isRelayPath(List<String> segments) {
    if (segments.length == 1) {
      return segments[0] == 'health' || segments[0] == 'ready';
    }
    if (segments.isEmpty || segments[0] != 'v1') return false;
    return switch (segments.length) {
      2 => segments[1] == 'pair',
      3 => const {'pair', 'link', 'mailbox'}.contains(segments[1]),
      4 => segments[1] == 'mailbox',
      _ => false,
    };
  }

  /// The guard around the routes (with `tom_core_server`'s authentication
  /// middleware inside it): a path that is not the relay's answered 404,
  /// the address filters (403), a blocked address ignored (the connection
  /// closed without an answer), and the refusals a WebSocket would get,
  /// answered before the upgrade.
  Middleware guardMiddleware() {
    final authentication = tomDefaultAuthenticationMiddleware(
      'tom_secrets_relay',
    );
    return (inner) {
      final authenticated = authentication(inner);
      return (request) async {
        final segments = request.url.pathSegments;
        if (!isRelayPath(segments)) return jsonError(404, 'not found');
        if (segments.length == 1) return authenticated(request);
        final verdict = await guard.check(addressOf(request));
        switch (verdict) {
          case TomSecretsRelayVerdict.refuse:
            return jsonError(403, 'this address is not served');
          case TomSecretsRelayVerdict.ignore:
            request.hijack((channel) => channel.sink.close());
          case TomSecretsRelayVerdict.serve:
            break;
        }
        final upgrade =
            request.headers['upgrade']?.toLowerCase() == 'websocket';
        if (upgrade && segments.length == 3) {
          try {
            if (segments[1] == 'pair') rendezvous.checkPair(segments[2]);
            if (segments[1] == 'link') {
              rendezvous.checkLink(segments[2], tokenOf(request));
            }
          } on TomSecretsRelayRefusal catch (e) {
            return jsonError(e.status, e.message);
          }
        }
        return authenticated(request);
      };
    };
  }

  /// Closes every channel (the server stops).
  void close() => rendezvous.closeAll();

  /// The expiry job: expired mailbox items, nameplates, proofs and old block
  /// records.
  Future<void> expire() async {
    final items = await mailbox.expire();
    final nameplates = rendezvous.expire();
    proofs.expire();
    guard.expire();
    if (items > 0 || nameplates > 0) {
      tomLog.info(
        'relay: expired $items mailbox items and $nameplates nameplates',
      );
    }
  }
}

/// A JSON error answer `{"error": message}` with [status] (and
/// `Retry-After` for a 429).
Response jsonError(int status, String message, {Duration? retryAfter}) =>
    Response(
      status,
      body: jsonEncode({'error': message}),
      headers: {
        'content-type': 'application/json',
        if (retryAfter != null)
          'retry-after':
              '${retryAfter.inSeconds < 1 ? 1 : retryAfter.inSeconds}',
      },
    );
