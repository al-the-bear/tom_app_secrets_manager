// Copyright (c) 2026 Peter Nicolai Alexis Kyaw
// SPDX-License-Identifier: BSD-3-Clause

/// The browser host (part-browser): native messaging's framing, the caller's
/// origin (only the product's extensions), the extension's requests against
/// a fake service (status, match, a fill only of an entry the page matches,
/// propose, openApp), refusals passed on with their kind, and the run until
/// the browser closes the port. Demo data only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_secrets_browser/tom_secrets_browser.dart';
import 'package:tom_secrets_client/admin.dart'
    show tomSecretsChromiumDevelopmentId, tomSecretsFirefoxExtensionId;
import 'package:tom_secrets_client/tom_secrets_client.dart';

final class _Service implements TomSecretsBrowserService {
  bool running = true;
  bool locked = false;
  final Map<String, List<TomSecretsLoginCandidate>> logins = {};
  final Map<String, Map<String, String>> stored = {};
  final List<List<String>> reads = [];
  final List<Map<String, String?>> proposals = [];
  final List<bool> waits = [];
  bool closed = false;

  Never _notRunning() => throw TomSecretsClientException(
    TomSecretsErrorKind.notRunning,
    'no service',
  );

  @override
  Future<void> open() async {
    if (!running) _notRunning();
  }

  @override
  Future<List<TomSecretsLoginCandidate>> match(
    String url, {
    String? frameUrl,
    bool wait = true,
  }) async {
    waits.add(wait);
    if (!running) _notRunning();
    if (locked) {
      throw TomSecretsClientException(TomSecretsErrorKind.locked, 'locked');
    }
    return logins[Uri.parse(frameUrl ?? url).host] ?? const [];
  }

  @override
  Future<List<String>> values(String entryId, List<String> fields) async {
    reads.add([entryId, ...fields]);
    return [for (final f in fields) stored[entryId]![f]!];
  }

  @override
  Future<bool> propose({
    required String url,
    required String userName,
    required String password,
    String? title,
  }) async {
    proposals.add({
      'url': url,
      'userName': userName,
      'password': password,
      'title': title,
    });
    return false;
  }

  @override
  Future<void> close() async => closed = true;
}

const _mail = TomSecretsLoginCandidate(
  entryId: 'team/~0123456789abcdef0123456789abcdef',
  title: 'Mail',
  userName: 'demo-user',
  matchedUrl: 'https://mail.example.com',
  hasTotp: true,
);

void main() {
  const chromiumOrigin = 'chrome-extension://$tomSecretsChromiumDevelopmentId/';
  late _Service service;
  late List<(String, List<String>)> started;
  late Directory app;
  late TomSecretsBrowserHost host;

  setUp(() {
    service = _Service()
      ..logins['mail.example.com'] = [_mail]
      ..stored[_mail.entryId] = {
        'UserName': 'demo-user',
        'Password': 'demo-mail-pw',
        'totp': '123456',
      };
    started = [];
    app = Directory.systemTemp.createTempSync('tsm_browser_app');
    File('${app.path}/tom_secrets_app').writeAsStringSync('');
    host = TomSecretsBrowserHost(
      service,
      launcher: TomSecretsAppLauncher(
        appExecutable: '${app.path}/tom_secrets_app',
        operatingSystem: 'linux',
        start: (exe, args) async => started.add((exe, args)),
      ),
    );
  });
  tearDown(() => app.deleteSync(recursive: true));

  group('framing', () {
    test('a frame is the length in the machine\'s byte order, then JSON', () {
      final frame = tomSecretsBrowserFrame({'op': 'status'});
      final length = ByteData.sublistView(frame).getUint32(0, Endian.host);
      expect(length, frame.length - 4);
      expect(jsonDecode(utf8.decode(frame.sublist(4))), {'op': 'status'});
    });

    test('messages split over chunks and several in one chunk', () async {
      final a = tomSecretsBrowserFrame({'id': 1});
      final b = tomSecretsBrowserFrame({'id': 2});
      final all = [...a, ...b];
      final chunks = [all.sublist(0, 3), all.sublist(3, 9), all.sublist(9)];
      expect(
        await tomSecretsBrowserMessages(Stream.fromIterable(chunks)).toList(),
        [
          {'id': 1},
          {'id': 2},
        ],
      );
    });

    test('an answer over 1 MB is refused; a request over the limit, a cut '
        'frame or a non-object ends the stream', () async {
      expect(
        () => tomSecretsBrowserFrame({'x': 'a' * (1024 * 1024)}),
        throwsA(isA<TomSecretsBrowserFrameException>()),
      );
      Uint8List raw(List<int> body) {
        final f = Uint8List(4 + body.length);
        ByteData.sublistView(f).setUint32(0, body.length, Endian.host);
        f.setRange(4, f.length, body);
        return f;
      }

      for (final input in [
        raw(List.filled(tomSecretsBrowserMaxRequest + 1, 32)),
        tomSecretsBrowserFrame({'id': 1}).sublist(0, 6),
        raw(utf8.encode('[1, 2]')),
        raw(utf8.encode('not json')),
      ]) {
        await expectLater(
          tomSecretsBrowserMessages(Stream.value(input)).toList(),
          throwsA(isA<TomSecretsBrowserFrameException>()),
        );
      }
    });
  });

  group('the caller', () {
    test('Chromium passes the origin first (Windows adds the parent window); '
        'Firefox the manifest and the id', () {
      final chromium = TomSecretsBrowserCaller.fromArguments([
        chromiumOrigin,
        '--parent-window=0',
      ])!;
      expect(chromium.family, TomSecretsBrowserFamily.chromium);
      expect(chromium.extensionId, tomSecretsChromiumDevelopmentId);
      expect(chromium.isProducts, isTrue);
      expect(chromium.clientName, contains('a Chromium browser'));

      final firefox = TomSecretsBrowserCaller.fromArguments([
        '/home/demo/.mozilla/native-messaging-hosts/net.tom.secrets.json',
        tomSecretsFirefoxExtensionId,
      ])!;
      expect(firefox.family, TomSecretsBrowserFamily.firefox);
      expect(firefox.isProducts, isTrue);
    });

    test('another extension, or no browser at all, is not served', () {
      expect(
        TomSecretsBrowserCaller.fromArguments([
          'chrome-extension://abcdefghijklmnopabcdefghijklmnop/',
        ])!.isProducts,
        isFalse,
      );
      expect(
        TomSecretsBrowserCaller.fromArguments([
          '/x/net.tom.secrets.json',
          'other@example.com',
        ])!.isProducts,
        isFalse,
      );
      expect(TomSecretsBrowserCaller.fromArguments(const []), isNull);
    });
  });

  group('the requests', () {
    test('status: running, locked or not running', () async {
      expect(
        (await host.handle({'id': 1, 'op': 'status'}))['state'],
        'running',
      );
      service.locked = true;
      expect((await host.handle({'id': 2, 'op': 'status'}))['state'], 'locked');
      service.running = false;
      expect(await host.handle({'id': 3, 'op': 'status'}), {
        'id': 3,
        'op': 'status',
        'state': 'not_running',
      });
    });

    test('match answers the candidates and never a value', () async {
      final answer = await host.handle({
        'id': 'm',
        'op': 'match',
        'url': 'https://mail.example.com/login',
      });
      expect(answer['id'], 'm');
      final candidates = (answer['candidates']! as List).cast<Map>();
      expect(candidates.single, {
        'entryId': _mail.entryId,
        'title': 'Mail',
        'userName': 'demo-user',
        'matchedUrl': 'https://mail.example.com',
        'hasTotp': true,
      });
      expect(jsonEncode(answer), isNot(contains('demo-mail-pw')));
    });

    test(
      'match waits for an unlock unless the extension says wait: false',
      () async {
        await host.handle({
          'id': 1,
          'op': 'match',
          'url': 'https://a.example/',
        });
        await host.handle({
          'id': 2,
          'op': 'match',
          'url': 'https://a.example/',
          'wait': true,
        });
        await host.handle({
          'id': 3,
          'op': 'match',
          'url': 'https://a.example/',
          'wait': false,
        });
        expect(service.waits, [true, true, false]);
      },
    );

    test('check tells new, changed, known and unknown and never answers a '
        'value', () async {
      Future<Map<String, Object?>> check(Map<String, Object?> args) =>
          host.handle({'id': 9, 'op': 'check', ...args});
      const url = 'https://mail.example.com/login';
      expect(
        (await check({
          'url': url,
          'userName': 'someone-else',
          'password': 'x',
        }))['state'],
        'new',
      );
      expect(
        (await check({
          'url': 'https://shop.example.org/',
          'userName': 'demo-user',
          'password': 'x',
        }))['state'],
        'new',
      );
      final known = await check({
        'url': url,
        'userName': 'demo-user',
        'password': 'demo-mail-pw',
      });
      expect(known['state'], 'known');
      expect(known['entryId'], _mail.entryId);
      final changed = await check({
        'url': url,
        'userName': 'demo-user',
        'password': 'demo-mail-pw-2',
      });
      expect(changed, {
        'id': 9,
        'op': 'check',
        'state': 'changed',
        'entryId': _mail.entryId,
        'userName': 'demo-user',
      });
      expect(jsonEncode([known, changed]), isNot(contains('demo-mail-pw')));
      // A change form without the user name: the page's one login.
      expect(
        (await check({'url': url, 'password': 'demo-mail-pw-2'}))['state'],
        'changed',
      );
      expect(
        ((await check({'url': url, 'userName': 'demo-user'}))['error']!
            as Map)['kind'],
        'malformed',
      );
      service.locked = true;
      expect(
        (await check({
          'url': url,
          'userName': 'demo-user',
          'password': 'x',
        }))['state'],
        'unknown',
      );
      expect(service.waits.last, isFalse, reason: 'a submit does not wait');
    });

    test('fill reads the values of an entry the page matches, the TOTP when '
        'asked', () async {
      final answer = await host.handle({
        'id': 2,
        'op': 'fill',
        'entryId': _mail.entryId,
        'url': 'https://mail.example.com/login',
        'totp': true,
      });
      expect(answer, {
        'id': 2,
        'op': 'fill',
        'userName': 'demo-user',
        'password': 'demo-mail-pw',
        'totp': '123456',
      });
      expect(service.reads.single, [
        _mail.entryId,
        'UserName',
        'Password',
        'totp',
      ]);
    });

    test('fill of an entry another site has is refused before any value is '
        'read', () async {
      final answer = await host.handle({
        'id': 3,
        'op': 'fill',
        'entryId': _mail.entryId,
        'url': 'https://evil.example.net/',
      });
      expect(answer['error'], {
        'kind': 'denied',
        'message': 'the entry is not a login of this page',
        'reason': 'not_matched',
      });
      expect(service.reads, isEmpty);
    });

    test('propose passes the login on; a missing field is malformed', () async {
      expect(
        await host.handle({
          'id': 4,
          'op': 'propose',
          'url': 'https://new.example.com/',
          'userName': 'demo',
          'password': 'demo-new-pw',
        }),
        {'id': 4, 'op': 'propose', 'accepted': true, 'known': false},
      );
      expect(service.proposals.single['password'], 'demo-new-pw');
      expect(
        (await host.handle({
          'id': 5,
          'op': 'propose',
          'url': 'https://x/',
        }))['error'],
        containsPair('reason', 'password'),
      );
      expect(
        (await host.handle({'id': 6, 'op': 'nope'}))['error'],
        containsPair('kind', 'malformed'),
      );
    });

    test('openApp starts the desktop app at the entry', () async {
      expect(
        await host.handle({'id': 7, 'op': 'openApp', 'entryId': _mail.entryId}),
        {'id': 7, 'op': 'openApp', 'opened': true},
      );
      expect(started.single.$1, '${app.path}/tom_secrets_app');
      expect(started.single.$2, ['--show-entry', _mail.entryId]);
      File('${app.path}/tom_secrets_app').deleteSync();
      expect(
        (await host.handle({'id': 8, 'op': 'openApp'}))['error'],
        containsPair('reason', 'no_app'),
      );
    });

    test('macOS opens the app bundle through Launch Services', () async {
      final bundle = Directory('${app.path}/X.app/Contents/MacOS')
        ..createSync(recursive: true);
      File('${bundle.path}/tom_secrets_app').writeAsStringSync('');
      final mac = TomSecretsAppLauncher(
        appExecutable: '${bundle.path}/tom_secrets_app',
        operatingSystem: 'macos',
        start: (exe, args) async => started.add((exe, args)),
      );
      expect(await mac.open(entry: 'team/~ab'), isTrue);
      expect(started.single.$1, 'open');
      expect(started.single.$2, [
        '-n',
        '-a',
        '${app.path}/X.app',
        '--args',
        '--show-entry',
        'team/~ab',
      ]);
    });
  });

  group('the run', () {
    Future<(int, List<Map<String, Object?>>)> run(
      List<String> arguments,
      List<Map<String, Object?>> requests,
    ) async {
      final output = StreamController<List<int>>();
      final answers = tomSecretsBrowserMessages(output.stream).toList();
      final code = await tomSecretsRunBrowserHost(
        arguments,
        input: Stream.fromIterable([
          for (final r in requests) tomSecretsBrowserFrame(r),
        ]),
        output: output.sink,
        serviceFor: (_) => service,
        hostFor: (_) => host,
      );
      await output.close();
      return (code, await answers);
    }

    test('answers each request in order until the browser closes the port, '
        'then closes the connection', () async {
      final (code, answers) = await run(
        [chromiumOrigin],
        [
          {'id': 1, 'op': 'status'},
          {'id': 2, 'op': 'match', 'url': 'https://mail.example.com/'},
        ],
      );
      expect(code, 0);
      expect(answers.map((a) => a['id']), [1, 2]);
      expect(service.closed, isTrue);
    });

    test('another extension gets one refusal and the host ends', () async {
      final (code, answers) = await run(
        ['chrome-extension://abcdefghijklmnopabcdefghijklmnop/'],
        [
          {'id': 1, 'op': 'match', 'url': 'https://mail.example.com/'},
        ],
      );
      expect(code, 1);
      expect(answers.single['error'], containsPair('reason', 'origin'));
    });
  });
}
