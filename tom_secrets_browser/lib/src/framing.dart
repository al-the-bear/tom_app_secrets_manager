// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// Native messaging's framing (the browsers' rule): each message is a 32-bit
/// length in the machine's byte order followed by that many bytes of UTF-8
/// JSON. A message to the browser is at most 1 MB; the extension's requests
/// are small, so one over [tomSecretsBrowserMaxRequest] ends the host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// The largest message the browser takes from a host (1 MB).
const int tomSecretsBrowserMaxAnswer = 1024 * 1024;

/// The largest request the host reads (64 KiB: a URL, a login).
const int tomSecretsBrowserMaxRequest = 64 * 1024;

/// A frame that breaks the rule.
final class TomSecretsBrowserFrameException implements Exception {
  /// The problem described by [message].
  const TomSecretsBrowserFrameException(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => 'TomSecretsBrowserFrameException: $message';
}

/// [message] as one frame. Throws [TomSecretsBrowserFrameException] when it
/// is larger than the browser takes.
Uint8List tomSecretsBrowserFrame(Map<String, Object?> message) {
  final body = utf8.encode(jsonEncode(message));
  if (body.length > tomSecretsBrowserMaxAnswer) {
    throw TomSecretsBrowserFrameException(
      'a message of ${body.length} bytes is over the browser\'s 1 MB',
    );
  }
  final frame = Uint8List(4 + body.length);
  ByteData.sublistView(frame).setUint32(0, body.length, Endian.host);
  frame.setRange(4, frame.length, body);
  return frame;
}

/// The messages of [input], one JSON object per frame. A frame over
/// [maxLength], one that is not a JSON object, or input that ends inside a
/// frame is an error of the stream.
Stream<Map<String, Object?>> tomSecretsBrowserMessages(
  Stream<List<int>> input, {
  int maxLength = tomSecretsBrowserMaxRequest,
}) async* {
  final buffer = BytesBuilder(copy: false);
  var pending = Uint8List(0);
  await for (final chunk in input) {
    buffer.add(chunk);
    pending = Uint8List.fromList([...pending, ...buffer.takeBytes()]);
    while (pending.length >= 4) {
      final length = ByteData.sublistView(pending).getUint32(0, Endian.host);
      if (length > maxLength) {
        throw TomSecretsBrowserFrameException(
          'a request of $length bytes is over $maxLength',
        );
      }
      if (pending.length < 4 + length) break;
      final body = pending.sublist(4, 4 + length);
      pending = pending.sublist(4 + length);
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(body));
      } on FormatException {
        throw const TomSecretsBrowserFrameException('a request is not JSON');
      }
      if (decoded is! Map) {
        throw const TomSecretsBrowserFrameException(
          'a request is not a JSON object',
        );
      }
      yield decoded.cast<String, Object?>();
    }
  }
  if (pending.isNotEmpty) {
    throw const TomSecretsBrowserFrameException('the input ended in a frame');
  }
}
