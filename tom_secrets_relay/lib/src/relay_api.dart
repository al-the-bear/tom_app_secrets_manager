// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// **[C]** The relay's endpoints under `/v1` (part-relay):
///
/// | Endpoint | Purpose |
/// | --- | --- |
/// | `POST /v1/pair` | a nameplate for 10 minutes: `{nameplate, expires}` |
/// | `GET /v1/pair/<nameplate>` | WebSocket: the pairing channel |
/// | `GET /v1/link/<link-id>` | WebSocket: the approval link (a token in token mode) |
/// | `PUT /v1/mailbox/<recipient>/<item-id>` | stores a package; `Tsm-Expires` |
/// | `POST /v1/mailbox/<recipient>/challenge` | the recipient's proof |
/// | `GET /v1/mailbox/<recipient>` | the items waiting (with the proof) |
/// | `GET` / `DELETE /v1/mailbox/<recipient>/<item-id>` | one item (with the proof) |
///
/// Every endpoint is public in `tom_core_server`'s sense: the relay has no
/// users. An instance token and a proof travel as `Authorization: Bearer`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:tom_core_server/tom_core_server.dart';

import 'config.dart';
import 'mailbox.dart';
import 'relay_state.dart';
import 'rendezvous.dart';

/// The relay's API.
@tomReflector
@TomService(version: 1)
abstract class TomSecretsRelayService {
  /// Allocates a nameplate.
  @TomPublicAccess()
  @TomEndpoint(
    methods: [TomHttpMethod.post],
    uri: '/pair',
    consumes: TomMimeType.octetStream,
    produces: TomMimeType.json,
  )
  Future<Response> allocate(Request request);

  /// A pairing channel under [nameplate].
  @TomPublicAccess()
  @TomWebSocketEndpoint(uri: '/pair/{nameplate}')
  Future<void> pair(TomWebSocketConnection socket, String nameplate);

  /// An approval link under [linkId].
  @TomPublicAccess()
  @TomWebSocketEndpoint(uri: '/link/{linkId}')
  Future<void> link(
    TomWebSocketConnection socket,
    Request request,
    String linkId,
  );

  /// Stores a package for [recipient] as [itemId].
  @TomPublicAccess()
  @TomEndpoint(
    methods: [TomHttpMethod.put],
    uri: '/mailbox/{recipient}/{itemId}',
    consumes: TomMimeType.octetStream,
    produces: TomMimeType.json,
  )
  Future<Response> put(Request request, String recipient, String itemId);

  /// The proof's challenge for [recipient].
  @TomPublicAccess()
  @TomEndpoint(
    methods: [TomHttpMethod.post],
    uri: '/mailbox/{recipient}/challenge',
    consumes: TomMimeType.octetStream,
    produces: TomMimeType.octetStream,
  )
  Future<Response> challenge(Request request, String recipient);

  /// The items waiting for [recipient].
  @TomPublicAccess()
  @TomEndpoint(
    methods: [TomHttpMethod.get],
    uri: '/mailbox/{recipient}',
    consumes: TomMimeType.octetStream,
    produces: TomMimeType.json,
  )
  Future<Response> list(Request request, String recipient);

  /// One item.
  @TomPublicAccess()
  @TomEndpoint(
    methods: [TomHttpMethod.get],
    uri: '/mailbox/{recipient}/{itemId}',
    consumes: TomMimeType.octetStream,
    produces: TomMimeType.octetStream,
  )
  Future<Response> fetch(Request request, String recipient, String itemId);

  /// Deletes one item.
  @TomPublicAccess()
  @TomEndpoint(
    methods: [TomHttpMethod.delete],
    uri: '/mailbox/{recipient}/{itemId}',
    consumes: TomMimeType.octetStream,
    produces: TomMimeType.json,
  )
  Future<Response> delete(Request request, String recipient, String itemId);
}

/// The relay's API over a [TomSecretsRelayState].
@tomReflector
@tomComponent
class TomSecretsRelayServer implements TomSecretsRelayService {
  /// The API of [state].
  TomSecretsRelayServer(this.state);

  /// The relay's state.
  final TomSecretsRelayState state;

  TomSecretsRelayConfig get _config => state.config;

  static Response _json(Object body, {int status = 200}) => Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );

  Future<Response> _answer(Future<Response> Function() body) async {
    try {
      return await body();
    } on TomSecretsRelayRefused catch (e) {
      return jsonError(e.status, e.message, retryAfter: e.retryAfter);
    }
  }

  @override
  Future<Response> allocate(Request request) => _answer(() async {
    await state.limit(
      'nameplates',
      state.addressOf(request),
      _config.nameplatesPerHour,
      const Duration(hours: 1),
      'nameplates per address per hour',
    );
    final TomSecretsRelayNameplate n;
    try {
      n = state.rendezvous.allocate();
    } on StateError {
      return jsonError(
        503,
        'every nameplate is taken',
        retryAfter: const Duration(minutes: 1),
      );
    }
    return _json({
      'nameplate': n.nameplate,
      'expires': n.expires.toUtc().toIso8601String(),
    });
  });

  @override
  Future<void> pair(TomWebSocketConnection socket, String nameplate) async {
    final peer = _SocketPeer(socket);
    final TomSecretsRelayChannel channel;
    try {
      channel = state.rendezvous.joinPair(nameplate, peer);
    } on TomSecretsRelayRefusal catch (e) {
      await socket.close(e.code, e.message);
      return;
    }
    await _carry(socket, peer, channel);
    state.rendezvous.leavePair(channel, peer);
  }

  @override
  Future<void> link(
    TomWebSocketConnection socket,
    Request request,
    String linkId,
  ) async {
    final peer = _SocketPeer(socket);
    final token = state.tokenOf(request);
    final TomSecretsRelayChannel channel;
    try {
      channel = state.rendezvous.joinLink(linkId, token, peer);
    } on TomSecretsRelayRefusal catch (e) {
      await socket.close(e.code, e.message);
      return;
    }
    await _carry(socket, peer, channel);
    state.rendezvous.leaveLink(channel, token, peer);
  }

  /// Forwards [socket]'s binary frames through [channel] until either side
  /// ends.
  Future<void> _carry(
    TomWebSocketConnection socket,
    _SocketPeer peer,
    TomSecretsRelayChannel channel,
  ) async {
    try {
      await for (final message in socket.messages) {
        if (peer.closed || channel.ended) break;
        if (message is List<int>) {
          channel.forward(peer, message);
        } else {
          await peer.close(
            TomSecretsRelayClose.notBinary,
            'the relay carries binary frames only',
          );
          break;
        }
      }
    } on Object {
      // A connection that broke is a side that left.
    }
  }

  @override
  Future<Response> put(
    Request request,
    String recipient,
    String itemId,
  ) => _answer(() async {
    final token = state.tokenOf(request);
    if (_config.mode == TomSecretsRelayMode.token && token == null) {
      return jsonError(
        401,
        'this relay accepts mailbox items only from holders of an '
        'instance token: add the token to the relay in the app\'s relay '
        'settings (the operator sets the tokens under relay.tokens, or '
        'relay.mode: open)',
      );
    }
    final expiresText = request.headers['tsm-expires'];
    final expires = expiresText == null ? null : DateTime.tryParse(expiresText);
    if (expires == null) {
      return jsonError(400, 'Tsm-Expires is missing or no ISO 8601 date-time');
    }
    final length = request.contentLength;
    if (length != null && length > _config.itemBytes) {
      await _discardBody(request, 4 * _config.itemBytes);
      return jsonError(413, 'an item has at most ${_config.itemBytes} bytes');
    }
    await state.limit(
      'puts',
      token ?? state.addressOf(request),
      _config.putsPerHour,
      const Duration(hours: 1),
      token == null
          ? 'puts per address per hour'
          : 'puts per instance token per hour',
    );
    final bytes = await _readBody(request, _config.itemBytes);
    await state.mailbox.put(recipient, itemId, bytes, expires.toUtc());
    tomLog.info(
      'relay: put ${bytes.length} bytes for '
      '${tomSecretsRelayShortRecipient(recipient)}'
      '${token == null ? '' : ' (token $token)'}',
    );
    return _json({'id': itemId}, status: 201);
  });

  @override
  Future<Response> challenge(Request request, String recipient) =>
      _answer(() async {
        final body = await _readBody(request, 8 * 1024);
        final file = await state.proofs.challenge(
          recipient,
          utf8.decode(body, allowMalformed: true),
        );
        return Response.ok(
          file,
          headers: {'content-type': 'application/octet-stream'},
        );
      });

  Future<Response> _proven(
    Request request,
    String recipient,
    Future<Response> Function() body,
  ) => _answer(() async {
    if (!tomSecretsRelayIsRecipient(recipient)) {
      return jsonError(400, 'not a recipient id');
    }
    if (!state.proofs.verify(
      recipient,
      TomSecretsRelayState.bearerOf(request),
    )) {
      return jsonError(
        401,
        'the mailbox needs the recipient\'s proof: POST '
        '/v1/mailbox/<recipient>/challenge, then the decrypted token as '
        'Authorization: Bearer',
      );
    }
    return body();
  });

  @override
  Future<Response> list(Request request, String recipient) =>
      _proven(request, recipient, () async {
        final items = await state.mailbox.list(recipient);
        return _json({
          'items': [for (final i in items) i.toJson()],
        });
      });

  @override
  Future<Response> fetch(Request request, String recipient, String itemId) =>
      _proven(request, recipient, () async {
        final bytes = await state.mailbox.fetch(recipient, itemId);
        if (bytes == null) return jsonError(404, 'no item $itemId');
        return Response.ok(
          bytes,
          headers: {'content-type': 'application/octet-stream'},
        );
      });

  @override
  Future<Response> delete(Request request, String recipient, String itemId) =>
      _proven(request, recipient, () async {
        if (!await state.mailbox.delete(recipient, itemId)) {
          return jsonError(404, 'no item $itemId');
        }
        tomLog.info(
          'relay: ${tomSecretsRelayShortRecipient(recipient)} deleted an item',
        );
        return Response(204);
      });

  /// Reads and drops [request]'s body when it is at most [limit] bytes, so
  /// the client, still sending, reads the refusal instead of a closed
  /// connection; a larger one is left (the connection is closed with the
  /// answer).
  static Future<void> _discardBody(Request request, int limit) async {
    final length = request.contentLength;
    if (length == null || length > limit) return;
    await request.read().drain<void>();
  }

  /// The body of [request], at most [limit] bytes (413 past it).
  ///
  /// Past the limit the rest is read and dropped, up to four times the
  /// limit, so a client still sending reads the refusal rather than a
  /// closed connection; past that the connection is closed with it.
  static Future<Uint8List> _readBody(Request request, int limit) async {
    final builder = BytesBuilder(copy: false);
    var seen = 0;
    await for (final chunk in request.read()) {
      seen += chunk.length;
      if (seen <= limit) {
        builder.add(chunk);
      } else if (seen > 4 * limit) {
        break;
      }
    }
    if (seen > limit) {
      throw TomSecretsRelayRefused(413, 'at most $limit bytes');
    }
    return builder.takeBytes();
  }
}

/// A WebSocket connection as a side of a channel.
final class _SocketPeer implements TomSecretsRelayPeer {
  _SocketPeer(this.socket);

  final TomWebSocketConnection socket;
  bool closed = false;

  @override
  void send(List<int> bytes) {
    if (closed) return;
    try {
      socket.sendBytes(bytes);
    } on Object {
      closed = true;
    }
  }

  @override
  Future<void> close(int code, String reason) async {
    if (closed) return;
    closed = true;
    try {
      await socket.close(code, reason);
    } on Object {
      // Gone already.
    }
  }
}
