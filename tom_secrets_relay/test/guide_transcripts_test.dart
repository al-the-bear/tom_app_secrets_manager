// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The transcripts of the relay's guide (`doc/user_guide.md`): each block
/// marked `<!-- transcript <name> -->` shows `curl -i` exchanges with a
/// relay started in this test (token mode, the default limits but a higher
/// per-second one), and this
/// test checks the guide still shows what the relay answers.
/// `TSM_UPDATE_TRANSCRIPTS=1 dart test test/guide_transcripts_test.dart`
/// writes them into the guide instead.
///
/// The relay's address is written as `https://relay.example.org` (behind
/// its reverse proxy), and what changes from run to run (a nameplate's
/// number, a time, a `Retry-After`) as fixed values, so a transcript
/// changes only when the relay's answers do. Demo data only.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_secrets_relay/tom_secrets_relay.dart';

import 'relay_harness.dart';

/// The guide the transcripts are in.
const guide = 'doc/user_guide.md';

/// The address the transcripts show.
const shownAddress = 'https://relay.example.org';

/// A demo recipient: 52 characters of the fingerprint's alphabet.
const demoRecipient = 'abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrst';

/// One exchange: [method] on [path] with [headers] and a [body].
final class Exchange {
  /// The exchange.
  const Exchange(this.method, this.path, {this.headers = const {}, this.body});

  /// The method.
  final String method;

  /// The path under the relay.
  final String path;

  /// Request headers shown and sent.
  final Map<String, String> headers;

  /// The body, as text.
  final String? body;

  /// The exchange as a `curl -i` line.
  String get line => [
    'curl -i',
    if (method != 'GET') '-X $method',
    for (final MapEntry(:key, :value) in headers.entries) "-H '$key: $value'",
    if (body != null) "--data '$body'",
    '$shownAddress$path',
  ].join(' ');
}

/// The sessions, by name.
final sessions = <String, List<Exchange>>{
  'health': [const Exchange('GET', '/health')],
  'pair': [const Exchange('POST', '/v1/pair')],
  'put-without-token': [
    const Exchange(
      'PUT',
      '/v1/mailbox/$demoRecipient/item-1',
      headers: {'Tsm-Expires': '2026-12-01T00:00:00Z'},
      body: 'age-encryption.org/v1',
    ),
  ],
  'list-without-proof': [const Exchange('GET', '/v1/mailbox/$demoRecipient')],
  'unknown-path': [const Exchange('GET', '/admin')],
};

/// [text] with the fenced block after `<!-- transcript [name] -->` replaced
/// by [body]; throws when the marker or its block is missing.
String replaceTranscript(String text, String name, String body) {
  final marker = '<!-- transcript $name -->';
  final at = text.indexOf(marker);
  if (at < 0) throw StateError('$guide has no $marker');
  final open = text.indexOf('```text\n', at);
  final close = open < 0 ? -1 : text.indexOf('\n```', open + 7);
  if (open < 0 ||
      close < 0 ||
      text.substring(at + marker.length, open).trim().isNotEmpty) {
    throw StateError('$marker is not followed by a ```text block');
  }
  return '${text.substring(0, open + 8)}$body${text.substring(close)}';
}

/// An answer's [text] with a nameplate's number as 42, every time as
/// `2026-11-24T09:10:00.000Z` and a `Retry-After` as 3600.
String normalize(String text) => text
    .replaceAll(RegExp(r'"nameplate":"\d+"'), '"nameplate":"42"')
    .replaceAll(
      RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z'),
      '2026-11-24T09:10:00.000Z',
    )
    .replaceAll(RegExp(r'retry-after: \d+'), 'retry-after: 3600');

/// The status line, the headers an operator looks at and the body.
String answer(({int status, HttpHeaders headers, List<int> body}) r) => [
  'HTTP/1.1 ${r.status}',
  if (r.headers.contentType case final type?) 'content-type: $type',
  if (r.headers.value('retry-after') case final after?) 'retry-after: $after',
  if (r.body.isNotEmpty) ...['', utf8.decode(r.body)],
].join('\n');

/// Checks (or writes) [name]'s block from [body].
String check(String text, String name, String body, bool update) {
  final updated = replaceTranscript(text, name, body);
  if (!update) {
    expect(
      updated,
      text,
      reason:
          'the transcript $name changed: run TSM_UPDATE_TRANSCRIPTS=1 '
          'dart test test/guide_transcripts_test.dart',
    );
  }
  return updated;
}

void main() {
  test('the guide shows what the relay answers', () async {
    final relay = await RelayHarness.start(
      const TomSecretsRelayConfig(
        tokens: {'team-a': 'demo-team-a-token-0123456789'},
        // The eleven nameplates below come at once; the per-second
        // denial-of-service limit would block the address before the
        // nameplate limit answers.
        requestsPerSecond: 1000,
      ),
    );
    addTearDown(relay.stop);
    final file = File(guide);
    var text = file.readAsStringSync();
    final update = Platform.environment['TSM_UPDATE_TRANSCRIPTS'] == '1';

    Future<String> run(List<Exchange> exchanges) async {
      final out = StringBuffer();
      for (final e in exchanges) {
        final r = await relay.send(
          e.method,
          e.path,
          headers: e.headers,
          body: e.body == null ? null : utf8.encode(e.body!),
        );
        out
          ..writeln('\$ ${e.line}')
          ..writeln(normalize(answer(r)));
      }
      return out.toString().trimRight();
    }

    for (final MapEntry(key: name, value: exchanges) in sessions.entries) {
      text = check(text, name, await run(exchanges), update);
    }

    // The eleventh nameplate within the hour from one address.
    for (var i = 0; i < 10; i++) {
      await relay.send('POST', '/v1/pair');
    }
    text = check(
      text,
      'rate-limited',
      await run([const Exchange('POST', '/v1/pair')]),
      update,
    );
    if (update) file.writeAsStringSync(text);
  });

  test('nameplates, times and Retry-After are normalized', () {
    expect(
      normalize('"nameplate":"317" 2027-01-02T03:04:05Z retry-after: 12'),
      '"nameplate":"42" 2026-11-24T09:10:00.000Z retry-after: 3600',
    );
  });
}
